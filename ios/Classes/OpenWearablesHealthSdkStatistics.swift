import Foundation
import HealthKit
import Flutter

/// Persistent sync statistics - tracks cumulative counts per data type
/// These survive across app restarts and individual sync sessions
internal class OpenWearablesHealthSdkStatistics {
    
    private static let defaults = UserDefaults(suiteName: "com.openwearables.healthsdk.statistics") ?? .standard
    
    // Keys
    private static let syncedCountsKey = "syncedCounts"
    private static let lastSyncTimestampKey = "lastSyncTimestamp"
    private static let totalSyncedKey = "totalSynced"
    
    // MARK: - Get/Set Synced Counts Per Type
    
    /// Get cumulative synced counts for all types
    static func getSyncedCounts() -> [String: Int] {
        return defaults.dictionary(forKey: syncedCountsKey) as? [String: Int] ?? [:]
    }
    
    /// Increment synced count for a specific type
    static func incrementSyncedCount(for typeIdentifier: String, by count: Int) {
        var counts = getSyncedCounts()
        counts[typeIdentifier, default: 0] += count
        defaults.set(counts, forKey: syncedCountsKey)
        
        // Also update total
        let total = defaults.integer(forKey: totalSyncedKey) + count
        defaults.set(total, forKey: totalSyncedKey)
        
        // Update last sync timestamp
        defaults.set(Date().timeIntervalSince1970, forKey: lastSyncTimestampKey)
        
        defaults.synchronize()
    }
    
    /// Get total synced count across all types
    static func getTotalSyncedCount() -> Int {
        return defaults.integer(forKey: totalSyncedKey)
    }
    
    /// Get last sync timestamp
    static func getLastSyncTimestamp() -> Date? {
        let timestamp = defaults.double(forKey: lastSyncTimestampKey)
        guard timestamp > 0 else { return nil }
        return Date(timeIntervalSince1970: timestamp)
    }
    
    /// Clear all statistics (used on sign out)
    static func clearAll() {
        defaults.removeObject(forKey: syncedCountsKey)
        defaults.removeObject(forKey: lastSyncTimestampKey)
        defaults.removeObject(forKey: totalSyncedKey)
        defaults.synchronize()
    }
    
    /// Clear statistics for specific user key (legacy, for migration)
    static func clearForUser(_ userKey: String) {
        // For now, clear all - in future could be user-specific
        clearAll()
    }
    
    // MARK: - Helper to format type identifier to readable name
    
    static func formatTypeName(_ identifier: String) -> String {
        return identifier
            .replacingOccurrences(of: "HKQuantityTypeIdentifier", with: "")
            .replacingOccurrences(of: "HKCategoryTypeIdentifier", with: "")
            .replacingOccurrences(of: "HKWorkoutType", with: "Workout")
    }
    
    // MARK: - Get Statistics Dictionary for Flutter
    
    /// Returns statistics in a format suitable for Flutter
    static func getStatisticsDict() -> [String: Any] {
        let syncedCounts = getSyncedCounts()
        
        // Format type names for display
        var formattedCounts: [String: Int] = [:]
        for (key, value) in syncedCounts {
            let formattedKey = formatTypeName(key)
            formattedCounts[formattedKey] = value
        }
        
        // Also include raw identifiers for programmatic access
        let lastSync = getLastSyncTimestamp()
        
        return [
            "syncedCounts": formattedCounts,
            "rawSyncedCounts": syncedCounts,
            "totalSynced": getTotalSyncedCount(),
            "lastSyncTimestamp": lastSync != nil ? ISO8601DateFormatter().string(from: lastSync!) : NSNull()
        ]
    }
}

// MARK: - Extension for OpenWearablesHealthSdkPlugin

extension OpenWearablesHealthSdkPlugin {
    
    /// Called when an upload succeeds - updates persistent statistics
    internal func recordSuccessfulUpload(typeIdentifier: String, count: Int) {
        OpenWearablesHealthSdkStatistics.incrementSyncedCount(for: typeIdentifier, by: count)
        logMessage("📈 Stats: +\(count) \(shortTypeName(typeIdentifier)) (total: \(OpenWearablesHealthSdkStatistics.getSyncedCounts()[typeIdentifier] ?? 0))")
    }
    
    /// Called when uploading combined payload - extracts counts per type
    internal func recordSuccessfulCombinedUpload(payload: [String: Any]) {
        guard let data = payload["data"] as? [String: Any] else { return }
        
        // Count records per type
        if let records = data["records"] as? [[String: Any]] {
            var typeCounts: [String: Int] = [:]
            for record in records {
                if let type = record["type"] as? String {
                    typeCounts[type, default: 0] += 1
                }
            }
            
            for (type, count) in typeCounts {
                OpenWearablesHealthSdkStatistics.incrementSyncedCount(for: type, by: count)
            }
        }
        
        // Count workouts
        if let workouts = data["workouts"] as? [[String: Any]], !workouts.isEmpty {
            OpenWearablesHealthSdkStatistics.incrementSyncedCount(for: "HKWorkoutType", by: workouts.count)
        }
    }
    
    /// Get sync statistics for Flutter
    internal func handleGetSyncStatistics(result: @escaping FlutterResult) {
        result(OpenWearablesHealthSdkStatistics.getStatisticsDict())
    }
    
    /// Clear sync statistics (called on sign out)
    internal func clearSyncStatistics() {
        OpenWearablesHealthSdkStatistics.clearAll()
        logMessage("🧹 Cleared sync statistics")
    }
}
