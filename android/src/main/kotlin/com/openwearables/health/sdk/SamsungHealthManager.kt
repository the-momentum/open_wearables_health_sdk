package com.openwearables.health.sdk

import android.app.Activity
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import com.samsung.android.sdk.health.data.HealthDataService
import com.samsung.android.sdk.health.data.HealthDataStore
import com.samsung.android.sdk.health.data.DeviceManager
import com.samsung.android.sdk.health.data.data.HealthDataPoint
import com.samsung.android.sdk.health.data.data.DataSource
import com.samsung.android.sdk.health.data.device.Device
import com.samsung.android.sdk.health.data.device.DeviceGroup
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
    private var deviceManager: DeviceManager? = null
    private var trackedTypeIds: Set<String> = emptySet()
    
    // Cache of devices by deviceId for quick lookup
    private var deviceCache: MutableMap<String, Device> = mutableMapOf()

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
     * Connect to Samsung Health by getting the HealthDataStore and DeviceManager.
     */
    suspend fun connect(): Boolean = withContext(Dispatchers.Main) {
        if (!isAvailable()) {
            logger("❌ Samsung Health not available on this device")
            return@withContext false
        }

        try {
            val store = HealthDataService.getStore(context)
            healthDataStore = store
            deviceManager = store.getDeviceManager()
            logger("✅ Connected to Samsung Health")
            
            // Load and cache all connected devices
            loadConnectedDevices()
            
            true
        } catch (e: Exception) {
            logger("❌ Failed to connect to Samsung Health: ${e.message}")
            e.printStackTrace()
            false
        }
    }
    
    /**
     * Load all connected devices from Samsung Health and cache them.
     */
    private suspend fun loadConnectedDevices() {
        val dm = deviceManager ?: return
        
        try {
            // Load devices from all device groups
            val deviceGroups = listOf(
                DeviceGroup.MOBILE,
                DeviceGroup.WATCH,
                DeviceGroup.RING,
                DeviceGroup.BAND,
                DeviceGroup.ACCESSORY
            )
            
            for (group in deviceGroups) {
                try {
                    val devices = dm.getDevices(group)
                    for (device in devices) {
                        device.id?.let { id ->
                            deviceCache[id] = device
                            logger("📱 Cached device: ${device.name ?: device.model} (${group.name})")
                        }
                    }
                } catch (e: Exception) {
                    // Some device groups might not be supported
                    logger("⚠️ Could not load ${group.name} devices: ${e.message}")
                }
            }
            
            logger("📱 Loaded ${deviceCache.size} devices from Samsung Health")
        } catch (e: Exception) {
            logger("⚠️ Error loading devices: ${e.message}")
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
            // Add 1ms to anchor to exclude already synced data (since() is inclusive >=)
            if (sinceTimestamp != null) {
                try {
                    val startTime = LocalDateTime.ofInstant(
                        Instant.ofEpochMilli(sinceTimestamp + 1),
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
     * Parse Samsung Health data point into universal record structure.
     * Uses type-specific field extraction (no reflection).
     */
    private fun parseDataPoint(typeId: String, dataPoint: HealthDataPoint): HealthDataRecord? {
        return try {
            val uid = dataPoint.uid ?: UUID.randomUUID().toString()
            val startTime = dataPoint.startTime.toEpochMilli()
            val endTime = dataPoint.endTime?.toEpochMilli()
            val source = dataPoint.dataSource
            
            // Extract fields based on data type
            val fields = extractFieldsForType(typeId, dataPoint)
            val dataTypeName = getDataTypeName(typeId)
            
            // Get device info
            val deviceInfo = getDeviceInfo(source)

            HealthDataRecord(
                uid = uid,
                dataType = dataTypeName,
                startTime = startTime,
                endTime = endTime,
                dataSource = RawDataSource(
                    appId = source?.appId,
                    deviceId = source?.deviceId
                ),
                device = deviceInfo,
                fields = fields
            )
        } catch (e: Exception) {
            logger("⚠️ Failed to parse $typeId record: ${e.message}")
            e.printStackTrace()
            null
        }
    }
    
    /**
     * Get device information from Samsung Health SDK DeviceManager.
     * Falls back to current phone info if source device not found.
     */
    private fun getDeviceInfo(source: DataSource?): DeviceInfo {
        val deviceId = source?.deviceId
        
        // Try to find the actual source device from cache
        val cachedDevice = deviceId?.let { deviceCache[it] }
        
        if (cachedDevice != null) {
            // Found the actual device that recorded this data (e.g., Galaxy Watch, Ring)
            val deviceGroup = getDeviceGroup(cachedDevice)
            
            return DeviceInfo(
                deviceId = deviceId,
                manufacturer = cachedDevice.manufacturer ?: "Unknown",
                model = cachedDevice.model ?: "Unknown",
                name = cachedDevice.name ?: cachedDevice.model ?: "Unknown",
                brand = cachedDevice.manufacturer ?: "Unknown",
                product = cachedDevice.model ?: "Unknown",
                osType = "Android",
                osVersion = "", // Not available from Device object
                sdkVersion = 0, // Not available from Device object
                deviceType = deviceGroup,
                isSourceDevice = true  // This is the actual device that recorded the data
            )
        }
        
        // Fallback: Use current phone info (device not found in cache)
        // This happens when data came from the phone itself
        return DeviceInfo(
            deviceId = deviceId,
            manufacturer = Build.MANUFACTURER,
            model = Build.MODEL,
            name = Build.DEVICE,
            brand = Build.BRAND,
            product = Build.PRODUCT,
            osType = "Android",
            osVersion = Build.VERSION.RELEASE,
            sdkVersion = Build.VERSION.SDK_INT,
            deviceType = "MOBILE",
            isSourceDevice = false  // Fallback to current phone info
        )
    }
    
    /**
     * Get device group/type from a Device object.
     */
    private fun getDeviceGroup(device: Device): String {
        return try {
            // Try to get the device group via reflection
            val groupMethod = device.javaClass.methods.find { it.name == "getGroup" || it.name == "getDeviceGroup" }
            val group = groupMethod?.invoke(device)
            
            when {
                group is DeviceGroup -> group.name
                group?.toString()?.contains("WATCH", ignoreCase = true) == true -> "WATCH"
                group?.toString()?.contains("RING", ignoreCase = true) == true -> "RING"
                group?.toString()?.contains("BAND", ignoreCase = true) == true -> "BAND"
                group?.toString()?.contains("ACCESSORY", ignoreCase = true) == true -> "ACCESSORY"
                else -> "MOBILE"
            }
        } catch (e: Exception) {
            "UNKNOWN"
        }
    }
    
    /**
     * Get SDK DataType name for a flutter type ID.
     */
    private fun getDataTypeName(typeId: String): String {
        return when (typeId) {
            "steps" -> "STEPS"
            "heartRate" -> "HEART_RATE"
            "sleep" -> "SLEEP"
            "workout" -> "EXERCISE"
            "oxygenSaturation" -> "BLOOD_OXYGEN"
            "bloodGlucose" -> "BLOOD_GLUCOSE"
            "bloodPressure", "bloodPressureSystolic", "bloodPressureDiastolic" -> "BLOOD_PRESSURE"
            "bodyTemperature" -> "BODY_TEMPERATURE"
            "flightsClimbed" -> "FLOORS_CLIMBED"
            "bodyMass", "bodyFatPercentage", "leanBodyMass" -> "BODY_COMPOSITION"
            "activeEnergy" -> "ACTIVITY_SUMMARY"
            "water" -> "WATER_INTAKE"
            else -> typeId.uppercase()
        }
    }
    
    /**
     * Extract fields based on data type.
     * Each type has its own specific field extraction logic.
     */
    private fun extractFieldsForType(typeId: String, dataPoint: HealthDataPoint): Map<String, Any?> {
        return when (typeId) {
            "heartRate" -> extractHeartRateFields(dataPoint)
            "steps" -> extractStepsFields(dataPoint)
            "oxygenSaturation" -> extractBloodOxygenFields(dataPoint)
            "bloodGlucose" -> extractBloodGlucoseFields(dataPoint)
            "bloodPressure", "bloodPressureSystolic", "bloodPressureDiastolic" -> extractBloodPressureFields(dataPoint)
            "bodyTemperature" -> extractBodyTemperatureFields(dataPoint)
            "flightsClimbed" -> extractFloorsClimbedFields(dataPoint)
            "bodyMass", "bodyFatPercentage", "leanBodyMass" -> extractBodyCompositionFields(dataPoint)
            "water" -> extractWaterIntakeFields(dataPoint)
            "workout" -> extractExerciseFields(dataPoint)
            "sleep" -> extractSleepFields(dataPoint)
            else -> emptyMap()
        }
    }
    
    // ==================== RECORDS TYPE EXTRACTORS ====================
    
    private fun extractHeartRateFields(dataPoint: HealthDataPoint): Map<String, Any?> {
        val fields = mutableMapOf<String, Any?>()
        getFieldValue<Float>(DataTypes.HEART_RATE, "HEART_RATE", dataPoint)?.let { fields["HEART_RATE"] = it }
        getFieldValue<Any>(DataTypes.HEART_RATE, "HEART_RATE_STATUS", dataPoint)?.let { 
            fields["HEART_RATE_STATUS"] = if (it is Enum<*>) it.name else it.toString()
        }
        return fields
    }
    
    private fun extractStepsFields(dataPoint: HealthDataPoint): Map<String, Any?> {
        val fields = mutableMapOf<String, Any?>()
        getFieldValue<Long>(DataTypes.STEPS, "TOTAL", dataPoint)?.let { fields["TOTAL"] = it }
        return fields
    }
    
    private fun extractBloodOxygenFields(dataPoint: HealthDataPoint): Map<String, Any?> {
        val fields = mutableMapOf<String, Any?>()
        getFieldValue<Float>(DataTypes.BLOOD_OXYGEN, "OXYGEN_SATURATION", dataPoint)?.let { fields["OXYGEN_SATURATION"] = it }
        return fields
    }
    
    private fun extractBloodGlucoseFields(dataPoint: HealthDataPoint): Map<String, Any?> {
        val fields = mutableMapOf<String, Any?>()
        getFieldValue<Float>(DataTypes.BLOOD_GLUCOSE, "LEVEL", dataPoint)?.let { fields["LEVEL"] = it }
        getFieldValue<Any>(DataTypes.BLOOD_GLUCOSE, "MEAL_STATUS", dataPoint)?.let {
            fields["MEAL_STATUS"] = if (it is Enum<*>) it.name else it.toString()
        }
        getFieldValue<Any>(DataTypes.BLOOD_GLUCOSE, "MEASUREMENT_TYPE", dataPoint)?.let {
            fields["MEASUREMENT_TYPE"] = if (it is Enum<*>) it.name else it.toString()
        }
        getFieldValue<Any>(DataTypes.BLOOD_GLUCOSE, "SAMPLE_SOURCE_TYPE", dataPoint)?.let {
            fields["SAMPLE_SOURCE_TYPE"] = if (it is Enum<*>) it.name else it.toString()
        }
        return fields
    }
    
    private fun extractBloodPressureFields(dataPoint: HealthDataPoint): Map<String, Any?> {
        val fields = mutableMapOf<String, Any?>()
        getFieldValue<Float>(DataTypes.BLOOD_PRESSURE, "SYSTOLIC", dataPoint)?.let { fields["SYSTOLIC"] = it }
        getFieldValue<Float>(DataTypes.BLOOD_PRESSURE, "DIASTOLIC", dataPoint)?.let { fields["DIASTOLIC"] = it }
        getFieldValue<Float>(DataTypes.BLOOD_PRESSURE, "PULSE", dataPoint)?.let { fields["PULSE"] = it }
        return fields
    }
    
    private fun extractBodyTemperatureFields(dataPoint: HealthDataPoint): Map<String, Any?> {
        val fields = mutableMapOf<String, Any?>()
        getFieldValue<Float>(DataTypes.BODY_TEMPERATURE, "TEMPERATURE", dataPoint)?.let { fields["TEMPERATURE"] = it }
        return fields
    }
    
    private fun extractFloorsClimbedFields(dataPoint: HealthDataPoint): Map<String, Any?> {
        val fields = mutableMapOf<String, Any?>()
        getFieldValue<Int>(DataTypes.FLOORS_CLIMBED, "FLOORS", dataPoint)?.let { fields["FLOORS"] = it }
        return fields
    }
    
    private fun extractBodyCompositionFields(dataPoint: HealthDataPoint): Map<String, Any?> {
        val fields = mutableMapOf<String, Any?>()
        getFieldValue<Float>(DataTypes.BODY_COMPOSITION, "WEIGHT", dataPoint)?.let { fields["WEIGHT"] = it }
        getFieldValue<Float>(DataTypes.BODY_COMPOSITION, "HEIGHT", dataPoint)?.let { fields["HEIGHT"] = it }
        getFieldValue<Float>(DataTypes.BODY_COMPOSITION, "BODY_FAT", dataPoint)?.let { fields["BODY_FAT"] = it }
        getFieldValue<Float>(DataTypes.BODY_COMPOSITION, "BODY_FAT_MASS", dataPoint)?.let { fields["BODY_FAT_MASS"] = it }
        getFieldValue<Float>(DataTypes.BODY_COMPOSITION, "FAT_FREE_MASS", dataPoint)?.let { fields["FAT_FREE_MASS"] = it }
        getFieldValue<Float>(DataTypes.BODY_COMPOSITION, "SKELETAL_MUSCLE_MASS", dataPoint)?.let { fields["SKELETAL_MUSCLE_MASS"] = it }
        getFieldValue<Float>(DataTypes.BODY_COMPOSITION, "BMI", dataPoint)?.let { fields["BMI"] = it }
        getFieldValue<Float>(DataTypes.BODY_COMPOSITION, "BASAL_METABOLIC_RATE", dataPoint)?.let { fields["BASAL_METABOLIC_RATE"] = it }
        return fields
    }
    
    private fun extractWaterIntakeFields(dataPoint: HealthDataPoint): Map<String, Any?> {
        val fields = mutableMapOf<String, Any?>()
        getFieldValue<Float>(DataTypes.WATER_INTAKE, "VOLUME", dataPoint)?.let { fields["VOLUME"] = it }
        return fields
    }
    
    // ==================== WORKOUT (EXERCISE) EXTRACTOR ====================
    
    private fun extractExerciseFields(dataPoint: HealthDataPoint): Map<String, Any?> {
        val fields = mutableMapOf<String, Any?>()
        
        // Exercise type
        getFieldValue<Any>(DataTypes.EXERCISE, "EXERCISE_TYPE", dataPoint)?.let {
            fields["EXERCISE_TYPE"] = if (it is Enum<*>) it.name else it.toString()
        }
        
        // Aggregated totals
        getFieldValue<Float>(DataTypes.EXERCISE, "TOTAL_CALORIES", dataPoint)?.let { fields["TOTAL_CALORIES"] = it }
        getFieldValue<Long>(DataTypes.EXERCISE, "TOTAL_DURATION", dataPoint)?.let { fields["TOTAL_DURATION"] = it }
        getFieldValue<String>(DataTypes.EXERCISE, "CUSTOM_TITLE", dataPoint)?.let { fields["CUSTOM_TITLE"] = it }
        
        // Sessions - extract detailed data
        getFieldValue<List<*>>(DataTypes.EXERCISE, "SESSIONS", dataPoint)?.let { sessions ->
            fields["SESSIONS"] = sessions.mapNotNull { session ->
                extractExerciseSession(session)
            }
        }
        
        return fields
    }
    
    /**
     * Extract ExerciseSession data safely without reflection loops.
     */
    private fun extractExerciseSession(session: Any?): Map<String, Any?>? {
        if (session == null) return null
        
        val data = mutableMapOf<String, Any?>()
        
        try {
            // Try to get known ExerciseSession properties via getter methods
            session.javaClass.methods.forEach { method ->
                if (method.parameterCount == 0 && method.name.startsWith("get") && method.name != "getClass") {
                    try {
                        val value = method.invoke(session)
                        if (value != null) {
                            val key = method.name.removePrefix("get").let { 
                                it.first().lowercase() + it.drop(1) 
                            }
                            
                            // Only include simple types
                            when (value) {
                                is Number -> data[key] = value
                                is String -> if (value.isNotEmpty()) data[key] = value
                                is Boolean -> data[key] = value
                                is Enum<*> -> data[key] = value.name
                                is java.time.Instant -> data[key] = value.toEpochMilli()
                                is java.time.Duration -> data[key] = value.toMillis()
                                // Skip complex types to avoid recursion issues
                            }
                        }
                    } catch (e: Exception) {
                        // Skip failed getters
                    }
                }
            }
        } catch (e: Exception) {
            logger("⚠️ Error extracting session: ${e.message}")
        }
        
        return if (data.isNotEmpty()) data else null
    }
    
    // ==================== SLEEP EXTRACTOR ====================
    
    private fun extractSleepFields(dataPoint: HealthDataPoint): Map<String, Any?> {
        val fields = mutableMapOf<String, Any?>()
        
        // Sleep stage
        getFieldValue<Any>(DataTypes.SLEEP, "STAGE", dataPoint)?.let {
            fields["STAGE"] = if (it is Enum<*>) it.name else it.toString()
        }
        
        // Sleep efficiency
        getFieldValue<Float>(DataTypes.SLEEP, "EFFICIENCY", dataPoint)?.let { fields["EFFICIENCY"] = it }
        
        // Sleep score
        getFieldValue<Int>(DataTypes.SLEEP, "SLEEP_SCORE", dataPoint)?.let { fields["SLEEP_SCORE"] = it }
        
        // Sessions - extract sleep stages
        getFieldValue<List<*>>(DataTypes.SLEEP, "SESSIONS", dataPoint)?.let { sessions ->
            fields["SESSIONS"] = sessions.mapNotNull { session ->
                extractSleepSession(session)
            }
        }
        
        return fields
    }
    
    /**
     * Extract SleepSession data safely.
     */
    private fun extractSleepSession(session: Any?): Map<String, Any?>? {
        if (session == null) return null
        
        val data = mutableMapOf<String, Any?>()
        
        try {
            session.javaClass.methods.forEach { method ->
                if (method.parameterCount == 0 && method.name.startsWith("get") && method.name != "getClass") {
                    try {
                        val value = method.invoke(session)
                        if (value != null) {
                            val key = method.name.removePrefix("get").let { 
                                it.first().lowercase() + it.drop(1) 
                            }
                            
                            when (value) {
                                is Number -> data[key] = value
                                is String -> if (value.isNotEmpty()) data[key] = value
                                is Boolean -> data[key] = value
                                is Enum<*> -> data[key] = value.name
                                is java.time.Instant -> data[key] = value.toEpochMilli()
                                is java.time.Duration -> data[key] = value.toMillis()
                                is List<*> -> {
                                    // Handle sleep stages list
                                    val stages = value.mapNotNull { stage -> extractSleepStage(stage) }
                                    if (stages.isNotEmpty()) data[key] = stages
                                }
                            }
                        }
                    } catch (e: Exception) {
                        // Skip
                    }
                }
            }
        } catch (e: Exception) {
            logger("⚠️ Error extracting sleep session: ${e.message}")
        }
        
        return if (data.isNotEmpty()) data else null
    }
    
    /**
     * Extract SleepStage data.
     */
    private fun extractSleepStage(stage: Any?): Map<String, Any?>? {
        if (stage == null) return null
        
        val data = mutableMapOf<String, Any?>()
        
        try {
            stage.javaClass.methods.forEach { method ->
                if (method.parameterCount == 0 && method.name.startsWith("get") && method.name != "getClass") {
                    try {
                        val value = method.invoke(stage)
                        if (value != null) {
                            val key = method.name.removePrefix("get").let { 
                                it.first().lowercase() + it.drop(1) 
                            }
                            
                            when (value) {
                                is Number -> data[key] = value
                                is Enum<*> -> data[key] = value.name
                                is java.time.Instant -> data[key] = value.toEpochMilli()
                                is java.time.Duration -> data[key] = value.toMillis()
                            }
                        }
                    } catch (e: Exception) {
                        // Skip
                    }
                }
            }
        } catch (e: Exception) {
            // Skip
        }
        
        return if (data.isNotEmpty()) data else null
    }
    
    // ==================== FIELD VALUE HELPER ====================
    
    /**
     * Get field value from a data point using reflection.
     */
    @Suppress("UNCHECKED_CAST")
    private fun <T> getFieldValue(dataType: DataType, fieldName: String, dataPoint: HealthDataPoint): T? {
        return try {
            val field = dataType.javaClass.getField(fieldName).get(dataType)
            val getValueMethod = dataPoint.javaClass.getMethod("getValue", com.samsung.android.sdk.health.data.data.Field::class.java)
            getValueMethod.invoke(dataPoint, field) as? T
        } catch (e: Exception) {
            null
        }
    }
    
}

/**
 * Universal health data record structure.
 * Works for all Samsung Health SDK data types.
 */
data class HealthDataRecord(
    // HealthDataPoint base properties
    val uid: String,
    val dataType: String,           // SDK DataType name (e.g., "HEART_RATE", "EXERCISE", "SLEEP")
    val startTime: Long,            // epoch milliseconds
    val endTime: Long?,             // epoch milliseconds
    val dataSource: RawDataSource,
    val device: DeviceInfo,
    
    // Universal fields map - contains all type-specific fields
    val fields: Map<String, Any?>
)

/**
 * DataSource from Samsung Health SDK
 */
data class RawDataSource(
    val appId: String?,
    val deviceId: String?
)

/**
 * Device information for the record.
 * Contains info about the device that actually recorded the health data.
 */
data class DeviceInfo(
    // Device identification
    val deviceId: String?,
    
    // Device hardware info (from Samsung Health SDK Device object)
    val manufacturer: String,
    val model: String,
    val name: String,
    val brand: String,
    val product: String,
    
    // OS info (only available for current phone, not for wearables)
    val osType: String,
    val osVersion: String,
    val sdkVersion: Int,
    
    // Device type: MOBILE, WATCH, RING, BAND, ACCESSORY
    val deviceType: String?,
    
    // True if this device info comes from Samsung Health SDK (actual source device)
    // False if it's a fallback to current phone info
    val isSourceDevice: Boolean = false
)
