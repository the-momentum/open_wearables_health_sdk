import Foundation

extension HealthBgSyncPlugin {

    // MARK: - URLSession delegate
    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let desc = task.taskDescription else { return }
        let parts = desc.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        let itemPath = parts.count > 0 ? parts[0] : ""
        let payloadPath = parts.count > 1 ? parts[1] : ""
        let anchorPath = parts.count > 2 ? parts[2] : ""

        defer {
            if !payloadPath.isEmpty { try? FileManager.default.removeItem(atPath: payloadPath) }
            if error == nil, !itemPath.isEmpty { try? FileManager.default.removeItem(atPath: itemPath) }
        }

        // Transport error → keep manifest + anchor for retry
        if let error = error {
            let nsError = error as NSError
            // Don't log cancelled requests (error -999) as they're normal
            if nsError.code != NSURLErrorCancelled {
                print("⛔️ background upload failed: \(error.localizedDescription)")
            }
            return
        }

        // Only treat 2xx as success (HEAD/redirects can happen in background)
        if let http = task.response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            print("⛔️ upload HTTP \(http.statusCode) — keep item for retry")
            return
        }

        // SUCCESS: save anchor BASED ON MANIFEST — no need to have trackedTypes in memory
        if !anchorPath.isEmpty,
           let itemData = try? Data(contentsOf: URL(fileURLWithPath: itemPath)),
           let item = try? JSONDecoder().decode(OutboxItem.self, from: itemData) {
            
            // Handle combined anchors differently
            if item.typeIdentifier == "combined" {
                // For combined uploads, save all anchors
                if let anchorData = try? Data(contentsOf: URL(fileURLWithPath: anchorPath)),
                   let anchorsDict = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSDictionary.self, from: anchorData) as? [String: Data] {
                    for (typeId, anchorData) in anchorsDict {
                        saveAnchorData(anchorData, typeIdentifier: typeId, endpointKey: item.endpointKey)
                    }
                }
            } else {
                // For single type uploads, save single anchor
                if let anchorData = try? Data(contentsOf: URL(fileURLWithPath: anchorPath)) {
                    saveAnchorData(anchorData, typeIdentifier: item.typeIdentifier, endpointKey: item.endpointKey)
                }
            }
            try? FileManager.default.removeItem(atPath: anchorPath)
        }
    }

    public func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        if let handler = HealthBgSyncPlugin.bgCompletionHandler {
            HealthBgSyncPlugin.bgCompletionHandler = nil
            handler()
        }
    }
}
