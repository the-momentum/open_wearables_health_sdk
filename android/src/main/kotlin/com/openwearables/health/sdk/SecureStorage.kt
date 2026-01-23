package com.openwearables.health.sdk

import android.content.Context
import android.content.SharedPreferences
import android.util.Log
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey

/**
 * Secure storage for credentials using EncryptedSharedPreferences
 */
class SecureStorage(private val context: Context) {

    companion object {
        private const val TAG = "SecureStorage"
        private const val PREFS_NAME = "com.openwearables.healthsdk.secure"
        private const val CONFIG_PREFS_NAME = "com.openwearables.healthsdk.config"

        // Secure keys (encrypted)
        private const val KEY_ACCESS_TOKEN = "accessToken"
        private const val KEY_USER_ID = "userId"
        private const val KEY_APP_ID = "appId"
        private const val KEY_APP_SECRET = "appSecret"

        // Config keys (not encrypted, not sensitive)
        private const val KEY_CUSTOM_SYNC_URL = "customSyncUrl"
        private const val KEY_SYNC_ACTIVE = "syncActive"
        private const val KEY_TRACKED_TYPES = "trackedTypes"
        private const val KEY_TOKEN_EXPIRES_AT = "tokenExpiresAt"
        private const val KEY_BASE_URL = "baseUrl"
        private const val KEY_APP_INSTALLED = "appInstalled"
    }

    private val securePrefs: SharedPreferences by lazy {
        try {
            val masterKey = MasterKey.Builder(context)
                .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
                .build()

            EncryptedSharedPreferences.create(
                context,
                PREFS_NAME,
                masterKey,
                EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
                EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM
            )
        } catch (e: Exception) {
            Log.e(TAG, "Failed to create encrypted prefs, falling back to regular prefs", e)
            context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        }
    }

    private val configPrefs: SharedPreferences by lazy {
        context.getSharedPreferences(CONFIG_PREFS_NAME, Context.MODE_PRIVATE)
    }

    // MARK: - Fresh Install Detection

    /**
     * Call this on app launch to clear data if app was reinstalled.
     */
    fun clearIfReinstalled() {
        val wasInstalled = configPrefs.getBoolean(KEY_APP_INSTALLED, false)

        if (!wasInstalled) {
            if (hasSession()) {
                Log.d(TAG, "App reinstalled - clearing stale data")
                clearAll()
            }
            configPrefs.edit().putBoolean(KEY_APP_INSTALLED, true).apply()
        }
    }

    // MARK: - Credentials

    fun saveCredentials(userId: String, accessToken: String) {
        securePrefs.edit()
            .putString(KEY_USER_ID, userId)
            .putString(KEY_ACCESS_TOKEN, accessToken)
            .apply()
    }

    fun getAccessToken(): String? = securePrefs.getString(KEY_ACCESS_TOKEN, null)

    fun getUserId(): String? = securePrefs.getString(KEY_USER_ID, null)

    fun hasSession(): Boolean = getAccessToken() != null && getUserId() != null

    // MARK: - App Credentials (for token refresh)

    fun saveAppCredentials(appId: String, appSecret: String, baseUrl: String) {
        securePrefs.edit()
            .putString(KEY_APP_ID, appId)
            .putString(KEY_APP_SECRET, appSecret)
            .apply()
        configPrefs.edit()
            .putString(KEY_BASE_URL, baseUrl)
            .apply()
    }

    fun getAppId(): String? = securePrefs.getString(KEY_APP_ID, null)

    fun getAppSecret(): String? = securePrefs.getString(KEY_APP_SECRET, null)

    fun getBaseUrl(): String? = configPrefs.getString(KEY_BASE_URL, null)

    fun hasRefreshCredentials(): Boolean {
        return getAppId() != null && getAppSecret() != null && getBaseUrl() != null && getUserId() != null
    }

    // MARK: - Token Expiry

    fun saveTokenExpiry(expiresAtMillis: Long) {
        configPrefs.edit()
            .putLong(KEY_TOKEN_EXPIRES_AT, expiresAtMillis)
            .apply()
    }

    fun getTokenExpiry(): Long = configPrefs.getLong(KEY_TOKEN_EXPIRES_AT, 0)

    fun isTokenExpired(): Boolean {
        val expiry = getTokenExpiry()
        if (expiry == 0L) return true
        // Consider expired if less than 5 minutes remaining
        return System.currentTimeMillis() + (5 * 60 * 1000) > expiry
    }

    // MARK: - Custom Sync URL

    fun saveCustomSyncUrl(url: String) {
        configPrefs.edit()
            .putString(KEY_CUSTOM_SYNC_URL, url)
            .apply()
    }

    fun getCustomSyncUrl(): String? = configPrefs.getString(KEY_CUSTOM_SYNC_URL, null)

    // MARK: - Sync Active State

    fun setSyncActive(active: Boolean) {
        configPrefs.edit()
            .putBoolean(KEY_SYNC_ACTIVE, active)
            .apply()
    }

    fun isSyncActive(): Boolean = configPrefs.getBoolean(KEY_SYNC_ACTIVE, false)

    // MARK: - Tracked Types

    fun saveTrackedTypes(types: List<String>) {
        configPrefs.edit()
            .putStringSet(KEY_TRACKED_TYPES, types.toSet())
            .apply()
    }

    fun getTrackedTypes(): List<String> {
        return configPrefs.getStringSet(KEY_TRACKED_TYPES, emptySet())?.toList() ?: emptyList()
    }

    // MARK: - Clear

    fun clearAll() {
        securePrefs.edit().clear().apply()
        configPrefs.edit()
            .remove(KEY_CUSTOM_SYNC_URL)
            .remove(KEY_SYNC_ACTIVE)
            .remove(KEY_TRACKED_TYPES)
            .remove(KEY_TOKEN_EXPIRES_AT)
            .remove(KEY_BASE_URL)
            .apply()
    }
}
