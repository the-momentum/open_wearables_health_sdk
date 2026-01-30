package com.openwearables.health.sdk

import android.content.Context
import android.content.SharedPreferences
import androidx.work.*
import com.google.gson.Gson
import com.google.gson.reflect.TypeToken
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import java.io.File
import java.text.SimpleDateFormat
import java.util.*
import java.util.concurrent.TimeUnit

/**
 * Progress tracking per data type
 */
data class TypeSyncProgress(
    val typeIdentifier: String,
    var sentCount: Int = 0,
    var isComplete: Boolean = false,
    var pendingAnchorTimestamp: Long? = null
)

/**
 * Sync state - tracks progress per type for resume capability
 */
data class SyncState(
    val userKey: String,
    val fullExport: Boolean,
    val createdAt: Long,
    var typeProgress: MutableMap<String, TypeSyncProgress> = mutableMapOf(),
    var totalSentCount: Int = 0,
    var completedTypes: MutableSet<String> = mutableSetOf(),
    var currentTypeIndex: Int = 0
) {
    val hasProgress: Boolean
        get() = totalSentCount > 0 || completedTypes.isNotEmpty()
}

/**
 * Manages health data synchronization
 */
class SyncManager(
    private val context: Context,
    private val secureStorage: SecureStorage,
    private val healthManager: SamsungHealthManager,
    private val logger: (String) -> Unit
) {
    companion object {
        private const val SYNC_PREFS_NAME = "com.openwearables.healthsdk.sync"
        private const val KEY_ANCHORS = "anchors"
        private const val KEY_FULL_EXPORT_DONE = "fullExportDone"
        
        private const val WORK_NAME_PERIODIC = "health_sync_periodic"
        private const val WORK_NAME_TESTING = "health_sync_testing"
        private const val CHUNK_SIZE = 2000
        
        // Testing mode: 1-minute interval (WorkManager minimum is 15 min for periodic, so we use chained one-time requests)
        private const val TESTING_INTERVAL_MINUTES = 1L
        private const val TESTING_MODE = true // Set to false for production (15 min intervals)
        
        // Sync state file
        private const val SYNC_STATE_DIR = "health_sync_state"
        private const val SYNC_STATE_FILE = "state.json"
    }

    private val syncPrefs: SharedPreferences by lazy {
        context.getSharedPreferences(SYNC_PREFS_NAME, Context.MODE_PRIVATE)
    }

    private val gson = Gson()
    private val httpClient = OkHttpClient.Builder()
        .connectTimeout(30, TimeUnit.SECONDS)
        .readTimeout(120, TimeUnit.SECONDS)
        .writeTimeout(120, TimeUnit.SECONDS)
        .build()

    private val dateFormat = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'", Locale.US).apply {
        timeZone = TimeZone.getTimeZone("UTC")
    }

    private var isSyncing = false
    
    // MARK: - User Key
    
    private fun userKey(): String {
        val userId = secureStorage.getUserId()
        return if (userId.isNullOrEmpty()) "user.none" else "user.$userId"
    }

    // MARK: - Background Sync

    /**
     * Start background sync using WorkManager
     */
    suspend fun startBackgroundSync(baseUrl: String, customSyncUrl: String?): Boolean {
        // Schedule periodic sync on main thread (WorkManager requirement)
        withContext(Dispatchers.Main) {
            val constraints = Constraints.Builder()
                .setRequiredNetworkType(NetworkType.CONNECTED)
                .build()

            if (TESTING_MODE) {
                // Testing mode: Use chained OneTimeWorkRequests for 1-minute intervals
                // (WorkManager's PeriodicWorkRequest has a minimum of 15 minutes)
                scheduleTestingSync(baseUrl, customSyncUrl, constraints)
                logger("🧪 TESTING MODE: Scheduled sync every $TESTING_INTERVAL_MINUTES minute(s)")
            } else {
                // Production mode: Use standard 15-minute periodic sync
                val periodicWork = PeriodicWorkRequestBuilder<HealthSyncWorker>(
                    15, TimeUnit.MINUTES,
                    5, TimeUnit.MINUTES
                )
                    .setConstraints(constraints)
                    .setInputData(
                        workDataOf(
                            HealthSyncWorker.KEY_BASE_URL to baseUrl,
                            HealthSyncWorker.KEY_CUSTOM_SYNC_URL to customSyncUrl
                        )
                    )
                    .build()

                WorkManager.getInstance(context)
                    .enqueueUniquePeriodicWork(
                        WORK_NAME_PERIODIC,
                        ExistingPeriodicWorkPolicy.UPDATE,
                        periodicWork
                    )

                logger("📅 Scheduled periodic sync every 15 minutes")
            }
        }

        // Initial sync
        syncNow(baseUrl, customSyncUrl, fullExport = !hasCompletedInitialSync())

        return true
    }
    
    /**
     * Schedule testing sync with 1-minute intervals using chained OneTimeWorkRequests
     */
    private fun scheduleTestingSync(baseUrl: String, customSyncUrl: String?, constraints: Constraints) {
        val oneTimeWork = OneTimeWorkRequestBuilder<HealthSyncWorker>()
            .setConstraints(constraints)
            .setInitialDelay(TESTING_INTERVAL_MINUTES, TimeUnit.MINUTES)
            .setInputData(
                workDataOf(
                    HealthSyncWorker.KEY_BASE_URL to baseUrl,
                    HealthSyncWorker.KEY_CUSTOM_SYNC_URL to customSyncUrl,
                    HealthSyncWorker.KEY_TESTING_MODE to true
                )
            )
            .build()

        WorkManager.getInstance(context)
            .enqueueUniqueWork(
                WORK_NAME_TESTING,
                ExistingWorkPolicy.REPLACE,
                oneTimeWork
            )
    }
    
    /**
     * Schedule an expedited one-time sync (for when app goes to background)
     */
    fun scheduleExpeditedSync(baseUrl: String, customSyncUrl: String?) {
        val constraints = Constraints.Builder()
            .setRequiredNetworkType(NetworkType.CONNECTED)
            .build()

        val expeditedWork = OneTimeWorkRequestBuilder<HealthSyncWorker>()
            .setConstraints(constraints)
            .setExpedited(OutOfQuotaPolicy.RUN_AS_NON_EXPEDITED_WORK_REQUEST)
            .setInputData(
                workDataOf(
                    HealthSyncWorker.KEY_BASE_URL to baseUrl,
                    HealthSyncWorker.KEY_CUSTOM_SYNC_URL to customSyncUrl
                )
            )
            .build()

        WorkManager.getInstance(context)
            .enqueueUniqueWork(
                "health_sync_expedited",
                ExistingWorkPolicy.REPLACE,
                expeditedWork
            )
        
        logger("🚀 Scheduled expedited sync")
    }

    /**
     * Stop background sync
     */
    suspend fun stopBackgroundSync() {
        withContext(Dispatchers.Main) {
            WorkManager.getInstance(context).cancelUniqueWork(WORK_NAME_PERIODIC)
            WorkManager.getInstance(context).cancelUniqueWork(WORK_NAME_TESTING)
            logger("🛑 Cancelled periodic sync")
        }
    }

    // MARK: - Sync Now

    /**
     * Perform sync now with session management and resume capability
     */
    suspend fun syncNow(baseUrl: String, customSyncUrl: String?, fullExport: Boolean) {
        if (isSyncing) {
            logger("⏭️ Sync already in progress")
            return
        }

        isSyncing = true

        try {
            val userId = secureStorage.getUserId()
            var accessToken = secureStorage.getAccessToken()

            if (userId == null || accessToken == null) {
                logger("❌ No credentials for sync")
                return
            }

            // Refresh token if needed
            if (secureStorage.isTokenExpired()) {
                val refreshed = refreshToken()
                if (!refreshed) {
                    logger("❌ Token refresh failed")
                    return
                }
                accessToken = secureStorage.getAccessToken()
            }

            val endpoint = buildSyncEndpoint(baseUrl, customSyncUrl, userId)
            
            // Get tracked types as list for indexed access
            val trackedTypes = healthManager.getTrackedTypes().toList()
            if (trackedTypes.isEmpty()) {
                logger("⚠️ No tracked types configured")
                return
            }

            // Check if we're resuming an interrupted sync
            val existingState = loadSyncState()
            val isResuming = existingState != null && existingState.hasProgress
            
            if (isResuming) {
                logger("🔄 Resuming sync (${existingState!!.totalSentCount} already sent, ${existingState.completedTypes.size} types done)")
            } else {
                logger("🔄 Starting streaming sync (fullExport: $fullExport, ${trackedTypes.size} types)")
                startNewSyncState(fullExport, trackedTypes)
            }
            
            // Get starting index for resume
            val startIndex = if (isResuming) getResumeTypeIndex() else 0
            
            // Process types sequentially
            processTypesSequentially(
                types = trackedTypes,
                typeIndex = startIndex,
                fullExport = fullExport,
                endpoint = endpoint,
                token = accessToken!!
            )
            
        } finally {
            isSyncing = false
        }
    }
    
    /**
     * Process types one by one - streaming approach
     */
    private suspend fun processTypesSequentially(
        types: List<String>,
        typeIndex: Int,
        fullExport: Boolean,
        endpoint: String,
        token: String
    ) {
        if (typeIndex >= types.size) {
            // All types processed
            finalizeSyncState()
            return
        }
        
        val type = types[typeIndex]
        
        // Skip already completed types
        if (!shouldSyncType(type)) {
            logger("⏭️ Skipping $type - already synced")
            processTypesSequentially(types, typeIndex + 1, fullExport, endpoint, token)
            return
        }
        
        // Update current type index for resume
        updateCurrentTypeIndex(typeIndex)
        
        // Process this type
        val success = processType(type, fullExport, endpoint, token)
        
        if (success) {
            // Continue to next type
            processTypesSequentially(types, typeIndex + 1, fullExport, endpoint, token)
        } else {
            // Failed - will resume from this type later
            logger("⚠️ Sync paused at $type, will resume later")
        }
    }
    
    /**
     * Process a single type - fetch and send data
     */
    private suspend fun processType(
        type: String,
        fullExport: Boolean,
        endpoint: String,
        token: String
    ): Boolean {
        val anchors = if (fullExport) emptyMap() else loadAnchors()
        val anchor = anchors[type]
        
        logger("📊 $type: querying...")
        
        // Read data for this type using existing readData method
        val data = healthManager.readData(type, anchor, CHUNK_SIZE)
        
        if (data.isEmpty()) {
            logger("  $type: ✓ complete (no new data)")
            updateTypeProgress(type, 0, isComplete = true, anchorTimestamp = null)
            return true
        }
        
        logger("  $type: ${data.size} samples")
        
        // Build payload for this type
        val payload = buildPayload(mapOf(type to data))
        
        // Get max timestamp for anchor (use endTime, fallback to startTime)
        val maxTimestamp = data.maxOfOrNull { it.endTime ?: it.startTime }
        
        // Send data
        val success = sendData(endpoint, token, payload)
        
        if (success) {
            // Update progress
            updateTypeProgress(type, data.size, isComplete = true, anchorTimestamp = maxTimestamp)
            logger("  $type: ✓ sent ${data.size} records")
            return true
        } else {
            logger("  $type: ❌ upload failed")
            return false
        }
    }

    // MARK: - Token Refresh

    private suspend fun refreshToken(): Boolean = withContext(Dispatchers.IO) {
        if (!secureStorage.hasRefreshCredentials()) {
            logger("⚠️ No refresh credentials available")
            return@withContext false
        }

        val appId = secureStorage.getAppId()
        val appSecret = secureStorage.getAppSecret()
        val baseUrl = secureStorage.getBaseUrl()
        val userId = secureStorage.getUserId()

        if (appId == null || appSecret == null || baseUrl == null || userId == null) {
            return@withContext false
        }

        logger("🔄 Refreshing token...")

        try {
            val url = "$baseUrl/api/v1/users/$userId/token"
            val bodyMap = mapOf("app_id" to appId, "app_secret" to appSecret)
            val body = gson.toJson(bodyMap)
            
            // Log request (mask secret)
            val logBody = mapOf("app_id" to appId, "app_secret" to "${appSecret.take(4)}***")
            logger("📤 Token refresh request: $url")
            logger("📋 REQUEST PAYLOAD: ${gson.toJson(logBody)}")
            
            val request = Request.Builder()
                .url(url)
                .post(body.toRequestBody("application/json".toMediaType()))
                .build()

            val response = httpClient.newCall(request).execute()
            val responseBody = response.body?.string()
            
            logger("📥 RESPONSE [${response.code}]: $responseBody")
            
            if (response.isSuccessful) {
                @Suppress("UNCHECKED_CAST")
                val json = gson.fromJson(responseBody, Map::class.java) as? Map<String, Any>
                val newToken = json?.get("access_token") as? String

                if (newToken != null) {
                    val fullToken = if (newToken.startsWith("Bearer ")) newToken else "Bearer $newToken"
                    secureStorage.saveCredentials(userId, fullToken)
                    secureStorage.saveTokenExpiry(System.currentTimeMillis() + 60 * 60 * 1000)
                    logger("✅ Token refreshed")
                    return@withContext true
                }
            }

            logger("❌ Token refresh failed: ${response.code}")
            return@withContext false
        } catch (e: Exception) {
            logger("❌ Token refresh error: ${e.message}")
            return@withContext false
        }
    }

    // MARK: - Data Sending

    // Pretty-printing Gson for logging
    private val prettyGson = com.google.gson.GsonBuilder().setPrettyPrinting().create()

    private suspend fun sendData(endpoint: String, accessToken: String, payload: Map<String, Any>): Boolean = 
        withContext(Dispatchers.IO) {
            try {
                val jsonBody = gson.toJson(payload)
                val prettyJson = prettyGson.toJson(payload)
                
                logger("📊 Payload size: ${jsonBody.length / 1024} KB")
                logger("📤 Endpoint: $endpoint")
                logger("🔑 Authorization: ${accessToken.take(20)}...")
                logger("📋 REQUEST PAYLOAD:\n$prettyJson")

                val request = Request.Builder()
                    .url(endpoint)
                    .post(jsonBody.toRequestBody("application/json".toMediaType()))
                    .header("Authorization", accessToken)
                    .header("Content-Type", "application/json")
                    .build()

                val response = httpClient.newCall(request).execute()
                val responseBody = response.body?.string()
                
                logger("📥 RESPONSE [${response.code}]: $responseBody")
                
                if (response.isSuccessful) {
                    return@withContext true
                } else {
                    logger("❌ Upload failed: ${response.code} - ${response.message}")
                    return@withContext false
                }
            } catch (e: Exception) {
                logger("❌ Upload error: ${e.message}")
                return@withContext false
            }
        }

    // MARK: - Payload Building (Universal structure)

    /**
     * Build payload with UNIVERSAL structure for all data types.
     * Every sample in each list has the SAME keys - backend can parse uniformly.
     * 
     * records[]: { uid, dataType, startTime, endTime, dataSource, device, values[] }
     * workouts[]: { uid, dataType, exerciseType, startTime, endTime, dataSource, device, values[], sessions[] }
     * sleep[]:    { uid, dataType, startTime, endTime, dataSource, device, values[], stages[] }
     */
    private fun buildPayload(data: Map<String, List<HealthDataRecord>>): Map<String, Any> {
        val records = mutableListOf<Map<String, Any?>>()
        val workouts = mutableListOf<Map<String, Any?>>()
        val sleep = mutableListOf<Map<String, Any?>>()

        for ((flutterTypeId, typeRecords) in data) {
            for (record in typeRecords) {
                // Common base for all samples
                val baseSample = mapOf(
                    "uid" to record.uid,
                    "dataType" to record.dataType,
                    "startTime" to record.startTime,
                    "endTime" to record.endTime,
                    "dataSource" to mapOf(
                        "appId" to record.dataSource.appId,
                        "deviceId" to record.dataSource.deviceId
                    ),
                    "device" to mapOf(
                        "deviceId" to record.device.deviceId,
                        "manufacturer" to record.device.manufacturer,
                        "model" to record.device.model,
                        "name" to record.device.name,
                        "brand" to record.device.brand,
                        "product" to record.device.product,
                        "osType" to record.device.osType,
                        "osVersion" to record.device.osVersion,
                        "sdkVersion" to record.device.sdkVersion,
                        "deviceType" to record.device.deviceType,
                        "isSourceDevice" to record.device.isSourceDevice
                    )
                )

                when (flutterTypeId) {
                    "workout" -> workouts.add(buildWorkoutSample(baseSample, record))
                    "sleep" -> sleep.add(buildSleepSample(baseSample, record))
                    else -> records.add(buildRecordSample(baseSample, record))
                }
            }
        }

        return mapOf(
            "data" to mapOf(
                "records" to records,
                "workouts" to workouts,
                "sleep" to sleep
            )
        )
    }
    
    /**
     * Build UNIVERSAL record sample structure.
     * All records have the same keys: values[] array with {type, value}
     */
    private fun buildRecordSample(base: Map<String, Any?>, record: HealthDataRecord): Map<String, Any?> {
        val sample = base.toMutableMap()
        
        // Convert fields map to universal values array
        sample["values"] = record.fields.map { (key, value) ->
            mapOf("type" to key, "value" to value)
        }
        
        return sample
    }
    
    /**
     * Build UNIVERSAL workout sample structure.
     * All workouts have: exerciseType, values[], sessions[]
     */
    private fun buildWorkoutSample(base: Map<String, Any?>, record: HealthDataRecord): Map<String, Any?> {
        val sample = base.toMutableMap()
        
        // Extract exerciseType to top level (always present for workouts)
        sample["exerciseType"] = record.fields["EXERCISE_TYPE"] ?: "UNKNOWN"
        
        // Extract sessions separately
        val sessions = record.fields["SESSIONS"] as? List<*> ?: emptyList<Any>()
        sample["sessions"] = sessions.map { session ->
            if (session is Map<*, *>) {
                // Convert session fields to universal format
                val sessionValues = session.entries
                    .filter { it.key != null && it.value != null }
                    .map { (key, value) ->
                        mapOf("type" to key.toString(), "value" to value)
                    }
                mapOf("values" to sessionValues)
            } else {
                mapOf("values" to emptyList<Any>())
            }
        }
        
        // All other fields as values array (excluding SESSIONS and EXERCISE_TYPE)
        sample["values"] = record.fields
            .filter { it.key != "SESSIONS" && it.key != "EXERCISE_TYPE" }
            .map { (key, value) ->
                mapOf("type" to key, "value" to value)
            }
        
        return sample
    }
    
    /**
     * Build UNIVERSAL sleep sample structure.
     * All sleep records have: values[], stages[]
     */
    private fun buildSleepSample(base: Map<String, Any?>, record: HealthDataRecord): Map<String, Any?> {
        val sample = base.toMutableMap()
        
        // Extract sessions/stages separately
        val sessions = record.fields["SESSIONS"] as? List<*> ?: emptyList<Any>()
        val stages = mutableListOf<Map<String, Any?>>()
        
        for (session in sessions) {
            if (session is Map<*, *>) {
                // Look for sleepStages in session
                val sleepStages = session["sleepStages"] as? List<*>
                if (sleepStages != null) {
                    for (stage in sleepStages) {
                        if (stage is Map<*, *>) {
                            stages.add(mapOf(
                                "stage" to (stage["stage"] ?: "UNKNOWN"),
                                "startTime" to stage["startTime"],
                                "endTime" to stage["endTime"]
                            ))
                        }
                    }
                }
            }
        }
        sample["stages"] = stages
        
        // All other fields as values array (excluding SESSIONS)
        sample["values"] = record.fields
            .filter { it.key != "SESSIONS" }
            .map { (key, value) ->
                mapOf("type" to key, "value" to value)
            }
        
        return sample
    }

    private fun buildSyncEndpoint(baseUrl: String, customSyncUrl: String?, userId: String): String {
        if (customSyncUrl != null) {
            // If custom URL contains placeholder, use it directly
            if (customSyncUrl.contains("{user_id}") || customSyncUrl.contains("{userId}")) {
                return customSyncUrl
                    .replace("{userId}", userId)
                    .replace("{user_id}", userId)
            }
            // Otherwise treat as base URL and append path
            val normalizedBase = customSyncUrl.trimEnd('/')
            return "$normalizedBase/sdk/users/$userId/sync/samsung"
        }
        return "$baseUrl/api/v1/sdk/users/$userId/sync/samsung"
    }

    // MARK: - Anchors (timestamps for incremental sync)

    private fun anchorKey(type: String): String = "anchor.${userKey()}.$type"
    
    private fun fullDoneKey(): String = "fullDone.${userKey()}"

    private fun loadAnchors(): Map<String, Long> {
        val json = syncPrefs.getString(KEY_ANCHORS, null) ?: return emptyMap()
        return try {
            @Suppress("UNCHECKED_CAST")
            val map = gson.fromJson(json, Map::class.java) as? Map<String, Double>
            map?.mapValues { it.value.toLong() } ?: emptyMap()
        } catch (e: Exception) {
            emptyMap()
        }
    }
    
    private fun saveAnchor(type: String, timestamp: Long) {
        val currentAnchors = loadAnchors().toMutableMap()
        currentAnchors[type] = timestamp
        val json = gson.toJson(currentAnchors)
        syncPrefs.edit().putString(KEY_ANCHORS, json).apply()
    }

    fun resetAnchors() {
        syncPrefs.edit()
            .remove(KEY_ANCHORS)
            .putBoolean(fullDoneKey(), false)
            .apply()
        clearSyncSession()
        logger("🔄 Anchors reset - will perform full sync on next sync")
    }

    private fun hasCompletedInitialSync(): Boolean {
        return syncPrefs.getBoolean(fullDoneKey(), false)
    }
    
    private fun markFullExportDone() {
        syncPrefs.edit().putBoolean(fullDoneKey(), true).apply()
    }

    // MARK: - Sync State File Management
    
    private fun syncStateDir(): File {
        return File(context.filesDir, SYNC_STATE_DIR).also { 
            if (!it.exists()) it.mkdirs() 
        }
    }
    
    private fun syncStateFile(): File = File(syncStateDir(), SYNC_STATE_FILE)
    
    // MARK: - Save/Load Sync State
    
    private fun saveSyncState(state: SyncState) {
        try {
            val json = gson.toJson(state)
            // Validate JSON before saving
            if (json.isNotBlank() && json.startsWith("{")) {
                val file = syncStateFile()
                // Write to temp file first, then rename (atomic write)
                val tempFile = File(file.parent, "${file.name}.tmp")
                tempFile.writeText(json)
                tempFile.renameTo(file)
            }
        } catch (e: Exception) {
            logger("❌ Failed to save sync state: ${e.message}")
        }
    }
    
    private fun loadSyncState(): SyncState? {
        return try {
            val file = syncStateFile()
            if (!file.exists()) return null
            
            val json = file.readText()
            if (json.isBlank()) {
                file.delete()
                return null
            }
            
            val state = gson.fromJson(json, SyncState::class.java)
            
            // Verify state belongs to current user
            if (state == null || state.userKey != userKey()) {
                logger("⚠️ Sync state invalid or for different user, clearing")
                clearSyncSession()
                return null
            }
            
            state
        } catch (e: Exception) {
            // Clear corrupted state file
            logger("⚠️ Corrupted sync state, clearing: ${e.message}")
            try {
                syncStateFile().delete()
            } catch (deleteError: Exception) {
                // Ignore delete errors
            }
            null
        }
    }
    
    // MARK: - Start New Sync State
    
    private fun startNewSyncState(fullExport: Boolean, types: List<String>): SyncState {
        val state = SyncState(
            userKey = userKey(),
            fullExport = fullExport,
            createdAt = System.currentTimeMillis(),
            typeProgress = mutableMapOf(),
            totalSentCount = 0,
            completedTypes = mutableSetOf(),
            currentTypeIndex = 0
        )
        
        saveSyncState(state)
        return state
    }
    
    // MARK: - Update Progress
    
    /**
     * Update progress for a specific type after sending a chunk
     */
    private fun updateTypeProgress(typeIdentifier: String, sentInChunk: Int, isComplete: Boolean, anchorTimestamp: Long?) {
        val state = loadSyncState() ?: return
        
        var progress = state.typeProgress[typeIdentifier] ?: TypeSyncProgress(
            typeIdentifier = typeIdentifier,
            sentCount = 0,
            isComplete = false,
            pendingAnchorTimestamp = null
        )
        
        progress.sentCount += sentInChunk
        progress.isComplete = isComplete
        if (anchorTimestamp != null) {
            progress.pendingAnchorTimestamp = anchorTimestamp
        }
        
        state.typeProgress[typeIdentifier] = progress
        state.totalSentCount += sentInChunk
        
        if (isComplete) {
            state.completedTypes.add(typeIdentifier)
            // Save anchor immediately when type is complete
            progress.pendingAnchorTimestamp?.let { timestamp ->
                saveAnchor(typeIdentifier, timestamp)
            }
        }
        
        saveSyncState(state)
    }
    
    /**
     * Mark current type index for resume
     */
    private fun updateCurrentTypeIndex(index: Int) {
        val state = loadSyncState() ?: return
        state.currentTypeIndex = index
        saveSyncState(state)
    }
    
    // MARK: - Finalize Sync
    
    private fun finalizeSyncState() {
        val state = loadSyncState() ?: return
        
        // Mark full export as complete if needed
        if (state.fullExport) {
            markFullExportDone()
            logger("✅ Marked full export complete")
        }
        
        logger("✅ Sync complete: ${state.totalSentCount} samples across ${state.completedTypes.size} types")
        
        // Clear state
        clearSyncSession()
    }

    // MARK: - Sync Session Management
    
    /**
     * Check if a specific type needs to be synced (not yet completed)
     */
    private fun shouldSyncType(typeIdentifier: String): Boolean {
        val state = loadSyncState() ?: return true
        return !state.completedTypes.contains(typeIdentifier)
    }
    
    /**
     * Get the starting type index for resume
     */
    private fun getResumeTypeIndex(): Int {
        val state = loadSyncState() ?: return 0
        return state.currentTypeIndex
    }

    fun getSyncStatus(): Map<String, Any?> {
        val state = loadSyncState()
        return if (state != null) {
            mapOf(
                "hasResumableSession" to state.hasProgress,
                "sentCount" to state.totalSentCount,
                "completedTypes" to state.completedTypes.size,
                "isFullExport" to state.fullExport,
                "createdAt" to dateFormat.format(Date(state.createdAt))
            )
        } else {
            mapOf(
                "hasResumableSession" to false,
                "sentCount" to 0,
                "completedTypes" to 0,
                "isFullExport" to false,
                "createdAt" to null
            )
        }
    }

    fun hasResumableSyncSession(): Boolean {
        val state = loadSyncState() ?: return false
        return state.hasProgress
    }

    fun clearSyncSession() {
        try {
            syncStateFile().delete()
            logger("🧹 Cleared sync state")
        } catch (e: Exception) {
            logger("❌ Failed to clear sync state: ${e.message}")
        }
    }
}

/**
 * WorkManager worker for background health sync
 */
class HealthSyncWorker(
    context: Context,
    params: WorkerParameters
) : CoroutineWorker(context, params) {

    companion object {
        const val KEY_BASE_URL = "baseUrl"
        const val KEY_CUSTOM_SYNC_URL = "customSyncUrl"
        const val KEY_TESTING_MODE = "testingMode"
        private const val NOTIFICATION_ID = 9001
        private const val CHANNEL_ID = "health_sync_channel"
        private const val WORK_NAME_TESTING = "health_sync_testing"
        private const val TESTING_INTERVAL_MINUTES = 1L
    }

    override suspend fun doWork(): Result {
        val baseUrl = inputData.getString(KEY_BASE_URL) ?: return Result.failure()
        val customSyncUrl = inputData.getString(KEY_CUSTOM_SYNC_URL)
        val isTestingMode = inputData.getBoolean(KEY_TESTING_MODE, false)

        val secureStorage = SecureStorage(applicationContext)
        val healthManager = SamsungHealthManager(applicationContext, null) { 
            android.util.Log.d("HealthSyncWorker", it) 
        }
        val syncManager = SyncManager(applicationContext, secureStorage, healthManager) { 
            android.util.Log.d("HealthSyncWorker", it) 
        }

        return try {
            // Restore tracked types
            val trackedTypes = secureStorage.getTrackedTypes()
            healthManager.setTrackedTypes(trackedTypes)

            // Perform sync
            android.util.Log.d("HealthSyncWorker", "🔄 Background sync triggered (testing mode: $isTestingMode)")
            syncManager.syncNow(baseUrl, customSyncUrl, fullExport = false)
            
            // If in testing mode, schedule the next sync after 1 minute
            if (isTestingMode) {
                scheduleNextTestingSync(baseUrl, customSyncUrl)
            }
            
            Result.success()
        } catch (e: Exception) {
            android.util.Log.e("HealthSyncWorker", "Sync failed", e)
            
            // Even if sync failed, reschedule in testing mode
            if (isTestingMode) {
                scheduleNextTestingSync(baseUrl, customSyncUrl)
            }
            
            Result.retry()
        }
    }
    
    /**
     * Schedule the next testing sync after 1 minute
     */
    private fun scheduleNextTestingSync(baseUrl: String, customSyncUrl: String?) {
        val constraints = Constraints.Builder()
            .setRequiredNetworkType(NetworkType.CONNECTED)
            .build()

        val nextWork = OneTimeWorkRequestBuilder<HealthSyncWorker>()
            .setConstraints(constraints)
            .setInitialDelay(TESTING_INTERVAL_MINUTES, TimeUnit.MINUTES)
            .setInputData(
                workDataOf(
                    KEY_BASE_URL to baseUrl,
                    KEY_CUSTOM_SYNC_URL to customSyncUrl,
                    KEY_TESTING_MODE to true
                )
            )
            .build()

        WorkManager.getInstance(applicationContext)
            .enqueueUniqueWork(
                WORK_NAME_TESTING,
                ExistingWorkPolicy.REPLACE,
                nextWork
            )
        
        android.util.Log.d("HealthSyncWorker", "🧪 Next testing sync scheduled in $TESTING_INTERVAL_MINUTES minute(s)")
    }
    
    /**
     * Required for expedited work - provides foreground notification info
     */
    override suspend fun getForegroundInfo(): ForegroundInfo {
        createNotificationChannel()
        
        val notification = androidx.core.app.NotificationCompat.Builder(applicationContext, CHANNEL_ID)
            .setContentTitle("Health Sync")
            .setContentText("Syncing health data...")
            .setSmallIcon(android.R.drawable.ic_popup_sync)
            .setPriority(androidx.core.app.NotificationCompat.PRIORITY_LOW)
            .setOngoing(true)
            .build()
        
        return ForegroundInfo(NOTIFICATION_ID, notification)
    }
    
    private fun createNotificationChannel() {
        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.O) {
            val channel = android.app.NotificationChannel(
                CHANNEL_ID,
                "Health Sync",
                android.app.NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Background health data synchronization"
            }
            
            val notificationManager = applicationContext.getSystemService(Context.NOTIFICATION_SERVICE) as android.app.NotificationManager
            notificationManager.createNotificationChannel(channel)
        }
    }
}
