Pod::Spec.new do |s|
  s.name             = 'open_wearables_health_sdk'
  s.version          = '0.0.1'
  s.summary          = 'Flutter SDK for background health data synchronization to Open Wearables platform.'
  s.description      = <<-DESC
Flutter SDK for secure background health data synchronization from Apple HealthKit to the Open Wearables platform.
  DESC
  s.homepage         = 'https://openwearables.io'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Open Wearables' => 'hello@openwearables.io' }
  s.source           = { :path => '.' }

  # KLUCZOWE: tylko pliki źródłowe
  s.source_files = 'Classes/**/*.{h,m,swift}'

  s.dependency 'Flutter'
  s.platform = :ios, '14.0'
  s.swift_version = '5.0'

  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386'
  }

  # (opcjonalnie) jawnie zadeklaruj frameworki
  s.frameworks = 'HealthKit', 'BackgroundTasks', 'UIKit'
end
