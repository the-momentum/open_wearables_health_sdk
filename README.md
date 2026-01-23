# Open Wearables Health SDK

A Flutter plugin for secure background health data synchronization from Apple HealthKit (iOS) to the Open Wearables platform.

## Features

- 🔐 **Simple Token Authentication** - Backend generates accessToken, SDK uses it directly
- 📱 **Background Sync** - Health data syncs even when app is in background
- 📦 **Incremental Updates** - Only syncs new data using anchored queries
- 💾 **Secure Storage** - Credentials stored in iOS Keychain
- 📊 **Wide Data Support** - Steps, heart rate, workouts, sleep, and more

---

## Authentication Flow

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              SECURE ZONE                                     │
│                         (Server-to-Server, HTTPS)                           │
│                                                                             │
│  ┌──────────────────┐                      ┌─────────────────┐             │
│  │  Your Backend    │   Generate Token     │  Open Wearables │             │
│  │                  │   (with API Key)     │  Platform       │             │
│  │  [API Key here]  │─────────────────────>│                 │             │
│  │                  │                      │                 │             │
│  │                  │<─────────────────────│                 │             │
│  │                  │   { accessToken,     │                 │             │
│  │                  │     userId }         │                 │             │
│  └────────┬─────────┘                      └────────┬────────┘             │
│           │                                         │                       │
└───────────│─────────────────────────────────────────│───────────────────────┘
            │                                         │
            │ userId + accessToken                    │
            │ (NO API Key!)                          │
            ▼                                         │
┌───────────────────────┐                            │
│  Mobile App           │                            │
│  (Flutter SDK)        │   Health data sync         │
│                       │───────────────────────────>│
│  [Keychain storage]   │   (Bearer accessToken)     │
└───────────────────────┘                            │
```

### Step-by-Step Flow

1. **User logs into your app** (your own authentication)

2. **Mobile app requests credentials from YOUR backend**
   ```
   POST /api/health/connect
   Authorization: Bearer <your-user-jwt>
   ```

3. **Your backend generates credentials** (server-to-server with API Key)
   ```http
   POST https://api.openwearables.com/v1/tokens
   X-API-Key: sk_live_your_secret_key
   Content-Type: application/json
   
   { "externalId": "user-123" }
   ```

   Response:
   ```json
   { 
     "userId": "usr_abc123",
     "accessToken": "at_..." 
   }
   ```

4. **Your backend returns credentials to mobile app**
   ```json
   { 
     "userId": "usr_abc123",
     "accessToken": "at_..." 
   }
   ```

5. **Mobile app signs in with the SDK**
   ```dart
   final user = await OpenWearablesHealthSdk.signIn(
     userId: response['userId'],
     accessToken: response['accessToken'],
   );
   ```

6. **SDK stores credentials securely** in iOS Keychain

7. **Health data syncs using accessToken**
   ```http
   POST https://api.openwearables.com/sdk/users/{userId}/sync/apple/healthion
   Authorization: at_...
   ```

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

## Backend Integration

Your backend needs ONE endpoint to generate credentials:

```javascript
// Node.js / Express example
app.post('/api/health/connect', authenticateUser, async (req, res) => {
  // 1. Get your authenticated user
  const userId = req.user.id;
  
  // 2. Call Open Wearables API to generate token
  const response = await fetch('https://api.openwearables.com/v1/tokens', {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'X-API-Key': process.env.OPENWEARABLES_API_KEY, // Secret! Never expose!
    },
    body: JSON.stringify({
      externalId: userId.toString(),
    }),
  });
  
  const { userId: owUserId, accessToken } = await response.json();
  
  // 3. Return credentials (NOT the API Key!)
  res.json({ userId: owUserId, accessToken });
});
```

---

## SDK Usage

### 1. Configure (once at app start)

```dart
await OpenWearablesHealthSdk.configure(
environment: OpenWearablesHealthSdkEnvironment.production,
);

// Or with custom URL for local testing:
await OpenWearablesHealthSdk.configure(
customSyncUrl: 'http://localhost:3000/sdk/users/{user_id}/sync/apple/healthion',
);

// Session is automatically restored if user was previously signed in
if (OpenWearablesHealthSdk.isSignedIn) {
print('Welcome back, ${OpenWearablesHealthSdk.currentUser?.userId}!');
}
```

### 2. Sign In

```dart
// Get credentials from YOUR backend
final response = await yourApi.post('/health/connect');

// Sign in with the credentials
try {
final user = await OpenWearablesHealthSdk.signIn(
userId: response['userId'],
accessToken: response['accessToken'],
);
print('Connected: ${user.userId}');
} on SignInException catch (e) {
print('Failed: ${e.message}');
}

// With automatic token refresh (optional):
final user = await OpenWearablesHealthSdk.signIn(
userId: response['userId'],
accessToken: response['accessToken'],
appId: 'your-app-id',
appSecret: 'your-app-secret',
baseUrl: 'https://api.openwearables.io',
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

## Complete Example

```dart
class HealthService {
   final ApiClient _api;

   Future<void> connect() async {
      // 1. Configure SDK (once)
      await OpenWearablesHealthSdk.configure();

      // 2. Check current status
      switch (OpenWearablesHealthSdk.status) {
         case OpenWearablesHealthSdkStatus.signedIn:
         // Already signed in, check if sync is active
            if (!OpenWearablesHealthSdk.isSyncActive) {
               await _startSync();
            }
            return;

         case OpenWearablesHealthSdkStatus.configured:
         // Need to sign in
            await _signIn();
            await _startSync();
            return;

         case OpenWearablesHealthSdkStatus.notConfigured:
            throw Exception('SDK not configured');
      }
   }

   Future<void> _signIn() async {
      // Get credentials from your backend
      final response = await _api.post('/health/connect');

      // Sign in with SDK (with optional auto-refresh)
      await OpenWearablesHealthSdk.signIn(
         userId: response['userId'],
         accessToken: response['accessToken'],
         appId: response['appId'],       // optional, for token refresh
         appSecret: response['appSecret'], // optional, for token refresh
         baseUrl: response['baseUrl'],    // optional, for token refresh
      );
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

   Future<void> checkSyncStatus() async {
      final status = await OpenWearablesHealthSdk.getSyncStatus();
      if (status['hasResumableSession'] == true) {
         print('Resumable sync: ${status['sentCount']} records sent');
         await OpenWearablesHealthSdk.resumeSync();
      }
   }
}
```

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
| `configure({environment, customSyncUrl})` | Initialize SDK and restore session |
| `signIn({userId, accessToken, appId?, appSecret?, baseUrl?})` | Sign in with credentials from backend |
| `signOut()` | Sign out and clear all credentials |
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

### OpenWearablesHealthSdkEnvironment

| Environment | Description |
|-------------|-------------|
| `production` | Production environment (default) |
| `sandbox` | Sandbox/Development environment for testing |

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
