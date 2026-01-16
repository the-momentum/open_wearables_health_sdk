package com.momentum.health.export.health_bg_sync

import android.content.Context
import android.util.Log
import com.google.gson.Gson
import com.google.gson.annotations.SerializedName
import java.io.File
import java.util.Date

/**
 * Manages sync session state for resumable uploads.
 * Stores sent UUIDs to avoid re-sending data after interruption.
 * Equivalent to iOS HealthBgSyncSession.
 */
class HealthBgSyncSession(context: Context) {

    companion object {
        private const val TAG = "HealthBgSyncSession"
        private const val STATE_DIR = "health_sync_state"
        private const val STATE_FILE = "state.json"
        private const val ANCHORS_FILE = "anchors.json"
    }

    private val gson = Gson()
    private val stateDir: File = File(context.filesDir, STATE_DIR)
    private val stateFile: File = File(stateDir, STATE_FILE)
    private val anchorsFile: File = File(stateDir, ANCHORS_FILE)

    init {
        ensureStateDir()
    }

    // MARK: - State Data Class

    data class SyncState(
        @SerializedName("user_key")
        val userKey: String,
        
        @SerializedName("full_export")
        val fullExport: Boolean,
        
        @SerializedName("sent_uuids")
        val sentUUIDs: MutableSet<String>,
        
        @SerializedName("created_at")
        val createdAt: Long,
        
        @SerializedName("anchors")
        val anchors: MutableMap<String, String>? = null
    )

    // MARK: - Directory Management

    private fun ensureStateDir() {
        if (!stateDir.exists()) {
            stateDir.mkdirs()
        }
    }

    // MARK: - Save/Load State

    fun saveSyncState(state: SyncState) {
        try {
            ensureStateDir()
            val json = gson.toJson(state)
            stateFile.writeText(json)
        } catch (e: Exception) {
            Log.e(TAG, "Failed to save sync state: ${e.message}")
        }
    }

    fun loadSyncState(): SyncState? {
        return try {
            if (!stateFile.exists()) return null
            val json = stateFile.readText()
            gson.fromJson(json, SyncState::class.java)
        } catch (e: Exception) {
            Log.e(TAG, "Failed to load sync state: ${e.message}")
            null
        }
    }

    fun loadSyncStateForUser(userKey: String): SyncState? {
        val state = loadSyncState()
        if (state?.userKey != userKey) {
            Log.w(TAG, "⚠️ Sync state for different user, clearing")
            clearSyncSession()
            return null
        }
        return state
    }

    // MARK: - UUID Tracking

    fun addSentUUIDs(uuids: List<String>) {
        val state = loadSyncState() ?: return
        state.sentUUIDs.addAll(uuids)
        saveSyncState(state)
    }

    fun filterSentUUIDs(uuids: List<String>, userKey: String): List<String> {
        val state = loadSyncStateForUser(userKey) ?: return uuids
        if (state.sentUUIDs.isEmpty()) return uuids
        
        val filtered = uuids.filter { !state.sentUUIDs.contains(it) }
        val skipped = uuids.size - filtered.size
        
        if (skipped > 0) {
            Log.d(TAG, "⏭️ Skipping $skipped already sent samples")
        }
        
        return filtered
    }

    // MARK: - Start New Sync

    fun startNewSyncState(
        userKey: String,
        fullExport: Boolean,
        anchors: Map<String, String>
    ): SyncState {
        // Save anchors to separate file for safety
        if (anchors.isNotEmpty()) {
            try {
                ensureStateDir()
                val json = gson.toJson(anchors)
                anchorsFile.writeText(json)
            } catch (e: Exception) {
                Log.e(TAG, "Failed to save anchors: ${e.message}")
            }
        }

        val state = SyncState(
            userKey = userKey,
            fullExport = fullExport,
            sentUUIDs = mutableSetOf(),
            createdAt = System.currentTimeMillis()
        )
        
        saveSyncState(state)
        return state
    }

    // MARK: - Finalize Sync

    fun finalizeSyncState(storage: HealthBgSyncStorage) {
        val state = loadSyncState() ?: return

        // Load and save anchors
        try {
            if (anchorsFile.exists()) {
                val json = anchorsFile.readText()
                val anchors = gson.fromJson<Map<String, String>>(
                    json, 
                    object : com.google.gson.reflect.TypeToken<Map<String, String>>() {}.type
                )
                
                anchors.forEach { (typeId, anchor) ->
                    storage.saveAnchor(typeId, state.userKey, anchor)
                }
                Log.d(TAG, "✅ Saved anchors for ${anchors.size} types")
            }
        } catch (e: Exception) {
            Log.e(TAG, "Failed to load anchors: ${e.message}")
        }

        // Mark full export complete if needed
        if (state.fullExport) {
            storage.setFullExportDone(state.userKey, true)
            Log.d(TAG, "✅ Marked full export complete")
        }

        // Clear state
        clearSyncSession()
    }

    // MARK: - Check Resumable Session

    fun hasResumableSyncSession(): Boolean {
        val state = loadSyncState() ?: return false
        return state.sentUUIDs.isNotEmpty()
    }

    // MARK: - Get Sync Status

    fun getSyncStatusMap(): Map<String, Any?> {
        val state = loadSyncState()
        
        return if (state != null) {
            mapOf(
                "hasResumableSession" to state.sentUUIDs.isNotEmpty(),
                "sentCount" to state.sentUUIDs.size,
                "isFullExport" to state.fullExport,
                "createdAt" to java.text.SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss'Z'", java.util.Locale.US)
                    .apply { timeZone = java.util.TimeZone.getTimeZone("UTC") }
                    .format(Date(state.createdAt))
            )
        } else {
            mapOf(
                "hasResumableSession" to false,
                "sentCount" to 0,
                "isFullExport" to false,
                "createdAt" to null
            )
        }
    }

    // MARK: - Clear

    fun clearSyncSession() {
        try {
            stateFile.delete()
            anchorsFile.delete()
            Log.d(TAG, "🧹 Cleared sync state")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to clear sync state: ${e.message}")
        }
    }
}
