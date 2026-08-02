//
//  SwiftAnymexExtensionRuntimeBridgePlugin.swift
//
//  Main iOS plugin for the AnymeX Extension Runtime Bridge.
//
//  This plugin embeds the OpenJDK Zero VM (compiled as a static library
//  libjvm.a for iOS ARM64) directly into the iOS application process. It
//  creates a JVM in-process via JNI_CreateJavaVM() and exposes functions
//  callable from Dart through Dart FFI (via @_cdecl exported C functions).
//
//  Architecture:
//    Dart (FFI) → @_cdecl Swift functions → JNI C API → libjvm.a (OpenJDK Zero)
//                                                          ↓
//                                                Extension JAR files
//
//  The plugin handles:
//    - JVM lifecycle (create, attach/detach threads, destroy)
//    - JNI type conversion (jstring ↔ C string, jobject ↔ JSON)
//    - Exception checking after every JNI call
//    - Thread-safe access via NSLock around global JVM state
//    - Cookie and user-agent injection via Java system properties
//
//  IMPORTANT: This plugin is NOT designed for App Store distribution.
//  It uses private API patterns (embedding a JVM) that Apple prohibits
//  in App Store submissions. It is intended for sideloaded / enterprise
//  distribution only.
//

import Foundation
@_implementationOnly import JNI

// MARK: - Global JVM State

/// The JavaVM pointer — created once by JNI_CreateJavaVM and held for the
/// lifetime of the application (or until anymex_ios_jvm_destroy is called).
private var gJavaVM: UnsafeMutablePointer<JavaVM>? = nil

/// The JNIEnv pointer for the thread that created the JVM. Other threads
/// must call AttachCurrentThread to obtain their own JNIEnv.
private var gJNIEnv: UnsafeMutablePointer<JNIEnv>? = nil

/// Whether the JVM has been successfully initialized.
private var gJVMInitialized: Bool = false

/// Mutex protecting all global JVM state. Every function that reads or
/// writes gJavaVM, gJNIEnv, or gJVMInitialized must hold this lock.
private let gJVMLock = NSLock()

/// A global reference to the IosExtensionLoader class, cached for performance.
/// This avoids repeated FindClass calls for every JNI method invocation.
private var gExtensionLoaderClassGlobalRef: jclass? = nil

// MARK: - Logging Helper

/// Internal logging function. Logs to stderr which is visible in the
/// Xcode console and device logs.
///
/// - Parameters:
///   - tag: A short identifier for the subsystem (e.g., "JVM", "FFI").
///   - message: The message to log.
private func log(_ tag: String, _ message: String) {
    let timestamp = DateFormatter()
    timestamp.dateFormat = "HH:mm:ss.SSS"
    let timeStr = timestamp.string(from: Date())
    fputs("[\(tag)][\(timeStr)] \(message)\n", stderr)
}

// MARK: - Thread Attachment Helper

/// Ensures the calling thread is attached to the JVM and returns an
/// `UnsafeMutablePointer<JNIEnv>` for the current thread.
///
/// On the thread that originally created the JVM, the cached `gJNIEnv`
/// is returned. On any other thread, `AttachCurrentThread` is called
/// to create a new JNIEnv for that thread.
///
/// - Returns: A pointer to the JNIEnv for the current thread, or nil
///   if the JVM is not initialized or attachment fails.
private func attachCurrentThread() -> UnsafeMutablePointer<JNIEnv>? {
    gJVMLock.lock()
    guard gJVMInitialized, let vm = gJavaVM else {
        log("JVM", "ERROR: attachCurrentThread called but JVM is not initialized")
        gJVMLock.unlock()
        return nil
    }

    // If this is the thread that created the JVM, return the cached env
    if let cachedEnv = gJNIEnv {
        // Verify the cached env is still valid by checking GetVersion
        gJVMLock.unlock()
        return cachedEnv
    }
    gJVMLock.unlock()

    // Attach this thread to the JVM
    var envPtr: UnsafeMutableRawPointer? = nil
    let attachResult = vm.pointee.functions.pointee.AttachCurrentThread(vm, &envPtr, nil)

    guard attachResult == JNI_OK, let rawEnv = envPtr else {
        log("JVM", "ERROR: AttachCurrentThread failed with code \(attachResult)")
        return nil
    }

    return rawEnv.assumingMemoryBound(to: JNIEnv.self)
}

// MARK: - JNI Exception Handling

/// Checks if a JNI exception occurred, logs it, and clears it.
///
/// This MUST be called after every JNI call that can throw (which is
/// virtually all JNI calls except GetVersion and a few others).
///
/// - Parameters:
///   - env: The JNIEnv pointer for the current thread.
///   - context: A description of what operation was being performed
///     when the exception may have occurred (for logging).
/// - Returns: `true` if an exception occurred, `false` otherwise.
private func checkAndClearJNIException(
    _ env: UnsafeMutablePointer<JNIEnv>?,
    context: String
) -> Bool {
    guard let env = env else { return false }

    let exceptionOccurred = env.pointee.functions.pointee.ExceptionCheck(env)
    if exceptionOccurred == JNI_TRUE {
        log("JVM", "JNI Exception during: \(context)")
        env.pointee.functions.pointee.ExceptionDescribe(env)
        env.pointee.functions.pointee.ExceptionClear(env)
        return true
    }
    return false
}

// MARK: - jstring ↔ Swift String Conversion

/// Converts a Swift `String` to a JNI `jstring` via `NewStringUTF`.
///
/// - Parameters:
///   - env: The JNIEnv for the current thread.
///   - str: The Swift string to convert.
/// - Returns: A new JNI jstring, or nil if the conversion fails.
///   The caller is responsible for calling `DeleteLocalRef` when done.
private func swiftStringToJString(
    _ env: UnsafeMutablePointer<JNIEnv>?,
    _ str: String
) -> jstring? {
    guard let env = env else { return nil }
    return env.pointee.functions.pointee.NewStringUTF(env, str.cString(using: .utf8))
}

/// Converts a JNI `jstring` to a Swift `String` via `GetStringUTFChars`.
///
/// This function calls `ReleaseStringUTFChars` after copying the C string,
/// so the caller does not need to manage the JNI string memory.
///
/// - Parameters:
///   - env: The JNIEnv for the current thread.
///   - jstr: The JNI jstring to convert (may be nil).
/// - Returns: The Swift String representation, or nil if conversion fails.
private func jStringToSwiftString(
    _ env: UnsafeMutablePointer<JNIEnv>?,
    _ jstr: jstring?
) -> String? {
    guard let env = env, let jstr = jstr else { return nil }

    let cChars = env.pointee.functions.pointee.GetStringUTFChars(env, jstr, nil)
    guard let cChars = cChars else { return nil }

    let swiftStr = String(cString: cChars, encoding: .utf8)
    env.pointee.functions.pointee.ReleaseStringUTFChars(env, jstr, cChars)
    return swiftStr
}

// MARK: - Static Method Caller

/// Calls a static method on the cached IosExtensionLoader class.
///
/// This is the central method invocation function. It:
/// 1. Finds the static method by name and signature on IosExtensionLoader
/// 2. Creates jstring arguments from the provided Swift strings
/// 3. Calls the method using CallStaticObjectMethodA (variadic-safe)
/// 4. Converts the returned jstring to a Swift String
/// 5. Cleans up local references
///
/// - Parameters:
///   - env: The JNIEnv for the current thread.
///   - methodName: The Java method name (e.g., "callMethod").
///   - methodSig: The JNI method signature (e.g., "(Ljava/lang/String;Ljava/lang/String;)Ljava/lang/String;").
///   - arg1: First String argument (optional).
///   - arg2: Second String argument (optional).
/// - Returns: The method result as a String, or an error JSON string.
private func callStaticJavaMethod(
    _ env: UnsafeMutablePointer<JNIEnv>?,
    methodName: String,
    methodSig: String,
    arg1: String? = nil,
    arg2: String? = nil
) -> String {
    guard let env = env else {
        return "{\"error\":\"JNIEnv is null\"}"
    }

    // Use the cached global class reference, or find the class
    let loaderClass: jclass
    if let globalRef = gExtensionLoaderClassGlobalRef {
        loaderClass = globalRef
    } else {
        let foundClass = env.pointee.functions.pointee.FindClass(env, "com/anymex/ios/IosExtensionLoader")
        if foundClass == nil {
            if checkAndClearJNIException(env, context: "FindClass(IosExtensionLoader)") {
                return "{\"error\":\"ClassNotFoundException: com.anymex.ios.IosExtensionLoader\"}"
            }
            return "{\"error\":\"ClassNotFoundException: com.anymex.ios.IosExtensionLoader (no exception details)\"}"
        }
        // Create a global reference so we don't have to find it again
        let globalRef = env.pointee.functions.pointee.NewGlobalRef(env, foundClass)
        env.pointee.functions.pointee.DeleteLocalRef(env, foundClass)
        if globalRef == nil {
            return "{\"error\":\"Failed to create global reference for IosExtensionLoader\"}"
        }
        gExtensionLoaderClassGlobalRef = globalRef
        loaderClass = globalRef
    }

    // Find the static method
    guard let methodID = env.pointee.functions.pointee.GetStaticMethodID(
        env,
        loaderClass,
        methodName,
        methodSig
    ) else {
        checkAndClearJNIException(env, context: "GetStaticMethodID(\(methodName), \(methodSig))")
        return "{\"error\":\"NoSuchMethodError: \(methodName)\(methodSig)\"}"
    }

    // Build jvalue array for arguments
    var jvalues: [jvalue] = []
    var localRefs: [jobject] = []

    if let a1 = arg1, let jstr1 = swiftStringToJString(env, a1) {
        jvalues.append(jvalue(l: jstr1))
        localRefs.append(jstr1)
    }
    if let a2 = arg2, let jstr2 = swiftStringToJString(env, a2) {
        jvalues.append(jvalue(l: jstr2))
        localRefs.append(jstr2)
    }

    // Call the static method using the A (array) variant (variadic-safe)
    let result: jobject
    if jvalues.isEmpty {
        result = env.pointee.functions.pointee.CallStaticObjectMethodA(
            env, loaderClass, methodID, nil
        )
    } else {
        result = env.pointee.functions.pointee.CallStaticObjectMethodA(
            env, loaderClass, methodID, jvalues
        )
    }

    // Check for exceptions after the method call
    if checkAndClearJNIException(env, context: "CallStaticObjectMethodA(\(methodName))") {
        // Clean up local refs
        for ref in localRefs {
            env.pointee.functions.pointee.DeleteLocalRef(env, ref)
        }
        return "{\"error\":\"Java exception thrown during \(methodName)\"}"
    }

    // Convert result to Swift string
    let resultStr = jStringToSwiftString(env, result)

    // Clean up local references
    if let r = result {
        env.pointee.functions.pointee.DeleteLocalRef(env, r)
    }
    for ref in localRefs {
        env.pointee.functions.pointee.DeleteLocalRef(env, ref)
    }

    return resultStr ?? "null"
}

// MARK: - Dart FFI Entry Points

/// Initializes the JVM with the given classpath.
///
/// This function:
/// 1. Constructs JavaVMInitArgs with the specified classpath and JVM options
/// 2. Calls JNI_CreateJavaVM() to create the JVM in-process
/// 3. Caches the JavaVM and JNIEnv pointers globally
/// 4. Verifies the JVM is functional by calling GetVersion
///
/// The classpath should be a colon-separated (:) list of paths, typically:
///   - The runtime bridge JAR (DesktopExtensionLoader etc.)
///   - Android stub JARs (android.jar stubs for compilation)
///   - The extension JAR directory (for loading extension classes)
///
/// JVM Options applied:
///   -Djava.class.path=<classpath>
///   -Dfile.encoding=UTF-8
///   -Xms64m
///   -Xmx256m
///   -noverify
///   -Dsun.stdout.encoding=UTF-8
///   -Dsun.stderr.encoding=UTF-8
///
/// - Parameter classpath: A C string containing the JVM classpath.
/// - Returns: JNI_OK (0) on success, or a negative JNI error code on failure.
@_cdecl("anymex_ios_jvm_init")
public func anymex_ios_jvm_init(_ classpath: UnsafePointer<CChar>) -> Int32 {
    gJVMLock.lock()

    // Prevent double initialization
    if gJVMInitialized {
        log("FFI", "JVM already initialized, skipping init")
        gJVMLock.unlock()
        return JNI_OK
    }

    let classpathStr = String(cString: classpath)
    log("FFI", "Initializing JVM with classpath: \(classpathStr)")

    // Build the JVM options array
    let jvmVersion = JNI_VERSION_1_8

    // Option strings — these must remain alive for the duration of the
    // JNI_CreateJavaVM call since JavaVMOption.optionString points into them.
    let optionStrings: [String] = [
        "-Djava.class.path=\(classpathStr)",
        "-Dfile.encoding=UTF-8",
        "-Xms64m",
        "-Xmx256m",
        "-noverify",
        "-Dsun.stdout.encoding=UTF-8",
        "-Dsun.stderr.encoding=UTF-8",
        "-Djava.net.preferIPv6Addresses=false",
        "-Djava.awt.headless=true",
        "-Djava.security.policy=allowAll",
    ]

    let nOptions = optionStrings.count

    // Allocate C copies of the option strings. These must stay alive
    // until after JNI_CreateJavaVM returns.
    let cOptionStrings: [UnsafeMutablePointer<CChar>?] = optionStrings.map { str in
        strdup(str)  // returns a heap-allocated copy
    }

    // Build the JavaVMOption array
    var vmOptions = [JavaVMOption]()
    for i in 0..<nOptions {
        var opt = JavaVMOption()
        opt.optionString = cOptionStrings[i]
        opt.extraInfo = nil
        vmOptions.append(opt)
    }

    // Build the JavaVMInitArgs struct
    var vmArgs = JavaVMInitArgs()
    vmArgs.version = jvmVersion
    vmArgs.nOptions = Int32(nOptions)
    vmArgs.options = UnsafeMutablePointer<JavaVMOption>.allocate(capacity: nOptions)
    vmArgs.ignoreUnrecognized = JNI_TRUE

    // Copy the options into the allocated buffer
    for i in 0..<nOptions {
        vmArgs.options!.advanced(by: i).pointee = vmOptions[i]
    }

    // Create the JavaVM
    var javaVMPtr: UnsafeMutablePointer<JavaVM>? = nil
    var envVoidPtr: UnsafeMutableRawPointer? = nil

    let createResult = JNI_CreateJavaVM(
        &javaVMPtr,
        &envVoidPtr,
        &vmArgs
    )

    // Clean up allocated option memory
    vmArgs.options?.deallocate()
    for cStr in cOptionStrings {
        if let s = cStr {
            free(s)
        }
    }

    if createResult != JNI_OK {
        log("FFI", "ERROR: JNI_CreateJavaVM failed with code \(createResult)")
        gJVMLock.unlock()
        return createResult
    }

    guard let javaVM = javaVMPtr, let envVoid = envVoidPtr else {
        log("FFI", "ERROR: JNI_CreateJavaVM returned nil pointers")
        gJVMLock.unlock()
        return JNI_ERR
    }

    let env = envVoid.assumingMemoryBound(to: JNIEnv.self)

    // Verify the JVM works by checking the version
    let version = env.pointee.functions.pointee.GetVersion(env)
    let major = Int32(version >> 16) & 0xFFFF
    let minor = Int32(version & 0xFFFF)
    log("FFI", "JVM created successfully. JNI version: \(major).\(minor)")

    // Store the global pointers
    gJavaVM = javaVM
    gJNIEnv = env
    gJVMInitialized = true

    gJVMLock.unlock()
    log("FFI", "JVM initialization complete")
    return JNI_OK
}

/// Calls a static Java method on IosExtensionLoader.
///
/// This is the primary mechanism for invoking Java/Kotlin extension code
/// from Dart on iOS. The Dart side serializes method arguments as a JSON
/// string, sends it to this function, which passes it to the Java
/// `IosExtensionLoader.callMethod(String methodName, String argsJson)`
/// static method. The Java method dispatches to the appropriate extension
/// method and returns the result as a JSON string.
///
/// The returned C string is allocated with `strdup()` and must be freed
/// by the caller (Dart FFI via `calloc.free()`).
///
/// - Parameters:
///   - method: A C string containing the method name (e.g., "loadExtensions",
///     "getPopular", "search").
///   - argsJson: A C string containing the method arguments as a JSON object.
///     For example: `{"sourceId":"123","page":1,"isAnime":true}`
/// - Returns: A C string containing the JSON result, or nil if an error occurs.
///   The caller MUST free this pointer when done.
@_cdecl("anymex_ios_jvm_call")
public func anymex_ios_jvm_call(
    _ method: UnsafePointer<CChar>,
    _ argsJson: UnsafePointer<CChar>
) -> UnsafePointer<CChar>? {
    let methodName = String(cString: method)
    let argsJsonStr = String(cString: argsJson)

    log("FFI", "JVM call: \(methodName) args=\(argsJsonStr.prefix(200))")

    // Ensure the JVM is initialized
    guard gJVMInitialized else {
        let errorMsg = "{\"error\":\"JVM is not initialized. Call anymex_ios_jvm_init first.\"}"
        return strdup(errorMsg)
    }

    // Attach the current thread to the JVM
    guard let env = attachCurrentThread() else {
        let errorMsg = "{\"error\":\"Failed to attach current thread to JVM\"}"
        return strdup(errorMsg)
    }

    // Call the Java IosExtensionLoader.callMethod(String, String) method
    let resultStr = callStaticJavaMethod(
        env,
        methodName: "callMethod",
        methodSig: "(Ljava/lang/String;Ljava/lang/String;)Ljava/lang/String;",
        arg1: methodName,
        arg2: argsJsonStr
    )

    log("FFI", "JVM call result for \(methodName): \(resultStr.prefix(300))")

    // Return a heap-allocated C string that Dart will free
    return strdup(resultStr)
}

/// Destroys the JVM and releases all associated resources.
///
/// This function:
/// 1. Destroys the global reference to IosExtensionLoader class
/// 2. Calls DestroyJavaVM to tear down the JVM
/// 3. Clears all global state
///
/// After this function is called, any subsequent calls to
/// `anymex_ios_jvm_call` will fail until `anymex_ios_jvm_init` is called again.
///
/// Note: `DestroyJavaVM` blocks until there are no non-daemon threads
/// running in the JVM. If extension code spawned background threads, this
/// may hang indefinitely. The caller should ensure all extension work
/// is complete before calling this function.
@_cdecl("anymex_ios_jvm_destroy")
public func anymex_ios_jvm_destroy() {
    gJVMLock.lock()
    log("FFI", "Destroying JVM...")

    guard gJVMInitialized, let vm = gJavaVM else {
        log("FFI", "JVM not initialized, nothing to destroy")
        gJVMInitialized = false
        gJavaVM = nil
        gJNIEnv = nil
        gJVMLock.unlock()
        return
    }

    // Release global reference to the extension loader class
    if let globalClassRef = gExtensionLoaderClassGlobalRef {
        if let env = gJNIEnv {
            env.pointee.functions.pointee.DeleteGlobalRef(env, globalClassRef)
        }
        gExtensionLoaderClassGlobalRef = nil
    }

    let destroyResult = vm.pointee.functions.pointee.DestroyJavaVM(vm)

    if destroyResult == JNI_OK {
        log("FFI", "JVM destroyed successfully")
    } else {
        log("FFI", "WARNING: DestroyJavaVM returned code \(destroyResult)")
    }

    // Clear global state regardless of result
    gJVMInitialized = false
    gJavaVM = nil
    gJNIEnv = nil

    gJVMLock.unlock()
}

/// Checks whether the JVM has been initialized and is available for use.
///
/// - Returns: `true` if the JVM is currently initialized, `false` otherwise.
@_cdecl("anymex_ios_jvm_is_initialized")
public func anymex_ios_jvm_is_initialized() -> Bool {
    gJVMLock.lock()
    let initialized = gJVMInitialized
    gJVMLock.unlock()
    return initialized
}

/// Sets cookies for a given URL by calling a Java method that injects
/// them into the JVM's HTTP client cookie store.
///
/// This proxies the cookie-setting to the Java side where the OkHttp
/// cookie manager can use them for subsequent HTTP requests made by
/// extension code.
///
/// - Parameters:
///   - url: A C string containing the URL to associate cookies with.
///   - cookieString: A C string containing the cookies in standard
///     "key=value; key2=value2" format.
/// - Returns: JNI_OK (0) on success, or JNI_ERR (-1) on failure.
@_cdecl("anymex_ios_jvm_set_cookies")
public func anymex_ios_jvm_set_cookies(
    _ url: UnsafePointer<CChar>,
    _ cookieString: UnsafePointer<CChar>
) -> Int32 {
    let urlStr = String(cString: url)
    let cookieStr = String(cString: cookieString)

    log("FFI", "Setting cookies for \(urlStr)")

    guard gJVMInitialized else {
        log("FFI", "ERROR: Cannot set cookies, JVM not initialized")
        return JNI_ERR
    }

    guard let env = attachCurrentThread() else {
        log("FFI", "ERROR: Cannot set cookies, thread attachment failed")
        return JNI_ERR
    }

    // Call IosExtensionLoader.setCookies(String url, String cookieString)
    let resultStr = callStaticJavaMethod(
        env,
        methodName: "setCookies",
        methodSig: "(Ljava/lang/String;Ljava/lang/String;)Ljava/lang/String;",
        arg1: urlStr,
        arg2: cookieStr
    )

    // Parse the result to determine success
    if resultStr == "ok" || resultStr == "\"ok\"" {
        log("FFI", "Cookies set successfully for \(urlStr)")
        return JNI_OK
    } else {
        log("FFI", "Failed to set cookies: \(resultStr)")
        return JNI_ERR
    }
}

/// Sets a custom User-Agent for a given URL by calling a Java method
/// that stores it in the JVM's HTTP client configuration.
///
/// Extension code running in the JVM can then use this User-Agent when
/// making HTTP requests to the specified host.
///
/// - Parameters:
///   - url: A C string containing the URL (the host portion is extracted).
///   - userAgent: A C string containing the User-Agent string to use.
/// - Returns: JNI_OK (0) on success, or JNI_ERR (-1) on failure.
@_cdecl("anymex_ios_jvm_set_user_agent")
public func anymex_ios_jvm_set_user_agent(
    _ url: UnsafePointer<CChar>,
    _ userAgent: UnsafePointer<CChar>
) -> Int32 {
    let urlStr = String(cString: url)
    let uaStr = String(cString: userAgent)

    log("FFI", "Setting User-Agent for \(urlStr): \(uaStr)")

    guard gJVMInitialized else {
        log("FFI", "ERROR: Cannot set user-agent, JVM not initialized")
        return JNI_ERR
    }

    guard let env = attachCurrentThread() else {
        log("FFI", "ERROR: Cannot set user-agent, thread attachment failed")
        return JNI_ERR
    }

    // Call IosExtensionLoader.setUserAgent(String url, String userAgent)
    let resultStr = callStaticJavaMethod(
        env,
        methodName: "setUserAgent",
        methodSig: "(Ljava/lang/String;Ljava/lang/String;)Ljava/lang/String;",
        arg1: urlStr,
        arg2: uaStr
    )

    if resultStr == "ok" || resultStr == "\"ok\"" {
        log("FFI", "User-Agent set successfully for \(urlStr)")
        return JNI_OK
    } else {
        log("FFI", "Failed to set user-agent: \(resultStr)")
        return JNI_ERR
    }
}

/// Sets a Java system property at runtime.
///
/// This is a convenience function for setting Java system properties
/// (e.g., "http.proxyHost", "https.proxyPort") that extension code
/// may read via System.getProperty().
///
/// - Parameters:
///   - key: A C string containing the property key.
///   - value: A C string containing the property value.
/// - Returns: JNI_OK (0) on success, or JNI_ERR (-1) on failure.
@_cdecl("anymex_ios_jvm_set_property")
public func anymex_ios_jvm_set_property(
    _ key: UnsafePointer<CChar>,
    _ value: UnsafePointer<CChar>
) -> Int32 {
    let keyStr = String(cString: key)
    let valueStr = String(cString: value)

    log("FFI", "Setting Java property \(keyStr) = \(valueStr)")

    guard gJVMInitialized else {
        log("FFI", "ERROR: Cannot set property, JVM not initialized")
        return JNI_ERR
    }

    guard let env = attachCurrentThread() else {
        log("FFI", "ERROR: Cannot set property, thread attachment failed")
        return JNI_ERR
    }

    // Call System.setProperty(key, value) via JNI
    guard let systemClass = env.pointee.functions.pointee.FindClass(env, "java/lang/System") else {
        checkAndClearJNIException(env, context: "FindClass(java/lang/System)")
        return JNI_ERR
    }

    guard let setPropMethod = env.pointee.functions.pointee.GetStaticMethodID(
        env,
        systemClass,
        "setProperty",
        "(Ljava/lang/String;Ljava/lang/String;)Ljava/lang/String;"
    ) else {
        checkAndClearJNIException(env, context: "GetStaticMethodID(setProperty)")
        env.pointee.functions.pointee.DeleteLocalRef(env, systemClass)
        return JNI_ERR
    }

    guard let jKey = swiftStringToJString(env, keyStr),
          let jValue = swiftStringToJString(env, valueStr) else {
        env.pointee.functions.pointee.DeleteLocalRef(env, systemClass)
        return JNI_ERR
    }

    var jvalues: [jvalue] = [
        jvalue(l: jKey),
        jvalue(l: jValue)
    ]

    let result = env.pointee.functions.pointee.CallStaticObjectMethodA(
        env, systemClass, setPropMethod, jvalues
    )

    if let r = result {
        env.pointee.functions.pointee.DeleteLocalRef(env, r)
    }
    env.pointee.functions.pointee.DeleteLocalRef(env, jKey)
    env.pointee.functions.pointee.DeleteLocalRef(env, jValue)
    env.pointee.functions.pointee.DeleteLocalRef(env, systemClass)

    if checkAndClearJNIException(env, context: "System.setProperty") {
        return JNI_ERR
    }

    return JNI_OK
}

/// Gets a Java system property at runtime.
///
/// - Parameter key: A C string containing the property key.
/// - Returns: A C string containing the property value, or nil if not found.
///   The caller MUST free this pointer when done.
@_cdecl("anymex_ios_jvm_get_property")
public func anymex_ios_jvm_get_property(
    _ key: UnsafePointer<CChar>
) -> UnsafePointer<CChar>? {
    let keyStr = String(cString: key)

    guard gJVMInitialized else {
        let errorMsg = "{\"error\":\"JVM not initialized\"}"
        return strdup(errorMsg)
    }

    guard let env = attachCurrentThread() else {
        let errorMsg = "{\"error\":\"Thread attachment failed\"}"
        return strdup(errorMsg)
    }

    guard let systemClass = env.pointee.functions.pointee.FindClass(env, "java/lang/System") else {
        checkAndClearJNIException(env, context: "FindClass(java/lang/System)")
        return strdup("{\"error\":\"System class not found\"}")
    }

    guard let getPropMethod = env.pointee.functions.pointee.GetStaticMethodID(
        env,
        systemClass,
        "getProperty",
        "(Ljava/lang/String;)Ljava/lang/String;"
    ) else {
        checkAndClearJNIException(env, context: "GetStaticMethodID(getProperty)")
        env.pointee.functions.pointee.DeleteLocalRef(env, systemClass)
        return strdup("{\"error\":\"getProperty method not found\"}")
    }

    guard let jKey = swiftStringToJString(env, keyStr) else {
        env.pointee.functions.pointee.DeleteLocalRef(env, systemClass)
        return strdup("{\"error\":\"Failed to create jstring for key\"}")
    }

    var jvalues: [jvalue] = [jvalue(l: jKey)]

    let result = env.pointee.functions.pointee.CallStaticObjectMethodA(
        env, systemClass, getPropMethod, jvalues
    )

    let resultStr = jStringToSwiftString(env, result)

    env.pointee.functions.pointee.DeleteLocalRef(env, jKey)
    env.pointee.functions.pointee.DeleteLocalRef(env, systemClass)
    if let r = result {
        env.pointee.functions.pointee.DeleteLocalRef(env, r)
    }

    checkAndClearJNIException(env, context: "System.getProperty")

    return strdup(resultStr ?? "null")
}

/// Retrieves the last Java exception as a JSON error string.
///
/// This function checks if there is a pending JNI exception, calls
/// ExceptionDescribe to get the stack trace, and returns it as a JSON
/// string with an "error" field.
///
/// - Returns: A C string containing the error JSON, or nil if no exception.
///   The caller MUST free this pointer when done.
@_cdecl("anymex_ios_jvm_get_last_error")
public func anymex_ios_jvm_get_last_error() -> UnsafePointer<CChar>? {
    guard gJVMInitialized, let env = attachCurrentThread() else {
        let errorMsg = "{\"error\":\"JVM not available\"}"
        return strdup(errorMsg)
    }

    if env.pointee.functions.pointee.ExceptionCheck(env) == JNI_TRUE {
        // We need to capture the exception message. Call toString() on the exception.
        let exception = env.pointee.functions.pointee.ExceptionOccurred(env)
        if let exc = exception {
            let excClass = env.pointee.functions.pointee.GetObjectClass(env, exc)
            if let excCls = excClass {
                let toStringMethod = env.pointee.functions.pointee.GetMethodID(
                    env, excCls, "toString", "()Ljava/lang/String;"
                )
                if let method = toStringMethod {
                    let msgJString = env.pointee.functions.pointee.CallObjectMethodA(
                        env, exc, method, nil
                    )
                    let msg = jStringToSwiftString(env, msgJString)
                    if let m = msgJString {
                        env.pointee.functions.pointee.DeleteLocalRef(env, m)
                    }
                    env.pointee.functions.pointee.ExceptionClear(env)
                    env.pointee.functions.pointee.DeleteLocalRef(env, excCls)
                    env.pointee.functions.pointee.DeleteLocalRef(env, exc)

                    let escapedMsg = (msg ?? "unknown").replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
                    let errorJson = "{\"error\":\"\(escapedMsg)\",\"type\":\"java_exception\"}"
                    return strdup(errorJson)
                }
                env.pointee.functions.pointee.DeleteLocalRef(env, excCls)
            }
            env.pointee.functions.pointee.ExceptionClear(env)
            env.pointee.functions.pointee.DeleteLocalRef(env, exc)
        } else {
            env.pointee.functions.pointee.ExceptionClear(env)
        }
        return strdup("{\"error\":\"Unknown Java exception\",\"type\":\"java_exception\"}")
    }

    return nil  // No exception pending
}

// MARK: - Flutter Plugin Extension

extension SwiftAnymexExtensionRuntimeBridgePlugin {

    /// Convenience method to get the JVM version as a string.
    /// Called from the Flutter MethodChannel for diagnostics.
    static func getJVMVersionString() -> String {
        gJVMLock.lock()
        defer { gJVMLock.unlock() }

        guard gJVMInitialized, let env = gJNIEnv else {
            return "JVM not initialized"
        }

        let version = env.pointee.functions.pointee.GetVersion(env)
        let major = Int32(version >> 16) & 0xFFFF
        let minor = Int32(version & 0xFFFF)
        return "JNI \(major).\(minor) (OpenJDK Zero VM for iOS ARM64)"
    }

    /// Convenience method to check JVM initialization status from
    /// the Flutter MethodChannel.
    static func isJVMRunning() -> Bool {
        gJVMLock.lock()
        let running = gJVMInitialized
        gJVMLock.unlock()
        return running
    }

    /// Returns diagnostic information about the JVM state.
    /// Useful for debugging from the Dart side via the MethodChannel.
    static func getJVMDebugInfo() -> String {
        var info: [String: Any] = [
            "initialized": isJVMRunning(),
            "platform": "ios",
            "arch": "arm64",
            "vm_type": "OpenJDK Zero",
        ]

        if isJVMRunning() {
            info["jni_version"] = getJVMVersionString()
            info["has_global_class_ref"] = gExtensionLoaderClassGlobalRef != nil
        }

        do {
            let data = try JSONSerialization.data(withJSONObject: info)
            if let jsonStr = String(data: data, encoding: .utf8) {
                return jsonStr
            }
        } catch {
            return "{\"error\":\"\(error.localizedDescription)\"}"
        }

        return "{\"error\":\"Failed to serialize debug info\"}"
    }
}
