pluginManagement {
    val flutterSdkPath =
        run {
            val properties = java.util.Properties()
            file("local.properties").inputStream().use { properties.load(it) }
            val flutterSdkPath = properties.getProperty("flutter.sdk")
            require(flutterSdkPath != null) { "flutter.sdk not set in local.properties" }
            flutterSdkPath
        }

    includeBuild("$flutterSdkPath/packages/flutter_tools/gradle")

    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

plugins {
    id("dev.flutter.flutter-plugin-loader") version "1.0.0"
    id("com.android.application") version "8.9.1" apply false
    id("com.android.library") version "8.9.1" apply false
    id("org.jetbrains.kotlin.android") version "2.1.0" apply false
}

include(":app")

// Use the local, mTLS-patched copy of the Android SDK when the sibling repo
// is checked out. Falls back to the JitPack artifact on CI or machines that
// don't have open_wearables_android_sdk checked out next to this repo.
val localAndroidSdk = file("../../../open_wearables_android_sdk")
if (localAndroidSdk.exists()) {
    includeBuild(localAndroidSdk) {
        dependencySubstitution {
            substitute(module("com.github.the-momentum.open_wearables_android_sdk:sdk"))
                .using(project(":sdk"))
        }
    }
}
