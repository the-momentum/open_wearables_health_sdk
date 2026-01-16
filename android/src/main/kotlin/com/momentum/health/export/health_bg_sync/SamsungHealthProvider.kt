package com.momentum.health.export.health_bg_sync

import android.app.Activity
import android.content.Context
import android.content.pm.PackageManager
import android.util.Log
import com.samsung.android.sdk.health.data.HealthDataService
import com.samsung.android.sdk.health.data.HealthDataStore
import com.samsung.android.sdk.health.data.data.HealthDataType
import com.samsung.android.sdk.health.data.permission.AccessType
import com.samsung.android.sdk.health.data.permission.Permission
import com.samsung.android.sdk.health.data.request.DataType
import com.samsung.android.sdk.health.data.request.ReadDataRequest
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.time.Instant
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter
import java.util.UUID
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

/**
 * Samsung Health SDK implementation for health data synchronization.
 * Provides methods to request permissions, read health data, and sync to backend.
 */
class SamsungHealthProvider(
    private val context: Context,
    private val storage: HealthBgSyncStorage,
    private val logCallback: ((String) -> Unit)? = null
) {

    companion object {
        private const val TAG = "SamsungHealthProvider"
        private const val SAMSUNG_HEALTH_PACKAGE = "com.sec.android.app.shealth"
        private const val MIN_SAMSUNG_HEALTH_VERSION = 6_030_002L // 6.30.2

        /**
         * Check if Samsung Health is available on this device.
         */
        fun isAvailable(context: Context): Boolean {
            return try {
                val pm = context.packageManager
                val packageInfo = pm.getPackageInfo(SAMSUNG_HEALTH_PACKAGE, 0)
                
                // Parse version code
                val versionCode = if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.P) {
                    packageInfo.longVersionCode
                } else {
                    @Suppress("DEPRECATION")
                    packageInfo.versionCode.toLong()
                }
                
                Log.d(TAG, "Samsung Health version: $versionCode (min required: $MIN_SAMSUNG_HEALTH_VERSION)")
                versionCode >= MIN_SAMSUNG_HEALTH_VERSION
            } catch (e: PackageManager.NameNotFoundException) {
                Log.d(TAG, "Samsung Health not installed")
                false
            }
        }
    }

    private var healthDataStore: HealthDataStore? = null
    private var trackedTypes: List<String> = emptyList()
    private val isoFormatter = DateTimeFormatter.ISO_INSTANT

    private fun log(message: String) {
        Log.d(TAG, message)
        logCallback?.invoke(message)
    }

    // MARK: - Initialization

    /**
     * Initialize Samsung Health SDK connection.
     */
    suspend fun initialize(): Boolean = withContext(Dispatchers.IO) {
        return@withContext try {
            if (!isAvailable(context)) {
                log("❌ Samsung Health not available")
                return@withContext false
            }

            val service = HealthDataService.getHealthDataService(context)
            healthDataStore = service.getHealthDataStore()
            
            log("✅ Samsung Health SDK initialized")
            true
        } catch (e: Exception) {
            log("❌ Failed to initialize Samsung Health: ${e.message}")
            false
        }
    }

    // MARK: - Permissions

    /**
     * Request read permissions for specified health data types.
     */
    suspend fun requestPermissions(activity: Activity, types: List<String>): Boolean {
        trackedTypes = types
        storage.saveTrackedTypes(types)

        return suspendCancellableCoroutine { continuation ->
            try {
                val permissions = buildPermissionSet(types)
                
                if (permissions.isEmpty()) {
                    log("⚠️ No valid Samsung Health types to request")
                    continuation.resume(false)
                    return@suspendCancellableCoroutine
                }

                log("📋 Requesting permissions for ${permissions.size} Samsung Health types")

                val store = healthDataStore
                if (store == null) {
                    log("❌ Health store not initialized")
                    continuation.resume(false)
                    return@suspendCancellableCoroutine
                }

                store.requestPermissions(permissions.toSet(), activity) { result ->
                    val grantedCount = result.resultPermissions.count { it.value == true }
                    log("✅ Granted $grantedCount/${permissions.size} permissions")
                    continuation.resume(grantedCount == permissions.size)
                }
            } catch (e: Exception) {
                log("❌ Permission request failed: ${e.message}")
                continuation.resumeWithException(e)
            }
        }
    }

    /**
     * Check if all required permissions are granted.
     */
    suspend fun hasPermissions(types: List<String>): Boolean = withContext(Dispatchers.IO) {
        return@withContext try {
            val store = healthDataStore ?: return@withContext false
            val permissions = buildPermissionSet(types)
            
            val granted = store.getGrantedPermissions(permissions.toSet())
            granted.size == permissions.size
        } catch (e: Exception) {
            log("❌ Failed to check permissions: ${e.message}")
            false
        }
    }

    private fun buildPermissionSet(types: List<String>): List<Permission> {
        val samsungTypes = HealthBgSyncTypes.getUniqueSamsungTypes(types)
        return samsungTypes.mapNotNull { type ->
            try {
                Permission(DataType(type), AccessType.READ)
            } catch (e: Exception) {
                log("⚠️ Unknown Samsung Health type: $type")
                null
            }
        }
    }

    // MARK: - Data Reading

    /**
     * Read all health data since the last sync anchor.
     * Returns JSON payload ready to send to backend.
     */
    suspend fun readHealthData(
        types: List<String>,
        fullExport: Boolean,
        userKey: String
    ): SyncResult = withContext(Dispatchers.IO) {
        val store = healthDataStore
        if (store == null) {
            log("❌ Health store not initialized")
            return@withContext SyncResult(emptyList(), emptyList(), emptyMap())
        }

        val records = mutableListOf<JSONObject>()
        val workouts = mutableListOf<JSONObject>()
        val newAnchors = mutableMapOf<String, String>()

        for (dartType in types) {
            val mapping = HealthBgSyncTypes.mapType(dartType) ?: continue
            
            try {
                val result = readDataType(
                    store = store,
                    dartType = dartType,
                    mapping = mapping,
                    fullExport = fullExport,
                    userKey = userKey
                )
                
                if (mapping.samsungType == "com.samsung.health.exercise") {
                    workouts.addAll(result.items)
                } else {
                    records.addAll(result.items)
                }
                
                if (result.anchor != null) {
                    newAnchors[dartType] = result.anchor
                }
                
                if (result.items.isNotEmpty()) {
                    log("  ${dartType}: ${result.items.size}")
                }
            } catch (e: Exception) {
                log("⚠️ Failed to read $dartType: ${e.message}")
            }
        }

        log("📊 Total: ${records.size} records, ${workouts.size} workouts")
        SyncResult(records, workouts, newAnchors)
    }

    private suspend fun readDataType(
        store: HealthDataStore,
        dartType: String,
        mapping: HealthBgSyncTypes.HealthTypeMapping,
        fullExport: Boolean,
        userKey: String
    ): DataTypeResult = suspendCancellableCoroutine { continuation ->
        try {
            val dataType = DataType(mapping.samsungType)
            
            // Get anchor if not full export
            val anchorTime = if (fullExport) {
                null
            } else {
                storage.getAnchor(dartType, userKey)?.toLongOrNull()
            }
            
            // Build request
            val requestBuilder = ReadDataRequest.Builder(dataType)
            
            if (anchorTime != null) {
                // Read from anchor time
                requestBuilder.setStartTime(Instant.ofEpochMilli(anchorTime))
            } else {
                // Full export - read last 365 days
                val startTime = Instant.now().minusSeconds(365L * 24 * 60 * 60)
                requestBuilder.setStartTime(startTime)
            }
            
            requestBuilder.setEndTime(Instant.now())
            
            val request = requestBuilder.build()
            
            store.readData(request) { result ->
                try {
                    val items = mutableListOf<JSONObject>()
                    var latestTime = anchorTime ?: 0L
                    
                    for (data in result.dataList) {
                        val json = serializeHealthData(data, dartType, mapping)
                        items.add(json)
                        
                        // Track latest timestamp for anchor
                        val endTime = data.endTime?.toEpochMilli() ?: data.startTime.toEpochMilli()
                        if (endTime > latestTime) {
                            latestTime = endTime
                        }
                    }
                    
                    val newAnchor = if (items.isNotEmpty()) {
                        latestTime.toString()
                    } else {
                        null
                    }
                    
                    continuation.resume(DataTypeResult(items, newAnchor))
                } catch (e: Exception) {
                    continuation.resume(DataTypeResult(emptyList(), null))
                }
            }
        } catch (e: Exception) {
            log("❌ Read error for $dartType: ${e.message}")
            continuation.resume(DataTypeResult(emptyList(), null))
        }
    }

    private fun serializeHealthData(
        data: com.samsung.android.sdk.health.data.data.HealthData,
        dartType: String,
        mapping: HealthBgSyncTypes.HealthTypeMapping
    ): JSONObject {
        val json = JSONObject()
        
        // Generate UUID for this record
        json.put("uuid", UUID.randomUUID().toString())
        json.put("type", mapping.samsungType)
        
        // Get value based on field name
        val value = when (mapping.valueField) {
            "count" -> data.getValue("count")?.toString()?.toDoubleOrNull() ?: 0.0
            "heart_rate" -> data.getValue("heart_rate")?.toString()?.toDoubleOrNull() ?: 0.0
            "weight" -> data.getValue("weight")?.toString()?.toDoubleOrNull() ?: 0.0
            "height" -> data.getValue("height")?.toString()?.toDoubleOrNull() ?: 0.0
            "spo2" -> data.getValue("spo2")?.toString()?.toDoubleOrNull() ?: 0.0
            "glucose" -> data.getValue("glucose")?.toString()?.toDoubleOrNull() ?: 0.0
            "systolic" -> data.getValue("systolic")?.toString()?.toDoubleOrNull() ?: 0.0
            "diastolic" -> data.getValue("diastolic")?.toString()?.toDoubleOrNull() ?: 0.0
            "calorie" -> data.getValue("calorie")?.toString()?.toDoubleOrNull() ?: 0.0
            "distance" -> data.getValue("distance")?.toString()?.toDoubleOrNull() ?: 0.0
            "duration" -> data.getValue("duration")?.toString()?.toDoubleOrNull() ?: 0.0
            else -> data.getValue(mapping.valueField)?.toString()?.toDoubleOrNull() ?: 0.0
        }
        
        json.put("value", value)
        json.put("unit", mapping.unit)
        
        // Timestamps
        json.put("startDate", isoFormatter.format(data.startTime.atOffset(ZoneOffset.UTC)))
        data.endTime?.let {
            json.put("endDate", isoFormatter.format(it.atOffset(ZoneOffset.UTC)))
        } ?: json.put("endDate", isoFormatter.format(data.startTime.atOffset(ZoneOffset.UTC)))
        
        // Source
        json.put("sourceName", data.packageName ?: "Samsung Health")
        
        // Metadata
        val metadata = JSONArray()
        data.metadata?.forEach { (key, value) ->
            val meta = JSONObject()
            meta.put("key", key)
            meta.put("value", value.toString())
            metadata.put(meta)
        }
        json.put("recordMetadata", metadata)
        
        return json
    }

    /**
     * Serialize workout data to JSON.
     */
    fun serializeWorkout(
        data: com.samsung.android.sdk.health.data.data.HealthData
    ): JSONObject {
        val json = JSONObject()
        
        json.put("uuid", UUID.randomUUID().toString())
        
        // Workout type
        val exerciseType = data.getValue("exercise_type")?.toString()?.toIntOrNull() ?: 0
        json.put("type", HealthBgSyncTypes.mapWorkoutType(exerciseType))
        
        // Timestamps
        json.put("startDate", isoFormatter.format(data.startTime.atOffset(ZoneOffset.UTC)))
        data.endTime?.let {
            json.put("endDate", isoFormatter.format(it.atOffset(ZoneOffset.UTC)))
        }
        
        json.put("sourceName", data.packageName ?: "Samsung Health")
        
        // Workout statistics
        val stats = JSONArray()
        
        // Duration
        val duration = data.getValue("duration")?.toString()?.toDoubleOrNull()
        if (duration != null) {
            val durationStat = JSONObject()
            durationStat.put("type", "duration")
            durationStat.put("value", duration / 1000.0) // Convert ms to seconds
            durationStat.put("unit", "s")
            stats.put(durationStat)
        }
        
        // Calories
        val calories = data.getValue("calorie")?.toString()?.toDoubleOrNull()
        if (calories != null) {
            val calStat = JSONObject()
            calStat.put("type", "activeEnergyBurned")
            calStat.put("value", calories)
            calStat.put("unit", "kcal")
            stats.put(calStat)
        }
        
        // Distance
        val distance = data.getValue("distance")?.toString()?.toDoubleOrNull()
        if (distance != null) {
            val distStat = JSONObject()
            distStat.put("type", "distance")
            distStat.put("value", distance)
            distStat.put("unit", "m")
            stats.put(distStat)
        }
        
        // Heart rate
        val avgHr = data.getValue("mean_heart_rate")?.toString()?.toDoubleOrNull()
        if (avgHr != null) {
            val hrStat = JSONObject()
            hrStat.put("type", "averageHeartRate")
            hrStat.put("value", avgHr)
            hrStat.put("unit", "bpm")
            stats.put(hrStat)
        }
        
        val maxHr = data.getValue("max_heart_rate")?.toString()?.toDoubleOrNull()
        if (maxHr != null) {
            val hrStat = JSONObject()
            hrStat.put("type", "maxHeartRate")
            hrStat.put("value", maxHr)
            hrStat.put("unit", "bpm")
            stats.put(hrStat)
        }
        
        json.put("workoutStatistics", stats)
        
        return json
    }

    // MARK: - Cleanup

    fun disconnect() {
        healthDataStore = null
        log("🔌 Samsung Health disconnected")
    }

    // MARK: - Data Classes

    data class SyncResult(
        val records: List<JSONObject>,
        val workouts: List<JSONObject>,
        val anchors: Map<String, String>
    ) {
        fun toPayload(): JSONObject {
            val data = JSONObject()
            
            val recordsArray = JSONArray()
            records.forEach { recordsArray.put(it) }
            data.put("records", recordsArray)
            
            val workoutsArray = JSONArray()
            workouts.forEach { workoutsArray.put(it) }
            data.put("workouts", workoutsArray)
            
            val payload = JSONObject()
            payload.put("data", data)
            
            return payload
        }
        
        val isEmpty: Boolean
            get() = records.isEmpty() && workouts.isEmpty()
        
        val totalCount: Int
            get() = records.size + workouts.size
    }

    private data class DataTypeResult(
        val items: List<JSONObject>,
        val anchor: String?
    )
}
