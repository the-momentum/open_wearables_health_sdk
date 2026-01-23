# Samsung Health SDK Setup

This folder contains the Samsung Health Data SDK published as a local Maven repository.

## Structure

```
libs/
├── maven/                          # Local Maven repository
│   └── com/samsung/android/health/data/1.0.0/
│       ├── data-1.0.0.aar          # Samsung Health SDK
│       └── data-1.0.0.pom          # Maven POM file
├── samsung-health-data-api-1.0.0.aar  # Original .aar (kept for reference)
└── README.md
```

## Why Maven Repository?

Flutter plugins compile to AAR files. Android Gradle Plugin does not support
direct `.aar` dependencies when building an AAR (the classes wouldn't be packaged).
Using a local Maven repository solves this issue.

## Download Instructions

1. Go to [Samsung Developer Portal](https://developer.samsung.com/health/android/overview.html)
2. Sign in with your Samsung account
3. Download the **Samsung Health Data SDK**
4. Extract the archive and find `samsung-health-data-api-x.x.x.aar`
5. Copy to `libs/maven/com/samsung/android/health/data/1.0.0/data-1.0.0.aar`
6. Keep the POM file as-is (or update version if needed)

## Requirements

- Samsung Health app v6.30.2 or higher installed on the device
- Android 10 (API 29) or higher
- Samsung device (Galaxy phones, tablets, watches)

## Developer Mode

For testing, you need to enable Developer Mode in Samsung Health:
1. Open Samsung Health app
2. Go to Settings > About Samsung Health
3. Tap version number 10 times to enable Developer Mode
4. Go back to Settings > Developer options
5. Enable "Developer mode"

This allows reading health data without partner app registration.

## Partner App Registration

For production apps, you need to register as a Samsung Health partner:
1. Go to [Samsung Health Partner Portal](https://developer.samsung.com/health/partner/apply)
2. Apply for partnership
3. Submit your app for review
4. Once approved, your app can access Samsung Health data in production

## Supported Data Types

The SDK supports reading the following data types:
- Steps (`com.samsung.health.step_count`)
- Heart Rate (`com.samsung.health.heart_rate`)
- Sleep (`com.samsung.health.sleep`)
- Exercise/Workout (`com.samsung.health.exercise`)
- Body Composition (`com.samsung.health.body_composition`)
- Blood Pressure (`com.samsung.health.blood_pressure`)
- Blood Glucose (`com.samsung.health.blood_glucose`)
- Oxygen Saturation (`com.samsung.health.oxygen_saturation`)
- Weight (`com.samsung.health.weight`)
- Height (`com.samsung.health.height`)
- And more...

## Troubleshooting

### "Samsung Health not available" error
- Ensure Samsung Health app is installed
- Ensure Samsung Health version is 6.30.2 or higher
- Ensure running on a Samsung device

### Permission denied
- Enable Developer Mode in Samsung Health for testing
- For production, ensure partner app registration is approved
