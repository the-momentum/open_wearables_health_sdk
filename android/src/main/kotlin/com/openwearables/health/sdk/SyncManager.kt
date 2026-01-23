package com.openwearables.health.sdk

import android.content.Context
import android.content.SharedPreferences
import androidx.work.*
import com.google.gson.Gson
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import java.text.SimpleDateFormat
import java.util.*
import java.util.concurrent.TimeUnit

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
        private const val KEY_SYNC_SESSION = "syncSession"
        private const val KEY_SENT_COUNT = "sentCount"
        private const val KEY_IS_FULL_EXPORT = "isFullExport"
        private const val KEY_CREATED_AT = "createdAt"
        private const val KEY_COMPLETED_TYPES = "completedTypes"
        
        private const val WORK_NAME_PERIODIC = "health_sync_periodic"
        private const val CHUNK_SIZE = 1000
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

        // Initial sync
        syncNow(baseUrl, customSyncUrl, fullExport = !hasCompletedInitialSync())

        return true
    }

    /**
     * Stop background sync
     */
    suspend fun stopBackgroundSync() {
        withContext(Dispatchers.Main) {
            WorkManager.getInstance(context).cancelUniqueWork(WORK_NAME_PERIODIC)
            logger("🛑 Cancelled periodic sync")
        }
    }

    // MARK: - Sync Now

    /**
     * Perform sync now
     */
    suspend fun syncNow(baseUrl: String, customSyncUrl: String?, fullExport: Boolean) {
        if (isSyncing) {
            logger("⏭️ Sync already in progress")
            return
        }

        isSyncing = true

        try {
            val userId = secureStorage.getUserId()
            val accessToken = secureStorage.getAccessToken()

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
            }

            val endpoint = buildSyncEndpoint(baseUrl, customSyncUrl, userId)
            logger("🔄 Starting sync (fullExport: $fullExport)")

            // Collect and sync data
            val trackedTypes = healthManager.getTrackedTypes()
            if (trackedTypes.isEmpty()) {
                logger("⚠️ No tracked types configured")
                return
            }

            // Load anchors
            val anchors = if (fullExport) emptyMap() else loadAnchors()

            // Read data from Samsung Health
            val data = healthManager.readAllData(anchors, CHUNK_SIZE)
            
            if (data.isEmpty()) {
                logger("✅ No new data to sync")
                return
            }

            // Send data to server
            val totalRecords = data.values.sumOf { it.size }
            logger("📤 Sending $totalRecords records...")

            val payload = buildPayload(data)
            val success = sendData(endpoint, accessToken, payload)

            if (success) {
                // Update anchors with latest timestamps
                updateAnchors(data)
                logger("✅ Sync completed: $totalRecords records sent")
            } else {
                logger("❌ Sync failed")
            }
        } finally {
            isSyncing = false
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
            val body = gson.toJson(mapOf("app_id" to appId, "app_secret" to appSecret))
            
            val request = Request.Builder()
                .url(url)
                .post(body.toRequestBody("application/json".toMediaType()))
                .build()

            val response = httpClient.newCall(request).execute()
            
            if (response.isSuccessful) {
                val responseBody = response.body?.string()
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

    private suspend fun sendData(endpoint: String, accessToken: String, payload: Map<String, Any>): Boolean = 
        withContext(Dispatchers.IO) {
            try {
                val jsonBody = gson.toJson(payload)
                logger("📊 Payload size: ${jsonBody.length / 1024} KB")

                val request = Request.Builder()
                    .url(endpoint)
                    .post(jsonBody.toRequestBody("application/json".toMediaType()))
                    .header("Authorization", accessToken)
                    .header("Content-Type", "application/json")
                    .build()

                val response = httpClient.newCall(request).execute()
                
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

    // MARK: - Payload Building

    private fun buildPayload(data: Map<String, List<HealthDataRecord>>): Map<String, Any> {
        val records = mutableListOf<Map<String, Any?>>()
        val workouts = mutableListOf<Map<String, Any?>>()
        val sleep = mutableListOf<Map<String, Any?>>()

        for ((type, typeRecords) in data) {
            for (record in typeRecords) {
                val recordMap = mapOf(
                    "uuid" to record.uuid,
                    "type" to record.type,
                    "value" to record.value,
                    "unit" to record.unit,
                    "startDate" to dateFormat.format(Date(record.startDate)),
                    "endDate" to dateFormat.format(Date(record.endDate)),
                    "source" to mapOf(
                        "name" to record.source.name,
                        "bundleIdentifier" to record.source.bundleIdentifier,
                        "deviceId" to record.source.deviceId
                    ),
                    "recordMetadata" to record.metadata.map { 
                        mapOf("key" to it.key, "value" to it.value) 
                    }
                )

                when (type) {
                    "workout" -> workouts.add(recordMap)
                    "sleep" -> sleep.add(recordMap)
                    else -> records.add(recordMap)
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

    private fun buildSyncEndpoint(baseUrl: String, customSyncUrl: String?, userId: String): String {
        if (customSyncUrl != null) {
            return customSyncUrl
                .replace("{userId}", userId)
                .replace("{user_id}", userId)
        }
        return "$baseUrl/sdk/users/$userId/sync/samsung/healthion"
    }

    // MARK: - Anchors (timestamps for incremental sync)

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

    private fun updateAnchors(data: Map<String, List<HealthDataRecord>>) {
        val currentAnchors = loadAnchors().toMutableMap()
        
        for ((type, records) in data) {
            val maxTimestamp = records.maxOfOrNull { it.endDate }
            if (maxTimestamp != null) {
                currentAnchors[type] = maxTimestamp
            }
        }

        val json = gson.toJson(currentAnchors)
        syncPrefs.edit().putString(KEY_ANCHORS, json).apply()
    }

    fun resetAnchors() {
        syncPrefs.edit().remove(KEY_ANCHORS).apply()
        logger("🔄 Anchors reset")
    }

    private fun hasCompletedInitialSync(): Boolean {
        return syncPrefs.getString(KEY_ANCHORS, null) != null
    }

    // MARK: - Sync Session Management

    fun getSyncStatus(): Map<String, Any?> {
        return mapOf(
            "hasResumableSession" to hasResumableSyncSession(),
            "sentCount" to syncPrefs.getInt(KEY_SENT_COUNT, 0),
            "isFullExport" to syncPrefs.getBoolean(KEY_IS_FULL_EXPORT, false),
            "createdAt" to syncPrefs.getString(KEY_CREATED_AT, null)
        )
    }

    fun hasResumableSyncSession(): Boolean {
        return syncPrefs.contains(KEY_SYNC_SESSION)
    }

    fun clearSyncSession() {
        syncPrefs.edit()
            .remove(KEY_SYNC_SESSION)
            .remove(KEY_SENT_COUNT)
            .remove(KEY_IS_FULL_EXPORT)
            .remove(KEY_CREATED_AT)
            .remove(KEY_COMPLETED_TYPES)
            .apply()
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
    }

    override suspend fun doWork(): Result {
        val baseUrl = inputData.getString(KEY_BASE_URL) ?: return Result.failure()
        val customSyncUrl = inputData.getString(KEY_CUSTOM_SYNC_URL)

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
            syncManager.syncNow(baseUrl, customSyncUrl, fullExport = false)
            Result.success()
        } catch (e: Exception) {
            android.util.Log.e("HealthSyncWorker", "Sync failed", e)
            Result.retry()
        }
    }
}
