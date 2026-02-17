import Flutter
import UIKit
import OpenWearablesHealthSDK

/// Flutter plugin wrapper that delegates all functionality to OpenWearablesHealthSDK.
/// This is a thin bridge between Flutter method channels and the native iOS SDK.
@objc(OpenWearablesHealthSdkPlugin)
public class OpenWearablesHealthSdkPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {

    private let sdk = OpenWearablesHealthSDK.shared
    
    // Log event sink
    private var logEventSink: FlutterEventSink?
    private var logEventChannel: FlutterEventChannel?
    
    // Auth error event sink
    internal var authErrorEventSink: FlutterEventSink?
    private var authErrorEventChannel: FlutterEventChannel?

    // MARK: - Flutter Registration
    
    @objc public static func register(with registrar: FlutterPluginRegistrar) {
        NSLog("[OpenWearablesHealthSdkPlugin] Registering plugin...")
        let channel = FlutterMethodChannel(name: "open_wearables_health_sdk", binaryMessenger: registrar.messenger())
        let instance = OpenWearablesHealthSdkPlugin()
        registrar.addMethodCallDelegate(instance, channel: channel)
        
        // Log event channel
        let logChannel = FlutterEventChannel(name: "open_wearables_health_sdk/logs", binaryMessenger: registrar.messenger())
        instance.logEventChannel = logChannel
        logChannel.setStreamHandler(instance)
        
        // Auth error event channel
        let authErrorChannel = FlutterEventChannel(name: "open_wearables_health_sdk/auth_errors", binaryMessenger: registrar.messenger())
        instance.authErrorEventChannel = authErrorChannel
        authErrorChannel.setStreamHandler(AuthErrorStreamHandler(plugin: instance))
        
        // Wire SDK callbacks to Flutter event channels
        instance.setupSDKCallbacks()
    }
    
    @objc public static func setBackgroundCompletionHandler(_ handler: @escaping () -> Void) {
        OpenWearablesHealthSDK.setBackgroundCompletionHandler(handler)
    }
    
    // MARK: - SDK Callback Wiring
    
    private func setupSDKCallbacks() {
        sdk.onLog = { [weak self] message in
            guard let self = self, let sink = self.logEventSink else { return }
            DispatchQueue.main.async {
                sink(message)
            }
        }
        
        sdk.onAuthError = { [weak self] statusCode, message in
            guard let self = self, let sink = self.authErrorEventSink else { return }
            DispatchQueue.main.async {
                sink(["statusCode": statusCode, "message": message])
            }
        }
    }

    // MARK: - Method Channel Handler
    
    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {

        case "configure":
            guard let args = call.arguments as? [String: Any],
                  let host = args["host"] as? String else {
                result(FlutterError(code: "bad_args", message: "Missing host", details: nil))
                return
            }
            sdk.configure(host: host)
            result(nil)

        case "signIn":
            guard let args = call.arguments as? [String: Any],
                  let userId = args["userId"] as? String else {
                result(FlutterError(code: "bad_args", message: "Missing userId", details: nil))
                return
            }
            let accessToken = args["accessToken"] as? String
            let refreshToken = args["refreshToken"] as? String
            let apiKey = args["apiKey"] as? String
            
            let hasTokens = accessToken != nil && refreshToken != nil
            let hasApiKey = apiKey != nil
            guard hasTokens || hasApiKey else {
                result(FlutterError(code: "bad_args", message: "Provide (accessToken + refreshToken) or (apiKey)", details: nil))
                return
            }
            
            sdk.signIn(userId: userId, accessToken: accessToken, refreshToken: refreshToken, apiKey: apiKey)
            result(nil)
            
        case "signOut":
            sdk.signOut()
            result(nil)
            
        case "restoreSession":
            result(sdk.restoreSession())
            
        case "isSessionValid":
            result(sdk.isSessionValid)
            
        case "isSyncActive":
            result(sdk.isSyncActive)
            
        case "updateTokens":
            guard let args = call.arguments as? [String: Any],
                  let accessToken = args["accessToken"] as? String else {
                result(FlutterError(code: "bad_args", message: "Missing accessToken", details: nil))
                return
            }
            let refreshToken = args["refreshToken"] as? String
            sdk.updateTokens(accessToken: accessToken, refreshToken: refreshToken)
            result(nil)
            
        case "getStoredCredentials":
            result(sdk.getStoredCredentials())

        case "requestAuthorization":
            guard let args = call.arguments as? [String: Any],
                  let types = args["types"] as? [String] else {
                result(FlutterError(code: "bad_args", message: "Missing types", details: nil))
                return
            }
            sdk.requestAuthorization(types: types) { ok in
                result(ok)
            }

        case "syncNow":
            sdk.syncNow { result(nil) }

        case "startBackgroundSync":
            guard sdk.isSessionValid else {
                result(FlutterError(code: "not_signed_in", message: "Not signed in", details: nil))
                return
            }
            sdk.startBackgroundSync { canStart in
                result(canStart)
            }

        case "stopBackgroundSync":
            sdk.stopBackgroundSync()
            result(nil)

        case "resetAnchors":
            sdk.resetAnchors()
            result(nil)
            
        case "getSyncStatus":
            result(sdk.getSyncStatus())
            
        case "resumeSync":
            sdk.resumeSync { success in
                if success {
                    result(nil)
                } else {
                    result(FlutterError(code: "no_session", message: "No resumable sync session", details: nil))
                }
            }
            
        case "clearSyncSession":
            sdk.clearSyncSession()
            result(nil)

        default:
            result(FlutterMethodNotImplemented)
        }
    }
    
    // MARK: - FlutterStreamHandler (Log channel)
    
    public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        logEventSink = events
        return nil
    }
    
    public func onCancel(withArguments arguments: Any?) -> FlutterError? {
        logEventSink = nil
        return nil
    }
}

// MARK: - Auth Error Stream Handler

class AuthErrorStreamHandler: NSObject, FlutterStreamHandler {
    weak var plugin: OpenWearablesHealthSdkPlugin?
    
    init(plugin: OpenWearablesHealthSdkPlugin) {
        self.plugin = plugin
    }
    
    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        plugin?.authErrorEventSink = events
        return nil
    }
    
    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        plugin?.authErrorEventSink = nil
        return nil
    }
}
