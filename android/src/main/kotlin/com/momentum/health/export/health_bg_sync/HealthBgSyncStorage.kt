package com.momentum.health.export.health_bg_sync

import android.content.Context
import android.content.SharedPreferences
import android.util.Log
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey

/**
 * Secure storage for credentials using Android EncryptedSharedPreferences.
 * Equivalent to iOS Keychain implementation.
 */
class HealthBgSyncStorage(context: Context) {

    companion object {
        private const val TAG = "HealthBgSyncStorage"
        private const val PREFS_NAME = "health_bg_sync_secure"
        private const val CONFIG_PREFS_NAME = "health_bg_sync_config"

        // Secure keys (encrypted)
        private const val KEY_ACCESS_TOKEN = "access_token"
        private const val KEY_USER_ID = "user_id"
        private const val KEY_APP_ID = "app_id"
        private const val KEY_APP_SECRET = "app_secret"

        // Config keys (non-sensitive, regular SharedPreferences)
        private const val KEY_BASE_URL = "base_url"
        private const val KEY_CUSTOM_SYNC_URL = "custom_sync_url"
        private const val KEY_SYNC_ACTIVE = "sync_active"
        private const val KEY_TRACKED_TYPES = "tracked_types"
        private const val KEY_TOKEN_EXPIRES_AT = "token_expires_at"
        private const val KEY_APP_INSTALLED = "app_installed"
        private const val KEY_PROVIDER = "provider"

        @Volatile
        private var instance: HealthBgSyncStorage? = null

        fun getInstance(context: Context): HealthBgSyncStorage {
            return instance ?: synchronized(this) {
                instance ?: HealthBgSyncStorage(context.applicationContext).also { instance = it }
            }
        }
    }

    private val securePrefs: SharedPreferences
    private val configPrefs: SharedPreferences

    init {
        // Create MasterKey for encryption
        val masterKey = MasterKey.Builder(context)
            .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
            .build()

        // Encrypted SharedPreferences for sensitive data
        securePrefs = EncryptedSharedPreferences.create(
            context,
            PREFS_NAME,
            masterKey,
            EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
            EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM
        )

        // Regular SharedPreferences for non-sensitive config
        configPrefs = context.getSharedPreferences(CONFIG_PREFS_NAME, Context.MODE_PRIVATE)

        // Check for reinstall
        clearIfReinstalled()
    }

    // MARK: - Fresh Install Detection

    /**
     * Clear storage if app was reinstalled.
     * Regular SharedPreferences is cleared on uninstall, EncryptedSharedPreferences may persist.
     */
    private fun clearIfReinstalled() {
        val wasInstalled = configPrefs.getBoolean(KEY_APP_INSTALLED, false)

        if (!wasInstalled) {
            // First launch after install (or reinstall)
            if (hasSession()) {
                Log.i(TAG, "🔄 App reinstalled - clearing stale storage data")
                clearAll()
            }

            // Mark as installed
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

    fun getTokenExpiry(): Long? {
        val timestamp = configPrefs.getLong(KEY_TOKEN_EXPIRES_AT, 0)
        return if (timestamp > 0) timestamp else null
    }

    fun isTokenExpired(): Boolean {
        val expiry = getTokenExpiry() ?: return true
        // Consider expired if less than 5 minutes remaining
        return System.currentTimeMillis() + (5 * 60 * 1000) > expiry
    }

    // MARK: - Custom Sync URL

    fun saveCustomSyncUrl(url: String?) {
        if (url != null) {
            configPrefs.edit().putString(KEY_CUSTOM_SYNC_URL, url).apply()
        } else {
            configPrefs.edit().remove(KEY_CUSTOM_SYNC_URL).apply()
        }
    }

    fun getCustomSyncUrl(): String? = configPrefs.getString(KEY_CUSTOM_SYNC_URL, null)

    // MARK: - Sync Active State

    fun setSyncActive(active: Boolean) {
        configPrefs.edit().putBoolean(KEY_SYNC_ACTIVE, active).apply()
    }

    fun isSyncActive(): Boolean = configPrefs.getBoolean(KEY_SYNC_ACTIVE, false)

    // MARK: - Tracked Types

    fun saveTrackedTypes(types: List<String>) {
        configPrefs.edit()
            .putStringSet(KEY_TRACKED_TYPES, types.toSet())
            .apply()
    }

    fun getTrackedTypes(): List<String>? {
        val set = configPrefs.getStringSet(KEY_TRACKED_TYPES, null)
        return set?.toList()
    }

    // MARK: - Provider

    fun saveProvider(provider: HealthProvider) {
        configPrefs.edit()
            .putString(KEY_PROVIDER, provider.id)
            .apply()
    }

    fun getProvider(): HealthProvider? {
        val id = configPrefs.getString(KEY_PROVIDER, null) ?: return null
        return HealthProvider.fromId(id)
    }

    // MARK: - Anchors (per-user, per-type)

    fun saveAnchor(typeIdentifier: String, userKey: String, anchorData: String) {
        val key = "anchor.$userKey.$typeIdentifier"
        configPrefs.edit().putString(key, anchorData).apply()
    }

    fun getAnchor(typeIdentifier: String, userKey: String): String? {
        val key = "anchor.$userKey.$typeIdentifier"
        return configPrefs.getString(key, null)
    }

    fun removeAnchor(typeIdentifier: String, userKey: String) {
        val key = "anchor.$userKey.$typeIdentifier"
        configPrefs.edit().remove(key).apply()
    }

    // MARK: - Full Export Done Flag

    fun setFullExportDone(userKey: String, done: Boolean) {
        val key = "fullDone.$userKey"
        configPrefs.edit().putBoolean(key, done).apply()
    }

    fun isFullExportDone(userKey: String): Boolean {
        val key = "fullDone.$userKey"
        return configPrefs.getBoolean(key, false)
    }

    // MARK: - Clear

    fun clearAll() {
        securePrefs.edit().clear().apply()
        
        // Clear config but preserve app_installed flag
        val editor = configPrefs.edit()
        editor.remove(KEY_CUSTOM_SYNC_URL)
        editor.remove(KEY_SYNC_ACTIVE)
        editor.remove(KEY_TRACKED_TYPES)
        editor.remove(KEY_TOKEN_EXPIRES_AT)
        editor.remove(KEY_BASE_URL)
        editor.remove(KEY_PROVIDER)
        editor.apply()
    }
}
