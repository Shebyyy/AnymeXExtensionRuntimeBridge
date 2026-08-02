#
#  AnymeX Extension Runtime Bridge — iOS Podspec
#
#  This Flutter plugin embeds the OpenJDK Zero VM as a static library (libjvm.a)
#  to run JAR files containing Java/Kotlin extensions directly on iOS devices
#  via in-process JNI invocation. The plugin is NOT designed for App Store
#  distribution — it uses aggressive approaches only suitable for sideloaded
#  or enterprise distribution.
#
#  Architecture:
#    Dart (FFI) → @_cdecl Swift → JNI C API → libjvm.a → Extension JARs
#
#  Build Requirements:
#    - Xcode 15+
#    - iOS SDK 13.0+
#    - libjvm.a + transitive static libs in ios/libs/
#    - jrt-fs.jar and other runtime resources in ios/libs/
#    - libffi (linked from static lib in ios/libs/)
#

Pod::Spec.new do |s|
  s.name             = 'anymex_extension_runtime_bridge'
  s.version          = '1.6.1'
  s.summary          = 'Flutter plugin that embeds OpenJDK Zero VM to run Java/Kotlin extensions on iOS'
  s.description      = <<-DESC
    The AnymeX Extension Runtime Bridge for iOS embeds the OpenJDK Zero VM (libjvm.a)
    directly into the iOS application process. It creates a JVM in-process via
    JNI_CreateJavaVM() and exposes Dart FFI functions for initializing the JVM,
    calling Java methods by name with JSON arguments, managing cookies and user-agents,
    and controlling the JVM lifecycle. This enables running JAR files containing
    Java/Kotlin extension code (Aniyomi, CloudStream, Kotatsu, etc.) on iOS devices
    without requiring a separate process or server-side execution.

    NOT FOR APP STORE: This plugin embeds a JVM which violates Apple's guidelines
    for App Store distribution. It is intended for sideloaded / enterprise use only.
  DESC
  s.homepage         = 'https://github.com/AnymeX/AnymeXExtensionRuntimeBridge'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'AnymeX' => 'dev@anymex.app' }
  s.source           = { :path => '.' }

  # ---------------------------------------------------------------------------
  # Source files
  # ---------------------------------------------------------------------------
  # Include all .m, .swift, .h files in the Classes directory
  s.source_files = 'Classes/**/*'

  # Public headers exposed to the host application
  s.public_header_files = 'Classes/**/*.h'

  # ---------------------------------------------------------------------------
  # Swift configuration
  # ---------------------------------------------------------------------------
  # Set the bridging header so Swift can import C types from jni.h
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386',
    'SWIFT_OBJC_BRIDGING_HEADER' => '${PODS_TARGET_SRCROOT}/Classes/SwiftAnymexExtensionRuntimeBridgePlugin-Bridging-Header.h',
    'OTHER_LDFLAGS' => '-ObjC',
    # Enable bitcode if needed (OpenJDK Zero may require it off)
    'ENABLE_BITCODE' => 'NO',
    # Treat pointer type warnings as errors for safety
    'OTHER_SWIFT_FLAGS' => '-warnings-as-errors',
    # Allow non-modular includes for the jni.h header
    'CLANG_ALLOW_NON_MODULAR_INCLUDES_IN_FRAMEWORK_MODULES' => 'YES',
    'GCC_PREPROCESSOR_DEFINITIONS' => '$(inherited) JNI_STATIC_BUILD=1',
  }

  # Swift version
  s.swift_version = '5.9'

  # ---------------------------------------------------------------------------
  # Platform requirements
  # ---------------------------------------------------------------------------
  # iOS 13.0+ is required for:
  #   - Sufficient stack space for JVM thread creation
  #   - Stable NSURLSession for HTTP client (used by extension code)
  #   - JSONSerialization improvements
  s.platforms = {
    :ios => '13.0'
  }

  # ---------------------------------------------------------------------------
  # Dependencies
  # ---------------------------------------------------------------------------
  s.dependency 'Flutter'

  # ---------------------------------------------------------------------------
  # Static library linking — OpenJDK Zero VM for iOS ARM64
  # ---------------------------------------------------------------------------
  # The following static libraries must be present in the ios/libs/ directory:
  #   libjvm.a    — The core Java Virtual Machine (OpenJDK Zero interpreter)
  #   libjava.a   — Java core library support (System, String, ClassLoader, etc.)
  #   libnet.a    — Java networking support (java.net.*)
  #   libnio.a    — Java NIO support (java.nio.*)
  #   libzip.a   — java.util.zip support (JAR reading)
  #   libverify.a — Bytecode verifier
  #   libffi.a   — Foreign Function Interface (required for JNI dispatch)
  #
  # These can be cross-compiled from OpenJDK source using the iOS SDK
  # toolchain. See the project README for build instructions.

  libs_dir = File.join(File.dirname(__FILE__), 'libs')

  # Link all required static libraries
  s.vendored_libraries = [
    "#{libs_dir}/libjvm.a",
    "#{libs_dir}/libjava.a",
    "#{libs_dir}/libnet.a",
    "#{libs_dir}/libnio.a",
    "#{libs_dir}/libzip.a",
    "#{libs_dir}/libverify.a",
    "#{libs_dir}/libffi.a",
  ]

  # ---------------------------------------------------------------------------
  # Framework dependencies
  # ---------------------------------------------------------------------------
  # These iOS system frameworks are required by the JVM and/or extension code:
  #   - Security:      TLS/SSL for HTTPS (used by java.net.HttpURLConnection)
  #   - CoreFoundation: Low-level data types and services
  #   - Foundation:    Object-C runtime and base services
  #   - UIKit:         For the plugin registrar (UIDevice, etc.)
  #   - SystemConfiguration: Network reachability checks
  #   - CoreGraphics:  Text rendering (for JVM debug output)
  #   - libstdc++:     C++ standard library (JVM internals use C++)
  s.frameworks = [
    'Security',
    'CoreFoundation',
    'Foundation',
    'UIKit',
    'SystemConfiguration',
    'CoreGraphics',
  ]

  # ---------------------------------------------------------------------------
  # Resource bundles — JVM runtime resources
  # ---------------------------------------------------------------------------
  # The iOS SDK classes and other JAR resources needed by the JVM at runtime.
  # These are bundled into the app and placed on the classpath during JVM init.

  # jrt-fs.jar — The Java Runtime file system provider (required by OpenJDK 9+)
  # android-stubs.jar — Android framework stub classes (for extension compatibility)
  # runtime-bridge.jar — The DesktopExtensionLoader / IosExtensionLoader runtime

  # Resource bundle for JVM runtime JARs
  s.resource_bundles = {
    'anymex_jvm_resources' => ['libs/*.jar', 'libs/*.properties']
  }

  # ---------------------------------------------------------------------------
  # Compiler and Linker Settings
  # ---------------------------------------------------------------------------

  # C flags for compiling the JNI header and Objective-C code
  s.pod_target_xcconfig['GCC_C_LANGUAGE_STANDARD'] = 'gnu17'
  s.pod_target_xcconfig['GCC_WARN_ABOUT_RETURN_TYPE'] = 'YES'
  s.pod_target_xcconfig['GCC_WARN_UNINITIALIZED_AUTOS'] = 'YES_AGGRESSIVE'

  # Additional linker flags for the static libraries
  # -lstdc++ is needed because libjvm.a contains C++ object code
  s.pod_target_xcconfig['OTHER_LDFLAGS'] = '$(inherited) -lstdc++ -lc++'

  # Header search paths — include/ directory for jni.h
  s.pod_target_xcconfig['HEADER_SEARCH_PATHS'] = '$(inherited) ${PODS_TARGET_SRCROOT}/include ${PODS_TARGET_SRCROOT}/Classes'

  # Library search paths
  s.pod_target_xcconfig['LIBRARY_SEARCH_PATHS'] = '$(inherited) ${PODS_TARGET_SRCROOT}/libs'

  # ---------------------------------------------------------------------------
  # Privacy manifest
  # ---------------------------------------------------------------------------
  # The JVM may make network requests for extension code (HTTP clients).
  # This privacy manifest declares the required reason APIs.
  # s.resource_bundles['anymex_extension_runtime_bridge_privacy'] = ['Resources/PrivacyInfo.xcprivacy']
end
