import Flutter
import UIKit
import HealthKit
import BackgroundTasks
import Network

@objc(OpenWearablesHealthSdkPlugin) public class OpenWearablesHealthSdkPlugin: NSObject, FlutterPlugin, FlutterStreamHandler, URLSessionDelegate, URLSessionTaskDelegate, URLSessionDataDelegate {

    // MARK: - Configuration State
    internal var host: String?
    
    // MARK: - User State (loaded from Keychain)
    internal var userId: String? { OpenWearablesHealthSdkKeychain.getUserId() }
    internal var accessToken: String? { OpenWearablesHealthSdkKeychain.getAccessToken() }
    internal var refreshToken: String? { OpenWearablesHealthSdkKeychain.getRefreshToken() }
    internal var apiKey: String? { OpenWearablesHealthSdkKeychain.getApiKey() }
    
    // Token refresh state (to avoid concurrent refreshes)
    private var isRefreshingToken = false
    private let tokenRefreshLock = NSLock()
    private var tokenRefreshCallbacks: [(Bool) -> Void] = []
    
    // MARK: - Auth Helpers
    
    /// Whether the SDK is using API key authentication (vs token-based).
    internal var isApiKeyAuth: Bool {
        return apiKey != nil && accessToken == nil
    }
    
    /// Returns the current auth credential (accessToken or apiKey), whichever is active.
    internal var authCredential: String? {
        return accessToken ?? apiKey
    }
    
    /// Returns true if the user has any valid auth credential.
    internal var hasAuth: Bool {
        return authCredential != nil
    }
    
    /// Applies the correct auth header to a URLRequest based on the current auth mode.
    internal func applyAuth(to request: inout URLRequest) {
        if let token = accessToken {
            request.setValue(token, forHTTPHeaderField: "Authorization")
        } else if let key = apiKey {
            request.setValue(key, forHTTPHeaderField: "X-Open-Wearables-API-Key")
        }
    }
    
    /// Applies the correct auth header using an explicit credential string.
    /// Uses API key header if in API key mode, otherwise Authorization header.
    internal func applyAuth(to request: inout URLRequest, credential: String) {
        if isApiKeyAuth {
            request.setValue(credential, forHTTPHeaderField: "X-Open-Wearables-API-Key")
        } else {
            request.setValue(credential, forHTTPHeaderField: "Authorization")
        }
    }
    
    // MARK: - HealthKit State
    internal let healthStore = HKHealthStore()
    internal var session: URLSession!
    internal var foregroundSession: URLSession!
    internal var trackedTypes: [HKSampleType] = []
    internal var chunkSize: Int = 1000
    internal var backgroundChunkSize: Int = 100
    internal var recordsPerChunk: Int = 2000
    
    // Debouncing
    private var pendingSyncWorkItem: DispatchWorkItem?
    private let syncDebounceQueue = DispatchQueue(label: "health_sync_debounce")
    private var observerBgTask: UIBackgroundTaskIdentifier = .invalid
    
    // Sync flags
    internal var isInitialSyncInProgress = false
    private var isSyncing: Bool = false
    private var syncCancelled: Bool = false
    private let syncLock = NSLock()
    
    // Network monitoring
    private var networkMonitor: NWPathMonitor?
    private let networkMonitorQueue = DispatchQueue(label: "health_sync_network_monitor")
    private var wasDisconnected = false
    
    // Protected data monitoring
    private var protectedDataObserver: NSObjectProtocol?
    internal var pendingSyncAfterUnlock = false

    // Per-user state (anchors)
    internal let defaults = UserDefaults(suiteName: "com.openwearables.healthsdk.state") ?? .standard

    // Observer queries
    internal var activeObserverQueries: [HKObserverQuery] = []

    // Background session
    internal let bgSessionId = "com.openwearables.healthsdk.upload.session"

    // BGTask identifiers
    internal let refreshTaskId  = "com.openwearables.healthsdk.task.refresh"
    internal let processTaskId  = "com.openwearables.healthsdk.task.process"

    internal static var bgCompletionHandler: (() -> Void)?
    
    // Log event sink
    private var logEventSink: FlutterEventSink?
    private var logEventChannel: FlutterEventChannel?
    
    // Auth error event sink (for 401 handling)
    internal var authErrorEventSink: FlutterEventSink?
    private var authErrorEventChannel: FlutterEventChannel?

    // Background response data buffer
    internal var backgroundDataBuffer: [Int: Data] = [:]
    private let bufferLock = NSLock()

    // MARK: - API Endpoints
    
    /// Base URL for all API calls: `{host}/api/v1`
    internal var apiBaseUrl: String? {
        guard let host = host else { return nil }
        let h = host.hasSuffix("/") ? String(host.dropLast()) : host
        return "\(h)/api/v1"
    }
    
    /// Endpoint to upload health data for the current user.
    /// Uses `{host}/api/v1/sdk/users/{userId}/sync/apple`.
    internal var syncEndpoint: URL? {
        guard let userId = userId else { return nil }
        guard let base = apiBaseUrl else { return nil }
        return URL(string: "\(base)/sdk/users/\(userId)/sync/apple")
    }

    // MARK: - Flutter registration
    @objc public static func register(with registrar: FlutterPluginRegistrar) {
        NSLog("[OpenWearablesHealthSdkPlugin] Registering plugin...")
        let channel = FlutterMethodChannel(name: "open_wearables_health_sdk", binaryMessenger: registrar.messenger())
        let instance = OpenWearablesHealthSdkPlugin()
        registrar.addMethodCallDelegate(instance, channel: channel)
        
        let logChannel = FlutterEventChannel(name: "open_wearables_health_sdk/logs", binaryMessenger: registrar.messenger())
        instance.logEventChannel = logChannel
        logChannel.setStreamHandler(instance)
        
        // Auth error channel for 401 handling
        let authErrorChannel = FlutterEventChannel(name: "open_wearables_health_sdk/auth_errors", binaryMessenger: registrar.messenger())
        instance.authErrorEventChannel = authErrorChannel
        authErrorChannel.setStreamHandler(AuthErrorStreamHandler(plugin: instance))
    }
    
    @objc public static func setBackgroundCompletionHandler(_ handler: @escaping () -> Void) {
        OpenWearablesHealthSdkPlugin.bgCompletionHandler = handler
    }

    // MARK: - Init
    override init() {
        super.init()
        
        let bgCfg = URLSessionConfiguration.background(withIdentifier: bgSessionId)
        bgCfg.isDiscretionary = false
        bgCfg.waitsForConnectivity = true
        self.session = URLSession(configuration: bgCfg, delegate: self, delegateQueue: nil)
        
        let fgCfg = URLSessionConfiguration.default
        fgCfg.timeoutIntervalForRequest = 120
        fgCfg.timeoutIntervalForResource = 600
        fgCfg.waitsForConnectivity = false
        self.foregroundSession = URLSession(configuration: fgCfg, delegate: nil, delegateQueue: OperationQueue.main)

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

        case "configure":
            handleConfigure(call: call, result: result)

        case "signIn":
            handleSignIn(call: call, result: result)
            
        case "signOut":
            handleSignOut(result: result)
            
        case "restoreSession":
            handleRestoreSession(result: result)
            
        case "isSessionValid":
            result(OpenWearablesHealthSdkKeychain.hasSession())
            
        case "isSyncActive":
            result(OpenWearablesHealthSdkKeychain.isSyncActive())
            
        case "updateTokens":
            handleUpdateTokens(call: call, result: result)
            
        case "getStoredCredentials":
            let credentials: [String: Any?] = [
                "userId": OpenWearablesHealthSdkKeychain.getUserId(),
                "accessToken": OpenWearablesHealthSdkKeychain.getAccessToken(),
                "refreshToken": OpenWearablesHealthSdkKeychain.getRefreshToken(),
                "apiKey": OpenWearablesHealthSdkKeychain.getApiKey(),
                "host": OpenWearablesHealthSdkKeychain.getHost(),
                "isSyncActive": OpenWearablesHealthSdkKeychain.isSyncActive()
            ]
            result(credentials)

        case "requestAuthorization":
            handleRequestAuthorization(call: call, result: result)

        case "syncNow":
            self.syncAll(fullExport: false) { result(nil) }

        case "startBackgroundSync":
            handleStartBackgroundSync(result: result)

        case "stopBackgroundSync":
            self.cancelSync()
            self.stopBackgroundDelivery()
            self.stopNetworkMonitoring()
            self.stopProtectedDataMonitoring()
            self.cancelAllBGTasks()
            OpenWearablesHealthSdkKeychain.setSyncActive(false)
            result(nil)

        case "resetAnchors":
            self.resetAllAnchors()
            self.clearSyncSession()
            self.clearOutbox()
            logMessage("🔄 Anchors reset - will perform full sync on next sync")
            // If sync is active, trigger a new full sync
            if OpenWearablesHealthSdkKeychain.isSyncActive() && self.hasAuth {
                logMessage("🔄 Triggering full export after reset...")
                self.syncAll(fullExport: true) {
                    self.logMessage("✅ Full export after reset completed")
                }
            }
            result(nil)
            
        case "getSyncStatus":
            handleGetSyncStatus(result: result)
            
        case "resumeSync":
            handleResumeSync(result: result)
            
        case "clearSyncSession":
            self.clearSyncSession()
            result(nil)

        default:
            result(FlutterMethodNotImplemented)
        }
    }
    
    // MARK: - Get Sync Status
    private func handleGetSyncStatus(result: @escaping FlutterResult) {
        result(getSyncStatusDict())
    }
    
    // MARK: - Resume Sync
    private func handleResumeSync(result: @escaping FlutterResult) {
        guard hasResumableSyncSession() else {
            result(FlutterError(code: "no_session", message: "No resumable sync session", details: nil))
            return
        }
        
        // Just trigger normal sync - it will automatically filter out already sent samples
        self.syncAll(fullExport: false) {
            result(nil)
        }
    }
    
    // MARK: - Configure
    private func handleConfigure(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let host = args["host"] as? String else {
            result(FlutterError(code: "bad_args", message: "Missing host", details: nil))
            return
        }
        
        // Clear Keychain if app was reinstalled
        OpenWearablesHealthSdkKeychain.clearKeychainIfReinstalled()
        
        self.host = host
        OpenWearablesHealthSdkKeychain.saveHost(host)
        
        // Restore tracked types if available
        if let storedTypes = OpenWearablesHealthSdkKeychain.getTrackedTypes() {
            self.trackedTypes = mapTypes(storedTypes)
            logMessage("📋 Restored \(trackedTypes.count) tracked types")
        }
        
        logMessage("✅ Configured: host=\(host)")
        
        // Auto-start sync if was previously active and session exists
        if OpenWearablesHealthSdkKeychain.isSyncActive() && OpenWearablesHealthSdkKeychain.hasSession() && !trackedTypes.isEmpty {
            logMessage("🔄 Auto-restoring background sync...")
            DispatchQueue.main.async { [weak self] in
                self?.autoRestoreSync()
            }
        }
        
        result(nil)
    }
    
    // MARK: - Auto Restore Sync
    private func autoRestoreSync() {
        guard userId != nil, hasAuth else {
            logMessage("⚠️ Cannot auto-restore: no session")
            return
        }
        
        self.startBackgroundDelivery()
        self.startNetworkMonitoring()
        self.startProtectedDataMonitoring()
        self.scheduleAppRefresh()
        self.scheduleProcessing()
        
        // Check for resumable sync session and resume if found
        if hasResumableSyncSession() {
            logMessage("📂 Found interrupted sync, will resume...")
            self.syncAll(fullExport: false) {
                self.logMessage("✅ Resumed sync completed")
            }
        }
        
        logMessage("✅ Background sync auto-restored")
    }
    
    // MARK: - Sign In (with tokens or API key)
    private func handleSignIn(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let userId = args["userId"] as? String else {
            result(FlutterError(code: "bad_args", message: "Missing userId", details: nil))
            return
        }
        
        let accessToken = args["accessToken"] as? String
        let refreshToken = args["refreshToken"] as? String
        let apiKey = args["apiKey"] as? String
        
        let hasTokens = accessToken != nil && refreshToken != nil
        let hasApiKey = apiKey != nil
        
        guard hasTokens || hasApiKey else {
            result(FlutterError(code: "bad_args", message: "Provide (accessToken + refreshToken) or (apiKey)", details: nil))
            return
        }
        
        // Clear stale sync state, anchors and outbox from previous sessions
        clearSyncSession()
        resetAllAnchors()
        clearOutbox()
        
        // Save user ID and tokens
        OpenWearablesHealthSdkKeychain.saveCredentials(userId: userId, accessToken: accessToken, refreshToken: refreshToken)
        
        // Save API key if provided
        if let apiKey = apiKey {
            OpenWearablesHealthSdkKeychain.saveApiKey(apiKey)
            logMessage("✅ API key saved")
        }
        
        let authMode = hasTokens ? "token" : "apiKey"
        logMessage("✅ Signed in: userId=\(userId), mode=\(authMode)")
        
        result(nil)
    }
    
    // MARK: - Update Tokens
    private func handleUpdateTokens(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let accessToken = args["accessToken"] as? String else {
            result(FlutterError(code: "bad_args", message: "Missing accessToken", details: nil))
            return
        }
        
        let refreshToken = args["refreshToken"] as? String
        
        OpenWearablesHealthSdkKeychain.updateTokens(accessToken: accessToken, refreshToken: refreshToken)
        logMessage("🔄 Tokens updated from Flutter")
        
        // Retry any pending outbox items with the new token
        self.retryOutboxIfPossible()
        
        result(nil)
    }
    
    // MARK: - Sign Out
    private func handleSignOut(result: @escaping FlutterResult) {
        logMessage("🔓 Signing out")
        
        // Cancel any in-progress sync first
        cancelSync()
        
        stopBackgroundDelivery()
        stopNetworkMonitoring()
        stopProtectedDataMonitoring()
        cancelAllBGTasks()
        
        // Reset anchors and fullDone flag BEFORE clearing keychain (need userId)
        resetAllAnchors()
        
        // Clear sync session state
        clearSyncSession()
        
        // Clear outbox
        clearOutbox()
        
        // Clear Keychain (this removes userId, accessToken, etc.)
        OpenWearablesHealthSdkKeychain.clearAll()
        
        logMessage("✅ Sign out complete - all sync state reset")
        
        result(nil)
    }
    
    // MARK: - Restore Session
    private func handleRestoreSession(result: @escaping FlutterResult) {
        if OpenWearablesHealthSdkKeychain.hasSession(),
           let userId = OpenWearablesHealthSdkKeychain.getUserId() {
            logMessage("📱 Session restored: userId=\(userId)")
            result(userId)
        } else {
            result(nil)
        }
    }
    
    // MARK: - Request Authorization
    private func handleRequestAuthorization(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let types = args["types"] as? [String] else {
            result(FlutterError(code: "bad_args", message: "Missing types", details: nil))
            return
        }
        
        self.trackedTypes = mapTypes(types)
        
        // Save tracked types for restoration after restart
        OpenWearablesHealthSdkKeychain.saveTrackedTypes(types)
        
        logMessage("📋 Requesting auth for \(trackedTypes.count) types")
        
        requestAuthorization { ok in
            result(ok)
        }
    }
    
    // MARK: - Start Background Sync
    private func handleStartBackgroundSync(result: @escaping FlutterResult) {
        guard userId != nil, hasAuth else {
            result(FlutterError(code: "not_signed_in", message: "Not signed in", details: nil))
            return
        }
        
        self.startBackgroundDelivery()
        self.startNetworkMonitoring()
        self.startProtectedDataMonitoring()
        
        self.initialSyncKickoff { started in
            if started {
                self.logMessage("✅ Sync started")
            } else {
                self.logMessage("❌ Sync failed to start")
                self.isInitialSyncInProgress = false
            }
        }
        
        self.scheduleAppRefresh()
        self.scheduleProcessing()
        
        let canStart = HKHealthStore.isHealthDataAvailable() &&
                      self.syncEndpoint != nil &&
                      self.hasAuth &&
                      !self.trackedTypes.isEmpty
        
        // Save sync active state for restoration after restart
        if canStart {
            OpenWearablesHealthSdkKeychain.setSyncActive(true)
        }
        
        result(canStart)
    }
    
    // MARK: - Get Auth Credential
    internal func getAuthCredential() -> String? {
        return authCredential
    }
    
    // MARK: - Helper: Get queryable types (filtering unsupported correlations)
    internal func getQueryableTypes() -> [HKSampleType] {
        // Filter out correlation types that cannot be used in authorization or queries
        // These should be accessed via their individual components instead
        let disallowedIdentifiers: Set<String> = [
            HKCorrelationTypeIdentifier.bloodPressure.rawValue
        ]
        
        return trackedTypes.filter { type in
            !disallowedIdentifiers.contains(type.identifier)
        }
    }
    

    // MARK: - Authorization
    internal func requestAuthorization(completion: @escaping (Bool)->Void) {
        guard HKHealthStore.isHealthDataAvailable() else { 
            DispatchQueue.main.async { completion(false) }
            return 
        }
        
        let readTypes = Set(getQueryableTypes())
        
        logMessage("📡 Requesting read-only auth for \(readTypes.count) types")
        
        // Request only read permissions (no write/share)
        healthStore.requestAuthorization(toShare: nil, read: readTypes) { ok, _ in
            DispatchQueue.main.async { completion(ok) }
        }
    }

    // MARK: - Sync
    internal func syncAll(fullExport: Bool, completion: @escaping ()->Void) {
        guard !trackedTypes.isEmpty else { completion(); return }
        
        guard self.hasAuth else {
            self.logMessage("❌ No auth credential for sync")
            completion()
            return
        }
        self.collectAllData(fullExport: fullExport, completion: completion)
    }
    
    // MARK: - Debounced sync
    internal func triggerCombinedSync() {
        if isInitialSyncInProgress {
            logMessage("⏭️ Skipping - initial sync in progress")
            return
        }
        
        if observerBgTask == .invalid {
            observerBgTask = UIApplication.shared.beginBackgroundTask(withName: "health_combined_sync") {
                self.logMessage("⚠️ Background task expired")
                UIApplication.shared.endBackgroundTask(self.observerBgTask)
                self.observerBgTask = .invalid
            }
        }
        
        pendingSyncWorkItem?.cancel()
        
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.syncAll(fullExport: false) {
                if self.observerBgTask != .invalid {
                    UIApplication.shared.endBackgroundTask(self.observerBgTask)
                    self.observerBgTask = .invalid
                }
            }
        }
        
        pendingSyncWorkItem = workItem
        syncDebounceQueue.asyncAfter(deadline: .now() + 2.0, execute: workItem)
    }
    
    // MARK: - Data collection
    internal func collectAllData(fullExport: Bool, completion: @escaping ()->Void) {
        collectAllData(fullExport: fullExport, isBackground: false, completion: completion)
    }
    
    /// Streaming data collection - processes one type at a time, chunk by chunk
    /// This prevents loading all data into memory at once
    internal func collectAllData(fullExport: Bool, isBackground: Bool, completion: @escaping ()->Void) {
        syncLock.lock()
        if isSyncing {
            logMessage("⚠️ Sync in progress, skipping")
            syncLock.unlock()
            completion()
            return
        }
        isSyncing = true
        syncLock.unlock()
        
        guard HKHealthStore.isHealthDataAvailable() else {
            logMessage("❌ HealthKit not available")
            finishSync()
            completion()
            return
        }
        
        guard let credential = self.authCredential, let endpoint = self.syncEndpoint else {
            logMessage("❌ No auth credential or endpoint")
            finishSync()
            completion()
            return
        }
        
        let queryableTypes = getQueryableTypes()
        guard !queryableTypes.isEmpty else {
            logMessage("❌ No queryable types")
            finishSync()
            completion()
            return
        }
        
        let typeNames = queryableTypes.map { shortTypeName($0.identifier) }.joined(separator: ", ")
        logMessage("📋 Types to sync (\(queryableTypes.count)): \(typeNames)")
        
        // Check if we're resuming an interrupted sync
        let existingState = loadSyncState()
        let isResuming = existingState != nil && existingState!.hasProgress
        
        if isResuming {
            logMessage("🔄 Resuming sync (\(existingState!.totalSentCount) already sent, \(existingState!.completedTypes.count) types done)")
        } else {
            logMessage("🔄 Starting streaming sync (fullExport: \(fullExport), \(queryableTypes.count) types)")
            _ = startNewSyncState(fullExport: fullExport, types: queryableTypes)
        }
        
        // Get starting index for resume
        let startIndex = isResuming ? getResumeTypeIndex() : 0
        
        // Process types sequentially, streaming chunks
        processTypesSequentially(
            types: queryableTypes,
            typeIndex: startIndex,
            fullExport: fullExport,
            endpoint: endpoint,
            credential: credential,
            isBackground: isBackground
        ) { [weak self] allTypesCompleted in
            guard let self = self else { return }
            if allTypesCompleted {
                // All types processed successfully - mark full export as done
                self.finalizeSyncState()
            } else {
                // Sync paused/failed mid-way - keep state for resume, do NOT mark fullDone
                self.logMessage("⚠️ Sync incomplete - will resume remaining types later")
            }
            self.finishSync()
            completion()
        }
    }
    
    /// Process types one by one - streaming approach
    /// Completion returns true if ALL types were processed, false if paused/failed mid-way
    private func processTypesSequentially(
        types: [HKSampleType],
        typeIndex: Int,
        fullExport: Bool,
        endpoint: URL,
        credential: String,
        isBackground: Bool,
        completion: @escaping (Bool)->Void
    ) {
        // Check cancellation
        syncLock.lock()
        let cancelled = syncCancelled
        syncLock.unlock()
        if cancelled {
            logMessage("🛑 Sync cancelled - stopping type processing")
            completion(false)
            return
        }
        
        guard typeIndex < types.count else {
            // All types processed successfully
            completion(true)
            return
        }
        
        let type = types[typeIndex]
        
        // Skip already completed types
        if !shouldSyncType(type.identifier) {
            logMessage("⏭️ Skipping \(shortTypeName(type.identifier)) - already synced")
            processTypesSequentially(
                types: types,
                typeIndex: typeIndex + 1,
                fullExport: fullExport,
                endpoint: endpoint,
                credential: credential,
                isBackground: isBackground,
                completion: completion
            )
            return
        }
        
        // Update current type index for resume
        updateCurrentTypeIndex(typeIndex)
        
        // Process this type with streaming chunks
        processTypeStreaming(
            type: type,
            fullExport: fullExport,
            endpoint: endpoint,
            credential: credential,
            chunkLimit: isBackground ? backgroundChunkSize : recordsPerChunk
        ) { [weak self] success in
            guard let self = self else {
                completion(false)
                return
            }
            
            if success {
                // Continue to next type
                self.processTypesSequentially(
                    types: types,
                    typeIndex: typeIndex + 1,
                    fullExport: fullExport,
                    endpoint: endpoint,
                    credential: credential,
                    isBackground: isBackground,
                    completion: completion
                )
            } else {
                // Failed - will resume from this type later
                self.logMessage("⚠️ Sync paused at \(self.shortTypeName(type.identifier)), will resume later")
                completion(false)
            }
        }
    }
    
    /// Process a single type with streaming - fetches and sends chunks without accumulating
    private func processTypeStreaming(
        type: HKSampleType,
        fullExport: Bool,
        endpoint: URL,
        credential: String,
        chunkLimit: Int,
        completion: @escaping (Bool)->Void
    ) {
        let anchor = fullExport ? nil : loadAnchor(for: type)
        
        logMessage("📊 \(shortTypeName(type.identifier)): querying...")
        
        // Use limit to fetch only a chunk at a time
        let query = HKAnchoredObjectQuery(type: type, predicate: nil, anchor: anchor, limit: chunkLimit) {
            [weak self] _, samplesOrNil, deletedObjects, newAnchor, error in
            
            // Use autoreleasepool to free memory after processing
            autoreleasepool {
                guard let self = self else {
                    completion(false)
                    return
                }
                
                // Check cancellation
                self.syncLock.lock()
                let cancelled = self.syncCancelled
                self.syncLock.unlock()
                if cancelled {
                    completion(false)
                    return
                }
                
                if let error = error {
                    // Check if this is a protected data error (device locked)
                    if self.isProtectedDataError(error) {
                        self.logMessage("🔒 \(self.shortTypeName(type.identifier)): protected data inaccessible (device locked) - pausing sync")
                        self.pendingSyncAfterUnlock = true
                        completion(false)
                        return
                    }
                    // Skip this type and continue to the next one (don't pause entire sync for a single type error)
                    self.logMessage("⚠️ \(self.shortTypeName(type.identifier)): \(error.localizedDescription) - skipping")
                    self.updateTypeProgress(typeIdentifier: type.identifier, sentInChunk: 0, isComplete: true, anchorData: nil)
                    completion(true)
                    return
                }
                
                let samples = samplesOrNil ?? []
                
                if samples.isEmpty {
                    // No more data for this type
                    self.logMessage("  \(self.shortTypeName(type.identifier)): ✓ complete")
                    // Mark type as complete (no anchor to save if no samples)
                    self.updateTypeProgress(typeIdentifier: type.identifier, sentInChunk: 0, isComplete: true, anchorData: nil)
                    completion(true)
                    return
                }
                
                self.logMessage("  \(self.shortTypeName(type.identifier)): \(samples.count) samples")
                
                // Serialize immediately within autoreleasepool
                let payload = self.serializeCombinedStreaming(samples: samples)
                
                // Prepare anchor data
                var anchorData: Data? = nil
                if let newAnchor = newAnchor {
                    anchorData = try? NSKeyedArchiver.archivedData(withRootObject: newAnchor, requiringSecureCoding: true)
                }
                
                // Check if this is the last chunk for this type
                let isLastChunk = samples.count < chunkLimit
                
                // Send immediately
                self.sendChunkStreaming(
                    payload: payload,
                    typeIdentifier: type.identifier,
                    sampleCount: samples.count,
                    anchorData: anchorData,
                    isLastChunk: isLastChunk,
                    endpoint: endpoint,
                    credential: credential
                ) { [weak self] success in
                    guard let self = self else {
                        completion(false)
                        return
                    }
                    
                    if success {
                        if isLastChunk {
                            // Type fully synced
                            completion(true)
                        } else {
                            // More chunks to fetch - continue with updated anchor
                            self.processTypeStreamingContinue(
                                type: type,
                                anchor: newAnchor,
                                endpoint: endpoint,
                                credential: credential,
                                chunkLimit: chunkLimit,
                                completion: completion
                            )
                        }
                    } else {
                        // Upload failed
                        completion(false)
                    }
                }
            }
        }
        
        healthStore.execute(query)
    }
    
    /// Continue streaming for a type (subsequent chunks)
    private func processTypeStreamingContinue(
        type: HKSampleType,
        anchor: HKQueryAnchor?,
        endpoint: URL,
        credential: String,
        chunkLimit: Int,
        completion: @escaping (Bool)->Void
    ) {
        let query = HKAnchoredObjectQuery(type: type, predicate: nil, anchor: anchor, limit: chunkLimit) {
            [weak self] _, samplesOrNil, deletedObjects, newAnchor, error in
            
            autoreleasepool {
                guard let self = self else {
                    completion(false)
                    return
                }
                
                // Check cancellation
                self.syncLock.lock()
                let cancelled = self.syncCancelled
                self.syncLock.unlock()
                if cancelled {
                    completion(false)
                    return
                }
                
                if let error = error {
                    // Check if this is a protected data error (device locked)
                    if self.isProtectedDataError(error) {
                        self.logMessage("🔒 \(self.shortTypeName(type.identifier)): protected data inaccessible (device locked) - pausing sync")
                        self.pendingSyncAfterUnlock = true
                        completion(false)
                        return
                    }
                    // Skip this type on error (don't pause entire sync)
                    self.logMessage("⚠️ \(self.shortTypeName(type.identifier)): \(error.localizedDescription) - skipping")
                    self.updateTypeProgress(typeIdentifier: type.identifier, sentInChunk: 0, isComplete: true, anchorData: nil)
                    completion(true)
                    return
                }
                
                let samples = samplesOrNil ?? []
                
                if samples.isEmpty {
                    // No more data
                    self.updateTypeProgress(typeIdentifier: type.identifier, sentInChunk: 0, isComplete: true, anchorData: nil)
                    completion(true)
                    return
                }
                
                self.logMessage("  \(self.shortTypeName(type.identifier)): +\(samples.count) samples")
                
                let payload = self.serializeCombinedStreaming(samples: samples)
                
                var anchorData: Data? = nil
                if let newAnchor = newAnchor {
                    anchorData = try? NSKeyedArchiver.archivedData(withRootObject: newAnchor, requiringSecureCoding: true)
                }
                
                let isLastChunk = samples.count < chunkLimit
                
                self.sendChunkStreaming(
                    payload: payload,
                    typeIdentifier: type.identifier,
                    sampleCount: samples.count,
                    anchorData: anchorData,
                    isLastChunk: isLastChunk,
                    endpoint: endpoint,
                    credential: credential
                ) { [weak self] success in
                    guard let self = self else {
                        completion(false)
                        return
                    }
                    
                    if success {
                        if isLastChunk {
                            completion(true)
                        } else {
                            self.processTypeStreamingContinue(
                                type: type,
                                anchor: newAnchor,
                                endpoint: endpoint,
                                credential: credential,
                                chunkLimit: chunkLimit,
                                completion: completion
                            )
                        }
                    } else {
                        completion(false)
                    }
                }
            }
        }
        
        healthStore.execute(query)
    }
    
    /// Send a single chunk and update progress
    private func sendChunkStreaming(
        payload: [String: Any],
        typeIdentifier: String,
        sampleCount: Int,
        anchorData: Data?,
        isLastChunk: Bool,
        endpoint: URL,
        credential: String,
        completion: @escaping (Bool)->Void
    ) {
        enqueueCombinedUpload(
            payload: payload,
            anchors: [:],  // We handle anchors separately now
            endpoint: endpoint,
            credential: credential,
            wasFullExport: false
        ) { [weak self] success in
            guard let self = self else {
                completion(false)
                return
            }
            
            if success {
                // Update progress
                self.updateTypeProgress(
                    typeIdentifier: typeIdentifier,
                    sentInChunk: sampleCount,
                    isComplete: isLastChunk,
                    anchorData: isLastChunk ? anchorData : nil
                )
            }
            
            completion(success)
        }
    }
    
    /// Helper to finish sync state
    private func finishSync() {
        syncLock.lock()
        isSyncing = false
        isInitialSyncInProgress = false
        syncLock.unlock()
    }
    
    /// Cancels any in-progress sync and all pending/in-flight network tasks
    internal func cancelSync() {
        logMessage("🛑 Cancelling sync...")
        
        // Set cancellation flag - checked by processTypesSequentially / processTypeStreaming
        syncLock.lock()
        syncCancelled = true
        syncLock.unlock()
        
        // Cancel debounced sync
        pendingSyncWorkItem?.cancel()
        pendingSyncWorkItem = nil
        
        // Cancel all in-flight foreground session tasks
        foregroundSession.getAllTasks { tasks in
            for task in tasks {
                task.cancel()
            }
        }
        
        // Cancel all in-flight background session tasks
        session.getAllTasks { tasks in
            for task in tasks {
                task.cancel()
            }
        }
        
        // End background task if active
        if observerBgTask != .invalid {
            UIApplication.shared.endBackgroundTask(observerBgTask)
            observerBgTask = .invalid
        }
        
        // Reset sync state
        finishSync()
        
        // Reset cancellation flag so future syncs can proceed
        syncLock.lock()
        syncCancelled = false
        syncLock.unlock()
        
        logMessage("🛑 Sync cancelled")
    }
    
    internal func syncType(_ type: HKSampleType, fullExport: Bool, completion: @escaping ()->Void) {
        let anchor = fullExport ? nil : loadAnchor(for: type)
        
        let query = HKAnchoredObjectQuery(type: type, predicate: nil, anchor: anchor, limit: chunkSize) {
            [weak self] _, samplesOrNil, deletedObjects, newAnchor, error in
            guard let self = self else { completion(); return }
            guard error == nil else { completion(); return }

            let samples = samplesOrNil ?? []
            guard !samples.isEmpty else { completion(); return }
            
            guard let credential = self.authCredential, let endpoint = self.syncEndpoint else { 
                completion()
                return 
            }

            let payload = self.serialize(samples: samples, type: type)
            self.enqueueBackgroundUpload(payload: payload, type: type, candidateAnchor: newAnchor, endpoint: endpoint, credential: credential) {
                if samples.count == self.chunkSize {
                    self.syncType(type, fullExport: false, completion: completion)
                } else {
                    completion()
                }
            }
        }
        healthStore.execute(query)
    }
    
    // MARK: - Logging
    internal func logMessage(_ message: String) {
        NSLog("[OpenWearablesHealthSdk] %@", message)
        
        if let sink = logEventSink {
            DispatchQueue.main.async { [weak self] in
                sink(message)
            }
        }
    }
    
    // MARK: - Token Refresh
    
    /// Attempts to refresh the access token using the refresh token.
    /// Calls `POST {host}/api/v1/token/refresh` with the current refresh token.
    /// On success, saves the new tokens and calls completion with `true`.
    /// On failure (or if no refresh token is available), calls completion with `false`.
    internal func attemptTokenRefresh(completion: @escaping (Bool) -> Void) {
        tokenRefreshLock.lock()
        
        // If already refreshing, queue the callback
        if isRefreshingToken {
            tokenRefreshCallbacks.append(completion)
            tokenRefreshLock.unlock()
            return
        }
        
        guard let refreshToken = self.refreshToken, let base = self.apiBaseUrl else {
            tokenRefreshLock.unlock()
            logMessage("🔒 No refresh token or host - cannot refresh")
            completion(false)
            return
        }
        
        isRefreshingToken = true
        tokenRefreshCallbacks.append(completion)
        tokenRefreshLock.unlock()
        
        guard let url = URL(string: "\(base)/token/refresh") else {
            logMessage("❌ Invalid refresh URL")
            finishTokenRefresh(success: false)
            return
        }
        
        logMessage("🔄 Attempting token refresh...")
        
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let body: [String: String] = ["refresh_token": refreshToken]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
            logMessage("❌ Failed to serialize refresh request body")
            finishTokenRefresh(success: false)
            return
        }
        req.httpBody = bodyData
        
        let task = foregroundSession.dataTask(with: req) { [weak self] data, response, error in
            guard let self = self else { return }
            
            if let error = error {
                self.logMessage("❌ Token refresh failed: \(error.localizedDescription)")
                self.finishTokenRefresh(success: false)
                return
            }
            
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode),
                  let data = data else {
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
                self.logMessage("❌ Token refresh failed: HTTP \(statusCode)")
                self.finishTokenRefresh(success: false)
                return
            }
            
            // Parse response: { "access_token": "...", "token_type": "bearer", "refresh_token": "...", "expires_in": 0 }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let newAccessToken = json["access_token"] as? String else {
                self.logMessage("❌ Token refresh: invalid response body")
                self.finishTokenRefresh(success: false)
                return
            }
            
            let newRefreshToken = json["refresh_token"] as? String
            
            // Save new tokens to Keychain
            OpenWearablesHealthSdkKeychain.updateTokens(accessToken: newAccessToken, refreshToken: newRefreshToken)
            
            self.logMessage("✅ Token refreshed successfully")
            self.finishTokenRefresh(success: true)
        }
        
        task.resume()
    }
    
    /// Resolves all pending token refresh callbacks
    private func finishTokenRefresh(success: Bool) {
        tokenRefreshLock.lock()
        let callbacks = tokenRefreshCallbacks
        tokenRefreshCallbacks = []
        isRefreshingToken = false
        tokenRefreshLock.unlock()
        
        for callback in callbacks {
            callback(success)
        }
    }
    
    // MARK: - Auth Error Emission
    internal func emitAuthError(statusCode: Int) {
        logMessage("🔒 Auth error: HTTP \(statusCode) - token invalid")
        
        if let sink = authErrorEventSink {
            DispatchQueue.main.async {
                sink(["statusCode": statusCode, "message": "Unauthorized - please re-authenticate"])
            }
        }
    }
    
    /// Logs full payload JSON to Xcode console only (NOT to Flutter event sink)
    /// Use this for debugging - payloads can be very large
    internal func logPayloadToConsole(_ data: Data, label: String) {
        #if DEBUG
        if let jsonObject = try? JSONSerialization.jsonObject(with: data, options: []),
           let prettyData = try? JSONSerialization.data(withJSONObject: jsonObject, options: [.prettyPrinted, .sortedKeys]),
           let prettyString = String(data: prettyData, encoding: .utf8) {
            NSLog("[OpenWearablesHealthSdk] ========== %@ PAYLOAD START ==========", label)
            // Split into chunks because NSLog has a limit (~1000 chars)
            let chunkSize = 800
            var index = prettyString.startIndex
            while index < prettyString.endIndex {
                let endIndex = prettyString.index(index, offsetBy: chunkSize, limitedBy: prettyString.endIndex) ?? prettyString.endIndex
                let chunk = String(prettyString[index..<endIndex])
                NSLog("[OpenWearablesHealthSdk] %@", chunk)
                index = endIndex
            }
            NSLog("[OpenWearablesHealthSdk] ========== %@ PAYLOAD END (%d bytes) ==========", label, data.count)
        } else {
            NSLog("[OpenWearablesHealthSdk] %@: Failed to pretty-print payload (%d bytes)", label, data.count)
        }
        #endif
    }
    
    /// Logs a summary of the payload (types and counts) without the full data
    internal func logPayloadSummary(_ data: Data, label: String) {
        guard let jsonObject = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
              let dataDict = jsonObject["data"] as? [String: Any] else {
            let sizeMB = Double(data.count) / (1024 * 1024)
            logMessage("\(label): \(String(format: "%.2f", sizeMB)) MB")
            return
        }
        
        var summary: [String] = []
        
        // Count records by type
        if let records = dataDict["records"] as? [[String: Any]] {
            var typeCounts: [String: Int] = [:]
            for record in records {
                if let type = record["type"] as? String {
                    // Extract short type name from full identifier
                    let shortType = type.replacingOccurrences(of: "HKQuantityTypeIdentifier", with: "")
                        .replacingOccurrences(of: "HKCategoryTypeIdentifier", with: "")
                    typeCounts[shortType, default: 0] += 1
                }
            }
            if !typeCounts.isEmpty {
                let typesList = typeCounts.sorted { $0.value > $1.value }
                    .map { "\($0.key): \($0.value)" }
                    .joined(separator: ", ")
                summary.append("Records: \(records.count) [\(typesList)]")
            }
        }
        
        // Count workouts
        if let workouts = dataDict["workouts"] as? [[String: Any]], !workouts.isEmpty {
            var workoutTypes: [String: Int] = [:]
            for workout in workouts {
                if let type = workout["type"] as? String {
                    workoutTypes[type, default: 0] += 1
                }
            }
            let workoutsList = workoutTypes.sorted { $0.value > $1.value }
                .map { "\($0.key): \($0.value)" }
                .joined(separator: ", ")
            summary.append("Workouts: \(workouts.count) [\(workoutsList)]")
        }
        
        let sizeMB = Double(data.count) / (1024 * 1024)
        let sizeStr = String(format: "%.2f MB", sizeMB)
        
        if summary.isEmpty {
            logMessage("\(label): \(sizeStr)")
        } else {
            logMessage("\(label): \(sizeStr) - \(summary.joined(separator: ", "))")
        }
    }
    
    // MARK: - Network Monitoring
    
    internal func startNetworkMonitoring() {
        // Don't start if already running
        guard networkMonitor == nil else { return }
        
        networkMonitor = NWPathMonitor()
        networkMonitor?.pathUpdateHandler = { [weak self] path in
            guard let self = self else { return }
            
            let isConnected = path.status == .satisfied
            
            if isConnected {
                // Network is available
                if self.wasDisconnected {
                    self.wasDisconnected = false
                    self.logMessage("📶 Network restored")
                    self.tryResumeAfterNetworkRestored()
                }
            } else {
                // Network is not available
                if !self.wasDisconnected {
                    self.wasDisconnected = true
                    self.logMessage("📵 Network lost")
                }
            }
        }
        
        networkMonitor?.start(queue: networkMonitorQueue)
        logMessage("📡 Network monitoring started")
    }
    
    internal func stopNetworkMonitoring() {
        networkMonitor?.cancel()
        networkMonitor = nil
        wasDisconnected = false
    }
    
    // MARK: - Protected Data Monitoring
    
    internal func startProtectedDataMonitoring() {
        guard protectedDataObserver == nil else { return }
        
        protectedDataObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.protectedDataDidBecomeAvailableNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            self.logMessage("🔓 Device unlocked - protected data available")
            
            if self.pendingSyncAfterUnlock {
                self.pendingSyncAfterUnlock = false
                self.logMessage("🔄 Triggering deferred sync after unlock...")
                
                // Small delay to let the system stabilize
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                    guard let self = self else { return }
                    
                    self.syncLock.lock()
                    let alreadySyncing = self.isSyncing
                    self.syncLock.unlock()
                    
                    guard !alreadySyncing else {
                        self.logMessage("⏭️ Sync already in progress after unlock")
                        return
                    }
                    
                    self.syncAll(fullExport: false) {
                        self.logMessage("✅ Deferred sync after unlock completed")
                    }
                }
            }
        }
        
        logMessage("🔐 Protected data monitoring started")
    }
    
    internal func stopProtectedDataMonitoring() {
        if let observer = protectedDataObserver {
            NotificationCenter.default.removeObserver(observer)
            protectedDataObserver = nil
        }
        pendingSyncAfterUnlock = false
    }
    
    /// Called when upload fails - marks network as disconnected so we can auto-resume
    internal func markNetworkError() {
        wasDisconnected = true
    }
    
    /// Try to resume sync after network is restored
    private func tryResumeAfterNetworkRestored() {
        // Wait a bit for network to stabilize
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self = self else { return }
            
            // Check if we have an interrupted sync to resume
            guard self.hasResumableSyncSession() else {
                self.logMessage("ℹ️ No sync to resume")
                return
            }
            
            // Don't resume if already syncing
            self.syncLock.lock()
            let alreadySyncing = self.isSyncing
            self.syncLock.unlock()
            
            if alreadySyncing {
                self.logMessage("⏭️ Sync already in progress")
                return
            }
            
            self.logMessage("🔄 Resuming sync after network restored...")
            self.syncAll(fullExport: false) {
                self.logMessage("✅ Network resume sync completed")
            }
        }
    }
    
    // MARK: - Protected Data Error Detection
    
    /// Checks if a HealthKit error is due to protected data being inaccessible (device locked).
    /// HealthKit encrypts data independently of the general iOS data protection — even when
    /// `UIApplication.shared.isProtectedDataAvailable` is true, HealthKit data may be locked.
    internal func isProtectedDataError(_ error: Error) -> Bool {
        let nsError = error as NSError
        // HKError.errorDatabaseInaccessible (code 6) — HealthKit DB locked
        if nsError.domain == "com.apple.healthkit" && nsError.code == 6 {
            return true
        }
        // Fallback: match the localized description for older iOS versions
        let msg = error.localizedDescription.lowercased()
        return msg.contains("protected health data") || msg.contains("inaccessible")
    }
    
    // MARK: - FlutterStreamHandler
    public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        logEventSink = events
        return nil
    }
    
    public func onCancel(withArguments arguments: Any?) -> FlutterError? {
        logEventSink = nil
        return nil
    }
    
    // MARK: - Helpers
    internal func shortTypeName(_ identifier: String) -> String {
        return identifier
            .replacingOccurrences(of: "HKQuantityTypeIdentifier", with: "")
            .replacingOccurrences(of: "HKCategoryTypeIdentifier", with: "")
            .replacingOccurrences(of: "HKWorkoutType", with: "Workout")
    }
}

// MARK: - Auth Error Stream Handler
class AuthErrorStreamHandler: NSObject, FlutterStreamHandler {
    weak var plugin: OpenWearablesHealthSdkPlugin?
    
    init(plugin: OpenWearablesHealthSdkPlugin) {
        self.plugin = plugin
    }
    
    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        plugin?.authErrorEventSink = events
        return nil
    }
    
    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        plugin?.authErrorEventSink = nil
        return nil
    }
}

// MARK: - Array extension
extension Array {
    func chunked(into size: Int) -> [[Element]] {
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
