# Open Wearables Health SDK (Flutter)

A Flutter plugin for secure background health data synchronization from **Apple HealthKit** (iOS), **Samsung Health**, and **Health Connect** (Android) to your backend.

> **Part of [Open Wearables](https://github.com/the-momentum/open-wearables)** - a self-hosted platform to unify wearable health data through one AI-ready API.

## Features

- **Token Authentication** - Sign in with accessToken + refreshToken, SDK handles refresh automatically
- **Background Sync** - Health data syncs even when app is in background
- **Incremental Updates** - Only syncs new data using anchored queries
- **Secure Storage** - Credentials stored in iOS Keychain / Android EncryptedSharedPreferences
- **Wide Data Support** - Steps, heart rate, workouts, sleep, and more
- **Custom Host** - Point the SDK at any compatible backend
- **Multi-Provider (Android)** - Samsung Health and Health Connect supported

---

## Installation

### 1. Add Dependency

```yaml
dependencies:
  open_wearables_health_sdk: ^0.0.15
```

### 2. iOS Configuration

Add to `Info.plist`:

```xml
<key>NSHealthShareUsageDescription</key>
<string>This app syncs your health data to your account.</string>

<key>UIBackgroundModes</key>
<array>
    <string>fetch</string>
    <string>processing</string>
</array>

<key>BGTaskSchedulerPermittedIdentifiers</key>
<array>
    <string>com.openwearables.healthsdk.task.refresh</string>
    <string>com.openwearables.healthsdk.task.process</string>
</array>
```

Enable HealthKit in Xcode: Target > Signing & Capabilities > + HealthKit.

### 3. Android Configuration

#### Set `minSdk` to 29

In `android/app/build.gradle.kts`:

```kotlin
android {
    defaultConfig {
        minSdk = 29
    }
}
```

#### Add Health Connect permission aliases to `AndroidManifest.xml`

In `android/app/src/main/AndroidManifest.xml`, inside the `<application>` tag:

```xml
<!-- Health Connect: permissions rationale (Android 14+) -->
<activity-alias
    android:name="ViewPermissionUsageActivity"
    android:exported="true"
    android:targetActivity=".MainActivity"
    android:permission="android.permission.START_VIEW_PERMISSION_USAGE">
    <intent-filter>
        <action android:name="android.intent.action.VIEW_PERMISSION_USAGE" />
        <category android:name="android.intent.category.HEALTH_PERMISSIONS" />
    </intent-filter>
</activity-alias>

<!-- Health Connect: permissions rationale (Android 12-13) -->
<activity-alias
    android:name="ShowPermissionRationaleActivity"
    android:exported="true"
    android:targetActivity=".MainActivity">
    <intent-filter>
        <action android:name="androidx.health.ACTION_SHOW_PERMISSIONS_RATIONALE" />
    </intent-filter>
</activity-alias>
```

#### Use `FlutterFragmentActivity`

In your `MainActivity.kt`, extend `FlutterFragmentActivity` instead of `FlutterActivity`:

```kotlin
import io.flutter.embedding.android.FlutterFragmentActivity

class MainActivity : FlutterFragmentActivity()
```

This is required for Health Connect permission dialogs to work.

#### Background Sync & Foreground Service (required for Play Store)

The SDK uses a WorkManager foreground service to sync health data in the background. Starting with Android 14, Google Play requires a correct **foreground service type** declaration. Since this SDK accesses health data, the correct type is `health` (not `dataSync`).

The SDK's `AndroidManifest.xml` already declares the correct service, permissions, and FGS type — they are automatically merged into your app via manifest merging. **You do not need to add a service declaration yourself.**

The following are added automatically by the SDK:

```xml
<uses-permission android:name="android.permission.FOREGROUND_SERVICE" />
<uses-permission android:name="android.permission.FOREGROUND_SERVICE_HEALTH" />
<uses-permission android:name="android.permission.HIGH_SAMPLING_RATE_SENSORS" />

<service
    android:name="androidx.work.impl.foreground.SystemForegroundService"
    android:foregroundServiceType="health"
    tools:node="merge" />
```

> **Warning:** If you previously declared the service manually with `foregroundServiceType="dataSync"`, **remove it** from your `AndroidManifest.xml`. Using `dataSync` for health data will cause Google Play rejection.

##### Play Console declaration

When submitting to Google Play, you must declare the foreground service type in the Play Console:

1. Go to **Policy > App content > Foreground service permissions**
2. Select **Health** as your foreground service type
3. Describe the use case: *"The app reads health data from Health Connect (steps, heart rate, sleep, etc.) and synchronizes it in the background to the user's account."*
4. Explain what happens if interrupted: *"If the sync is interrupted, it automatically resumes on next app launch or when the system allows. No data is lost."*
5. Provide a video or screenshots showing:
   - The user granting Health Connect permissions
   - A visible notification during background sync (see `setSyncNotification` below)
   - The in-app UI indicating that sync is active

##### Foreground notification (required)

Android requires a visible notification while a foreground service is running. Call `setSyncNotification` **before** starting background sync so the user can see what's happening:

```dart
if (Platform.isAndroid) {
  await OpenWearablesHealthSdk.setSyncNotification(
    title: 'MyApp',
    text: 'Syncing your health data...',
  );
}
```

This notification is a Play Store requirement — without it, your app will be rejected for "FGS not perceptible to the user".

#### Samsung Health

Samsung Health is supported out of the box - the Samsung Health Data SDK is bundled in the Android SDK repository. No extra download needed.

For testing on Samsung devices, enable Developer Mode in Samsung Health: Settings > About Samsung Health > tap version 10 times.

---

## SDK Usage

### 1. Configure (once at app start)

```dart
await OpenWearablesHealthSdk.configure(
  host: 'https://api.example.com',
);

// Session is automatically restored if user was previously signed in
if (OpenWearablesHealthSdk.isSignedIn) {
  print('Welcome back, ${OpenWearablesHealthSdk.currentUser?.userId}!');
}
```

### 2. Sign In

```dart
// Sign in with tokens (supports automatic token refresh)
try {
  final user = await OpenWearablesHealthSdk.signIn(
    userId: 'user-id',
    accessToken: 'Bearer access-token',
    refreshToken: 'refresh-token',
  );
  print('Connected: ${user.userId}');
} on SignInException catch (e) {
  print('Failed: ${e.message}');
}

// Or with API key (simpler, no automatic token refresh):
final user = await OpenWearablesHealthSdk.signIn(
  userId: 'your-user-id',
  apiKey: 'your-api-key',
);
```

### 3. Select Provider (Android only)

On Android, multiple health data providers may be available. Let the user choose:

```dart
import 'dart:io';

if (Platform.isAndroid) {
  final providers = await OpenWearablesHealthSdk.getAvailableProviders();
  // Show UI to let user pick a provider
  // providers = [AvailableProvider(samsung, Samsung Health), AvailableProvider(google, Health Connect)]

  await OpenWearablesHealthSdk.setProvider(AndroidHealthProvider.healthConnect);
  // or: await OpenWearablesHealthSdk.setProvider(AndroidHealthProvider.samsungHealth);
}
```

### 4. Request Permissions

```dart
final authorized = await OpenWearablesHealthSdk.requestAuthorization(
  types: [
    HealthDataType.steps,
    HealthDataType.heartRate,
    HealthDataType.sleep,
    HealthDataType.workout,
  ],
);

// Health Connect only: request optional access separately.
// Foreground/manual sync still works if either request returns false.
final historyAuthorized =
    await OpenWearablesHealthSdk.requestHistoryReadAuthorization();
final backgroundAuthorized =
    await OpenWearablesHealthSdk.requestBackgroundReadAuthorization();
```

### 5. Start Background Sync

```dart
await OpenWearablesHealthSdk.startBackgroundSync();
```

### 6. Listen to Logs and Auth Errors (optional)

```dart
OpenWearablesHealthSdk.logStream.listen((message) {
  print('[SDK] $message');
});

OpenWearablesHealthSdk.authErrorStream.listen((error) {
  print('Auth error: ${error['statusCode']} - ${error['message']}');
  // Handle token expiration - redirect to login, etc.
});
```

### 7. Sign Out

```dart
await OpenWearablesHealthSdk.signOut();
```

---

## URL Structure

When you provide a `host` (e.g. `https://api.example.com`), the SDK constructs endpoints automatically:

| Endpoint | URL |
|----------|-----|
| Health data sync | `{host}/api/v1/sdk/users/{userId}/sync` |
| Token refresh | `{host}/api/v1/token/refresh` |

You can also provide a `customSyncUrl` during `configure()` to override the sync endpoint.

---

## Complete Example

```dart
class HealthService {
  final String host;

  HealthService({required this.host});

  Future<void> connect({
    required String userId,
    required String accessToken,
    required String refreshToken,
  }) async {
    // 1. Configure SDK
    await OpenWearablesHealthSdk.configure(host: host);

    // 2. Check existing session
    if (OpenWearablesHealthSdk.isSignedIn) {
      if (!OpenWearablesHealthSdk.isSyncActive) {
        await _startSync();
      }
      return;
    }

    // 3. Sign in
    await OpenWearablesHealthSdk.signIn(
      userId: userId,
      accessToken: accessToken,
      refreshToken: refreshToken,
    );

    // 4. Select provider on Android
    if (Platform.isAndroid) {
      await OpenWearablesHealthSdk.setProvider(
        AndroidHealthProvider.healthConnect,
      );
    }

    // 5. Start syncing
    await _startSync();
  }

  Future<void> _startSync() async {
    await OpenWearablesHealthSdk.requestAuthorization(
      types: HealthDataType.values,
    );

    // Required on Android: set a visible notification before starting sync
    if (Platform.isAndroid) {
      await OpenWearablesHealthSdk.setSyncNotification(
        title: 'Health sync active',
        text: 'Syncing your health data...',
      );
    }

    await OpenWearablesHealthSdk.startBackgroundSync();
  }

  Future<void> disconnect() async {
    await OpenWearablesHealthSdk.stopBackgroundSync();
    await OpenWearablesHealthSdk.signOut();
  }
}
```

---

## Supported Health Data Types

### Supported on all platforms

| Category | Types |
|----------|-------|
| **Activity** | steps, distanceWalkingRunning, flightsClimbed |
| **Energy** | activeEnergy, basalEnergy |
| **Heart** | heartRate, restingHeartRate, heartRateVariabilitySDNN, vo2Max, oxygenSaturation |
| **Respiratory** | respiratoryRate |
| **Body** | bodyMass, height, bodyFatPercentage, leanBodyMass, bodyTemperature |
| **Blood** | bloodGlucose, bloodPressure, bloodPressureSystolic, bloodPressureDiastolic |
| **Nutrition** | dietaryWater |
| **Sleep** | sleep |
| **Workouts** | workout |

### iOS only

| Category | Types |
|----------|-------|
| **Activity** | distanceCycling, walkingSpeed, walkingStepLength, walkingAsymmetryPercentage, walkingDoubleSupportPercentage, sixMinuteWalkTestDistance |
| **Body** | bmi, waistCircumference (iOS 16+) |
| **Glucose** | insulinDelivery (iOS 16+) |
| **Nutrition** | dietaryEnergyConsumed, dietaryCarbohydrates, dietaryProtein, dietaryFatTotal |
| **Sleep** | mindfulSession |
| **Reproductive** | menstrualFlow, cervicalMucusQuality, ovulationTestResult, sexualActivity |

### Android only

| Category | Types |
|----------|-------|
| **Activity** | distanceCycling (Health Connect) |

> Types not supported on the current platform are silently ignored during sync.

---

## API Reference

### OpenWearablesHealthSdk

| Method | Description |
|--------|-------------|
| `configure({required host, customSyncUrl?})` | Initialize SDK with host URL and restore session |
| `signIn({userId, accessToken?, refreshToken?, apiKey?})` | Sign in with tokens or API key |
| `signOut()` | Sign out and clear all credentials |
| `updateTokens({accessToken, refreshToken?})` | Update tokens without re-signing in |
| `requestAuthorization({types})` | Request health data permissions |
| `startBackgroundSync()` | Enable background sync |
| `stopBackgroundSync()` | Disable background sync |
| `syncNow()` | Trigger immediate sync |
| `resetAnchors()` | Reset sync state (forces full re-export) |
| `getStoredCredentials()` | Get stored credentials for debugging |
| `getSyncStatus()` | Get current sync session status |
| `resumeSync()` | Manually resume interrupted sync |
| `clearSyncSession()` | Clear interrupted sync without resuming |
| `setProvider(AndroidHealthProvider)` | Set health data provider (Android only) |
| `getAvailableProviders()` | Get available providers on device (Android only) |

### Properties

| Property | Type | Description |
|----------|------|-------------|
| `isConfigured` | `bool` | SDK is configured |
| `isSignedIn` | `bool` | User is signed in |
| `isSyncActive` | `bool` | Background sync is active |
| `currentUser` | `OpenWearablesHealthSdkUser?` | Current user info |
| `config` | `OpenWearablesHealthSdkConfig?` | Current configuration |
| `status` | `OpenWearablesHealthSdkStatus` | Current SDK status |
| `logStream` | `Stream<String>` | SDK log messages |
| `authErrorStream` | `Stream<Map>` | Auth error events |

### Exceptions

| Exception | When Thrown |
|-----------|-------------|
| `NotConfiguredException` | `configure()` was not called |
| `NotSignedInException` | No user signed in |
| `SignInException` | Sign-in failed |

---

## Architecture

```
┌──────────────────────────────────────────────────┐
│ Flutter App (Dart)                                │
│  OpenWearablesHealthSdk → MethodChannel           │
└──────────────────┬───────────────────────────────┘
                   │
┌──────────────────▼───────────────────────────────┐
│ Flutter Plugin (thin wrapper)                     │
│  OpenWearablesHealthSdkPlugin.kt                  │
│    └── delegates to ↓                             │
│                                                   │
│ Open Wearables Android SDK (native library)       │
│  OpenWearablesHealthSDK (facade)                  │
│    ├── SamsungHealthManager → Samsung Health       │
│    ├── HealthConnectManager → Health Connect       │
│    └── SyncManager → WorkManager background sync  │
└───────────────────────────────────────────────────┘
```

On Android, the Flutter plugin is a thin wrapper around the **Open Wearables Android SDK** (`com.openwearables.health:sdk`), which can also be used independently in native Android apps.

---

## License

MIT License
