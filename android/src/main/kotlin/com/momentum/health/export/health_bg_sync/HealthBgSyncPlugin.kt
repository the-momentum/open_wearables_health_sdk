package com.momentum.health.export.health_bg_sync

import android.app.Activity
import android.content.Context
import android.util.Log
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import kotlinx.coroutines.*
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONObject
import java.util.concurrent.TimeUnit

/**
 * HealthBgSyncPlugin - Flutter plugin for background health data synchronization.
 * 
 * Android implementation supporting Samsung Health SDK with provider abstraction
 * for future Health Connect support.
 */
class HealthBgSyncPlugin : FlutterPlugin, MethodCallHandler, ActivityAware, EventChannel.StreamHandler {

    companion object {
        private const val TAG = "HealthBgSyncPlugin"
        private const val CHANNEL_NAME = "health_bg_sync"
        private const val LOG_CHANNEL_NAME = "health_bg_sync/logs"
    }

    // Plugin bindings
    private lateinit var channel: MethodChannel
    private lateinit var logChannel: EventChannel
    private var context: Context? = null
    private var activity: Activity? = null

    // Components
    private var storage: HealthBgSyncStorage? = null
    private var session: HealthBgSyncSession? = null
    private var samsungProvider: SamsungHealthProvider? = null

    // Configuration
    private var baseUrl: String? = null
    private var customSyncUrl: String? = null
    private var trackedTypes: List<String> = emptyList()

    // Coroutine scope
    private val scope = CoroutineScope(Dispatchers.Main + SupervisorJob())

    // Log event sink
    private var logEventSink: EventChannel.EventSink? = null

    // HTTP client
    private val httpClient = OkHttpClient.Builder()
        .connectTimeout(30, TimeUnit.SECONDS)
        .writeTimeout(120, TimeUnit.SECONDS)
        .readTimeout(60, TimeUnit.SECONDS)
        .build()

    // Sync state
    private var isSyncing = false
    private var isInitialSyncInProgress = false

    // MARK: - FlutterPlugin

    override fun onAttachedToEngine(flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
        context = flutterPluginBinding.applicationContext
        storage = HealthBgSyncStorage.getInstance(flutterPluginBinding.applicationContext)
        session = HealthBgSyncSession(flutterPluginBinding.applicationContext)

        channel = MethodChannel(flutterPluginBinding.binaryMessenger, CHANNEL_NAME)
        channel.setMethodCallHandler(this)

        logChannel = EventChannel(flutterPluginBinding.binaryMessenger, LOG_CHANNEL_NAME)
        logChannel.setStreamHandler(this)

        log("📱 HealthBgSync plugin attached")
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        logChannel.setStreamHandler(null)
        scope.cancel()
        samsungProvider?.disconnect()
        context = null
    }

    // MARK: - ActivityAware

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
    }

    override fun onDetachedFromActivityForConfigChanges() {
        activity = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        activity = binding.activity
    }

    override fun onDetachedFromActivity() {
        activity = null
    }

    // MARK: - EventChannel.StreamHandler

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        logEventSink = events
    }

    override fun onCancel(arguments: Any?) {
        logEventSink = null
    }

    // MARK: - MethodCallHandler

    override fun onMethodCall(call: MethodCall, result: Result) {
        when (call.method) {
            "configure" -> handleConfigure(call, result)
            "signIn" -> handleSignIn(call, result)
            "signOut" -> handleSignOut(result)
            "restoreSession" -> handleRestoreSession(result)
            "isSessionValid" -> result.success(storage?.hasSession() == true)
            "isSyncActive" -> result.success(storage?.isSyncActive() == true)
            "getStoredCredentials" -> handleGetStoredCredentials(result)
            "requestAuthorization" -> handleRequestAuthorization(call, result)
            "syncNow" -> handleSyncNow(result)
            "startBackgroundSync" -> handleStartBackgroundSync(result)
            "stopBackgroundSync" -> handleStopBackgroundSync(result)
            "resetAnchors" -> handleResetAnchors(result)
            "getSyncStatus" -> handleGetSyncStatus(result)
            "resumeSync" -> handleResumeSync(result)
            "clearSyncSession" -> handleClearSyncSession(result)
            "setProvider" -> handleSetProvider(call, result)
            "getAvailableProviders" -> handleGetAvailableProviders(result)
            else -> result.notImplemented()
        }
    }

    // MARK: - Configure

    private fun handleConfigure(call: MethodCall, result: Result) {
        val args = call.arguments as? Map<*, *>
        val baseUrlArg = args?.get("baseUrl") as? String

        if (baseUrlArg == null) {
            result.error("bad_args", "Missing baseUrl", null)
            return
        }

        baseUrl = baseUrlArg

        // Use provided customSyncUrl, or restore from storage
        val providedCustomUrl = args["customSyncUrl"] as? String
        if (providedCustomUrl != null) {
            customSyncUrl = providedCustomUrl
            storage?.saveCustomSyncUrl(providedCustomUrl)
        } else {
            customSyncUrl = storage?.getCustomSyncUrl()
        }

        // Restore tracked types if available
        storage?.getTrackedTypes()?.let { types ->
            trackedTypes = types
            log("📋 Restored ${trackedTypes.size} tracked types")
        }

        if (customSyncUrl != null) {
            log("✅ Configured: customSyncUrl=$customSyncUrl")
        } else {
            log("✅ Configured: baseUrl=$baseUrl")
        }

        // Auto-start sync if was previously active and session exists
        if (storage?.isSyncActive() == true && storage?.hasSession() == true && trackedTypes.isNotEmpty()) {
            log("🔄 Auto-restoring background sync...")
            scope.launch {
                autoRestoreSync()
            }
        }

        // Return whether sync was auto-restored
        result.success(storage?.isSyncActive() == true)
    }

    private suspend fun autoRestoreSync() {
        val ctx = context ?: return
        
        if (storage?.getUserId() == null || storage?.getAccessToken() == null) {
            log("⚠️ Cannot auto-restore: no session")
            return
        }

        // Initialize provider
        initializeProvider()

        // Schedule background sync
        HealthBgSyncWorker.schedulePeriodicSync(ctx)

        // Check for resumable sync session
        if (session?.hasResumableSyncSession() == true) {
            log("📂 Found interrupted sync, will resume...")
            val refreshed = refreshTokenIfNeeded()
            if (refreshed) {
                syncAll(fullExport = false)
            } else {
                log("⚠️ Token refresh failed, will retry later")
            }
        }

        log("✅ Background sync auto-restored")
    }

    // MARK: - Sign In

    private fun handleSignIn(call: MethodCall, result: Result) {
        val args = call.arguments as? Map<*, *>
        val userId = args?.get("userId") as? String
        val accessToken = args?.get("accessToken") as? String

        if (userId == null || accessToken == null) {
            result.error("bad_args", "Missing userId or accessToken", null)
            return
        }

        // Save to secure storage
        storage?.saveCredentials(userId, accessToken)

        // Save app credentials for token refresh (optional)
        val appId = args["appId"] as? String
        val appSecret = args["appSecret"] as? String
        val signInBaseUrl = args["baseUrl"] as? String

        if (appId != null && appSecret != null && signInBaseUrl != null) {
            storage?.saveAppCredentials(appId, appSecret, signInBaseUrl)
            log("✅ App credentials saved for refresh")
        }

        // Save token expiry (60 minutes from now)
        storage?.saveTokenExpiry(System.currentTimeMillis() + 60 * 60 * 1000)

        log("✅ Signed in: userId=$userId")

        result.success(null)
    }

    // MARK: - Sign Out

    private fun handleSignOut(result: Result) {
        log("🔓 Signing out")

        val ctx = context
        if (ctx != null) {
            HealthBgSyncWorker.cancelSync(ctx)
        }

        samsungProvider?.disconnect()
        samsungProvider = null

        storage?.clearAll()
        session?.clearSyncSession()

        result.success(null)
    }

    // MARK: - Restore Session

    private fun handleRestoreSession(result: Result) {
        val userId = storage?.getUserId()
        if (storage?.hasSession() == true && userId != null) {
            log("📱 Session restored: userId=$userId")
            result.success(userId)
        } else {
            result.success(null)
        }
    }

    // MARK: - Get Stored Credentials

    private fun handleGetStoredCredentials(result: Result) {
        val credentials = mapOf(
            "userId" to storage?.getUserId(),
            "accessToken" to storage?.getAccessToken(),
            "customSyncUrl" to storage?.getCustomSyncUrl(),
            "isSyncActive" to (storage?.isSyncActive() ?: false),
            "provider" to (storage?.getProvider()?.id ?: HealthProvider.SAMSUNG_HEALTH.id)
        )
        result.success(credentials)
    }

    // MARK: - Request Authorization

    private fun handleRequestAuthorization(call: MethodCall, result: Result) {
        val args = call.arguments as? Map<*, *>
        @Suppress("UNCHECKED_CAST")
        val types = args?.get("types") as? List<String>

        if (types == null) {
            result.error("bad_args", "Missing types", null)
            return
        }

        trackedTypes = types
        storage?.saveTrackedTypes(types)

        log("📋 Requesting auth for ${trackedTypes.size} types")

        val act = activity
        if (act == null) {
            result.error("no_activity", "No activity available", null)
            return
        }

        scope.launch {
            try {
                initializeProvider()
                
                val provider = samsungProvider
                if (provider == null) {
                    result.error("provider_error", "Failed to initialize Samsung Health", null)
                    return@launch
                }

                val granted = provider.requestPermissions(act, types)
                result.success(granted)
            } catch (e: Exception) {
                log("❌ Permission request failed: ${e.message}")
                result.error("permission_error", e.message, null)
            }
        }
    }

    // MARK: - Sync Now

    private fun handleSyncNow(result: Result) {
        scope.launch {
            syncAll(fullExport = false)
            result.success(null)
        }
    }

    // MARK: - Start Background Sync

    private fun handleStartBackgroundSync(result: Result) {
        if (storage?.getUserId() == null || storage?.getAccessToken() == null) {
            result.error("not_signed_in", "Not signed in", null)
            return
        }

        val ctx = context
        if (ctx == null) {
            result.error("no_context", "No context available", null)
            return
        }

        scope.launch {
            try {
                // Initialize provider
                initializeProvider()

                // Schedule periodic background sync
                HealthBgSyncWorker.schedulePeriodicSync(ctx)

                // Perform initial sync
                val userId = storage?.getUserId() ?: return@launch
                val userKey = "user.$userId"
                val isFullExport = storage?.isFullExportDone(userKey) != true

                if (isFullExport) {
                    log("🔄 Starting full export")
                    isInitialSyncInProgress = true
                }

                syncAll(fullExport = isFullExport)

                storage?.setSyncActive(true)
                
                log("✅ Background sync started")
                result.success(true)
            } catch (e: Exception) {
                log("❌ Failed to start background sync: ${e.message}")
                result.success(false)
            }
        }
    }

    // MARK: - Stop Background Sync

    private fun handleStopBackgroundSync(result: Result) {
        val ctx = context
        if (ctx != null) {
            HealthBgSyncWorker.cancelSync(ctx)
        }

        storage?.setSyncActive(false)
        log("🔌 Background sync stopped")
        
        result.success(null)
    }

    // MARK: - Reset Anchors

    private fun handleResetAnchors(result: Result) {
        val userId = storage?.getUserId()
        if (userId != null) {
            val userKey = "user.$userId"
            trackedTypes.forEach { type ->
                storage?.removeAnchor(type, userKey)
            }
            storage?.setFullExportDone(userKey, false)
        }
        session?.clearSyncSession()
        log("🔄 Reset all anchors")
        result.success(null)
    }

    // MARK: - Get Sync Status

    private fun handleGetSyncStatus(result: Result) {
        val status = session?.getSyncStatusMap() ?: mapOf(
            "hasResumableSession" to false,
            "sentCount" to 0,
            "isFullExport" to false,
            "createdAt" to null
        )
        result.success(status)
    }

    // MARK: - Resume Sync

    private fun handleResumeSync(result: Result) {
        if (session?.hasResumableSyncSession() != true) {
            result.error("no_session", "No resumable sync session", null)
            return
        }

        scope.launch {
            syncAll(fullExport = false)
            result.success(null)
        }
    }

    // MARK: - Clear Sync Session

    private fun handleClearSyncSession(result: Result) {
        session?.clearSyncSession()
        result.success(null)
    }

    // MARK: - Provider Selection

    private fun handleSetProvider(call: MethodCall, result: Result) {
        val args = call.arguments as? Map<*, *>
        val providerId = args?.get("provider") as? String

        if (providerId == null) {
            result.error("bad_args", "Missing provider", null)
            return
        }

        val provider = HealthProvider.fromId(providerId)
        if (provider == null) {
            result.error("invalid_provider", "Unknown provider: $providerId", null)
            return
        }

        storage?.saveProvider(provider)
        
        // Reinitialize with new provider
        samsungProvider?.disconnect()
        samsungProvider = null
        
        scope.launch {
            initializeProvider()
            result.success(null)
        }
    }

    private fun handleGetAvailableProviders(result: Result) {
        val ctx = context
        if (ctx == null) {
            result.success(emptyList<String>())
            return
        }

        val available = HealthProvider.getAvailableProviders(ctx)
        result.success(available.map { 
            mapOf(
                "id" to it.id,
                "displayName" to it.displayName
            )
        })
    }

    // MARK: - Provider Initialization

    private suspend fun initializeProvider() {
        val ctx = context ?: return
        val stor = storage ?: return

        // For now, only Samsung Health is supported
        if (samsungProvider == null) {
            samsungProvider = SamsungHealthProvider(ctx, stor) { msg ->
                log(msg)
            }
        }

        samsungProvider?.initialize()
    }

    // MARK: - Sync Implementation

    private suspend fun syncAll(fullExport: Boolean) {
        if (isSyncing) {
            log("⚠️ Sync already in progress")
            return
        }

        isSyncing = true

        try {
            // Refresh token if needed
            if (!refreshTokenIfNeeded()) {
                log("❌ Token refresh failed, cannot sync")
                return
            }

            val provider = samsungProvider
            if (provider == null) {
                log("❌ Provider not initialized")
                return
            }

            val userId = storage?.getUserId() ?: return
            val userKey = "user.$userId"

            // Read health data
            val syncResult = provider.readHealthData(
                types = trackedTypes,
                fullExport = fullExport,
                userKey = userKey
            )

            if (syncResult.isEmpty) {
                log("ℹ️ No new data to sync")
                
                // If resuming, finalize
                if (session?.hasResumableSyncSession() == true) {
                    session?.finalizeSyncState(storage!!)
                }
                return
            }

            // Start sync state for resumability
            if (session?.hasResumableSyncSession() != true) {
                session?.startNewSyncState(
                    userKey = userKey,
                    fullExport = fullExport,
                    anchors = syncResult.anchors
                )
            }

            // Upload data in chunks
            val chunkSize = 2000
            val allRecords = syncResult.records + syncResult.workouts
            val chunks = allRecords.chunked(chunkSize)

            log("📦 Splitting into ${chunks.size} chunks")

            for ((index, chunk) in chunks.withIndex()) {
                val isLastChunk = index == chunks.lastIndex
                
                log("📤 Chunk ${index + 1}/${chunks.size}: ${chunk.size} items")

                val payload = JSONObject().apply {
                    val data = JSONObject()
                    val records = org.json.JSONArray()
                    val workouts = org.json.JSONArray()
                    
                    chunk.forEach { item ->
                        if (item.optString("type") == "com.samsung.health.exercise") {
                            workouts.put(item)
                        } else {
                            records.put(item)
                        }
                    }
                    
                    data.put("records", records)
                    data.put("workouts", workouts)
                    put("data", data)
                }

                val success = uploadPayload(payload, isLastChunk && fullExport)

                if (success) {
                    // Mark UUIDs as sent
                    val uuids = chunk.map { it.getString("uuid") }
                    session?.addSentUUIDs(uuids)

                    if (isLastChunk) {
                        session?.finalizeSyncState(storage!!)
                    }
                } else {
                    log("❌ Chunk ${index + 1} failed, will resume later")
                    return
                }
            }

            log("✅ Sync completed")

        } finally {
            isSyncing = false
            isInitialSyncInProgress = false
        }
    }

    private suspend fun uploadPayload(payload: JSONObject, wasFullExport: Boolean): Boolean {
        val userId = storage?.getUserId() ?: return false
        val token = storage?.getAccessToken() ?: return false

        val endpoint = customSyncUrl?.let { url ->
            url.replace("{userId}", userId)
                .replace("{user_id}", userId)
        } ?: run {
            val base = baseUrl ?: return false
            "$base/sdk/users/$userId/sync/samsung/healthion"
        }

        return withContext(Dispatchers.IO) {
            try {
                val payloadStr = payload.toString()
                val sizeMB = payloadStr.length / (1024.0 * 1024.0)
                log("📤 Sending ${String.format("%.2f", sizeMB)} MB")

                val request = Request.Builder()
                    .url(endpoint)
                    .post(payloadStr.toRequestBody("application/json".toMediaType()))
                    .addHeader("Authorization", token)
                    .addHeader("Content-Type", "application/json")
                    .build()

                val response = httpClient.newCall(request).execute()

                if (response.isSuccessful) {
                    log("✅ HTTP ${response.code}")
                    true
                } else {
                    val errorBody = response.body?.string()?.take(200) ?: ""
                    log("❌ HTTP ${response.code} - $errorBody")
                    false
                }
            } catch (e: Exception) {
                log("❌ Upload error: ${e.message}")
                false
            }
        }
    }

    private suspend fun refreshTokenIfNeeded(): Boolean {
        if (storage?.isTokenExpired() != true) {
            return true
        }

        log("🔄 Token expired, refreshing...")

        if (storage?.hasRefreshCredentials() != true) {
            log("❌ Missing credentials for token refresh")
            return false
        }

        val appId = storage?.getAppId() ?: return false
        val appSecret = storage?.getAppSecret() ?: return false
        val refreshBaseUrl = storage?.getBaseUrl() ?: return false
        val userId = storage?.getUserId() ?: return false

        return withContext(Dispatchers.IO) {
            try {
                val url = "$refreshBaseUrl/api/v1/users/$userId/token"

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
                        storage?.saveCredentials(userId, newToken)
                        storage?.saveTokenExpiry(System.currentTimeMillis() + 60 * 60 * 1000)
                        log("✅ Token refreshed successfully")
                        true
                    } else {
                        log("❌ Token refresh: empty token")
                        false
                    }
                } else {
                    log("❌ Token refresh failed: ${response.code}")
                    false
                }
            } catch (e: Exception) {
                log("❌ Token refresh error: ${e.message}")
                false
            }
        }
    }

    // MARK: - Logging

    private fun log(message: String) {
        Log.d(TAG, message)
        scope.launch(Dispatchers.Main) {
            logEventSink?.success(message)
        }
    }
}
