import Flutter
import UIKit
import HealthKit
import BackgroundTasks

public class HealthBgSyncPlugin: NSObject, FlutterPlugin, URLSessionDelegate, URLSessionTaskDelegate {

    // MARK: - State
    internal let healthStore = HKHealthStore()
    internal var session: URLSession!
    internal var endpoint: URL?
    internal var token: String?
    internal var trackedTypes: [HKSampleType] = []
    internal var chunkSize: Int = 1000 // Configurable chunk size to prevent HTTP 413 errors
    internal var backgroundChunkSize: Int = 100 // Smaller chunk size for background operations

    // Per-endpoint state (anchors + full-export-done flag)
    internal let defaults = UserDefaults(suiteName: "com.healthbgsync.state") ?? .standard

    // Observer queries for background delivery
    internal var activeObserverQueries: [HKObserverQuery] = []

    // Background session identifier
    internal let bgSessionId = "com.healthbgsync.upload.session"

    // BGTask identifiers (MUST be present in Info.plist -> BGTaskSchedulerPermittedIdentifiers)
    internal let refreshTaskId  = "com.healthbgsync.task.refresh"
    internal let processTaskId  = "com.healthbgsync.task.process"

    // AppDelegate will pass its background completion handler here
    internal static var bgCompletionHandler: (() -> Void)?

    // MARK: - Flutter registration
    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "health_bg_sync", binaryMessenger: registrar.messenger())
        let instance = HealthBgSyncPlugin()
        registrar.addMethodCallDelegate(instance, channel: channel)
    }

    // Call from AppDelegate.handleEventsForBackgroundURLSession
    public static func setBackgroundCompletionHandler(_ handler: @escaping () -> Void) {
        HealthBgSyncPlugin.bgCompletionHandler = handler
    }

    // MARK: - Init
    override init() {
        super.init()
        let cfg = URLSessionConfiguration.background(withIdentifier: bgSessionId)
        cfg.isDiscretionary = false
        cfg.waitsForConnectivity = true
        self.session = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)

        // Register BGTasks (iOS 13+)
        if #available(iOS 13.0, *) {
            BGTaskScheduler.shared.register(forTaskWithIdentifier: refreshTaskId, using: nil) { [weak self] task in
                self?.handleAppRefresh(task: task as! BGAppRefreshTask)
            }
            BGTaskScheduler.shared.register(forTaskWithIdentifier: processTaskId, using: nil) { [weak self] task in
                self?.handleProcessing(task: task as! BGProcessingTask)
            }
        }
    }

    // MARK: - MethodChannel
    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {

        case "initialize":
            guard let args = call.arguments as? [String: Any],
                  let endpointStr = args["endpoint"] as? String,
                  let token = args["token"] as? String,
                  let types = args["types"] as? [String] else {
                result(FlutterError(code: "bad_args", message: "Missing args", details: nil))
                return
            }
            self.endpoint = URL(string: endpointStr)
            self.token = token
            self.trackedTypes = mapTypes(types)
            
            // Configure chunk size if provided (default: 1000)
            if let chunkSizeArg = args["chunkSize"] as? Int, chunkSizeArg > 0 {
                self.chunkSize = chunkSizeArg
            }

            print("✅ Initialized for endpointKey=\(endpointKey()) types=\(trackedTypes.map{$0.identifier}) chunkSize=\(chunkSize)")

            // Retry pending outbox items (if any)
            retryOutboxIfPossible()

            // If no full export was done for this endpoint yet — perform it
            initialSyncKickoff { result(nil) }

        case "requestAuthorization":
            requestAuthorization { ok in result(ok) }

        case "syncNow":
            // Manual incremental sync (does not trigger full export)
            self.syncAll(fullExport: false) { result(nil) }

        case "startBackgroundSync":
            // Register observers and perform initial sync (full only for types without an anchor)
            self.startBackgroundDelivery()
            self.initialSyncKickoff { }
            // Schedule fallback BG tasks
            self.scheduleAppRefresh()
            self.scheduleProcessing()
            result(nil)

        case "stopBackgroundSync":
            self.stopBackgroundDelivery()
            self.cancelAllBGTasks()
            result(nil)

        case "resetAnchors":
            self.resetAllAnchors()
            result(nil)

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - Authorization
    internal func requestAuthorization(completion: @escaping (Bool)->Void) {
        guard HKHealthStore.isHealthDataAvailable() else { 
            DispatchQueue.main.async { completion(false) }
            return 
        }
        
        // Filter out correlation types - they cannot be requested for authorization
        // Correlation types are automatically available when component types are authorized
        let toRead = Set(trackedTypes.filter { !($0 is HKCorrelationType) })
        
        healthStore.requestAuthorization(toShare: nil, read: toRead) { ok, _ in
            DispatchQueue.main.async { completion(ok) }
        }
    }

    // MARK: - Sync (all / single)
    internal func syncAll(fullExport: Bool, completion: @escaping ()->Void) {
        guard !trackedTypes.isEmpty else { completion(); return }
        
        // Collect data from all types and send together
        collectAllData(fullExport: fullExport, completion: completion)
    }
    
    // MARK: - Combined data collection and sync
    internal func collectAllData(fullExport: Bool, completion: @escaping ()->Void) {
        collectAllData(fullExport: fullExport, isBackground: false, completion: completion)
    }
    
    internal func collectAllData(fullExport: Bool, isBackground: Bool, completion: @escaping ()->Void) {
        let allSamples = NSMutableArray()
        let allAnchors = NSMutableDictionary()
        let group = DispatchGroup()
        let lock = NSLock()
        
        // Use smaller chunk size for background operations
        let currentChunkSize = isBackground ? backgroundChunkSize : chunkSize
        
        // Process all types concurrently but with proper thread management
        for type in trackedTypes {
            group.enter()
            let anchor = fullExport ? nil : loadAnchor(for: type)
            
            let query = HKAnchoredObjectQuery(type: type, predicate: nil, anchor: anchor, limit: currentChunkSize) {
                [weak self] _, samplesOrNil, deletedObjects, newAnchor, error in
                guard let self = self else { 
                    group.leave()
                    return 
                }
                guard error == nil else { 
                    group.leave()
                    return 
                }
                
                let samples = samplesOrNil ?? []
                // Thread-safe access to shared data
                lock.lock()
                allSamples.addObjects(from: samples)
                if let newAnchor = newAnchor {
                    allAnchors[type.identifier] = newAnchor
                }
                lock.unlock()
                group.leave()
            }
            healthStore.execute(query)
        }
        
        // Use notify instead of wait to avoid blocking the main thread
        group.notify(queue: .main) { [weak self] in
            guard let self = self else { completion(); return }
            
            // If no data, we're done
            guard allSamples.count > 0 else { completion(); return }
            guard let endpoint = self.endpoint, let token = self.token else { completion(); return }
            
            // Convert back to proper types
            let samples = allSamples.compactMap { $0 as? HKSample }
            var anchors: [String: HKQueryAnchor] = [:]
            for (key, value) in allAnchors {
                if let keyString = key as? String, let anchor = value as? HKQueryAnchor {
                    anchors[keyString] = anchor
                }
            }
            
            // Create combined payload
            let payload = self.serializeCombined(samples: samples, anchors: anchors)
            
            // Send combined data
            self.enqueueCombinedUpload(payload: payload, anchors: anchors, endpoint: endpoint, token: token) {
                // If we got currentChunkSize samples from any type, there might be more data
                let hasMoreData = samples.count >= currentChunkSize
                if hasMoreData {
                    // Continue with next chunk
                    self.collectAllData(fullExport: false, isBackground: isBackground, completion: completion)
                } else {
                    completion()
                }
            }
        }
    }

    internal func syncType(_ type: HKSampleType, fullExport: Bool, completion: @escaping ()->Void) {
        let anchor = fullExport ? nil : loadAnchor(for: type)
        
        let query = HKAnchoredObjectQuery(type: type, predicate: nil, anchor: anchor, limit: chunkSize) {
            [weak self] _, samplesOrNil, deletedObjects, newAnchor, error in
            guard let self = self else { completion(); return }
            guard error == nil else { completion(); return }

            let samples = samplesOrNil ?? []
            // Nothing to send if empty
            guard !samples.isEmpty else { completion(); return }
            guard let endpoint = self.endpoint, let token = self.token else { completion(); return }

            let payload = self.serialize(samples: samples, type: type)
            self.enqueueBackgroundUpload(payload: payload, type: type, candidateAnchor: newAnchor, endpoint: endpoint, token: token) {
                // If we got exactly chunkSize samples, there might be more - continue syncing
                if samples.count == self.chunkSize {
                    // Recursively continue with the new anchor
                    self.syncType(type, fullExport: false, completion: completion)
                } else {
                    // We got fewer than chunkSize, so we're done
                    completion()
                }
            }
        }
        healthStore.execute(query)
    }
    
    // MARK: - Background-optimized sync
    internal func syncTypeBackground(_ type: HKSampleType, fullExport: Bool, completion: @escaping ()->Void) {
        let anchor = fullExport ? nil : loadAnchor(for: type)
        
        let query = HKAnchoredObjectQuery(type: type, predicate: nil, anchor: anchor, limit: backgroundChunkSize) {
            [weak self] _, samplesOrNil, deletedObjects, newAnchor, error in
            guard let self = self else { completion(); return }
            guard error == nil else { completion(); return }

            let samples = samplesOrNil ?? []
            // Nothing to send if empty
            guard !samples.isEmpty else { completion(); return }
            guard let endpoint = self.endpoint, let token = self.token else { completion(); return }

            let payload = self.serialize(samples: samples, type: type)
            self.enqueueBackgroundUpload(payload: payload, type: type, candidateAnchor: newAnchor, endpoint: endpoint, token: token) {
                // If we got backgroundChunkSize samples, there might be more - continue syncing
                if samples.count == self.backgroundChunkSize {
                    // Recursively continue with the new anchor
                    self.syncTypeBackground(type, fullExport: false, completion: completion)
                } else {
                    // We got fewer than backgroundChunkSize, so we're done
                    completion()
                }
            }
        }
        healthStore.execute(query)
    }
    
    // MARK: - Background-safe sync (for use in background tasks)
    internal func syncTypeWithTimeout(_ type: HKSampleType, fullExport: Bool, timeout: TimeInterval = 20, completion: @escaping ()->Void) {
        let group = DispatchGroup()
        group.enter()
        
        syncType(type, fullExport: fullExport) {
            group.leave()
        }
        
        // Wait with timeout
        let result = group.wait(timeout: .now() + timeout)
        if result == .timedOut {
            print("⚠️ Sync timeout for \(type.identifier)")
        }
        completion()
    }
}

// MARK: - Array extension for chunking
extension Array {
    func chunked(into size: Int) -> [[Element]] {
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
