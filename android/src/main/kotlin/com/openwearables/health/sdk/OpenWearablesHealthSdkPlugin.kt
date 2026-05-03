package com.openwearables.health.sdk

import android.app.Activity
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
 * Flutter plugin that wraps [OpenWearablesHealthSDK].
 * All health data logic lives in the native Android SDK; this class
 * only translates MethodChannel calls into SDK API calls.
 */
class OpenWearablesHealthSdkPlugin : FlutterPlugin, MethodCallHandler, ActivityAware, EventChannel.StreamHandler, DefaultLifecycleObserver {

    companion object {
        private const val TAG = "OpenWearablesHealthSdk"
        private const val CHANNEL_NAME = "open_wearables_health_sdk"
        private const val LOG_CHANNEL_NAME = "open_wearables_health_sdk/logs"
        private const val AUTH_ERROR_CHANNEL_NAME = "open_wearables_health_sdk/auth_errors"
    }

    private lateinit var methodChannel: MethodChannel
    private lateinit var logChannel: EventChannel
    private lateinit var authErrorChannel: EventChannel
    private var logEventSink: EventChannel.EventSink? = null
    private var authErrorEventSink: EventChannel.EventSink? = null

    private var sdk: OpenWearablesHealthSDK? = null
    private var lifecycleObserverRegistered = false
    private val scope = CoroutineScope(Dispatchers.Main + SupervisorJob())

    // -----------------------------------------------------------------------
    // FlutterPlugin
    // -----------------------------------------------------------------------

    override fun onAttachedToEngine(flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
        val context = flutterPluginBinding.applicationContext
        sdk = OpenWearablesHealthSDK.initialize(context)

        sdk?.logListener = { message ->
            android.os.Handler(android.os.Looper.getMainLooper()).post {
                logEventSink?.success(message)
            }
        }
        sdk?.authErrorListener = { statusCode, message ->
            android.os.Handler(android.os.Looper.getMainLooper()).post {
                authErrorEventSink?.success(mapOf("statusCode" to statusCode, "message" to message))
            }
        }

        methodChannel = MethodChannel(flutterPluginBinding.binaryMessenger, CHANNEL_NAME)
        methodChannel.setMethodCallHandler(this)

        logChannel = EventChannel(flutterPluginBinding.binaryMessenger, LOG_CHANNEL_NAME)
        logChannel.setStreamHandler(this)

        authErrorChannel = EventChannel(flutterPluginBinding.binaryMessenger, AUTH_ERROR_CHANNEL_NAME)
        authErrorChannel.setStreamHandler(AuthErrorStreamHandler())

        registerLifecycleObserver()
        Log.d(TAG, "Plugin attached to engine")
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methodChannel.setMethodCallHandler(null)
        logChannel.setStreamHandler(null)
        authErrorChannel.setStreamHandler(null)
        sdk?.destroy()
        unregisterLifecycleObserver()
        scope.cancel()
        sdk = null
        Log.d(TAG, "Plugin detached from engine")
    }

    // Auth Error Stream Handler
    private inner class AuthErrorStreamHandler : EventChannel.StreamHandler {
        override fun onListen(arguments: Any?, events: EventChannel.EventSink?) { authErrorEventSink = events }
        override fun onCancel(arguments: Any?) { authErrorEventSink = null }
    }

    // -----------------------------------------------------------------------
    // Lifecycle
    // -----------------------------------------------------------------------

    private fun registerLifecycleObserver() {
        if (!lifecycleObserverRegistered) {
            try {
                ProcessLifecycleOwner.get().lifecycle.addObserver(this)
                lifecycleObserverRegistered = true
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
            } catch (_: Exception) {}
        }
    }

    override fun onStart(owner: LifecycleOwner) {
        sdk?.onForeground()
    }

    override fun onStop(owner: LifecycleOwner) {
        sdk?.onBackground()
    }

    // -----------------------------------------------------------------------
    // ActivityAware
    // -----------------------------------------------------------------------

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        sdk?.setActivity(binding.activity)
    }

    override fun onDetachedFromActivityForConfigChanges() {
        sdk?.unregisterPermissionLauncher()
        sdk?.setActivity(null)
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        sdk?.setActivity(binding.activity)
    }

    override fun onDetachedFromActivity() {
        sdk?.unregisterPermissionLauncher()
        sdk?.setActivity(null)
    }

    // EventChannel.StreamHandler (Log channel)
    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) { logEventSink = events }
    override fun onCancel(arguments: Any?) { logEventSink = null }

    // -----------------------------------------------------------------------
    // MethodCallHandler
    // -----------------------------------------------------------------------

    override fun onMethodCall(call: MethodCall, result: Result) {
        val s = sdk
        if (s == null) {
            result.error("not_initialized", "SDK not initialized", null)
            return
        }

        when (call.method) {
            "configure" -> handleConfigure(s, call, result)
            "signIn" -> handleSignIn(s, call, result)
            "signOut" -> handleSignOut(s, result)
            "restoreSession" -> result.success(s.restoreSession())
            "isSessionValid" -> result.success(s.isSessionValid())
            "isSyncActive" -> result.success(s.isSyncActive())
            "updateTokens" -> handleUpdateTokens(s, call, result)
            "getStoredCredentials" -> result.success(s.getStoredCredentials())
            "requestAuthorization" -> handleRequestAuthorization(s, call, result)
            "startBackgroundSync" -> handleStartBackgroundSync(s, call, result)
            "stopBackgroundSync" -> handleStopBackgroundSync(s, result)
            "syncNow" -> handleSyncNow(s, result)
            "resetAnchors" -> handleResetAnchors(s, result)
            "getSyncStatus" -> result.success(s.getSyncStatus())
            "resumeSync" -> handleResumeSync(s, result)
            "clearSyncSession" -> { s.clearSyncSession(); result.success(null) }
            "setProvider" -> handleSetProvider(s, call, result)
            "getAvailableProviders" -> result.success(s.getAvailableProviders())
            "setSyncNotification" -> handleSetSyncNotification(s, call, result)
            "setLogLevel" -> handleSetLogLevel(s, call, result)
            "pickClientCertificate" -> handlePickClientCertificate(s, call, result)
            "getClientCertificateAlias" -> result.success(s.getClientCertificateAlias())
            "clearClientCertificate" -> { s.clearClientCertificate(); result.success(null) }
            "redeemInvitationCode" -> handleRedeemInvitationCode(s, call, result)
            else -> result.notImplemented()
        }
    }

    private fun handlePickClientCertificate(sdk: OpenWearablesHealthSDK, call: MethodCall, result: Result) {
        val hostHint = call.argument<String>("hostHint")
        var replied = false
        sdk.pickClientCertificate(hostHint) { alias ->
            // KeyChain may invoke the callback on a non-main thread; marshal back.
            android.os.Handler(android.os.Looper.getMainLooper()).post {
                if (!replied) {
                    replied = true
                    result.success(alias)
                }
            }
        }
    }

    private fun handleRedeemInvitationCode(sdk: OpenWearablesHealthSDK, call: MethodCall, result: Result) {
        val host = call.argument<String>("host")
        val code = call.argument<String>("code")
        if (host.isNullOrEmpty() || code.isNullOrEmpty()) {
            result.error("bad_args", "host and code are required", null); return
        }
        scope.launch {
            try {
                val response = sdk.redeemInvitationCode(host, code)
                result.success(response)
            } catch (e: Exception) {
                result.error("redeem_failed", e.message, null)
            }
        }
    }

    // -----------------------------------------------------------------------
    // Handler methods — thin wrappers that delegate to SDK
    // -----------------------------------------------------------------------

    private fun handleConfigure(sdk: OpenWearablesHealthSDK, call: MethodCall, result: Result) {
        val host = call.argument<String>("host")
        if (host == null) { result.error("bad_args", "Missing host", null); return }
        val customSyncUrl = call.argument<String>("customSyncUrl")
        val isSyncActive = sdk.configure(host, customSyncUrl)
        result.success(isSyncActive)
    }

    private fun handleSignIn(sdk: OpenWearablesHealthSDK, call: MethodCall, result: Result) {
        val userId = call.argument<String>("userId")
        if (userId == null) { result.error("bad_args", "Missing userId", null); return }

        val accessToken = call.argument<String>("accessToken")
        val refreshToken = call.argument<String>("refreshToken")
        val apiKey = call.argument<String>("apiKey")

        if ((accessToken == null || refreshToken == null) && apiKey == null) {
            result.error("bad_args", "Provide (accessToken + refreshToken) or (apiKey)", null)
            return
        }

        scope.launch {
            try {
                sdk.signIn(userId, accessToken, refreshToken, apiKey)
                result.success(null)
            } catch (e: Exception) {
                result.error("sign_in_failed", e.message, null)
            }
        }
    }

    private fun handleSignOut(sdk: OpenWearablesHealthSDK, result: Result) {
        scope.launch {
            try {
                sdk.signOut()
            } catch (e: Exception) {
                Log.e(TAG, "Sign out error (state cleared anyway)", e)
            }
            result.success(null)
        }
    }

    private fun handleUpdateTokens(sdk: OpenWearablesHealthSDK, call: MethodCall, result: Result) {
        val accessToken = call.argument<String>("accessToken")
        if (accessToken == null) { result.error("bad_args", "Missing accessToken", null); return }
        sdk.updateTokens(accessToken, call.argument<String>("refreshToken"))
        result.success(null)
    }

    private fun handleRequestAuthorization(sdk: OpenWearablesHealthSDK, call: MethodCall, result: Result) {
        val types = call.argument<List<String>>("types")
        if (types == null) { result.error("bad_args", "Missing types", null); return }

        scope.launch {
            try {
                val authorized = sdk.requestAuthorization(types)
                result.success(authorized)
            } catch (e: Exception) {
                result.error("auth_failed", e.message, null)
            }
        }
    }

    private fun handleStartBackgroundSync(sdk: OpenWearablesHealthSDK, call: MethodCall, result: Result) {
        if (!sdk.isSessionValid()) {
            result.error("not_signed_in", "Not signed in", null)
            return
        }

        val syncDaysBack = call.argument<Int>("syncDaysBack")

        // Return true immediately so the UI reflects "syncing" right away.
        // The actual initial sync runs asynchronously in the background.
        result.success(true)

        scope.launch {
            try {
                sdk.startBackgroundSync(syncDaysBack)
            } catch (e: Exception) {
                Log.e(TAG, "Background sync error: ${e.message}")
            }
        }
    }

    private fun handleStopBackgroundSync(sdk: OpenWearablesHealthSDK, result: Result) {
        scope.launch {
            sdk.stopBackgroundSync()
            result.success(null)
        }
    }

    private fun handleSyncNow(sdk: OpenWearablesHealthSDK, result: Result) {
        scope.launch {
            try {
                sdk.syncNow()
                result.success(null)
            } catch (e: Exception) {
                result.error("sync_failed", e.message, null)
            }
        }
    }

    private fun handleResetAnchors(sdk: OpenWearablesHealthSDK, result: Result) {
        sdk.resetAnchors()
        result.success(null)
    }

    private fun handleResumeSync(sdk: OpenWearablesHealthSDK, result: Result) {
        scope.launch {
            try {
                sdk.resumeSync()
                result.success(null)
            } catch (e: IllegalStateException) {
                val code = if (e.message?.contains("resumable") == true) "no_session" else "not_configured"
                result.error(code, e.message, null)
            } catch (e: Exception) {
                result.error("sync_failed", e.message, null)
            }
        }
    }

    private fun handleSetProvider(sdk: OpenWearablesHealthSDK, call: MethodCall, result: Result) {
        val providerId = call.argument<String>("provider")
        if (providerId == null) { result.error("bad_args", "Missing provider", null); return }

        if (sdk.setProvider(providerId)) {
            result.success(null)
        } else {
            result.error("provider_unavailable", "Provider '$providerId' is not available on this device", null)
        }
    }

    private fun handleSetSyncNotification(sdk: OpenWearablesHealthSDK, call: MethodCall, result: Result) {
        sdk.setSyncNotification(
            title = call.argument<String>("title"),
            text = call.argument<String>("text")
        )
        result.success(null)
    }

    private fun handleSetLogLevel(sdk: OpenWearablesHealthSDK, call: MethodCall, result: Result) {
        val level = when (call.argument<String>("level")) {
            "none" -> OWLogLevel.NONE
            "always" -> OWLogLevel.ALWAYS
            "debug" -> OWLogLevel.DEBUG
            else -> OWLogLevel.DEBUG
        }
        sdk.logLevel = level
        result.success(null)
    }
}
