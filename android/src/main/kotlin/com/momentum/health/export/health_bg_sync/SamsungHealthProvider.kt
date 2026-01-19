package com.momentum.health.export.health_bg_sync

import android.app.Activity
import android.content.Context
import android.content.pm.PackageManager
import android.util.Log
import com.samsung.android.sdk.health.data.HealthDataService
import com.samsung.android.sdk.health.data.HealthDataStore
import com.samsung.android.sdk.health.data.data.HealthDataPoint
import com.samsung.android.sdk.health.data.permission.AccessType
import com.samsung.android.sdk.health.data.permission.Permission
import com.samsung.android.sdk.health.data.request.DataType
import com.samsung.android.sdk.health.data.request.LocalTimeFilter
import com.samsung.android.sdk.health.data.request.ReadDataRequest
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.time.Instant
import java.time.LocalDateTime
import java.time.ZoneId
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter
import java.util.UUID

/**
 * Samsung Health SDK implementation for health data synchronization.
 * 
 * IMPORTANT: This requires Samsung Health Data SDK .aar file in android/libs/
 * Download from: https://developer.samsung.com/health/android/overview.html
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
            } catch (e: Exception) {
                Log.e(TAG, "Error checking Samsung Health: ${e.message}")
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

            // Get HealthDataStore from HealthDataService
            healthDataStore = HealthDataService.getHealthDataStore(context)
            
            log("✅ Samsung Health SDK initialized")
            true
        } catch (e: Exception) {
            log("❌ Failed to initialize Samsung Health: ${e.message}")
            e.printStackTrace()
            false
        }
    }

    // MARK: - Permissions

    /**
     * Request read permissions for specified health data types.
     */
    suspend fun requestPermissions(activity: Activity, types: List<String>): Boolean = withContext(Dispatchers.IO) {
        trackedTypes = types
        storage.saveTrackedTypes(types)

        try {
            val permissions = buildPermissionSet(types)
            
            if (permissions.isEmpty()) {
                log("⚠️ No valid Samsung Health types to request")
                return@withContext false
            }

            log("📋 Requesting permissions for ${permissions.size} Samsung Health types")

            val store = healthDataStore
            if (store == null) {
                log("❌ Health store not initialized")
                return@withContext false
            }

            // Samsung Health Data SDK uses suspend functions
            val grantedPermissions = store.requestPermissions(permissions, activity)
            
            val grantedCount = grantedPermissions.size
            log("✅ Granted $grantedCount/${permissions.size} permissions")
            
            return@withContext grantedCount == permissions.size
        } catch (e: Exception) {
            log("❌ Permission request failed: ${e.message}")
            e.printStackTrace()
            return@withContext false
        }
    }

    /**
     * Check if all required permissions are granted.
     */
    suspend fun hasPermissions(types: List<String>): Boolean = withContext(Dispatchers.IO) {
        return@withContext try {
            val store = healthDataStore ?: return@withContext false
            val permissions = buildPermissionSet(types)
            
            val granted = store.getGrantedPermissions(permissions)
            granted.size == permissions.size
        } catch (e: Exception) {
            log("❌ Failed to check permissions: ${e.message}")
            false
        }
    }

    private fun buildPermissionSet(types: List<String>): Set<Permission> {
        val permissions = mutableSetOf<Permission>()
        
        for (dartType in types) {
            try {
                when (dartType) {
                    "steps" -> permissions.add(Permission.of(DataType.StepsType, AccessType.READ))
                    "heartRate", "restingHeartRate" -> permissions.add(Permission.of(DataType.HeartRateType, AccessType.READ))
                    "sleep" -> permissions.add(Permission.of(DataType.SleepType, AccessType.READ))
                    "workout", "activeEnergy" -> permissions.add(Permission.of(DataType.ExerciseType, AccessType.READ))
                    "bloodGlucose" -> permissions.add(Permission.of(DataType.BloodGlucoseType, AccessType.READ))
                    "oxygenSaturation" -> permissions.add(Permission.of(DataType.BloodOxygenType, AccessType.READ))
                    "bloodPressure", "bloodPressureSystolic", "bloodPressureDiastolic" -> 
                        permissions.add(Permission.of(DataType.BloodPressureType, AccessType.READ))
                    "flightsClimbed" -> permissions.add(Permission.of(DataType.FloorsClimbedType, AccessType.READ))
                }
            } catch (e: Exception) {
                log("⚠️ Error creating permission for $dartType: ${e.message}")
            }
        }
        
        return permissions
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
        
        // Track which Samsung types we've already processed
        val processedTypes = mutableSetOf<String>()

        for (dartType in types) {
            try {
                // Skip if we already processed this Samsung type
                val samsungType = getSamsungTypeName(dartType) ?: continue
                if (samsungType in processedTypes) continue
                processedTypes.add(samsungType)
                
                val result = readDataForType(
                    store = store,
                    dartType = dartType,
                    fullExport = fullExport,
                    userKey = userKey
                )
                
                if (dartType == "workout" || dartType == "activeEnergy") {
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
                e.printStackTrace()
            }
        }

        log("📊 Total: ${records.size} records, ${workouts.size} workouts")
        SyncResult(records, workouts, newAnchors)
    }

    private fun getSamsungTypeName(dartType: String): String? {
        return when (dartType) {
            "steps" -> "steps"
            "heartRate", "restingHeartRate" -> "heartRate"
            "sleep" -> "sleep"
            "workout", "activeEnergy" -> "exercise"
            "bloodGlucose" -> "bloodGlucose"
            "oxygenSaturation" -> "bloodOxygen"
            "bloodPressure", "bloodPressureSystolic", "bloodPressureDiastolic" -> "bloodPressure"
            "flightsClimbed" -> "floorsClimbed"
            else -> null
        }
    }

    private suspend fun readDataForType(
        store: HealthDataStore,
        dartType: String,
        fullExport: Boolean,
        userKey: String
    ): DataTypeResult {
        // Get anchor if not full export
        val anchorTime = if (fullExport) {
            null
        } else {
            storage.getAnchor(dartType, userKey)?.toLongOrNull()
        }

        // Calculate time range
        val endTime = LocalDateTime.now()
        val startTime = if (anchorTime != null) {
            LocalDateTime.ofInstant(Instant.ofEpochMilli(anchorTime), ZoneId.systemDefault())
        } else {
            // Full export - read last 365 days
            endTime.minusDays(365)
        }

        val timeFilter = LocalTimeFilter.of(startTime, endTime)
        val items = mutableListOf<JSONObject>()
        var latestTime = anchorTime ?: 0L

        try {
            when (dartType) {
                "steps" -> {
                    val request = ReadDataRequest.Builder(DataType.StepsType)
                        .setLocalTimeFilter(timeFilter)
                        .build()
                    val response = store.readData(request)
                    
                    for (dataPoint in response.dataList) {
                        val json = createRecordJson(
                            type = "steps",
                            value = dataPoint.count.toDouble(),
                            unit = "count",
                            startTime = dataPoint.startTime,
                            endTime = dataPoint.endTime,
                            source = dataPoint.dataSource?.appPackageName
                        )
                        items.add(json)
                        
                        val time = dataPoint.endTime.atZone(ZoneId.systemDefault()).toInstant().toEpochMilli()
                        if (time > latestTime) latestTime = time
                    }
                }
                "heartRate", "restingHeartRate" -> {
                    val request = ReadDataRequest.Builder(DataType.HeartRateType)
                        .setLocalTimeFilter(timeFilter)
                        .build()
                    val response = store.readData(request)
                    
                    for (dataPoint in response.dataList) {
                        val json = createRecordJson(
                            type = "heartRate",
                            value = dataPoint.heartRate.toDouble(),
                            unit = "bpm",
                            startTime = dataPoint.startTime,
                            endTime = dataPoint.endTime,
                            source = dataPoint.dataSource?.appPackageName
                        )
                        items.add(json)
                        
                        val time = dataPoint.endTime.atZone(ZoneId.systemDefault()).toInstant().toEpochMilli()
                        if (time > latestTime) latestTime = time
                    }
                }
                "sleep" -> {
                    val request = ReadDataRequest.Builder(DataType.SleepType)
                        .setLocalTimeFilter(timeFilter)
                        .build()
                    val response = store.readData(request)
                    
                    for (dataPoint in response.dataList) {
                        val durationMinutes = java.time.Duration.between(
                            dataPoint.startTime, 
                            dataPoint.endTime
                        ).toMinutes()
                        
                        val json = createRecordJson(
                            type = "sleep",
                            value = durationMinutes.toDouble(),
                            unit = "min",
                            startTime = dataPoint.startTime,
                            endTime = dataPoint.endTime,
                            source = dataPoint.dataSource?.appPackageName
                        )
                        items.add(json)
                        
                        val time = dataPoint.endTime.atZone(ZoneId.systemDefault()).toInstant().toEpochMilli()
                        if (time > latestTime) latestTime = time
                    }
                }
                "workout", "activeEnergy" -> {
                    val request = ReadDataRequest.Builder(DataType.ExerciseType)
                        .setLocalTimeFilter(timeFilter)
                        .build()
                    val response = store.readData(request)
                    
                    for (dataPoint in response.dataList) {
                        val json = createWorkoutJson(dataPoint)
                        items.add(json)
                        
                        val time = dataPoint.endTime.atZone(ZoneId.systemDefault()).toInstant().toEpochMilli()
                        if (time > latestTime) latestTime = time
                    }
                }
                "bloodGlucose" -> {
                    val request = ReadDataRequest.Builder(DataType.BloodGlucoseType)
                        .setLocalTimeFilter(timeFilter)
                        .build()
                    val response = store.readData(request)
                    
                    for (dataPoint in response.dataList) {
                        val json = createRecordJson(
                            type = "bloodGlucose",
                            value = dataPoint.bloodGlucose.toDouble(),
                            unit = "mg/dL",
                            startTime = dataPoint.time,
                            endTime = dataPoint.time,
                            source = dataPoint.dataSource?.appPackageName
                        )
                        items.add(json)
                        
                        val time = dataPoint.time.atZone(ZoneId.systemDefault()).toInstant().toEpochMilli()
                        if (time > latestTime) latestTime = time
                    }
                }
                "oxygenSaturation" -> {
                    val request = ReadDataRequest.Builder(DataType.BloodOxygenType)
                        .setLocalTimeFilter(timeFilter)
                        .build()
                    val response = store.readData(request)
                    
                    for (dataPoint in response.dataList) {
                        val json = createRecordJson(
                            type = "oxygenSaturation",
                            value = dataPoint.oxygenSaturation.toDouble(),
                            unit = "%",
                            startTime = dataPoint.time,
                            endTime = dataPoint.time,
                            source = dataPoint.dataSource?.appPackageName
                        )
                        items.add(json)
                        
                        val time = dataPoint.time.atZone(ZoneId.systemDefault()).toInstant().toEpochMilli()
                        if (time > latestTime) latestTime = time
                    }
                }
                "bloodPressure", "bloodPressureSystolic", "bloodPressureDiastolic" -> {
                    val request = ReadDataRequest.Builder(DataType.BloodPressureType)
                        .setLocalTimeFilter(timeFilter)
                        .build()
                    val response = store.readData(request)
                    
                    for (dataPoint in response.dataList) {
                        // Add systolic
                        items.add(createRecordJson(
                            type = "bloodPressureSystolic",
                            value = dataPoint.systolic.toDouble(),
                            unit = "mmHg",
                            startTime = dataPoint.time,
                            endTime = dataPoint.time,
                            source = dataPoint.dataSource?.appPackageName
                        ))
                        // Add diastolic
                        items.add(createRecordJson(
                            type = "bloodPressureDiastolic",
                            value = dataPoint.diastolic.toDouble(),
                            unit = "mmHg",
                            startTime = dataPoint.time,
                            endTime = dataPoint.time,
                            source = dataPoint.dataSource?.appPackageName
                        ))
                        
                        val time = dataPoint.time.atZone(ZoneId.systemDefault()).toInstant().toEpochMilli()
                        if (time > latestTime) latestTime = time
                    }
                }
                "flightsClimbed" -> {
                    val request = ReadDataRequest.Builder(DataType.FloorsClimbedType)
                        .setLocalTimeFilter(timeFilter)
                        .build()
                    val response = store.readData(request)
                    
                    for (dataPoint in response.dataList) {
                        val json = createRecordJson(
                            type = "flightsClimbed",
                            value = dataPoint.floor.toDouble(),
                            unit = "count",
                            startTime = dataPoint.startTime,
                            endTime = dataPoint.endTime,
                            source = dataPoint.dataSource?.appPackageName
                        )
                        items.add(json)
                        
                        val time = dataPoint.endTime.atZone(ZoneId.systemDefault()).toInstant().toEpochMilli()
                        if (time > latestTime) latestTime = time
                    }
                }
            }
        } catch (e: Exception) {
            log("❌ Error reading $dartType: ${e.message}")
            e.printStackTrace()
        }

        val newAnchor = if (items.isNotEmpty()) latestTime.toString() else null
        return DataTypeResult(items, newAnchor)
    }

    private fun createRecordJson(
        type: String,
        value: Double,
        unit: String,
        startTime: LocalDateTime,
        endTime: LocalDateTime,
        source: String?
    ): JSONObject {
        return JSONObject().apply {
            put("uuid", UUID.randomUUID().toString())
            put("type", type)
            put("value", value)
            put("unit", unit)
            put("startDate", formatTime(startTime))
            put("endDate", formatTime(endTime))
            put("sourceName", source ?: "Samsung Health")
            put("recordMetadata", JSONArray())
        }
    }

    private fun createWorkoutJson(dataPoint: HealthDataPoint): JSONObject {
        val stats = JSONArray()
        
        // Duration
        val durationSeconds = java.time.Duration.between(
            dataPoint.startTime, 
            dataPoint.endTime
        ).seconds
        stats.put(JSONObject().apply {
            put("type", "duration")
            put("value", durationSeconds)
            put("unit", "s")
        })
        
        return JSONObject().apply {
            put("uuid", UUID.randomUUID().toString())
            put("type", "workout")
            put("startDate", formatTime(dataPoint.startTime))
            put("endDate", formatTime(dataPoint.endTime))
            put("sourceName", dataPoint.dataSource?.appPackageName ?: "Samsung Health")
            put("workoutStatistics", stats)
        }
    }

    private fun formatTime(time: LocalDateTime): String {
        return isoFormatter.format(time.toInstant(ZoneOffset.UTC))
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
