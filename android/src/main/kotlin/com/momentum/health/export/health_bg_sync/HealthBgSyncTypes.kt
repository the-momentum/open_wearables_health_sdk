package com.momentum.health.export.health_bg_sync

/**
 * Maps Dart health data type identifiers to Samsung Health SDK types.
 * Mirrors the iOS HealthBgSyncTypes implementation.
 */
object HealthBgSyncTypes {

    /**
     * Data class representing a mapped health type with its unit.
     */
    data class HealthTypeMapping(
        val samsungType: String,
        val unit: String,
        val valueField: String = "value"
    )

    /**
     * Maps Dart type identifier to Samsung Health type info.
     * Returns null if the type is not supported.
     */
    fun mapType(dartType: String): HealthTypeMapping? {
        return when (dartType) {
            // Activity / movement
            "steps" -> HealthTypeMapping(
                samsungType = "com.samsung.health.step_count",
                unit = "count",
                valueField = "count"
            )
            "distanceWalkingRunning" -> HealthTypeMapping(
                samsungType = "com.samsung.health.step_count",
                unit = "m",
                valueField = "distance"
            )
            "distanceCycling" -> HealthTypeMapping(
                samsungType = "com.samsung.health.exercise",
                unit = "m",
                valueField = "distance"
            )
            "flightsClimbed" -> HealthTypeMapping(
                samsungType = "com.samsung.health.floors_climbed",
                unit = "count",
                valueField = "count"
            )

            // Energy
            "activeEnergy" -> HealthTypeMapping(
                samsungType = "com.samsung.health.exercise",
                unit = "Cal",
                valueField = "calorie"
            )
            "basalEnergy" -> HealthTypeMapping(
                samsungType = "com.samsung.health.step_count",
                unit = "Cal",
                valueField = "calorie"
            )

            // Heart
            "heartRate" -> HealthTypeMapping(
                samsungType = "com.samsung.health.heart_rate",
                unit = "bpm",
                valueField = "heart_rate"
            )
            "restingHeartRate" -> HealthTypeMapping(
                samsungType = "com.samsung.health.heart_rate",
                unit = "bpm",
                valueField = "heart_rate"
            )
            "heartRateVariabilitySDNN" -> HealthTypeMapping(
                samsungType = "com.samsung.health.heart_rate",
                unit = "ms",
                valueField = "heart_rate_variability"
            )
            "vo2Max" -> HealthTypeMapping(
                samsungType = "com.samsung.health.vo2_max",
                unit = "mL/kg/min",
                valueField = "vo2_max"
            )
            "oxygenSaturation" -> HealthTypeMapping(
                samsungType = "com.samsung.health.oxygen_saturation",
                unit = "%",
                valueField = "spo2"
            )

            // Respiratory
            "respiratoryRate" -> HealthTypeMapping(
                samsungType = "com.samsung.health.respiratory_rate",
                unit = "breaths/min",
                valueField = "respiratory_rate"
            )

            // Body
            "bodyMass" -> HealthTypeMapping(
                samsungType = "com.samsung.health.weight",
                unit = "kg",
                valueField = "weight"
            )
            "height" -> HealthTypeMapping(
                samsungType = "com.samsung.health.height",
                unit = "m",
                valueField = "height"
            )
            "bmi" -> HealthTypeMapping(
                samsungType = "com.samsung.health.weight",
                unit = "kg/m²",
                valueField = "bmi"
            )
            "bodyFatPercentage" -> HealthTypeMapping(
                samsungType = "com.samsung.health.body_composition",
                unit = "%",
                valueField = "body_fat"
            )
            "leanBodyMass" -> HealthTypeMapping(
                samsungType = "com.samsung.health.body_composition",
                unit = "kg",
                valueField = "skeletal_muscle"
            )
            "bodyTemperature" -> HealthTypeMapping(
                samsungType = "com.samsung.health.body_temperature",
                unit = "degC",
                valueField = "temperature"
            )

            // Glucose
            "bloodGlucose" -> HealthTypeMapping(
                samsungType = "com.samsung.health.blood_glucose",
                unit = "mg/dL",
                valueField = "glucose"
            )

            // Blood pressure
            "bloodPressureSystolic" -> HealthTypeMapping(
                samsungType = "com.samsung.health.blood_pressure",
                unit = "mmHg",
                valueField = "systolic"
            )
            "bloodPressureDiastolic" -> HealthTypeMapping(
                samsungType = "com.samsung.health.blood_pressure",
                unit = "mmHg",
                valueField = "diastolic"
            )
            "bloodPressure" -> HealthTypeMapping(
                samsungType = "com.samsung.health.blood_pressure",
                unit = "mmHg",
                valueField = "systolic"
            )

            // Nutrition
            "dietaryEnergyConsumed" -> HealthTypeMapping(
                samsungType = "com.samsung.health.food_intake",
                unit = "Cal",
                valueField = "calorie"
            )
            "dietaryCarbohydrates" -> HealthTypeMapping(
                samsungType = "com.samsung.health.food_intake",
                unit = "g",
                valueField = "carbohydrate"
            )
            "dietaryProtein" -> HealthTypeMapping(
                samsungType = "com.samsung.health.food_intake",
                unit = "g",
                valueField = "protein"
            )
            "dietaryFatTotal" -> HealthTypeMapping(
                samsungType = "com.samsung.health.food_intake",
                unit = "g",
                valueField = "total_fat"
            )
            "dietaryWater" -> HealthTypeMapping(
                samsungType = "com.samsung.health.water_intake",
                unit = "mL",
                valueField = "amount"
            )

            // Sleep
            "sleep" -> HealthTypeMapping(
                samsungType = "com.samsung.health.sleep",
                unit = "min",
                valueField = "sleep_duration"
            )

            // Mindfulness (Samsung doesn't have direct equivalent)
            "mindfulSession" -> null

            // Reproductive (Samsung has limited support)
            "menstrualFlow" -> HealthTypeMapping(
                samsungType = "com.samsung.health.menstrual_cycle",
                unit = "count",
                valueField = "menstrual_flow"
            )
            "cervicalMucusQuality" -> null
            "ovulationTestResult" -> null
            "sexualActivity" -> null

            // Workout
            "workout" -> HealthTypeMapping(
                samsungType = "com.samsung.health.exercise",
                unit = "min",
                valueField = "duration"
            )

            else -> null
        }
    }

    /**
     * Get unique Samsung Health data types from list of Dart types.
     */
    fun getUniqueSamsungTypes(dartTypes: List<String>): Set<String> {
        return dartTypes.mapNotNull { mapType(it)?.samsungType }.toSet()
    }

    /**
     * Maps workout type to string identifier.
     */
    fun mapWorkoutType(samsungExerciseType: Int): String {
        return when (samsungExerciseType) {
            // Running & Walking
            1001 -> "running"
            1002 -> "walking"
            1003 -> "hiking"
            
            // Cycling
            2001 -> "cycling"
            2002 -> "hand_cycling"
            
            // Swimming
            3001 -> "swimming"
            3002 -> "water_sports"
            
            // Gym & Fitness
            4001 -> "strength_training"
            4002 -> "flexibility"
            4003 -> "hiit"
            4004 -> "elliptical"
            4005 -> "stair_climbing"
            4006 -> "jump_rope"
            4007 -> "pilates"
            
            // Mind & Body
            5001 -> "yoga"
            5002 -> "tai_chi"
            
            // Dance
            6001 -> "dance"
            
            // Racket Sports
            7001 -> "tennis"
            7002 -> "badminton"
            7003 -> "squash"
            7004 -> "table_tennis"
            
            // Team Sports
            8001 -> "soccer"
            8002 -> "basketball"
            8003 -> "volleyball"
            8004 -> "baseball"
            8005 -> "rugby"
            8006 -> "hockey"
            
            // Combat Sports
            9001 -> "boxing"
            9002 -> "martial_arts"
            
            // Winter Sports
            10001 -> "skiing"
            10002 -> "snowboarding"
            10003 -> "skating"
            
            // Outdoor
            11001 -> "golf"
            11002 -> "archery"
            11003 -> "climbing"
            
            else -> "other"
        }
    }
}
