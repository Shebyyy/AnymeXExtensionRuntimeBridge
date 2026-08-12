// AnymexExtensionRuntimeBridgePlugin.swift
// AnymeX Extension Runtime Bridge — iOS Plugin
//
// Flutter plugin that bridges Dart ↔ native ↔ Java (JVM).
// On iOS, uses PojavLauncher's OpenJDK 8 Zero interpreter (arm64).
//
// Flow: Dart (method channel) → Swift plugin → JNI → Java RuntimeBridge

import Flutter

// ---------------------------------------------------------------------------
// Static state shared across the plugin lifecycle
// ---------------------------------------------------------------------------
private var sharedPlugin: AnymexExtensionRuntimeBridgePlugin?
private var jvmReady = false
private var jvmMutex = pthread_mutex_t()

public class AnymexExtensionRuntimeBridgePlugin: NSObject, FlutterPlugin {

    private var channel: FlutterMethodChannel?
    private let launcher = JavaLauncher()
    private let jni = JniHelper.shared
    private var javaHome: String?
    private var bridgeJarPath: String?

    // MARK: - Registration

    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(
            name: "anymeXBridge",
            binaryMessenger: registrar.messenger()
        )
        let instance = AnymexExtensionRuntimeBridgePlugin(channel: channel)
        registrar.addMethodCallDelegate(instance, channel: channel)
        sharedPlugin = instance
    }

    init(channel: FlutterMethodChannel) {
        self.channel = channel
        super.init()
    }

    // MARK: - Handle Method Call

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let method = call.method

        if method == "loadAnymeXRuntimeHost" {
            handleLoadRuntime(call: call, result: result)
            return
        }

        if method == "isLoaded" {
            result(jni.isAvailable)
            return
        }

        if method == "setCookies" {
            handleSetCookies(call: call, result: result)
            return
        }

        if method == "setUserAgent" {
            handleSetUserAgent(call: call, result: result)
            return
        }

        if method == "cancelRequest" {
            handleCancelRequest(call: call, result: result)
            return
        }

        if method == "getImageBytes" {
            handleGetImageBytes(call: call, result: result)
            return
        }

        if method == "invokeBridgeMethod" {
            handleInvokeBridgeMethod(call: call, result: result)
            return
        }

        result(FlutterMethodNotImplemented)
    }

    // MARK: - JVM Launch

    private func handleLoadRuntime(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any?] else {
            result(FlutterError(code: "INVALID_ARGS", message: "Expected dict argument", details: nil))
            return
        }

        let bridgePath = args["path"] as? String ?? ""
        let settings = args["settings"] as? [String: Any?]
        let jrePath = args["jrePath"] as? String ?? ""

        if bridgePath.isEmpty {
            result(false)
            return
        }

        // Discover the JDK: prefer explicit path from Dart, fallback to auto-discovery in app bundle
        let jdkHome: String? = jrePath.isEmpty ? JavaLauncher.findJavaHome() : jrePath
        guard let effectiveJdkHome = jdkHome else {
            print("[AnymeXPlugin] OpenJDK not found (neither provided nor in app bundle)")
            result(false)
            return
        }

        self.javaHome = effectiveJdkHome
        self.bridgeJarPath = bridgePath

        print("[AnymeXPlugin] Launching JVM from: \(effectiveJdkHome)")
        print("[AnymeXPlugin] Bridge JAR: \(bridgePath)")

        // Reset exit override state
        ExitOverride.shared.reset()

        // Build extra JVM args from settings
        var extraArgs: [String] = []

        if let proxyHost = settings?["proxyHost"] as? String {
            let port = settings?["proxyPort"] as? String ?? "8080"
            extraArgs.append("-Dhttp.proxyHost=\(proxyHost)")
            extraArgs.append("-Dhttp.proxyPort=\(port)")
            extraArgs.append("-Dhttps.proxyHost=\(proxyHost)")
            extraArgs.append("-Dhttps.proxyPort=\(port)")
        }

        // Launch JVM
        launcher.startJvmAsync(
            javaHome: effectiveJdkHome,
            bridgeJarPath: bridgePath,
            extraArgs: extraArgs
        ) { [weak self] success in
            guard let self = self else {
                result(false)
                return
            }

            if success {
                // Try to obtain JavaVM via JNI
                let attached = self.jni.obtainJavaVM()
                if attached {
                    pthread_mutex_lock(&jvmMutex)
                    jvmReady = true
                    pthread_mutex_unlock(&jvmMutex)

                    print("[AnymeXPlugin] JVM launched and JNI attached successfully")

                    // Initialize the bridge Java side
                    self.initializeBridgeJavaSide()

                    result(true)
                } else {
                    print("[AnymeXPlugin] ❌ JVM started but JNI_GetCreatedJavaVMs failed")
                    result(FlutterError(code: "JNI_ATTACH_FAILED", message: "JVM started but JNI_GetCreatedJavaVMs returned no JVM", details: nil))
                }
            } else {
                print("[AnymeXPlugin] ❌ JVM launch failed (exitIntercepted=\(ExitOverride.shared.exitIntercepted), exitCode=\(ExitOverride.shared.lastExitCode))")
                result(FlutterError(code: "JVM_LAUNCH_FAILED", message: "JVM failed to start", details: "exitIntercepted=\(ExitOverride.shared.exitIntercepted), exitCode=\(ExitOverride.shared.lastExitCode)"))
            }
        }
    }

    // MARK: - Bridge Java-Side Init

    private func initializeBridgeJavaSide() {
        pthread_mutex_lock(&jvmMutex)
        defer { pthread_mutex_unlock(&jvmMutex) }

        guard let env = jni.getEnv() else {
            print("[AnymeXPlugin] Cannot init bridge: no JNIEnv")
            return
        }

        // Look up the RuntimeBridge main class
        let bridgeClass = jni.findClass(name: "com/anymex/runtimehost/RuntimeBridge")
        guard let cls = bridgeClass else {
            print("[AnymeXPlugin] RuntimeBridge class not found — bridge JAR may not contain it")
            jni.exceptionClear()
            return
        }

        // Call static void init() if it exists
        if let initMethod = jni.getStaticMethodID(cls: cls, name: "init", sig: "()V") {
            let _ = jni.callStaticVoidMethod(cls: cls, methodID: initMethod)
            jni.exceptionClear()
        }

        print("[AnymeXPlugin] Bridge Java side initialized")
    }

    // MARK: - Set Cookies

    private func handleSetCookies(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any?] else {
            result(nil)
            return
        }

        guard let url = args["url"] as? String, !url.isEmpty,
              let cookieString = args["cookieString"] as? String, !cookieString.isEmpty else {
            result(nil)
            return
        }

        pthread_mutex_lock(&jvmMutex)
        defer { pthread_mutex_unlock(&jvmMutex) }

        guard jvmReady, jni.getEnv() != nil else {
            result(nil)
            return
        }

        guard let bridgeClass = jni.findClass(name: "com/anymex/runtimehost/RuntimeBridge") else {
            jni.exceptionClear()
            result(nil)
            return
        }

        if let method = jni.getStaticMethodID(cls: bridgeClass, name: "setCookies", sig: "(Ljava/lang/String;Ljava/lang/String;)V") {
            let jUrl = jni.toJString(url)
            let jCookies = jni.toJString(cookieString)
            let _ = jni.callStaticVoidMethod(cls: bridgeClass, methodID: method, args: [
                jvalue(l: jUrl),
                jvalue(l: jCookies),
            ])
            jni.exceptionClear()
        }

        result(nil)
    }

    // MARK: - Set User Agent

    private func handleSetUserAgent(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any?] else {
            result(nil)
            return
        }

        guard let url = args["url"] as? String, !url.isEmpty,
              let userAgent = args["userAgent"] as? String, !userAgent.isEmpty else {
            result(nil)
            return
        }

        pthread_mutex_lock(&jvmMutex)
        defer { pthread_mutex_unlock(&jvmMutex) }

        guard jvmReady, jni.getEnv() != nil else {
            result(nil)
            return
        }

        guard let bridgeClass = jni.findClass(name: "com/anymex/runtimehost/RuntimeBridge") else {
            jni.exceptionClear()
            result(nil)
            return
        }

        if let method = jni.getStaticMethodID(cls: bridgeClass, name: "setUserAgent", sig: "(Ljava/lang/String;Ljava/lang/String;)V") {
            let jUrl = jni.toJString(url)
            let jUa = jni.toJString(userAgent)
            let _ = jni.callStaticVoidMethod(cls: bridgeClass, methodID: method, args: [
                jvalue(l: jUrl),
                jvalue(l: jUa),
            ])
            jni.exceptionClear()
        }

        result(nil)
    }

    // MARK: - Cancel Request

    private func handleCancelRequest(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any?] else {
            result(false)
            return
        }

        guard let token = args["token"] as? String, !token.isEmpty else {
            result(false)
            return
        }

        pthread_mutex_lock(&jvmMutex)
        defer { pthread_mutex_unlock(&jvmMutex) }

        guard jvmReady, jni.getEnv() != nil else {
            result(false)
            return
        }

        guard let bridgeClass = jni.findClass(name: "com/anymex/runtimehost/RuntimeBridge") else {
            jni.exceptionClear()
            result(false)
            return
        }

        if let method = jni.getStaticMethodID(cls: bridgeClass, name: "cancelRequest", sig: "(Ljava/lang/String;)Z") {
            let jToken = jni.toJString(token)
            let cancelled = jni.callStaticBooleanMethod(cls: bridgeClass, methodID: method, args: [
                jvalue(l: jToken),
            ])
            jni.exceptionClear()
            result(cancelled)
        } else {
            result(false)
        }
    }

    // MARK: - Get Image Bytes

    private func handleGetImageBytes(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any?] else {
            result(nil)
            return
        }

        guard let sourceId = args["sourceId"] as? String, !sourceId.isEmpty,
              let urlString = args["url"] as? String, !urlString.isEmpty else {
            result(nil)
            return
        }

        let isAnime = args["isAnime"] as? Bool ?? false

        pthread_mutex_lock(&jvmMutex)
        defer { pthread_mutex_unlock(&jvmMutex) }

        guard jvmReady, jni.getEnv() != nil else {
            result(nil)
            return
        }

        guard let bridgeClass = jni.findClass(name: "com/anymex/runtimehost/RuntimeBridge") else {
            jni.exceptionClear()
            result(nil)
            return
        }

        if let method = jni.getStaticMethodID(cls: bridgeClass, name: "getImageBytes", sig: "(Ljava/lang/String;ZLjava/lang/String;)[B") {
            let jSourceId = jni.toJString(sourceId)
            let jUrl = jni.toJString(urlString)

            let imageBytes = jni.callStaticObjectMethod(cls: bridgeClass, methodID: method, args: [
                jvalue(l: jSourceId),
                jvalue(z: isAnime ? 1 : 0),
                jvalue(l: jUrl),
            ])

            if let bytes = imageBytes, jni.exceptionCheck() == 0 {
                if let data = convertJByteArrayToFlutterData(bytes) {
                    result(FlutterStandardTypedData(bytes: data))
                } else {
                    result(nil)
                }
            } else {
                jni.exceptionClear()
                result(nil)
            }
        } else {
            result(nil)
        }
    }

    // MARK: - Generic Bridge Method Invocation

    private func handleInvokeBridgeMethod(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any?] else {
            result(FlutterError(code: "INVALID_ARGS", message: "Expected dict argument", details: nil))
            return
        }

        guard let methodName = args["methodName"] as? String, !methodName.isEmpty else {
            result(FlutterError(code: "INVALID_ARGS", message: "methodName is required", details: nil))
            return
        }

        let dartArgs = args["args"] as? [Any?] ?? []

        pthread_mutex_lock(&jvmMutex)
        defer { pthread_mutex_unlock(&jvmMutex) }

        guard jvmReady, jni.getEnv() != nil else {
            result(FlutterError(code: "JVM_NOT_READY", message: "JVM is not running", details: nil))
            return
        }

        guard let bridgeClass = jni.findClass(name: "com/anymex/runtimehost/RuntimeBridge") else {
            jni.exceptionClear()
            result(FlutterError(code: "CLASS_NOT_FOUND", message: "RuntimeBridge class not found", details: nil))
            return
        }

        // Try to find the method with different signatures
        var method: jmethodID? = nil
        method = jni.getStaticMethodID(cls: bridgeClass, name: "invoke", sig: "(Ljava/lang/String;[Ljava/lang/Object;)Ljava/lang/Object;")

        if method == nil {
            method = jni.getStaticMethodID(cls: bridgeClass, name: "dispatch", sig: "(Ljava/lang/String;[Ljava/lang/Object;)Ljava/lang/String;")
        }

        guard let effectiveMethod = method else {
            jni.exceptionClear()
            result(FlutterError(code: "METHOD_NOT_FOUND", message: "invoke/dispatch method not found on RuntimeBridge", details: nil))
            return
        }

        // Convert Dart args to Java Object array
        let jMethodName = jni.toJString(methodName)

        guard let objClass = jni.findClass(name: "java/lang/Object") else {
            result(FlutterError(code: "ARRAY_CREATE_FAILED", message: "Object class not found", details: nil))
            return
        }

        let jArgsArray = jni.newObjectArray(size: jint(dartArgs.count), elementClass: objClass)
        guard let argsArray = jArgsArray else {
            jni.exceptionClear()
            result(FlutterError(code: "ARRAY_CREATE_FAILED", message: "Failed to create Java Object[]", details: nil))
            return
        }

        for (i, dartArg) in dartArgs.enumerated() {
            if let jArg = convertDartToJavaObject(dartArg) {
                jni.setObjectArrayElement(array: argsArray, index: jint(i), value: jArg)
            }
        }

        // Invoke
        let javaResult = jni.callStaticObjectMethod(cls: bridgeClass, methodID: effectiveMethod, args: [
            jvalue(l: jMethodName),
            jvalue(l: argsArray),
        ])

        if jni.exceptionCheck() != 0 {
            let errMsg = getJavaExceptionMessage()
            jni.exceptionClear()
            result(FlutterError(code: "JAVA_EXCEPTION", message: errMsg ?? "Unknown Java exception", details: nil))
            return
        }

        // Convert Java result back to Dart-compatible type
        let dartResult = convertJavaObjectToDart(javaResult)
        result(dartResult)
    }

    // MARK: - Dart ↔ Java Type Conversion

    /// Convert a jbyteArray to Data for FlutterStandardTypedData.
    private func convertJByteArrayToFlutterData(_ array: jobject?) -> Data? {
        guard let array = array else { return nil }

        let len = jni.getArrayLength(array: array)
        if len <= 0 { return Data() }

        guard let bytes = jni.getByteArrayElements(array: array) else { return nil }
        let count = Int(len)
        var data = Data(count: count)
        data.withUnsafeMutableBytes { ptr in
            if let baseAddr = ptr.baseAddress {
                memcpy(baseAddr, bytes, count)
            }
        }
        jni.releaseByteArrayElements(array: array, bytes: bytes)

        return data
    }

    /// Convert a Dart object (from method channel) to a Java object.
    private func convertDartToJavaObject(_ obj: Any?) -> jobject? {
        guard let obj = obj else { return nil }

        if obj is NSNull { return nil }

        if let str = obj as? String {
            return jni.toJString(str)
        }

        if let num = obj as? NSNumber {
            let type = String(cString: num.objCType)

            if type == "B" || type == "c" {
                // Bool
                if let cls = jni.findClass(name: "java/lang/Boolean") {
                    if let m = jni.getStaticMethodID(cls: cls, name: "valueOf", sig: "(Z)Ljava/lang/Boolean;") {
                        return jni.callStaticObjectMethod(cls: cls, methodID: m, args: [
                            jvalue(z: num.boolValue ? 1 : 0),
                        ])
                    }
                }
            }

            if type == "i" || type == "s" {
                // Int / Short
                if let cls = jni.findClass(name: "java/lang/Integer") {
                    if let m = jni.getStaticMethodID(cls: cls, name: "valueOf", sig: "(I)Ljava/lang/Integer;") {
                        return jni.callStaticObjectMethod(cls: cls, methodID: m, args: [
                            jvalue(i: num.int32Value),
                        ])
                    }
                }
            }

            if type == "l" || type == "q" {
                // Long
                if let cls = jni.findClass(name: "java/lang/Long") {
                    if let m = jni.getStaticMethodID(cls: cls, name: "valueOf", sig: "(J)Ljava/lang/Long;") {
                        return jni.callStaticObjectMethod(cls: cls, methodID: m, args: [
                            jvalue(j: num.int64Value),
                        ])
                    }
                }
            }

            if type == "d" || type == "f" {
                // Double / Float
                if let cls = jni.findClass(name: "java/lang/Double") {
                    if let m = jni.getStaticMethodID(cls: cls, name: "valueOf", sig: "(D)Ljava/lang/Double;") {
                        return jni.callStaticObjectMethod(cls: cls, methodID: m, args: [
                            jvalue(d: num.doubleValue),
                        ])
                    }
                }
            }

            // Default: Integer
            if let cls = jni.findClass(name: "java/lang/Integer") {
                if let m = jni.getStaticMethodID(cls: cls, name: "valueOf", sig: "(I)Ljava/lang/Integer;") {
                    return jni.callStaticObjectMethod(cls: cls, methodID: m, args: [
                        jvalue(i: num.int32Value),
                    ])
                }
            }
        }

        if let arr = obj as? [Any?] {
            if let listClass = jni.findClass(name: "java/util/ArrayList") {
                let list = jni.createJavaArrayList(from: arr.compactMap { $0 })
                return list
            }
        }

        if let dict = obj as? [String: Any?] {
            return jni.createJavaHashMap(from: dict)
        }

        if let typedData = obj as? FlutterStandardTypedData {
            let data = typedData.data
            let byteArray = jni.newByteArray(size: jsize(data.count))
            if let ba = byteArray {
                jni.setByteArrayRegion(array: ba, buffer: (data as NSData).bytes.bindMemory(to: jbyte.self, capacity: data.count), length: jsize(data.count))
            }
            return byteArray
        }

        // Fallback: convert to string
        return jni.toJString("\(obj)")
    }

    /// Convert a Java object back to a Dart-compatible type.
    private func convertJavaObjectToDart(_ obj: jobject?) -> Any? {
        guard let obj = obj else { return nil }

        // Check if it's a String
        if let stringClass = jni.findClass(name: "java/lang/String") {
            if jni.isInstanceOf(obj: obj, cls: stringClass) {
                return jni.fromJString(obj as? jstring)
            }
        }

        // Check if it's a Number
        if let numberClass = jni.findClass(name: "java/lang/Number") {
            if jni.isInstanceOf(obj: obj, cls: numberClass) {
                // Try Boolean first
                if let boolClass = jni.findClass(name: "java/lang/Boolean") {
                    if jni.isInstanceOf(obj: obj, cls: boolClass) {
                        if let m = jni.getMethodID(cls: boolClass, name: "booleanValue", sig: "()Z") {
                            let val = jni.callBooleanMethod(obj: obj, methodID: m)
                            return val != 0
                        }
                    }
                }

                // Try Integer
                if let intClass = jni.findClass(name: "java/lang/Integer") {
                    if jni.isInstanceOf(obj: obj, cls: intClass) {
                        if let m = jni.getMethodID(cls: intClass, name: "intValue", sig: "()I") {
                            return jni.callIntMethod(obj: obj, methodID: m)
                        }
                    }
                }

                // Try Long
                if let longClass = jni.findClass(name: "java/lang/Long") {
                    if jni.isInstanceOf(obj: obj, cls: longClass) {
                        if let m = jni.getMethodID(cls: longClass, name: "longValue", sig: "()J") {
                            return jni.callLongMethod(obj: obj, methodID: m)
                        }
                    }
                }

                // Try Double
                if let doubleClass = jni.findClass(name: "java/lang/Double") {
                    if jni.isInstanceOf(obj: obj, cls: doubleClass) {
                        if let m = jni.getMethodID(cls: doubleClass, name: "doubleValue", sig: "()D") {
                            return jni.callDoubleMethod(obj: obj, methodID: m)
                        }
                    }
                }

                // Generic number fallback
                if let m = jni.getMethodID(cls: numberClass, name: "doubleValue", sig: "()D") {
                    return jni.callDoubleMethod(obj: obj, methodID: m)
                }
            }
        }

        // Check if it's a List/Collection
        if let listClass = jni.findClass(name: "java/util/List") {
            if jni.isInstanceOf(obj: obj, cls: listClass) {
                if let sizeMethod = jni.getMethodID(cls: listClass, name: "size", sig: "()I"),
                   let getMethod = jni.getMethodID(cls: listClass, name: "get", sig: "(I)Ljava/lang/Object;") {
                    let size = Int(jni.callIntMethod(obj: obj, methodID: sizeMethod))
                    var arr: [Any?] = []
                    for i in 0..<size {
                        let element = jni.callObjectMethod(obj: obj, methodID: getMethod, args: [jvalue(i: jint(i))])
                        arr.append(convertJavaObjectToDart(element) ?? NSNull())
                    }
                    return arr
                }
            }
        }

        // Check if it's a Map
        if let mapClass = jni.findClass(name: "java/util/Map") {
            if jni.isInstanceOf(obj: obj, cls: mapClass) {
                if let entrySetMethod = jni.getMethodID(cls: mapClass, name: "entrySet", sig: "()Ljava/util/Set;") {
                    let entrySet = jni.callObjectMethod(obj: obj, methodID: entrySetMethod)

                    if let setClass = jni.findClass(name: "java/util/Set"),
                       let iteratorMethod = jni.getMethodID(cls: setClass, name: "iterator", sig: "()Ljava/util/Iterator;") {
                        let iterator = jni.callObjectMethod(obj: entrySet, methodID: iteratorMethod)

                        if let iteratorClass = jni.findClass(name: "java/util/Iterator"),
                           let hasNextMethod = jni.getMethodID(cls: iteratorClass, name: "hasNext", sig: "()Z"),
                           let nextMethod = jni.getMethodID(cls: iteratorClass, name: "next", sig: "()Ljava/lang/Object;") {

                            var dict: [String: Any?] = [:]

                            while jni.callBooleanMethod(obj: iterator, methodID: hasNextMethod) != 0 {
                                let entry = jni.callObjectMethod(obj: iterator, methodID: nextMethod)

                                if let entryClass = jni.findClass(name: "java/util/Map$Entry"),
                                   let getKeyMethod = jni.getMethodID(cls: entryClass, name: "getKey", sig: "()Ljava/lang/Object;"),
                                   let getValueMethod = jni.getMethodID(cls: entryClass, name: "getValue", sig: "()Ljava/lang/Object;") {
                                    let key = jni.callObjectMethod(obj: entry, methodID: getKeyMethod)
                                    let value = jni.callObjectMethod(obj: entry, methodID: getValueMethod)

                                    if let dartKey = convertJavaObjectToDart(key) as? String {
                                        dict[dartKey] = convertJavaObjectToDart(value) ?? NSNull()
                                    }
                                }
                            }

                            return dict
                        }
                    }
                }
            }
        }

        // Check if it's a byte array
        if jni.isByteArray(obj) {
            if let data = convertJByteArrayToFlutterData(obj) {
                return FlutterStandardTypedData(bytes: data)
            }
        }

        // Fallback: toString
        if let objClass = jni.findClass(name: "java/lang/Object"),
           let toStringMethod = jni.getMethodID(cls: objClass, name: "toString", sig: "()Ljava/lang/String;") {
            let strObj = jni.callObjectMethod(obj: obj, methodID: toStringMethod)
            if let str = strObj {
                return jni.fromJString(str as? jstring)
            }
        }

        return NSNull()
    }

    /// Get the message from a pending Java exception.
    private func getJavaExceptionMessage() -> String? {
        guard let exc = jni.exceptionOccurred() else {
            return "Unknown error"
        }

        var message: String?

        if let throwableClass = jni.findClass(name: "java/lang/Throwable") {
            if let getMessage = jni.getMethodID(cls: throwableClass, name: "getMessage", sig: "()Ljava/lang/String;") {
                let msgObj = jni.callObjectMethod(obj: exc, methodID: getMessage)
                message = jni.fromJString(msgObj as? jstring)
            }

            if message == nil {
                if let toString = jni.getMethodID(cls: throwableClass, name: "toString", sig: "()Ljava/lang/String;") {
                    let strObj = jni.callObjectMethod(obj: exc, methodID: toString)
                    message = jni.fromJString(strObj as? jstring)
                }
            }
        }

        jni.exceptionClear()
        return message ?? "Unknown Java exception"
    }

    // MARK: - Cleanup

    deinit {
        pthread_mutex_lock(&jvmMutex)
        jvmReady = false
        jni.detachCurrentThread()
        pthread_mutex_unlock(&jvmMutex)
    }
}
