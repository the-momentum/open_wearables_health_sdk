package com.openwearables.health.sdk

import android.app.Activity
import android.content.Context
import android.util.Log
import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.ProcessLifecycleOwner
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import kotlinx.coroutines.*

/**
 * OpenWearablesHealthSdkPlugin - Flutter plugin for Samsung Health data sync
 */
class OpenWearablesHealthSdkPlugin : FlutterPlugin, MethodCallHandler, ActivityAware, EventChannel.StreamHandler, DefaultLifecycleObserver {

    companion object {
        private const val TAG = "OpenWearablesHealthSdk"
        private const val CHANNEL_NAME = "open_wearables_health_sdk"
        private const val LOG_CHANNEL_NAME = "open_wearables_health_sdk/logs"
    }

    // Flutter channels
    private lateinit var methodChannel: MethodChannel
    private lateinit var logChannel: EventChannel
    private var logEventSink: EventChannel.EventSink? = null

    // Context references
    private var context: Context? = null
    private var activity: Activity? = null

    // Components (lazy initialized)
    private val secureStorage: SecureStorage by lazy { SecureStorage(context!!) }
    private val samsungHealthManager: SamsungHealthManager by lazy { 
        SamsungHealthManager(context!!, activity, ::logMessage) 
    }
    private val syncManager: SyncManager by lazy { 
        SyncManager(context!!, secureStorage, samsungHealthManager, ::logMessage) 
    }

    // Configuration
    private var baseUrl: String? = null
    private var customSyncUrl: String? = null
    
    // Lifecycle tracking
    private var isInForeground = true
    private var lifecycleObserverRegistered = false

    // Coroutine scope for async operations
    private val scope = CoroutineScope(Dispatchers.Main + SupervisorJob())

    // MARK: - FlutterPlugin

    override fun onAttachedToEngine(flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
        context = flutterPluginBinding.applicationContext

        methodChannel = MethodChannel(flutterPluginBinding.binaryMessenger, CHANNEL_NAME)
        methodChannel.setMethodCallHandler(this)

        logChannel = EventChannel(flutterPluginBinding.binaryMessenger, LOG_CHANNEL_NAME)
        logChannel.setStreamHandler(this)
        
        // Register lifecycle observer to detect app going to background
        registerLifecycleObserver()

        Log.d(TAG, "Plugin attached to engine")
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methodChannel.setMethodCallHandler(null)
        logChannel.setStreamHandler(null)
        unregisterLifecycleObserver()
        scope.cancel()
        context = null
        Log.d(TAG, "Plugin detached from engine")
    }
    
    // MARK: - Lifecycle Observer
    
    private fun registerLifecycleObserver() {
        if (!lifecycleObserverRegistered) {
            try {
                ProcessLifecycleOwner.get().lifecycle.addObserver(this)
                lifecycleObserverRegistered = true
                Log.d(TAG, "Lifecycle observer registered")
            } catch (e: Exception) {
                Log.e(TAG, "Failed to register lifecycle observer: ${e.message}")
            }
        }
    }
    
    private fun unregisterLifecycleObserver() {
        if (lifecycleObserverRegistered) {
            try {
                ProcessLifecycleOwner.get().lifecycle.removeObserver(this)
                lifecycleObserverRegistered = false
            } catch (e: Exception) {
                Log.e(TAG, "Failed to unregister lifecycle observer: ${e.message}")
            }
        }
    }
    
    // MARK: - DefaultLifecycleObserver
    
    override fun onStart(owner: LifecycleOwner) {
        isInForeground = true
        logMessage("📱 App came to foreground")
        
        // Check if we have pending sync to resume
        if (secureStorage.isSyncActive() && secureStorage.hasSession()) {
            logMessage("🔄 Checking for pending sync...")
            scope.launch {
                if (syncManager.hasResumableSyncSession()) {
                    logMessage("📂 Found interrupted sync, resuming...")
                    baseUrl?.let { url ->
                        syncManager.syncNow(url, customSyncUrl, fullExport = false)
                    }
                }
            }
        }
    }
    
    override fun onStop(owner: LifecycleOwner) {
        isInForeground = false
        logMessage("📱 App went to background")
        
        // Trigger expedited sync when going to background
        if (secureStorage.isSyncActive() && secureStorage.hasSession()) {
            baseUrl?.let { url ->
                logMessage("🚀 Scheduling background sync...")
                syncManager.scheduleExpeditedSync(url, customSyncUrl)
            }
        }
    }

    // MARK: - ActivityAware

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
        samsungHealthManager.setActivity(activity)
    }

    override fun onDetachedFromActivityForConfigChanges() {
        activity = null
        samsungHealthManager.setActivity(null)
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        activity = binding.activity
        samsungHealthManager.setActivity(activity)
    }

    override fun onDetachedFromActivity() {
        activity = null
        samsungHealthManager.setActivity(null)
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
            "isSessionValid" -> result.success(secureStorage.hasSession())
            "isSyncActive" -> result.success(secureStorage.isSyncActive())
            "getStoredCredentials" -> handleGetStoredCredentials(result)
            "requestAuthorization" -> handleRequestAuthorization(call, result)
            "startBackgroundSync" -> handleStartBackgroundSync(result)
            "stopBackgroundSync" -> handleStopBackgroundSync(result)
            "syncNow" -> handleSyncNow(result)
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
        val baseUrl = call.argument<String>("baseUrl")
        if (baseUrl == null) {
            result.error("bad_args", "Missing baseUrl", null)
            return
        }

        this.baseUrl = baseUrl
        this.customSyncUrl = call.argument<String>("customSyncUrl")
            ?: secureStorage.getCustomSyncUrl()

        if (customSyncUrl != null) {
            secureStorage.saveCustomSyncUrl(customSyncUrl!!)
        }

        // Restore tracked types if available
        val storedTypes = secureStorage.getTrackedTypes()
        if (storedTypes.isNotEmpty()) {
            samsungHealthManager.setTrackedTypes(storedTypes)
            logMessage("📋 Restored ${storedTypes.size} tracked types")
        }

        logMessage("✅ Configured: ${customSyncUrl ?: baseUrl}")

        // Check if sync was active and should auto-restore
        val isSyncActive = secureStorage.isSyncActive() && secureStorage.hasSession()
        
        if (isSyncActive && storedTypes.isNotEmpty()) {
            logMessage("🔄 Auto-restoring background sync...")
            scope.launch {
                autoRestoreSync()
            }
        }

        result.success(isSyncActive)
    }

    private suspend fun autoRestoreSync() {
        if (secureStorage.getUserId() == null || secureStorage.getAccessToken() == null) {
            logMessage("⚠️ Cannot auto-restore: no session")
            return
        }

        syncManager.startBackgroundSync(baseUrl!!, customSyncUrl)
        logMessage("✅ Background sync auto-restored")
    }

    // MARK: - Sign In

    private fun handleSignIn(call: MethodCall, result: Result) {
        val userId = call.argument<String>("userId")
        val accessToken = call.argument<String>("accessToken")

        if (userId == null || accessToken == null) {
            result.error("bad_args", "Missing userId or accessToken", null)
            return
        }

        secureStorage.saveCredentials(userId, accessToken)

        // Save app credentials for token refresh (optional)
        val appId = call.argument<String>("appId")
        val appSecret = call.argument<String>("appSecret")
        val tokenBaseUrl = call.argument<String>("baseUrl")

        if (appId != null && appSecret != null && tokenBaseUrl != null) {
            secureStorage.saveAppCredentials(appId, appSecret, tokenBaseUrl)
            logMessage("✅ App credentials saved for refresh")
        }

        // Save token expiry (60 minutes from now)
        secureStorage.saveTokenExpiry(System.currentTimeMillis() + 60 * 60 * 1000)

        logMessage("✅ Signed in: userId=$userId")
        result.success(null)
    }

    // MARK: - Sign Out

    private fun handleSignOut(result: Result) {
        logMessage("🔓 Signing out")

        scope.launch {
            syncManager.stopBackgroundSync()
            syncManager.resetAnchors()
            syncManager.clearSyncSession()
            secureStorage.clearAll()

            logMessage("✅ Sign out complete - all sync state reset")
            result.success(null)
        }
    }

    // MARK: - Restore Session

    private fun handleRestoreSession(result: Result) {
        if (secureStorage.hasSession()) {
            val userId = secureStorage.getUserId()
            logMessage("📱 Session restored: userId=$userId")
            result.success(userId)
        } else {
            result.success(null)
        }
    }

    // MARK: - Get Stored Credentials

    private fun handleGetStoredCredentials(result: Result) {
        val credentials = mapOf(
            "userId" to secureStorage.getUserId(),
            "accessToken" to secureStorage.getAccessToken(),
            "customSyncUrl" to secureStorage.getCustomSyncUrl(),
            "isSyncActive" to secureStorage.isSyncActive()
        )
        result.success(credentials)
    }

    // MARK: - Request Authorization

    private fun handleRequestAuthorization(call: MethodCall, result: Result) {
        val types = call.argument<List<String>>("types")
        if (types == null) {
            result.error("bad_args", "Missing types", null)
            return
        }

        // Save tracked types for restoration after restart
        secureStorage.saveTrackedTypes(types)
        samsungHealthManager.setTrackedTypes(types)

        logMessage("📋 Requesting auth for ${types.size} types")

        scope.launch {
            try {
                val authorized = samsungHealthManager.requestAuthorization(types)
                result.success(authorized)
            } catch (e: Exception) {
                logMessage("❌ Authorization failed: ${e.message}")
                result.error("auth_failed", e.message, null)
            }
        }
    }

    // MARK: - Start Background Sync

    private fun handleStartBackgroundSync(result: Result) {
        val userId = secureStorage.getUserId()
        val accessToken = secureStorage.getAccessToken()

        if (userId == null || accessToken == null) {
            result.error("not_signed_in", "Not signed in", null)
            return
        }

        if (baseUrl == null) {
            result.error("not_configured", "Not configured", null)
            return
        }

        scope.launch {
            try {
                val started = syncManager.startBackgroundSync(baseUrl!!, customSyncUrl)
                if (started) {
                    secureStorage.setSyncActive(true)
                    logMessage("✅ Background sync started")
                }
                result.success(started)
            } catch (e: Exception) {
                logMessage("❌ Failed to start sync: ${e.message}")
                result.error("sync_failed", e.message, null)
            }
        }
    }

    // MARK: - Stop Background Sync

    private fun handleStopBackgroundSync(result: Result) {
        scope.launch(Dispatchers.Main) {
            syncManager.stopBackgroundSync()
            secureStorage.setSyncActive(false)
            logMessage("🛑 Background sync stopped")
            result.success(null)
        }
    }

    // MARK: - Sync Now

    private fun handleSyncNow(result: Result) {
        scope.launch {
            try {
                syncManager.syncNow(baseUrl!!, customSyncUrl, fullExport = false)
                result.success(null)
            } catch (e: Exception) {
                logMessage("❌ Sync failed: ${e.message}")
                result.error("sync_failed", e.message, null)
            }
        }
    }

    // MARK: - Reset Anchors

    private fun handleResetAnchors(result: Result) {
        syncManager.resetAnchors()
        syncManager.clearSyncSession()
        logMessage("🔄 Anchors reset - will perform full sync on next sync")

        // If sync is active, trigger a new full sync
        if (secureStorage.isSyncActive() && secureStorage.getAccessToken() != null) {
            logMessage("🔄 Triggering full export after reset...")
            scope.launch {
                syncManager.syncNow(baseUrl!!, customSyncUrl, fullExport = true)
                logMessage("✅ Full export after reset completed")
            }
        }

        result.success(null)
    }

    // MARK: - Get Sync Status

    private fun handleGetSyncStatus(result: Result) {
        val status = syncManager.getSyncStatus()
        result.success(status)
    }

    // MARK: - Resume Sync

    private fun handleResumeSync(result: Result) {
        if (!syncManager.hasResumableSyncSession()) {
            result.error("no_session", "No resumable sync session", null)
            return
        }

        scope.launch {
            try {
                syncManager.syncNow(baseUrl!!, customSyncUrl, fullExport = false)
                result.success(null)
            } catch (e: Exception) {
                result.error("sync_failed", e.message, null)
            }
        }
    }

    // MARK: - Clear Sync Session

    private fun handleClearSyncSession(result: Result) {
        syncManager.clearSyncSession()
        result.success(null)
    }

    // MARK: - Provider Management

    private fun handleSetProvider(call: MethodCall, result: Result) {
        val providerId = call.argument<String>("provider")
        if (providerId == null) {
            result.error("bad_args", "Missing provider", null)
            return
        }
        // On Android with Samsung Health, provider is always samsung_health
        result.success(null)
    }

    private fun handleGetAvailableProviders(result: Result) {
        // Check if Samsung Health is available
        val providers = mutableListOf<Map<String, Any>>()

        if (samsungHealthManager.isAvailable()) {
            providers.add(
                mapOf(
                    "id" to "samsung_health",
                    "name" to "Samsung Health",
                    "isAvailable" to true
                )
            )
        }

        result.success(providers)
    }

    // MARK: - Logging

    private fun logMessage(message: String) {
        Log.d(TAG, message)
        // EventSink must be called on main thread
        android.os.Handler(android.os.Looper.getMainLooper()).post {
            logEventSink?.success(message)
        }
    }
}
