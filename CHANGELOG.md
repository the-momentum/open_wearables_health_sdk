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
