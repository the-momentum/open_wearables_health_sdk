## 0.0.21

* Bumped native iOS SDK dependency from `~> 0.13.0` to `~> 0.14.0`.
* Bumped native Android SDK dependency from `v0.10.0` to `v0.11.2`.
* **iOS: fixed sync loop** — full export no longer gets poisoned into an infinite re-upload of old data on first-upload failure. Anchor capture errors and outbox retry storms also fixed.
* **Historical sync banner**: example app now shows "Historical data sync in progress" with a live record count while the initial export runs, and keeps the screen awake until it completes (`wakelock_plus`).
* **New `getSyncStatus()` keys**: `initialExportDone` and `isSyncing` exposed on both platforms.

## 0.0.20

* Bumped native iOS SDK dependency from `~> 0.12.0` to `~> 0.13.0`.
* Bumped native Android SDK dependency from `v0.9.0` to `v0.10.0`.
* **Sync telemetry**: both iOS and Android SDKs now send diagnostic events (`sync_start`, per-type `sync_end`, `device_state`) to the `/logs` endpoint during initial full syncs.
* **Android: auto full export**: first sync now automatically runs as full export, matching iOS behavior.
* **Android: fixed OkHttp connection leaks** in sync uploads and log requests.

## 0.0.19

* Bumped native iOS SDK dependency from `~> 0.11.0` to `~> 0.12.0`.
* **Source device name**: health data payloads now include a human-readable device `name` field alongside existing source metadata (via iOS SDK 0.12.0).

## 0.0.18

* Bumped native iOS SDK dependency from `~> 0.10.0` to `~> 0.11.0`.
* Bumped native Android SDK dependency from `v0.8.0` to `v0.9.0`.
* **Smarter disconnect behavior**: transient network errors during token refresh no longer force user sign-out — only genuine authentication failures (401/403) trigger disconnect.
* Added Sentry error logging to the example app for disconnect events and sync failures.

## 0.0.17

* **Breaking: Foreground service type changed from `dataSync` to `health`** to comply with Google Play policy. Apps must update their Play Console FGS declaration from "Data Sync" to "Health" and remove any manual `<service android:foregroundServiceType="dataSync">` from their `AndroidManifest.xml` — the SDK now provides the correct declaration via manifest merge.
* Added `FOREGROUND_SERVICE_HEALTH` and `HIGH_SAMPLING_RATE_SENSORS` permissions to the plugin manifest.
* Updated README with Android foreground service requirements, Play Console declaration guide, and mandatory `setSyncNotification()` usage.
* Bumped native Android SDK dependency from `v0.7.0` to `v0.8.0`.

## 0.0.16

* Bumped native iOS SDK dependency from `~> 0.9.0` to `~> 0.10.0`.
* Bumped native Android SDK dependency from `v0.6.0` to `v0.7.0`.
* Fixed `isSignedIn` returning `true` after `signOut()` — Dart-side state is now always cleared in a `finally` block.
* Fixed Android `signOut()` hanging if native call throws — wrapped in `try-catch` with guaranteed `result.success()`.
* Added `setSyncNotification(title, text)` — customize the Android foreground service notification shown during background sync (no-op on iOS).

## 0.0.15

* Bumped native iOS SDK dependency from `~> 0.8.0` to `~> 0.9.0`.
* Bumped native Android SDK dependency from `v0.5.0` to `v0.6.0`.

## 0.0.14

* Bumped native iOS SDK dependency from `~> 0.7.0` to `~> 0.8.0`.

## 0.0.13

* Added `syncDaysBack` parameter to `startBackgroundSync()` — control how many days of history to sync.
* Added `setLogLevel()` API with `OWLogLevel` enum (`none`, `always`, `debug`).
* SDK logs are now auto-printed to the Dart console based on the log level (debug by default).
* Bumped native iOS SDK dependency from `~> 0.6.0` to `~> 0.7.0`.
* Bumped native Android SDK dependency from `v0.4.0` to `v0.5.0`.

## 0.0.12

* Bumped native Android SDK dependency from `v0.3.0` to `v0.4.0`.

## 0.0.11

* Fixed LLDB "overlapping Mach-O section" warnings (`__TPRO_CONST` / `__DATA_CONST`) on iOS <17 devices when built with Xcode 15+.
* Added `-ld_classic` linker flag in Podfile to force legacy Mach-O section layout.
* Bumped native iOS SDK dependency from `~> 0.5.0` to `~> 0.6.0`.
* Aligned iOS deployment target to 15.0 across all podspecs.

## 0.0.10

* **Android support** — the plugin now works on both iOS and Android.
* Android implementation uses the [Open Wearables Android SDK](https://github.com/the-momentum/open_wearables_android_sdk) via JitPack — the Flutter plugin is a thin wrapper, same as on iOS.
* Dual health provider support on Android: **Samsung Health** and **Health Connect** with runtime selection (`setProvider`, `getAvailableProviders`).
* Background sync powered by WorkManager with resumable sessions and incremental updates.
* Token auth with automatic 401 refresh + API key alternative.
* Updated example app with provider picker, invitation code flow, and live sync logs.

## 0.0.9

* Bumped native iOS SDK dependency from `~> 0.3.0` to `~> 0.4.0`.

## 0.0.8

* Bumped native iOS SDK dependency from `~> 0.2.0` to `~> 0.3.0`.

## 0.0.7

* **Breaking:** Replaced the embedded native iOS implementation with the [OpenWearablesHealthSDK](https://cocoapods.org/pods/OpenWearablesHealthSDK) CocoaPod (`~> 0.2.0`). The Flutter plugin is now a thin wrapper around the native iOS SDK.
* All HealthKit logic (authorization, background sync, anchored queries, data serialization, keychain storage) is now handled by the native SDK.
* Health data type authorization now uses the native `HealthDataType` enum instead of raw strings.
* No changes to the public Dart API — existing Flutter integrations continue to work without modification.

## 0.0.6

* Replaced `baseUrl` with required `host` parameter in SDK configuration
* Added refresh token handling with automatic token renewal on 401 errors
* Added invitation code flow support
* Improved sync resilience and error handling
* Removed `customSyncUrl` support

## 0.0.5

* Fixed example app default sync URL to use correct `/api/v1/` base path

## 0.0.4

* Fixed iOS sync endpoint URL - added missing `/api/v1/` prefix

## 0.0.3

* Changed sync endpoint URL from `/sdk/users/{user_id}/sync/apple/healthion` to `/sdk/users/{user_id}/sync/apple`

## 0.0.2

* Added repository and issue tracker URLs for pub.dev

## 0.0.1

* Initial release of Open Wearables Health SDK
* Background health data synchronization from Apple HealthKit (iOS)
* Secure credential storage using iOS Keychain
* Token-based authentication with automatic refresh support
* Incremental sync using anchored queries
* Resumable sync sessions for interrupted uploads
* Support for 40+ health data types including:
  - Activity: steps, distance, flights climbed, walking metrics
  - Heart: heart rate, resting heart rate, HRV, VO2 max
  - Body: weight, height, BMI, body fat percentage
  - Sleep: sleep analysis, mindful sessions
  - Workouts: all workout types with detailed statistics
  - And more...
