package com.momentum.health.export.health_bg_sync

import android.content.Context

/**
 * Enum representing available health data providers on Android.
 * Currently only Samsung Health is implemented, but this allows
 * easy extension to Health Connect and other providers in the future.
 */
enum class HealthProvider(val id: String, val displayName: String) {
    SAMSUNG_HEALTH("samsung_health", "Samsung Health"),
    // Future providers:
    // HEALTH_CONNECT("health_connect", "Health Connect"),
    // GARMIN("garmin", "Garmin Connect"),
    // FITBIT("fitbit", "Fitbit"),
    ;

    companion object {
        fun fromId(id: String): HealthProvider? {
            return entries.find { it.id == id }
        }

        /**
         * Returns the default provider for the current device.
         * In the future, this could detect Samsung devices and prefer Samsung Health,
         * or prefer Health Connect on other devices.
         */
        fun getDefaultProvider(context: Context): HealthProvider {
            // For now, default to Samsung Health
            // In the future: check device manufacturer, installed apps, etc.
            return SAMSUNG_HEALTH
        }

        /**
         * Returns list of available providers on this device.
         */
        fun getAvailableProviders(context: Context): List<HealthProvider> {
            val available = mutableListOf<HealthProvider>()
            
            // Check Samsung Health availability
            if (SamsungHealthProvider.isAvailable(context)) {
                available.add(SAMSUNG_HEALTH)
            }
            
            // Future: Check Health Connect availability
            // if (HealthConnectProvider.isAvailable(context)) {
            //     available.add(HEALTH_CONNECT)
            // }
            
            return available
        }
    }
}
