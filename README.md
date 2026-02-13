# Open Wearables Health SDK

A Flutter plugin for secure background health data synchronization from Apple HealthKit (iOS) to your backend.

> **Part of [Open Wearables](https://github.com/the-momentum/open-wearables)** - a self-hosted platform to unify wearable health data through one AI-ready API.

## Features

- 🔐 **Token Authentication** - Sign in with accessToken + refreshToken, SDK handles refresh automatically
- 📱 **Background Sync** - Health data syncs even when app is in background
- 📦 **Incremental Updates** - Only syncs new data using anchored queries
- 💾 **Secure Storage** - Credentials stored in iOS Keychain
- 📊 **Wide Data Support** - Steps, heart rate, workouts, sleep, and more
- 🌐 **Custom Host** - Point the SDK at any compatible backend

---

## Installation

### 1. Add Dependency

```yaml
dependencies:
  open_wearables_health_sdk: ^0.1.0
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

Enable HealthKit in Xcode → Target → Signing & Capabilities → + HealthKit.

---

## SDK Usage

### 1. Configure (once at app start)

The `host` parameter is required — provide just the host URL, the SDK appends `/api/v1/...` paths automatically.

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

### 3. Request Permissions

```dart
final authorized = await OpenWearablesHealthSdk.requestAuthorization(
  types: [
    HealthDataType.steps,
    HealthDataType.heartRate,
    HealthDataType.sleep,
    HealthDataType.workout,
  ],
);
```

### 4. Start Background Sync

```dart
await OpenWearablesHealthSdk.startBackgroundSync();
```

### 5. Check Sync Status (optional)

```dart
final status = await OpenWearablesHealthSdk.getSyncStatus();
if (status['hasResumableSession'] == true) {
  print('Sync interrupted, ${status['sentCount']} records already sent');
  // Manually resume if needed
  await OpenWearablesHealthSdk.resumeSync();
}
```

### 6. Sign Out

```dart
await OpenWearablesHealthSdk.signOut();
// All credentials cleared from Keychain
```

---

## URL Structure

When you provide a `host` (e.g. `https://api.example.com`), the SDK constructs all endpoints automatically:

| Endpoint | URL |
|----------|-----|
| Health data sync | `{host}/api/v1/sdk/users/{userId}/sync/apple` |
| Token refresh | `{host}/api/v1/token/refresh` |

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
    // 1. Configure SDK with your host
    await OpenWearablesHealthSdk.configure(host: host);

    // 2. Check current status
    if (OpenWearablesHealthSdk.isSignedIn) {
      // Already signed in, just start sync if needed
      if (!OpenWearablesHealthSdk.isSyncActive) {
        await _startSync();
      }
      return;
    }

    // 3. Sign in with credentials
    await OpenWearablesHealthSdk.signIn(
      userId: userId,
      accessToken: accessToken,
      refreshToken: refreshToken,
    );

    // 4. Start syncing
    await _startSync();
  }

  Future<void> _startSync() async {
    await OpenWearablesHealthSdk.requestAuthorization(
      types: HealthDataType.values,
    );
    await OpenWearablesHealthSdk.startBackgroundSync();
  }

  Future<void> disconnect() async {
    await OpenWearablesHealthSdk.stopBackgroundSync();
    await OpenWearablesHealthSdk.signOut();
  }
}
```

---

## Example App

The example app demonstrates the full flow using an invitation code:

1. Enter the **Host** URL and an **Invitation Code**
2. The app redeems the code at `{host}/api/v1/invitation-code/redeem`
3. Receives `access_token`, `refresh_token`, and `user_id`
4. Signs in with the SDK and starts syncing
5. Session auto-restores on app restart — no need to re-enter the code

---

## Supported Health Data Types

| Category | Types |
|----------|-------|
| **Activity** | steps, distanceWalkingRunning, distanceCycling, flightsClimbed, walkingSpeed, walkingStepLength, walkingAsymmetryPercentage, walkingDoubleSupportPercentage, sixMinuteWalkTestDistance |
| **Energy** | activeEnergy, basalEnergy |
| **Heart** | heartRate, restingHeartRate, heartRateVariabilitySDNN, vo2Max, oxygenSaturation |
| **Respiratory** | respiratoryRate |
| **Body** | bodyMass, height, bmi, bodyFatPercentage, leanBodyMass, waistCircumference (iOS 16+), bodyTemperature |
| **Blood Glucose / Insulin** | bloodGlucose, insulinDelivery (iOS 16+) |
| **Blood Pressure** | bloodPressure, bloodPressureSystolic, bloodPressureDiastolic |
| **Nutrition** | dietaryEnergyConsumed, dietaryCarbohydrates, dietaryProtein, dietaryFatTotal, dietaryWater |
| **Sleep** | sleep, mindfulSession |
| **Reproductive** | menstrualFlow, cervicalMucusQuality, ovulationTestResult, sexualActivity |
| **Workouts** | workout |

---

## API Reference

### OpenWearablesHealthSdk

| Method | Description |
|--------|-------------|
| `configure({required host})` | Initialize SDK with host URL and restore session |
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

### Properties

| Property | Type | Description |
|----------|------|-------------|
| `isConfigured` | `bool` | SDK is configured |
| `isSignedIn` | `bool` | User is signed in |
| `isSyncActive` | `bool` | Background sync is active |
| `currentUser` | `OpenWearablesHealthSdkUser?` | Current user info |
| `config` | `OpenWearablesHealthSdkConfig?` | Current configuration |
| `status` | `OpenWearablesHealthSdkStatus` | Current SDK status |

### OpenWearablesHealthSdkStatus

| Status | Description |
|--------|-------------|
| `notConfigured` | SDK not configured, call `configure()` |
| `configured` | SDK configured, but no user signed in |
| `signedIn` | User signed in, ready to sync |

### getSyncStatus() Return Values

| Key | Type | Description |
|-----|------|-------------|
| `hasResumableSession` | `bool` | Whether there's an interrupted sync to resume |
| `sentCount` | `int` | Number of records already sent in this session |
| `isFullExport` | `bool` | Whether this is a full export or incremental sync |
| `createdAt` | `String?` | ISO8601 timestamp when sync started |

### Exceptions

| Exception | When Thrown |
|-----------|-------------|
| `NotConfiguredException` | `configure()` was not called |
| `NotSignedInException` | No user signed in |
| `SignInException` | Sign-in failed |

---

## License

MIT License
