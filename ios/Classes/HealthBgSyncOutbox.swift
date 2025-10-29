import Foundation
import HealthKit

extension HealthBgSyncPlugin {

    // MARK: - Outbox model
    internal struct OutboxItem: Codable {
        let typeIdentifier: String
        let endpointKey: String
        let payloadPath: String
        let anchorPath: String?
    }

    internal func outboxDir() -> URL {
        let base = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return (base ?? FileManager.default.temporaryDirectory).appendingPathComponent("health_outbox", isDirectory: true)
    }

    internal func ensureOutboxDir() {
        try? FileManager.default.createDirectory(at: outboxDir(), withIntermediateDirectories: true)
    }

    internal func newPath(_ name: String, ext: String) -> URL {
        ensureOutboxDir()
        return outboxDir().appendingPathComponent("\(name).\(ext)")
    }

    // MARK: - Background upload with persistence
    internal func enqueueBackgroundUpload(
        payload: [String: Any],
        type: HKSampleType,
        candidateAnchor: HKQueryAnchor?,
        endpoint: URL,
        token: String,
        completion: @escaping ()->Void
    ) {
        // 1) payload → file
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { completion(); return }
        let id = UUID().uuidString
        let payloadURL = newPath("payload_\(id)", ext: "json")
        do { try data.write(to: payloadURL, options: .atomic) } catch { completion(); return }

        // 2) candidate anchor → file (optional)
        var anchorURL: URL? = nil
        if let cand = candidateAnchor,
           let ad = try? NSKeyedArchiver.archivedData(withRootObject: cand, requiringSecureCoding: true) {
            let u = newPath("anchor_\(id)", ext: "bin")
            try? ad.write(to: u, options: .atomic)
            anchorURL = u
        }

        // 3) manifest (item) → file
        let item = OutboxItem(
            typeIdentifier: type.identifier,
            endpointKey: endpointKey(),
            payloadPath: payloadURL.path,
            anchorPath: anchorURL?.path
        )
        let itemURL = newPath("item_\(id)", ext: "json")
        if let md = try? JSONEncoder().encode(item) { try? md.write(to: itemURL, options: .atomic) }

        // 4) request
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        // 5) background upload (from file)
        let task = session.uploadTask(with: req, fromFile: payloadURL)
        task.taskDescription = [itemURL.path, payloadURL.path, anchorURL?.path ?? ""].joined(separator: "|")
        task.resume()

        completion()
    }
    
    // MARK: - Combined upload for all data types
    internal func enqueueCombinedUpload(
        payload: [String: Any],
        anchors: [String: HKQueryAnchor],
        endpoint: URL,
        token: String,
        completion: @escaping ()->Void
    ) {
        // 1) payload → file
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { completion(); return }
        let id = UUID().uuidString
        let payloadURL = newPath("combined_payload_\(id)", ext: "json")
        do { try data.write(to: payloadURL, options: .atomic) } catch { completion(); return }

        // 2) anchors → file (for all types) - serialize as binary data
        var anchorsURL: URL? = nil
        if !anchors.isEmpty {
            // Create a dictionary to store anchor data
            var anchorsData: [String: Data] = [:]
            for (typeId, anchor) in anchors {
                if let data = try? NSKeyedArchiver.archivedData(withRootObject: anchor, requiringSecureCoding: true) {
                    anchorsData[typeId] = data
                }
            }
            
            // Serialize the dictionary as binary data
            if let serializedData = try? NSKeyedArchiver.archivedData(withRootObject: anchorsData, requiringSecureCoding: true) {
                let u = newPath("combined_anchors_\(id)", ext: "bin")
                try? serializedData.write(to: u, options: .atomic)
                anchorsURL = u
            }
        }

        // 3) manifest (item) → file
        let item = OutboxItem(
            typeIdentifier: "combined", // Special identifier for combined data
            endpointKey: endpointKey(),
            payloadPath: payloadURL.path,
            anchorPath: anchorsURL?.path
        )
        let itemURL = newPath("combined_item_\(id)", ext: "json")
        if let md = try? JSONEncoder().encode(item) { try? md.write(to: itemURL, options: .atomic) }

        // 4) request
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        // 5) background upload (from file)
        let task = session.uploadTask(with: req, fromFile: payloadURL)
        task.taskDescription = [itemURL.path, payloadURL.path, anchorsURL?.path ?? ""].joined(separator: "|")
        task.resume()

        completion()
    }

    // Retry pending items after startup (when endpoint/token are available)
    internal func retryOutboxIfPossible() {
        guard let endpoint = self.endpoint, let token = self.token else { return }
        let dir = outboxDir()
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        
        // Handle both regular and combined items
        let regularItems = files.filter { $0.lastPathComponent.hasPrefix("item_") && $0.pathExtension == "json" && !$0.lastPathComponent.hasPrefix("combined_item_") }
        let combinedItems = files.filter { $0.lastPathComponent.hasPrefix("combined_item_") && $0.pathExtension == "json" }

        // Retry regular items
        for itemURL in regularItems {
            guard let data = try? Data(contentsOf: itemURL),
                  let item = try? JSONDecoder().decode(OutboxItem.self, from: data) else { continue }
            let payloadURL = URL(fileURLWithPath: item.payloadPath)
            guard FileManager.default.fileExists(atPath: payloadURL.path) else { continue }

            var req = URLRequest(url: endpoint)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

            let task = session.uploadTask(with: req, fromFile: payloadURL)
            task.taskDescription = [itemURL.path, payloadURL.path, item.anchorPath ?? ""].joined(separator: "|")
            task.resume()
        }
        
        // Retry combined items
        for itemURL in combinedItems {
            guard let data = try? Data(contentsOf: itemURL),
                  let item = try? JSONDecoder().decode(OutboxItem.self, from: data) else { continue }
            let payloadURL = URL(fileURLWithPath: item.payloadPath)
            guard FileManager.default.fileExists(atPath: payloadURL.path) else { continue }

            var req = URLRequest(url: endpoint)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

            let task = session.uploadTask(with: req, fromFile: payloadURL)
            task.taskDescription = [itemURL.path, payloadURL.path, item.anchorPath ?? ""].joined(separator: "|")
            task.resume()
        }
    }
}
