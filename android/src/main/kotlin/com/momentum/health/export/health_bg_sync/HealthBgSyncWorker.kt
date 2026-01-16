package com.momentum.health.export.health_bg_sync

import android.content.Context
import android.util.Log
import androidx.work.*
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONObject
import java.util.concurrent.TimeUnit

/**
 * WorkManager worker for background health data synchronization.
 * Equivalent to iOS BGTaskScheduler implementation.
 */
class HealthBgSyncWorker(
    context: Context,
    params: WorkerParameters
) : CoroutineWorker(context, params) {

    companion object {
        private const val TAG = "HealthBgSyncWorker"
        const val WORK_NAME = "health_bg_sync_periodic"
        const val WORK_NAME_IMMEDIATE = "health_bg_sync_immediate"

        private val httpClient = OkHttpClient.Builder()
            .connectTimeout(30, TimeUnit.SECONDS)
            .writeTimeout(120, TimeUnit.SECONDS)
            .readTimeout(60, TimeUnit.SECONDS)
            .build()

        /**
         * Schedule periodic background sync.
         * Runs every 15 minutes when network is available.
         */
        fun schedulePeriodicSync(context: Context) {
            val constraints = Constraints.Builder()
                .setRequiredNetworkType(NetworkType.CONNECTED)
                .build()

            val request = PeriodicWorkRequestBuilder<HealthBgSyncWorker>(
                repeatInterval = 15,
                repeatIntervalTimeUnit = TimeUnit.MINUTES,
                flexTimeInterval = 5,
                flexTimeIntervalUnit = TimeUnit.MINUTES
            )
                .setConstraints(constraints)
                .setBackoffCriteria(
                    BackoffPolicy.EXPONENTIAL,
                    WorkRequest.MIN_BACKOFF_MILLIS,
                    TimeUnit.MILLISECONDS
                )
                .addTag("health_sync")
                .build()

            WorkManager.getInstance(context)
                .enqueueUniquePeriodicWork(
                    WORK_NAME,
                    ExistingPeriodicWorkPolicy.KEEP,
                    request
                )

            Log.d(TAG, "📅 Scheduled periodic sync")
        }

        /**
         * Trigger an immediate sync.
         */
        fun triggerImmediateSync(context: Context) {
            val constraints = Constraints.Builder()
                .setRequiredNetworkType(NetworkType.CONNECTED)
                .build()

            val request = OneTimeWorkRequestBuilder<HealthBgSyncWorker>()
                .setConstraints(constraints)
                .setExpedited(OutOfQuotaPolicy.RUN_AS_NON_EXPEDITED_WORK_REQUEST)
                .addTag("health_sync_immediate")
                .build()

            WorkManager.getInstance(context)
                .enqueueUniqueWork(
                    WORK_NAME_IMMEDIATE,
                    ExistingWorkPolicy.REPLACE,
                    request
                )

            Log.d(TAG, "🔄 Triggered immediate sync")
        }

        /**
         * Cancel all sync workers.
         */
        fun cancelSync(context: Context) {
            WorkManager.getInstance(context).cancelUniqueWork(WORK_NAME)
            WorkManager.getInstance(context).cancelUniqueWork(WORK_NAME_IMMEDIATE)
            Log.d(TAG, "🚫 Cancelled all sync workers")
        }
    }

    private val storage by lazy { HealthBgSyncStorage.getInstance(applicationContext) }
    private val session by lazy { HealthBgSyncSession(applicationContext) }

    override suspend fun doWork(): Result = withContext(Dispatchers.IO) {
        Log.d(TAG, "🔄 Background sync started")

        // Check if we have valid session
        if (!storage.hasSession()) {
            Log.d(TAG, "⚠️ No session, skipping sync")
            return@withContext Result.success()
        }

        if (!storage.isSyncActive()) {
            Log.d(TAG, "⚠️ Sync not active, skipping")
            return@withContext Result.success()
        }

        try {
            // Check token expiry and refresh if needed
            if (storage.isTokenExpired()) {
                val refreshed = refreshToken()
                if (!refreshed) {
                    Log.w(TAG, "⚠️ Token refresh failed, will retry later")
                    return@withContext Result.retry()
                }
            }

            // Initialize provider
            val provider = SamsungHealthProvider(applicationContext, storage) { msg ->
                Log.d(TAG, msg)
            }

            val initialized = provider.initialize()
            if (!initialized) {
                Log.w(TAG, "⚠️ Failed to initialize Samsung Health")
                return@withContext Result.retry()
            }

            // Get tracked types
            val trackedTypes = storage.getTrackedTypes()
            if (trackedTypes.isNullOrEmpty()) {
                Log.d(TAG, "⚠️ No tracked types, skipping sync")
                return@withContext Result.success()
            }

            // Determine if full export or incremental
            val userId = storage.getUserId() ?: return@withContext Result.failure()
            val userKey = "user.$userId"
            val isFullExport = !storage.isFullExportDone(userKey)

            // Read health data
            val syncResult = provider.readHealthData(
                types = trackedTypes,
                fullExport = isFullExport,
                userKey = userKey
            )

            if (syncResult.isEmpty) {
                Log.d(TAG, "ℹ️ No new data to sync")
                return@withContext Result.success()
            }

            // Start sync state for resumability
            if (!session.hasResumableSyncSession()) {
                session.startNewSyncState(
                    userKey = userKey,
                    fullExport = isFullExport,
                    anchors = syncResult.anchors
                )
            }

            // Upload data
            val uploadSuccess = uploadData(syncResult.toPayload(), isFullExport)

            if (uploadSuccess) {
                // Save sent UUIDs
                val uuids = syncResult.records.map { it.getString("uuid") } +
                        syncResult.workouts.map { it.getString("uuid") }
                session.addSentUUIDs(uuids)

                // Finalize sync
                session.finalizeSyncState(storage)

                provider.disconnect()
                Log.d(TAG, "✅ Background sync completed")
                return@withContext Result.success()
            } else {
                provider.disconnect()
                Log.w(TAG, "⚠️ Upload failed, will retry")
                return@withContext Result.retry()
            }
        } catch (e: Exception) {
            Log.e(TAG, "❌ Background sync error: ${e.message}")
            return@withContext Result.retry()
        }
    }

    private suspend fun refreshToken(): Boolean {
        if (!storage.hasRefreshCredentials()) {
            Log.w(TAG, "❌ Missing credentials for token refresh")
            return false
        }

        val appId = storage.getAppId() ?: return false
        val appSecret = storage.getAppSecret() ?: return false
        val baseUrl = storage.getBaseUrl() ?: return false
        val userId = storage.getUserId() ?: return false

        return try {
            val url = "$baseUrl/api/v1/users/$userId/token"
            
            val body = JSONObject().apply {
                put("app_id", appId)
                put("app_secret", appSecret)
            }

            val request = Request.Builder()
                .url(url)
                .post(body.toString().toRequestBody("application/json".toMediaType()))
                .build()

            val response = httpClient.newCall(request).execute()
            
            if (response.isSuccessful) {
                val responseBody = response.body?.string()
                val json = JSONObject(responseBody ?: "{}")
                var newToken = json.optString("access_token", "")
                
                if (newToken.isNotEmpty()) {
                    if (!newToken.startsWith("Bearer ")) {
                        newToken = "Bearer $newToken"
                    }
                    storage.saveCredentials(userId, newToken)
                    storage.saveTokenExpiry(System.currentTimeMillis() + 60 * 60 * 1000) // 60 minutes
                    Log.d(TAG, "✅ Token refreshed successfully")
                    true
                } else {
                    false
                }
            } else {
                Log.w(TAG, "❌ Token refresh failed: ${response.code}")
                false
            }
        } catch (e: Exception) {
            Log.e(TAG, "❌ Token refresh error: ${e.message}")
            false
        }
    }

    private suspend fun uploadData(payload: JSONObject, wasFullExport: Boolean): Boolean {
        val userId = storage.getUserId() ?: return false
        val token = storage.getAccessToken() ?: return false
        
        val endpoint = storage.getCustomSyncUrl()?.let { customUrl ->
            customUrl
                .replace("{userId}", userId)
                .replace("{user_id}", userId)
        } ?: run {
            val baseUrl = storage.getBaseUrl() ?: return false
            "$baseUrl/sdk/users/$userId/sync/samsung/healthion"
        }

        return try {
            val payloadStr = payload.toString()
            val sizeMB = payloadStr.length / (1024.0 * 1024.0)
            Log.d(TAG, "📤 Uploading ${String.format("%.2f", sizeMB)} MB")

            val request = Request.Builder()
                .url(endpoint)
                .post(payloadStr.toRequestBody("application/json".toMediaType()))
                .addHeader("Authorization", token)
                .addHeader("Content-Type", "application/json")
                .build()

            val response = httpClient.newCall(request).execute()
            
            if (response.isSuccessful) {
                Log.d(TAG, "✅ HTTP ${response.code}")
                true
            } else {
                val errorBody = response.body?.string()?.take(200) ?: ""
                Log.w(TAG, "❌ HTTP ${response.code} - $errorBody")
                false
            }
        } catch (e: Exception) {
            Log.e(TAG, "❌ Upload error: ${e.message}")
            false
        }
    }
}
