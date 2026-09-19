/// Supported health types (must match iOS `mapTypes` string identifiers).
enum HealthDataType {
  // Activity / movement
  steps,
  distanceWalkingRunning,
  distanceCycling,
  flightsClimbed,
  walkingSpeed,
  walkingStepLength,
  walkingAsymmetryPercentage,
  walkingDoubleSupportPercentage,
  sixMinuteWalkTestDistance,

  // Energy
  activeEnergy,
  basalEnergy,
  restingEnergy, // alias of basalEnergy on iOS
  totalCaloriesBurned, // Android Health Connect only; iOS ignores it

  // Heart
  heartRate,
  restingHeartRate,
  heartRateVariabilitySDNN,
  vo2Max,
  oxygenSaturation,
  bloodOxygen, // alias of oxygenSaturation on iOS
  // Respiratory
  respiratoryRate,

  // Body
  bodyMass,
  height,
  bmi,
  bodyFatPercentage,
  leanBodyMass,
  waistCircumference, // iOS 16+
  bodyTemperature,

  // Glucose / insulin
  bloodGlucose,
  insulinDelivery, // iOS 16+
  // Blood pressure
  bloodPressureSystolic,
  bloodPressureDiastolic,
  bloodPressure, // correlation
  // Nutrition
  dietaryEnergyConsumed,
  dietaryCarbohydrates,
  dietaryProtein,
  dietaryFatTotal,
  dietaryWater,

  // Sleep / mindfulness
  sleep,
  mindfulSession,

  // Reproductive
  menstrualFlow,
  cervicalMucusQuality,
  ovulationTestResult,
  sexualActivity,

  // Running dynamics (iOS 16+)
  runningPower,
  runningVerticalOscillation,
  runningGroundContactTime,

  // Cycling (iOS 17+)
  cyclingPower,
  cyclingCadence,
  cyclingSpeed,
  cyclingFunctionalThresholdPower,

  // Workouts
  workout,
  workoutEffortScore, // iOS 18+
  estimatedWorkoutEffortScore, // iOS 18+
}

extension HealthDataTypeId on HealthDataType {
  /// String identifier passed to the iOS plugin. Must match Swift switch-cases.
  String get id {
    switch (this) {
      case HealthDataType.steps:
        return 'steps';
      case HealthDataType.distanceWalkingRunning:
        return 'distanceWalkingRunning';
      case HealthDataType.distanceCycling:
        return 'distanceCycling';
      case HealthDataType.flightsClimbed:
        return 'flightsClimbed';
      case HealthDataType.walkingSpeed:
        return 'walkingSpeed';
      case HealthDataType.walkingStepLength:
        return 'walkingStepLength';
      case HealthDataType.walkingAsymmetryPercentage:
        return 'walkingAsymmetryPercentage';
      case HealthDataType.walkingDoubleSupportPercentage:
        return 'walkingDoubleSupportPercentage';
      case HealthDataType.sixMinuteWalkTestDistance:
        return 'sixMinuteWalkTestDistance';

      // Energy
      case HealthDataType.activeEnergy:
        return 'activeEnergy';
      case HealthDataType.basalEnergy:
        return 'basalEnergy';
      case HealthDataType.restingEnergy:
        return 'restingEnergy';
      case HealthDataType.totalCaloriesBurned:
        return 'totalCaloriesBurned';

      // Heart
      case HealthDataType.heartRate:
        return 'heartRate';
      case HealthDataType.restingHeartRate:
        return 'restingHeartRate';
      case HealthDataType.heartRateVariabilitySDNN:
        return 'heartRateVariabilitySDNN';
      case HealthDataType.vo2Max:
        return 'vo2Max';
      case HealthDataType.oxygenSaturation:
        return 'oxygenSaturation';
      case HealthDataType.bloodOxygen:
        return 'bloodOxygen';

      // Respiratory
      case HealthDataType.respiratoryRate:
        return 'respiratoryRate';

      // Body
      case HealthDataType.bodyMass:
        return 'bodyMass';
      case HealthDataType.height:
        return 'height';
      case HealthDataType.bmi:
        return 'bmi';
      case HealthDataType.bodyFatPercentage:
        return 'bodyFatPercentage';
      case HealthDataType.leanBodyMass:
        return 'leanBodyMass';
      case HealthDataType.waistCircumference:
        return 'waistCircumference';
      case HealthDataType.bodyTemperature:
        return 'bodyTemperature';

      // Glucose / insulin
      case HealthDataType.bloodGlucose:
        return 'bloodGlucose';
      case HealthDataType.insulinDelivery:
        return 'insulinDelivery';

      // Blood pressure
      case HealthDataType.bloodPressureSystolic:
        return 'bloodPressureSystolic';
      case HealthDataType.bloodPressureDiastolic:
        return 'bloodPressureDiastolic';
      case HealthDataType.bloodPressure:
        return 'bloodPressure';

      // Nutrition
      case HealthDataType.dietaryEnergyConsumed:
        return 'dietaryEnergyConsumed';
      case HealthDataType.dietaryCarbohydrates:
        return 'dietaryCarbohydrates';
      case HealthDataType.dietaryProtein:
        return 'dietaryProtein';
      case HealthDataType.dietaryFatTotal:
        return 'dietaryFatTotal';
      case HealthDataType.dietaryWater:
        return 'dietaryWater';

      // Sleep / mindfulness
      case HealthDataType.sleep:
        return 'sleep';
      case HealthDataType.mindfulSession:
        return 'mindfulSession';

      // Reproductive
      case HealthDataType.menstrualFlow:
        return 'menstrualFlow';
      case HealthDataType.cervicalMucusQuality:
        return 'cervicalMucusQuality';
      case HealthDataType.ovulationTestResult:
        return 'ovulationTestResult';
      case HealthDataType.sexualActivity:
        return 'sexualActivity';

      // Running dynamics (iOS 16+)
      case HealthDataType.runningPower:
        return 'runningPower';
      case HealthDataType.runningVerticalOscillation:
        return 'runningVerticalOscillation';
      case HealthDataType.runningGroundContactTime:
        return 'runningGroundContactTime';

      // Cycling (iOS 17+)
      case HealthDataType.cyclingPower:
        return 'cyclingPower';
      case HealthDataType.cyclingCadence:
        return 'cyclingCadence';
      case HealthDataType.cyclingSpeed:
        return 'cyclingSpeed';
      case HealthDataType.cyclingFunctionalThresholdPower:
        return 'cyclingFunctionalThresholdPower';

      // Workouts
      case HealthDataType.workout:
        return 'workout';
      case HealthDataType.workoutEffortScore:
        return 'workoutEffortScore';
      case HealthDataType.estimatedWorkoutEffortScore:
        return 'estimatedWorkoutEffortScore';
    }
  }
}
