#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint anymex_extension_runtime_bridge.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'anymex_extension_runtime_bridge'
  s.version          = '0.0.1'
  s.summary          = 'AnymeX Extension Runtime Bridge for iOS, Android, macOS, Windows, Linux.'
  s.description      = <<-DESC
Flutter plugin that bridges Dart to a Java/JVM runtime for executing Aniyomi, CloudStream, Kotatsu, and Mangayomi extensions.
On iOS, embeds PojavLauncher OpenJDK 8 and launches a JVM via JLI_Launch + JNI.
On Android, loads the runtime host APK via the Android embedding.
On Desktop platforms, spawns a JVM subprocess and communicates via stdin/stdout JSON.
                       DESC
  s.homepage         = 'https://github.com/RyanYuuki/AnymeXExtensionRuntimeBridge'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'RyanYuuki' => 'https://github.com/RyanYuuki' }
  s.source           = { :path => '.' }

  s.source_files = 'Classes/**/*'
  s.public_header_files = 'Classes/**/*.h'
  s.dependency 'Flutter'

  s.ios.deployment_target = '13.0'
  s.osx.deployment_target = '10.15'

  # iOS: Exclude simulator i386 slice (32-bit not supported)
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386',
    'OTHER_LDFLAGS' => '-ljava',
  }

  # Ensure Swift files are compiled
  s.swift_version = '5.0'

  # Link required system frameworks for dlopen/JNI on iOS
  s.frameworks = 'Foundation', 'UIKit'

  # iOS-specific resource bundle (optional)
  # s.resource_bundles = {'anymex_extension_runtime_bridge_privacy' => ['Resources/PrivacyInfo.xcprivacy']}
end
