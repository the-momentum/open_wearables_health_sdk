# Kaj Patch Notes

This fork carries one production-blocking patch on top of the upstream
`the-momentum/open_wearables_health_sdk` Flutter plugin.

## What changed

`android/build.gradle`:
- Native Android SDK switched from `com.github.the-momentum.open_wearables_android_sdk:sdk:v0.10.0` (jitpack)
  to a locally bundled `com.openwearables.health:sdk:0.11.1` served from
  `android/libs/maven`.
- A local Maven repository pointing at `android/libs/maven` is registered
  on `rootProject.allprojects` so consumer apps pick it up automatically.

## Why

Upstream `v0.10.0` throws `java.lang.Integer cannot be cast to java.lang.Float`
when Samsung Health emits integer values for body composition fields
(`bodyFatPercentage`, `leanBodyMass`, etc.), which causes the entire sync
batch to be dropped — sleep, heart, weight, BMI, every record.

The fix lives in `Tamulus47/open_wearables_android_sdk@v0.11.1` (commit
`267487`). That tag does NOT build on jitpack because the same release also
added a `fun setLogLevel(level)` that JVM-collides with the auto-generated
setter for `var logLevel` (platform declaration clash).

This fork applies a one-line `@JvmName("applyLogLevel")` annotation on top
of the `setLogLevel` function, builds the AAR locally with JDK 17, and
commits the resulting Maven artifacts into `android/libs/maven`.

## Bundled artifacts

`android/libs/maven/`:
- `com/openwearables/health/sdk/0.11.1/...` — patched native SDK
- `com/samsung/android/health/data/1.0.0/...` — Samsung Health Data SDK
  (transitive dep, normally fetched from the SDK's own bundled repo)

## How to consume

In the consumer app's `pubspec.yaml`:

```yaml
dependencies:
  open_wearables_health_sdk:
    git:
      url: https://github.com/OsamaNasserDev/open_wearables_health_sdk.git
      ref: kaj-patched
```

Then `flutter pub get` and the patched artifacts resolve automatically.

## How to rebuild the AAR if upstream releases a fix

1. Clone the fixed upstream native SDK to a working dir.
2. Build the release AAR + publish to this plugin's bundled repo in one shot:
   ```
   ./gradlew :sdk:publishReleasePublicationToFlutterPluginRepository \
     -PflutterPluginRepo=<absolute path>/android/libs/maven
   ```
3. Commit the regenerated `android/libs/maven` tree.
4. If the upstream version number changed, also update `android/build.gradle`'s
   `implementation("com.openwearables.health:sdk:<new>")` line.

## When to drop this fork

Either of the following makes this fork unnecessary:
- `the-momentum/open_wearables_android_sdk` ships a release ≥ v0.11.1 with
  the Integer→Float cast fix.
- An upstream release of `open_wearables_health_sdk` bumps its native dep
  past v0.10.0 and includes that fix.

When that happens, switch `pubspec.yaml` back to the pub.dev version.
