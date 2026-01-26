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
