package com.openwearables.health.sdk

import android.app.Activity
import android.content.Context
import android.content.pm.PackageManager
import com.samsung.android.sdk.health.data.HealthDataService
import com.samsung.android.sdk.health.data.HealthDataStore
import com.samsung.android.sdk.health.data.data.HealthDataPoint
import com.samsung.android.sdk.health.data.data.DataSource
import com.samsung.android.sdk.health.data.permission.AccessType
import com.samsung.android.sdk.health.data.permission.Permission
import com.samsung.android.sdk.health.data.request.DataType
import com.samsung.android.sdk.health.data.request.DataTypes
import com.samsung.android.sdk.health.data.request.LocalTimeFilter
import com.samsung.android.sdk.health.data.request.Ordering
import com.samsung.android.sdk.health.data.request.ReadDataRequest
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.time.Instant
import java.time.LocalDateTime
import java.time.ZoneId
import java.util.*

/**
 * Manages Samsung Health SDK interactions using the official Samsung Health Data SDK.
 * 
 * API Flow:
 * 1. Get HealthDataStore via HealthDataService.getStore(context)
 * 2. Request permissions via store.requestPermissions(permissions, activity)
 * 3. Read data via store.readData(request) - this is a suspend function
 * 4. Get values from HealthDataPoint using getValue(Field)
 */
class SamsungHealthManager(
    private val context: Context,
    private var activity: Activity?,
    private val logger: (String) -> Unit
) {
    private var healthDataStore: HealthDataStore? = null
    private var trackedTypeIds: Set<String> = emptySet()

    companion object {
        private const val SAMSUNG_HEALTH_PACKAGE = "com.sec.android.app.shealth"
        private const val MIN_SAMSUNG_HEALTH_VERSION = 6030002 // v6.30.2
    }

    fun setActivity(activity: Activity?) {
        this.activity = activity
    }

    fun setTrackedTypes(typeIds: List<String>) {
        trackedTypeIds = typeIds.toSet()
        val validTypes = typeIds.count { mapToDataType(it) != null }
        logger("📋 Tracking $validTypes Samsung Health types (out of ${typeIds.size} requested)")
    }

    fun getTrackedTypes(): Set<String> = trackedTypeIds

    /**
     * Map Flutter type ID to Samsung DataType.
     * Returns null for types not supported by Samsung Health SDK.
     */
    private fun mapToDataType(typeId: String): DataType? {
        return try {
            when (typeId) {
                "steps" -> DataTypes.STEPS
                "heartRate" -> DataTypes.HEART_RATE
                "sleep" -> DataTypes.SLEEP
                "workout" -> DataTypes.EXERCISE
                "oxygenSaturation" -> DataTypes.BLOOD_OXYGEN
                "bloodGlucose" -> DataTypes.BLOOD_GLUCOSE
                "bloodPressure", "bloodPressureSystolic", "bloodPressureDiastolic" -> DataTypes.BLOOD_PRESSURE
                "flightsClimbed" -> DataTypes.FLOORS_CLIMBED
                "bodyTemperature" -> DataTypes.BODY_TEMPERATURE
                "bodyMass", "bodyFatPercentage", "leanBodyMass" -> DataTypes.BODY_COMPOSITION
                "activeEnergy" -> DataTypes.ACTIVITY_SUMMARY
                "water" -> DataTypes.WATER_INTAKE
                else -> null
            }
        } catch (e: Exception) {
            logger("⚠️ Error mapping type $typeId: ${e.message}")
            null
        }
    }

    /**
     * Check if Samsung Health is available on this device.
     */
    fun isAvailable(): Boolean {
        return try {
            val packageInfo = context.packageManager.getPackageInfo(SAMSUNG_HEALTH_PACKAGE, 0)
            @Suppress("DEPRECATION")
            val versionCode = packageInfo.versionCode
            val available = versionCode >= MIN_SAMSUNG_HEALTH_VERSION
            
            if (!available) {
                logger("⚠️ Samsung Health version too old: $versionCode (need $MIN_SAMSUNG_HEALTH_VERSION+)")
            } else {
                logger("✅ Samsung Health available (version $versionCode)")
            }
            available
        } catch (e: PackageManager.NameNotFoundException) {
            logger("⚠️ Samsung Health app not installed")
            false
        } catch (e: Exception) {
            logger("⚠️ Error checking Samsung Health: ${e.message}")
            false
        }
    }

    /**
     * Connect to Samsung Health by getting the HealthDataStore.
     */
    suspend fun connect(): Boolean = withContext(Dispatchers.Main) {
        if (!isAvailable()) {
            logger("❌ Samsung Health not available on this device")
            return@withContext false
        }

        try {
            healthDataStore = HealthDataService.getStore(context)
            logger("✅ Connected to Samsung Health")
            true
        } catch (e: Exception) {
            logger("❌ Failed to connect to Samsung Health: ${e.message}")
            e.printStackTrace()
            false
        }
    }

    /**
     * Disconnect from Samsung Health.
     */
    fun disconnect() {
        healthDataStore = null
        logger("📱 Disconnected from Samsung Health")
    }

    /**
     * Request authorization for health data types.
     * This will show Samsung Health's permission dialog.
     */
    suspend fun requestAuthorization(typeIds: List<String>): Boolean {
        trackedTypeIds = typeIds.toSet()
        
        // Map to Samsung DataTypes and filter out unsupported types
        val dataTypes = typeIds.mapNotNull { mapToDataType(it) }.toSet()
        if (dataTypes.isEmpty()) {
            logger("⚠️ No valid Samsung Health types to authorize")
            return false
        }
        
        // Ensure we're connected
        if (healthDataStore == null) {
            val connected = connect()
            if (!connected) return false
        }

        val store = healthDataStore ?: return false
        val act = activity
        
        if (act == null) {
            logger("❌ Activity not available for permission request")
            return false
        }

        return withContext(Dispatchers.Main) {
            try {
                // Build permission set using Permission.of() factory method
                val permissions = dataTypes.map { dataType ->
                    Permission.of(dataType, AccessType.READ)
                }.toSet()
                
                logger("📋 Requesting ${permissions.size} Samsung Health permissions...")

                // Call the suspend function directly
                val grantedPermissions = store.requestPermissions(permissions, act)
                
                val allGranted = grantedPermissions.size == permissions.size
                if (allGranted) {
                    logger("✅ All ${permissions.size} permissions granted")
                } else {
                    logger("⚠️ Granted ${grantedPermissions.size}/${permissions.size} permissions")
                }
                allGranted
            } catch (e: Exception) {
                logger("❌ Permission request failed: ${e.message}")
                e.printStackTrace()
                false
            }
        }
    }

    /**
     * Read health data for a specific type.
     */
    suspend fun readData(
        typeId: String,
        sinceTimestamp: Long? = null,
        limit: Int = 1000
    ): List<HealthDataRecord> = withContext(Dispatchers.IO) {
        val dataType = mapToDataType(typeId)
        if (dataType == null) {
            logger("⚠️ Unsupported data type: $typeId")
            return@withContext emptyList()
        }

        // Ensure we're connected
        if (healthDataStore == null) {
            withContext(Dispatchers.Main) { connect() }
        }
        
        val store = healthDataStore
        if (store == null) {
            logger("❌ Not connected to Samsung Health")
            return@withContext emptyList()
        }

        try {
            // Build the read request using reflection to get the proper builder
            val request = buildReadRequest(dataType, sinceTimestamp, limit)
            if (request == null) {
                logger("⚠️ Could not build read request for $typeId")
                return@withContext emptyList()
            }

            logger("📊 Reading $typeId data...")

            // Call the suspend function
            val response = store.readData(request)
            val dataList = response.dataList
            
            val records = dataList.mapNotNull { dataPoint ->
                parseDataPoint(typeId, dataPoint as HealthDataPoint)
            }

            logger("📊 Read ${records.size} $typeId records")
            records
        } catch (e: Exception) {
            logger("❌ Failed to read $typeId: ${e.message}")
            e.printStackTrace()
            emptyList()
        }
    }

    /**
     * Build a ReadDataRequest using reflection since SDK uses different builder types.
     */
    @Suppress("UNCHECKED_CAST")
    private fun buildReadRequest(
        dataType: DataType,
        sinceTimestamp: Long?,
        limit: Int
    ): ReadDataRequest<HealthDataPoint>? {
        return try {
            // Get the builder via getReadDataRequestBuilder() method
            val builderMethod = dataType.javaClass.getMethod("getReadDataRequestBuilder")
            val builder = builderMethod.invoke(dataType) ?: return null
            
            // Use reflection to call setLimit, setOrdering, setLocalTimeFilter, build
            val builderClass = builder.javaClass
            
            // setLimit(int)
            try {
                val setLimitMethod = builderClass.getMethod("setLimit", Int::class.java)
                setLimitMethod.invoke(builder, limit)
            } catch (e: Exception) {
                logger("⚠️ Could not set limit: ${e.message}")
            }
            
            // setOrdering(Ordering)
            try {
                val setOrderingMethod = builderClass.getMethod("setOrdering", Ordering::class.java)
                setOrderingMethod.invoke(builder, Ordering.ASC)
            } catch (e: Exception) {
                logger("⚠️ Could not set ordering: ${e.message}")
            }
            
            // setLocalTimeFilter if timestamp provided
            if (sinceTimestamp != null) {
                try {
                    val startTime = LocalDateTime.ofInstant(
                        Instant.ofEpochMilli(sinceTimestamp),
                        ZoneId.systemDefault()
                    )
                    val filter = LocalTimeFilter.since(startTime)
                    val setFilterMethod = builderClass.getMethod("setLocalTimeFilter", LocalTimeFilter::class.java)
                    setFilterMethod.invoke(builder, filter)
                } catch (e: Exception) {
                    logger("⚠️ Could not set time filter: ${e.message}")
                }
            }
            
            // build()
            val buildMethod = builderClass.getMethod("build")
            buildMethod.invoke(builder) as? ReadDataRequest<HealthDataPoint>
        } catch (e: NoSuchMethodException) {
            logger("⚠️ DataType doesn't support reading (no builder method)")
            null
        } catch (e: Exception) {
            logger("⚠️ Error building request: ${e.message}")
            e.printStackTrace()
            null
        }
    }

    /**
     * Read all tracked types.
     */
    suspend fun readAllData(
        sinceTimestamps: Map<String, Long>,
        limit: Int = 1000
    ): Map<String, List<HealthDataRecord>> {
        val result = mutableMapOf<String, List<HealthDataRecord>>()

        for (typeId in trackedTypeIds) {
            if (mapToDataType(typeId) != null) {
                val sinceTimestamp = sinceTimestamps[typeId]
                val records = readData(typeId, sinceTimestamp, limit)
                if (records.isNotEmpty()) {
                    result[typeId] = records
                }
            }
        }

        if (result.isEmpty()) {
            logger("ℹ️ No new data found")
        } else {
            val totalRecords = result.values.sumOf { it.size }
            logger("📊 Total: $totalRecords records across ${result.size} types")
        }

        return result
    }

    /**
     * Parse Samsung Health data point to our record format.
     */
    private fun parseDataPoint(typeId: String, dataPoint: HealthDataPoint): HealthDataRecord? {
        return try {
            val uuid = dataPoint.uid ?: UUID.randomUUID().toString()
            val startTime = dataPoint.startTime.toEpochMilli()
            val endTime = dataPoint.endTime?.toEpochMilli() ?: startTime
            val source = dataPoint.dataSource

            // Extract value based on type
            val (value, unit) = extractValueAndUnit(typeId, dataPoint)

            HealthDataRecord(
                uuid = uuid,
                type = getSamsungTypeId(typeId),
                value = value,
                unit = unit,
                startDate = startTime,
                endDate = endTime,
                source = parseDataSource(source),
                metadata = emptyList()
            )
        } catch (e: Exception) {
            logger("⚠️ Failed to parse $typeId record: ${e.message}")
            null
        }
    }

    /**
     * Extract value and unit from a data point based on type.
     * Uses reflection to access the appropriate Field constants.
     */
    private fun extractValueAndUnit(typeId: String, dataPoint: HealthDataPoint): Pair<Double, String> {
        return try {
            when (typeId) {
                "heartRate" -> {
                    // DataTypes.HEART_RATE has HEART_RATE field
                    val value = getFieldValue<Float>(DataTypes.HEART_RATE, "HEART_RATE", dataPoint)
                    Pair(value?.toDouble() ?: 0.0, "bpm")
                }
                "oxygenSaturation" -> {
                    val value = getFieldValue<Float>(DataTypes.BLOOD_OXYGEN, "OXYGEN_SATURATION", dataPoint)
                    Pair(value?.toDouble() ?: 0.0, "%")
                }
                "bloodGlucose" -> {
                    val value = getFieldValue<Float>(DataTypes.BLOOD_GLUCOSE, "LEVEL", dataPoint)
                    Pair(value?.toDouble() ?: 0.0, "mg/dL")
                }
                "bodyTemperature" -> {
                    val value = getFieldValue<Float>(DataTypes.BODY_TEMPERATURE, "TEMPERATURE", dataPoint)
                    Pair(value?.toDouble() ?: 0.0, "degC")
                }
                "sleep" -> {
                    // Sleep is a session - calculate duration
                    val durationMs = (dataPoint.endTime?.toEpochMilli() ?: 0) - dataPoint.startTime.toEpochMilli()
                    Pair(durationMs / 60000.0, "min")
                }
                "workout" -> {
                    // Exercise is a session - calculate duration
                    val durationMs = (dataPoint.endTime?.toEpochMilli() ?: 0) - dataPoint.startTime.toEpochMilli()
                    Pair(durationMs / 60000.0, "min")
                }
                "bloodPressure", "bloodPressureSystolic" -> {
                    val value = getFieldValue<Float>(DataTypes.BLOOD_PRESSURE, "SYSTOLIC", dataPoint)
                    Pair(value?.toDouble() ?: 0.0, "mmHg")
                }
                "bloodPressureDiastolic" -> {
                    val value = getFieldValue<Float>(DataTypes.BLOOD_PRESSURE, "DIASTOLIC", dataPoint)
                    Pair(value?.toDouble() ?: 0.0, "mmHg")
                }
                "steps" -> {
                    // Steps aggregation
                    val value = getFieldValue<Long>(DataTypes.STEPS, "TOTAL", dataPoint)
                    Pair(value?.toDouble() ?: 0.0, "count")
                }
                "flightsClimbed" -> {
                    val value = getFieldValue<Int>(DataTypes.FLOORS_CLIMBED, "FLOORS", dataPoint)
                    Pair(value?.toDouble() ?: 0.0, "count")
                }
                "bodyMass" -> {
                    val value = getFieldValue<Float>(DataTypes.BODY_COMPOSITION, "WEIGHT", dataPoint)
                    Pair(value?.toDouble() ?: 0.0, "kg")
                }
                "water" -> {
                    val value = getFieldValue<Float>(DataTypes.WATER_INTAKE, "VOLUME", dataPoint)
                    Pair(value?.toDouble() ?: 0.0, "mL")
                }
                else -> Pair(0.0, "count")
            }
        } catch (e: Exception) {
            logger("⚠️ Error extracting value for $typeId: ${e.message}")
            Pair(0.0, "count")
        }
    }

    /**
     * Get field value from a data point using reflection.
     */
    @Suppress("UNCHECKED_CAST")
    private fun <T> getFieldValue(dataType: DataType, fieldName: String, dataPoint: HealthDataPoint): T? {
        return try {
            // Get the Field constant from the DataType class
            val field = dataType.javaClass.getField(fieldName).get(dataType)
            // Call dataPoint.getValue(field)
            val getValueMethod = dataPoint.javaClass.getMethod("getValue", com.samsung.android.sdk.health.data.data.Field::class.java)
            getValueMethod.invoke(dataPoint, field) as? T
        } catch (e: Exception) {
            null
        }
    }

    private fun parseDataSource(source: DataSource?): HealthDataSource {
        return HealthDataSource(
            name = "Samsung Health",
            bundleIdentifier = source?.appId ?: SAMSUNG_HEALTH_PACKAGE,
            deviceId = source?.deviceId
        )
    }

    private fun getSamsungTypeId(typeId: String): String {
        return when (typeId) {
            "steps" -> "com.samsung.health.step_count"
            "heartRate" -> "com.samsung.health.heart_rate"
            "sleep" -> "com.samsung.health.sleep"
            "workout" -> "com.samsung.health.exercise"
            "oxygenSaturation" -> "com.samsung.health.oxygen_saturation"
            "bloodGlucose" -> "com.samsung.health.blood_glucose"
            "bloodPressure", "bloodPressureSystolic", "bloodPressureDiastolic" -> "com.samsung.health.blood_pressure"
            "bodyTemperature" -> "com.samsung.health.body_temperature"
            "flightsClimbed" -> "com.samsung.health.floors_climbed"
            "bodyMass", "bodyFatPercentage" -> "com.samsung.health.body_composition"
            "water" -> "com.samsung.health.water_intake"
            else -> typeId
        }
    }
}

/**
 * Represents a parsed health data record ready for sync.
 */
data class HealthDataRecord(
    val uuid: String,
    val type: String,
    val value: Double,
    val unit: String,
    val startDate: Long,
    val endDate: Long,
    val source: HealthDataSource,
    val metadata: List<HealthDataMetadata>
)

data class HealthDataSource(
    val name: String,
    val bundleIdentifier: String,
    val deviceId: String? = null
)

data class HealthDataMetadata(
    val key: String,
    val value: String
)
