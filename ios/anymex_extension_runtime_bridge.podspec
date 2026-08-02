#
#  AnymeX Extension Runtime Bridge — iOS Podspec
#
Pod::Spec.new do |s|
  s.name             = 'anymex_extension_runtime_bridge'
  s.version          = '1.6.1'
  s.summary          = 'Flutter plugin that embeds OpenJDK Zero VM to run Java/Kotlin extensions on iOS'
  s.description      = <<-DESC
    Embeds OpenJDK Zero VM (libjvm.a) into iOS to run JAR extensions via JNI.
    NOT FOR APP STORE distribution.
  DESC
  s.homepage         = 'https://github.com/Shebyyy/AnymeXExtensionRuntimeBridge'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Shebyyy' => '' }
  s.source           = { :path => '.' }

  s.source_files = 'Classes/**/*'
  s.public_header_files = 'Classes/**/*.h'

  s.swift_version = '5.9'

  s.platforms = { :ios => '13.0' }

  s.dependency 'Flutter'

  # Static libraries — OpenJDK Zero VM for iOS ARM64
  libs_dir = File.join(File.dirname(__FILE__), 'libs')
  s.vendored_libraries = Dir[File.join(libs_dir, '*.a')]

  s.frameworks = [
    'Security',
    'CoreFoundation',
    'Foundation',
    'UIKit',
    'SystemConfiguration',
    'CoreGraphics',
  ]

  # Resource bundle for JVM runtime JARs
  s.resource_bundles = {
    'anymex_jvm_resources' => ['libs/*.jar', 'libs/*.properties']
  }

  # All xcconfig settings merged into one hash
  # NOTE: Bridging headers are unsupported for framework targets.
  # We use a C module map (Classes/include/JNI/module.modulemap) instead.
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386',
    'ENABLE_BITCODE' => 'NO',
    'CLANG_ALLOW_NON_MODULAR_INCLUDES_IN_FRAMEWORK_MODULES' => 'YES',
    'GCC_PREPROCESSOR_DEFINITIONS' => '$(inherited) JNI_STATIC_BUILD=1',
    'GCC_C_LANGUAGE_STANDARD' => 'gnu17',
    'GCC_WARN_ABOUT_RETURN_TYPE' => 'YES',
    'GCC_WARN_UNINITIALIZED_AUTOS' => 'YES_AGGRESSIVE',
    'OTHER_LDFLAGS' => '$(inherited) -ObjC -lstdc++ -lc++',
    'HEADER_SEARCH_PATHS' => '$(inherited) ${PODS_TARGET_SRCROOT}/Classes ${PODS_TARGET_SRCROOT}/Classes/include/JNI',
    'LIBRARY_SEARCH_PATHS' => '$(inherited) ${PODS_TARGET_SRCROOT}/libs',
    'SWIFT_INCLUDE_PATHS' => '$(inherited) ${PODS_TARGET_SRCROOT}/Classes/include/JNI',
  }
end
