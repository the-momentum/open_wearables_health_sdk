Pod::Spec.new do |s|
  s.name             = 'health_bg_sync'
  s.version          = '0.0.1'
  s.summary          = 'A new Flutter plugin project.'
  s.description      = <<-DESC
A new Flutter plugin project.
  DESC
  s.homepage         = 'http://example.com'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Your Company' => 'email@example.com' }
  s.source           = { :path => '.' }

  # KLUCZOWE: tylko pliki źródłowe
  s.source_files = 'Classes/**/*.{h,m,swift}'
  s.public_header_files = 'Classes/**/*.h'

  s.dependency 'Flutter'
  s.platform = :ios, '14.0'
  s.swift_version = '5.0'

  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386',
    'SWIFT_COMPILATION_MODE' => 'wholemodule'
  }

  # (opcjonalnie) jawnie zadeklaruj frameworki
  s.frameworks = 'HealthKit', 'BackgroundTasks', 'UIKit'
end
