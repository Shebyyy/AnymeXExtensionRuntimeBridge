// JniHelper.swift
// AnymeX Extension Runtime Bridge — iOS Plugin
//
// Provides a Swift-friendly wrapper around JNI (Java Native Interface) C API.
// Manages thread attachment, type conversion, and method invocation.
//
// After the JVM is started via JLI_Launch, we need to obtain the JavaVM
// pointer. On PojavLauncher's OpenJDK 8 for iOS, JNI_GetCreatedJavaVMs()
// returns the running JVM instance.

import Foundation
import Darwin

// MARK: - Raw C JNI Types

/// Mirror the key JNI C types. On 64-bit iOS these are pointers.
public typealias JavaVM = UnsafeMutableRawPointer
public typealias JNIEnv = UnsafeMutableRawPointer

public typealias jobject = UnsafeMutableRawPointer?
public typealias jclass = jobject
public typealias jstring = jobject
public typealias jthrowable = jobject
public typealias jmethodID = UnsafeMutableRawPointer?
public typealias jfieldID = UnsafeMutableRawPointer?
public typealias jboolean = UInt8
public typealias jbyte = Int8
public typealias jchar = UInt16
public typealias jshort = Int16
public typealias jint = Int32
public typealias jlong = Int64
public typealias jfloat = Float
public typealias jdouble = Double
public typealias jsize = Int32

/// JNI false/true constants
let JNI_FALSE: jboolean = 0
let JNI_TRUE: jboolean = 1

/// JNI version constant for Java 1.8
let JNI_VERSION_1_8: jint = 0x00010008

/// Thread attachment return codes
let JNI_OK: jint = 0
let JNI_EDETACHED: jint = -2
let JNI_EVERSION: jint = -3
let JNI_ENOMEM: jint = -4
let JNI_EEXIST: jint = -5
let JNI_EINVAL: jint = -6

// MARK: - JNI Invocation Table Function Pointers
//
// The JNIEnv is actually a pointer to a pointer to the function table.
// We access the functions through the JNINativeInterface struct.

/// Function pointer types for the JNI functions we use.
/// These mirror the corresponding entries in the JNINativeInterface vtable
/// (jni.h) and are cast to from raw function-table slots via `getJniFunction`.
typealias jniFindClassFn = @convention(c) (JNIEnv?, UnsafePointer<Int8>) -> jclass
typealias jniGetStaticMethodIDFn = @convention(c) (JNIEnv?, jclass, UnsafePointer<Int8>, UnsafePointer<Int8>) -> jmethodID
typealias jniGetMethodIDFn = @convention(c) (JNIEnv?, jclass, UnsafePointer<Int8>, UnsafePointer<Int8>) -> jmethodID
typealias jniGetFieldIDFn = @convention(c) (JNIEnv?, jclass, UnsafePointer<Int8>, UnsafePointer<Int8>) -> jfieldID
typealias jniGetStaticObjectFieldFn = @convention(c) (JNIEnv?, jclass, jfieldID) -> jobject
typealias jniGetObjectClassFn = @convention(c) (JNIEnv?, jobject) -> jclass
typealias jniNewStringUTFnFn = @convention(c) (JNIEnv?, UnsafePointer<Int8>) -> jstring
typealias jniGetStringUTFCharsFn = @convention(c) (JNIEnv?, jstring, UnsafeMutablePointer<jboolean>?) -> UnsafePointer<Int8>?
typealias jniReleaseStringUTFCharsFn = @convention(c) (JNIEnv?, jstring, UnsafePointer<Int8>?) -> Void
typealias jniDeleteLocalRefFn = @convention(c) (JNIEnv?, jobject) -> Void
typealias jniNewGlobalRefFn = @convention(c) (JNIEnv?, jobject) -> jobject
typealias jniDeleteGlobalRefFn = @convention(c) (JNIEnv?, jobject) -> Void
typealias jniExceptionCheckFn = @convention(c) (JNIEnv?) -> jboolean
typealias jniExceptionDescribeFn = @convention(c) (JNIEnv?) -> Void
typealias jniExceptionClearFn = @convention(c) (JNIEnv?) -> Void
typealias jniExceptionOccurredFn = @convention(c) (JNIEnv?) -> jthrowable

// MARK: - JNI Exception

/// Represents a JNI exception that occurred during a Java method call.
public struct JniException: Error, CustomStringConvertible {
    public let message: String
    public let stackTrace: String

    public var description: String {
        return "JNIException: \(message)\n\(stackTrace)"
    }
}

/// Error thrown when JNI infrastructure is not available.
public struct JniNotAvailableError: Error, CustomStringConvertible {
    public var description: String {
        return "JNI is not available. The JVM has not been started or the JavaVM pointer could not be obtained."
    }
}

// MARK: - JniHelper

/// Thread-safe singleton that wraps JNI access.
/// Provides Swift-friendly methods for:
/// - Obtaining and caching the JavaVM pointer
/// - Attaching/detaching threads
/// - Finding classes and methods
/// - Calling static and instance methods
/// - Converting between Swift and JNI types
public class JniHelper: NSObject {

    // MARK: - Singleton

    @objc public static let shared = JniHelper()
    @objc public override init() {}

    // MARK: - JVM State

    /// Raw pointer to the JavaVM (obtained via JNI_GetCreatedJavaVMs).
    private var javaVM: JavaVM?
    private var javaVMReady = false
    private let vmLock = NSLock()

    /// Per-thread JNIEnv cache to avoid repeated attachment.
    private var threadEnvMap: [UInt: JNIEnv] = [:]
    private let threadLock = NSLock()

    @objc public var isAvailable: Bool {
        vmLock.lock()
        defer { vmLock.unlock() }
        return javaVMReady
    }

    // MARK: - JNI Function Table Access

    /// Get the JNIEnv for the current thread, attaching if necessary.
    /// This is the fundamental entry point for all JNI operations.
    ///
    /// - Returns: The JNIEnv pointer, or nil if attachment failed.
    public func getEnv() -> JNIEnv? {
        threadLock.lock()
        let tid = UInt(pthread_mach_thread_np(pthread_self()))
        if let cached = threadEnvMap[tid] {
            threadLock.unlock()
            return cached
        }
        threadLock.unlock()

        vmLock.lock()
        guard let vm = javaVM else {
            vmLock.unlock()
            print("[JniHelper] JavaVM pointer is nil — JVM not started")
            return nil
        }
        vmLock.unlock()

        // The JNI_GetEnv function pointer is at index 6 in the JNIInvokeInterface.
        // The JavaVM pointer is actually a pointer to a pointer to the function table.
        let invokeInterface = vm.assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
        guard let funcTable = invokeInterface.pointee else {
            print("[JniHelper] JNI invoke interface function table is nil")
            return nil
        }

        // Function table is an array of function pointers.
        // Index 4 = GetEnv (0=reserved, 1=DestroyJavaVM, 2=AttachCurrentThread,
        //   3=DetachCurrentThread, 4=GetEnv, 5=AttachCurrentThreadAsDaemon)
        typealias GetEnvFn = @convention(c) (JavaVM?, UnsafeMutablePointer<UnsafeMutableRawPointer?>?, jint) -> jint
        let funcTableTyped = funcTable.assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
        let getEnv = unsafeBitCast(
            funcTableTyped.advanced(by: 4).pointee,
            to: GetEnvFn.self
        )

        var envPtr: UnsafeMutableRawPointer?
        let result = getEnv(vm, &envPtr, JNI_VERSION_1_8)

        if result == JNI_OK, let env = envPtr {
            threadLock.lock()
            threadEnvMap[tid] = env
            threadLock.unlock()
            return env
        }

        if result == JNI_EDETACHED {
            // Need to attach the current thread
            let attached = attachCurrentThread(vm: vm, funcTable: funcTable)
            if attached, let env = envPtr {
                threadLock.lock()
                threadEnvMap[tid] = env
                threadLock.unlock()
                return env
            }
        }

        print("[JniHelper] GetEnv failed with code \(result)")
        return nil
    }

    /// Attach the current native thread to the JVM.
    private func attachCurrentThread(vm: JavaVM, funcTable: UnsafeMutableRawPointer) -> Bool {
        typealias AttachFn = @convention(c) (JavaVM?, UnsafeMutablePointer<UnsafeMutableRawPointer?>?, UnsafeMutableRawPointer?) -> jint
        let funcTableTyped = funcTable.assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
        let attach = unsafeBitCast(
            funcTableTyped.advanced(by: 3).pointee,  // AttachCurrentThread is at index 3
            to: AttachFn.self
        )

        var envPtr: UnsafeMutableRawPointer?
        let result = attach(vm, &envPtr, nil)

        if result == JNI_OK {
            print("[JniHelper] Attached thread to JVM")
            return true
        }

        print("[JniHelper] Failed to attach thread to JVM, error: \(result)")
        return false
    }

    // MARK: - JavaVM Initialization

    /// Attempt to obtain the JavaVM pointer from the running JVM.
    /// Call this after JLI_Launch has completed.
    ///
    /// - Returns: true if the JavaVM pointer was obtained successfully.
    public func obtainJavaVM() -> Bool {
        vmLock.lock()
        defer { vmLock.unlock() }

        // Use JNI_GetCreatedJavaVMs to find the running JVM.
        // This function is exported by libjvm.dylib.
        guard let getCreatedVMsSym = dlsym(RTLD_DEFAULT, "JNI_GetCreatedJavaVMs") else {
            print("[JniHelper] JNI_GetCreatedJavaVMs not found")
            return false
        }

        typealias GetCreatedVMsFn = @convention(c) (UnsafeMutablePointer<UnsafeMutableRawPointer?>?, jsize, UnsafeMutablePointer<jsize>?) -> jint
        let getCreatedVMs = unsafeBitCast(getCreatedVMsSym, to: GetCreatedVMsFn.self)

        var vmPtr: UnsafeMutableRawPointer?
        var vmCount: jsize = 0
        let result = getCreatedVMs(&vmPtr, 1, &vmCount)

        if result == JNI_OK && vmCount > 0 && vmPtr != nil {
            javaVM = vmPtr
            javaVMReady = true
            print("[JniHelper] Obtained JavaVM pointer (\(vmCount) JVM(s) created))")
            return true
        }

        print("[JniHelper] JNI_GetCreatedJavaVMs returned \(result), count=\(vmCount)")
        return false
    }

    /// Manually set the JavaVM pointer (e.g., if obtained through other means).
    public func setJavaVM(_ vm: JavaVM?) {
        vmLock.lock()
        javaVM = vm
        javaVMReady = (vm != nil)
        vmLock.unlock()
    }

    // MARK: - Function Table Access

    /// Access a function from the JNIEnv's function table.
    ///
    /// The JNIEnv pointer points to a pointer to the function table (JNINativeInterface).
    /// Index 0 through 4 are reserved, so actual JNI functions start at index 4.
    ///
    /// - Parameters:
    ///   - env: The JNIEnv pointer
    ///   - index: Index in the function table
    ///   - type: The function pointer type to cast to
    /// - Returns: The function pointer
    private func getJniFunction<T>(env: JNIEnv, index: Int, as type: T.Type) -> T {
        let envPtr = env.assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
        guard let funcTable = envPtr.pointee else {
            fatalError("[JniHelper] JNIEnv function table is nil")
        }
        let funcTableTyped = funcTable.assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
        return unsafeBitCast(funcTableTyped.advanced(by: index).pointee, to: T.self)
    }

    // MARK: - Class and Method Resolution

    /// Find a Java class by its JNI name (e.g., "com/example/MyClass").
    ///
    /// - Parameter name: JNI class name with slashes
    /// - Returns: The jclass reference, or nil if not found
    public func findClass(name: String) -> jclass {
        guard let env = getEnv() else { return nil }
        let fn: jniFindClassFn = getJniFunction(env: env, index: 6, as: jniFindClassFn.self)
        let cls = fn(env, name)
        checkAndClearException(env: env, context: "findClass(\(name))")
        return cls
    }

    /// Get a static method ID.
    ///
    /// - Parameters:
    ///   - cls: The class
    ///   - name: Method name
    ///   - sig: JNI method signature (e.g., "(Ljava/lang/String;)V")
    /// - Returns: The jmethodID, or nil if not found
    public func getStaticMethodID(cls: jclass, name: String, sig: String) -> jmethodID {
        guard let env = getEnv() else { return nil }
        let fn: jniGetStaticMethodIDFn = getJniFunction(env: env, index: 114, as: jniGetStaticMethodIDFn.self)
        let mid = fn(env, cls, name, sig)
        if mid == nil {
            checkAndClearException(env: env, context: "getStaticMethodID(\(name), \(sig))")
        }
        return mid
    }

    /// Get an instance method ID.
    public func getMethodID(cls: jclass, name: String, sig: String) -> jmethodID {
        guard let env = getEnv() else { return nil }
        let fn: jniGetMethodIDFn = getJniFunction(env: env, index: 33, as: jniGetMethodIDFn.self)
        let mid = fn(env, cls, name, sig)
        if mid == nil {
            checkAndClearException(env: env, context: "getMethodID(\(name), \(sig))")
        }
        return mid
    }

    /// Get a static field ID.
    public func getStaticFieldID(cls: jclass, name: String, sig: String) -> jfieldID {
        guard let env = getEnv() else { return nil }
        let fn: jniGetFieldIDFn = getJniFunction(env: env, index: 94, as: jniGetFieldIDFn.self)
        let fid = fn(env, cls, name, sig)
        if fid == nil {
            checkAndClearException(env: env, context: "getStaticFieldID(\(name), \(sig))")
        }
        return fid
    }

    /// Get the value of a static object field.
    public func getStaticObjectField(cls: jclass, fieldID: jfieldID) -> jobject {
        guard let env = getEnv() else { return nil }
        let fn: jniGetStaticObjectFieldFn = getJniFunction(env: env, index: 145, as: jniGetStaticObjectFieldFn.self)
        let result = fn(env, cls, fieldID)
        checkAndClearException(env: env, context: "getStaticObjectField")
        return result
    }

    /// Get the class of a Java object.
    public func getObjectClass(obj: jobject) -> jclass {
        guard let env = getEnv() else { return nil }
        let fn: jniGetObjectClassFn = getJniFunction(env: env, index: 31, as: jniGetObjectClassFn.self)
        return fn(env, obj)
    }

    // MARK: - Method Invocation

    /// Call a static method that returns an Object.
    public func callStaticObjectMethod(cls: jclass, methodID: jmethodID, args: [jvalue]) -> jobject {
        guard let env = getEnv() else { return nil }
        let fn = getJniFunction(env: env, index: 116, as: (@convention(c) (JNIEnv?, jclass, jmethodID, UnsafeMutableRawPointer?) -> jobject).self)

        // Build a va_list-like structure. For simplicity with variadic JNI calls,
        // we use the ... version by passing arguments directly.
        // Since we can't easily do variadic in Swift, we use the "va_list" variant.
        // Actually, JNI provides both VA_LIST and non-VA versions.
        // Let's use CallStaticObjectMethodV (index 118)
        let fnV = getJniFunction(env: env, index: 118, as: (@convention(c) (JNIEnv?, jclass, jmethodID, UnsafeMutableRawPointer?) -> jobject).self)

        let result: jobject
        if args.isEmpty {
            result = fn(env, cls, methodID, nil)
        } else {
            // Pack args into a contiguous buffer
            let argBuffer = UnsafeMutableBufferPointer<jvalue>.allocate(capacity: args.count)
            for (i, arg) in args.enumerated() {
                argBuffer[i] = arg
            }
            result = fnV(env, cls, methodID, argBuffer.baseAddress)
            argBuffer.deallocate()
        }

        if let exc = checkAndClearException(env: env, context: "callStaticObjectMethod") {
            print("[JniHelper] Exception in static object method: \(exc.message)")
        }
        return result
    }

    /// Call a static method that returns a boolean.
    public func callStaticBooleanMethod(cls: jclass, methodID: jmethodID, args: [jvalue] = []) -> Bool? {
        guard let env = getEnv() else { return nil }
        let fnV = getJniFunction(env: env, index: 126, as: (@convention(c) (JNIEnv?, jclass, jmethodID, UnsafeMutableRawPointer?) -> jboolean).self)

        let result: jboolean
        if args.isEmpty {
            result = fnV(env, cls, methodID, nil)
        } else {
            let argBuffer = UnsafeMutableBufferPointer<jvalue>.allocate(capacity: args.count)
            for (i, arg) in args.enumerated() {
                argBuffer[i] = arg
            }
            result = fnV(env, cls, methodID, argBuffer.baseAddress)
            argBuffer.deallocate()
        }

        checkAndClearException(env: env, context: "callStaticBooleanMethod")
        return result != JNI_FALSE
    }

    /// Call a static method that returns an int.
    public func callStaticIntMethod(cls: jclass, methodID: jmethodID, args: [jvalue] = []) -> Int32? {
        guard let env = getEnv() else { return nil }
        let fnV = getJniFunction(env: env, index: 130, as: (@convention(c) (JNIEnv?, jclass, jmethodID, UnsafeMutableRawPointer?) -> jint).self)

        let result: jint
        if args.isEmpty {
            result = fnV(env, cls, methodID, nil)
        } else {
            let argBuffer = UnsafeMutableBufferPointer<jvalue>.allocate(capacity: args.count)
            for (i, arg) in args.enumerated() {
                argBuffer[i] = arg
            }
            result = fnV(env, cls, methodID, argBuffer.baseAddress)
            argBuffer.deallocate()
        }

        checkAndClearException(env: env, context: "callStaticIntMethod")
        return result
    }

    /// Call a static void method.
    public func callStaticVoidMethod(cls: jclass, methodID: jmethodID, args: [jvalue] = []) {
        guard let env = getEnv() else { return }
        let fnV = getJniFunction(env: env, index: 140, as: (@convention(c) (JNIEnv?, jclass, jmethodID, UnsafeMutableRawPointer?) -> Void).self)

        if args.isEmpty {
            fnV(env, cls, methodID, nil)
        } else {
            let argBuffer = UnsafeMutableBufferPointer<jvalue>.allocate(capacity: args.count)
            for (i, arg) in args.enumerated() {
                argBuffer[i] = arg
            }
            fnV(env, cls, methodID, argBuffer.baseAddress)
            argBuffer.deallocate()
        }

        checkAndClearException(env: env, context: "callStaticVoidMethod")
    }

    /// Call an instance method that returns an Object.
    public func callObjectMethod(obj: jobject, methodID: jmethodID, args: [jvalue] = []) -> jobject {
        guard let env = getEnv() else { return nil }
        let fnV = getJniFunction(env: env, index: 35, as: (@convention(c) (JNIEnv?, jobject, jmethodID, UnsafeMutableRawPointer?) -> jobject).self)

        let result: jobject
        if args.isEmpty {
            result = fnV(env, obj, methodID, nil)
        } else {
            let argBuffer = UnsafeMutableBufferPointer<jvalue>.allocate(capacity: args.count)
            for (i, arg) in args.enumerated() {
                argBuffer[i] = arg
            }
            result = fnV(env, obj, methodID, argBuffer.baseAddress)
            argBuffer.deallocate()
        }

        checkAndClearException(env: env, context: "callObjectMethod")
        return result
    }

    /// Call an instance void method.
    public func callVoidMethod(obj: jobject, methodID: jmethodID, args: [jvalue] = []) {
        guard let env = getEnv() else { return }
        let fnV = getJniFunction(env: env, index: 59, as: (@convention(c) (JNIEnv?, jobject, jmethodID, UnsafeMutableRawPointer?) -> Void).self)

        if args.isEmpty {
            fnV(env, obj, methodID, nil)
        } else {
            let argBuffer = UnsafeMutableBufferPointer<jvalue>.allocate(capacity: args.count)
            for (i, arg) in args.enumerated() {
                argBuffer[i] = arg
            }
            fnV(env, obj, methodID, argBuffer.baseAddress)
            argBuffer.deallocate()
        }

        checkAndClearException(env: env, context: "callVoidMethod")
    }

    // MARK: - String Conversion

    /// Convert a Swift String to a JNI jstring.
    public func toJString(_ string: String) -> jstring {
        guard let env = getEnv() else { return nil }
        let fn: jniNewStringUTFnFn = getJniFunction(env: env, index: 164, as: jniNewStringUTFnFn.self)
        return fn(env, string)
    }

    /// Convert a JNI jstring to a Swift String.
    public func fromJString(_ jstr: jstring?) -> String? {
        guard let jstr = jstr, let env = getEnv() else { return nil }
        let getChars: jniGetStringUTFCharsFn = getJniFunction(
            env: env, index: 165, as: jniGetStringUTFCharsFn.self
        )
        let releaseChars: jniReleaseStringUTFCharsFn = getJniFunction(
            env: env, index: 166, as: jniReleaseStringUTFCharsFn.self
        )

        guard let cstr = getChars(env, jstr, nil) else { return nil }
        let swiftString = String(cString: cstr)
        releaseChars(env, jstr, cstr)
        return swiftString
    }

    // MARK: - Object ↔ Map Conversion

    /// Convert a Java Map to a Swift [String: Any?].
    /// Uses java.util.Map.entrySet() to iterate.
    public func javaMapToSwiftDict(_ mapObj: jobject?) -> [String: Any?]? {
        guard let mapObj = mapObj, let env = getEnv() else { return nil }

        let mapClass = findClass(name: "java/util/Map")
        let entrySetMethod = getMethodID(cls: mapClass, name: "entrySet", sig: "()Ljava/util/Set;")
        guard let entrySet = callObjectMethod(obj: mapObj, methodID: entrySetMethod) else {
            return [:]
        }

        let setClass = findClass(name: "java/util/Set")
        let iteratorMethod = getMethodID(cls: setClass, name: "iterator", sig: "()Ljava/util/Iterator;")
        guard let iterator = callObjectMethod(obj: entrySet, methodID: iteratorMethod) else {
            return [:]
        }

        let iterClass = findClass(name: "java/util/Iterator")
        let hasNextMethod = getMethodID(cls: iterClass, name: "hasNext", sig: "()Z")
        let nextMethod = getMethodID(cls: iterClass, name: "next", sig: "()Ljava/lang/Object;")

        let entryClass = findClass(name: "java/util/Map$Entry")
        let getKeyMethod = getMethodID(cls: entryClass, name: "getKey", sig: "()Ljava/lang/Object;")
        let getValueMethod = getMethodID(cls: entryClass, name: "getValue", sig: "()Ljava/lang/Object;")

        var result: [String: Any?] = [:]

        while true {
            guard let hasNext = callObjectMethod(obj: iterator, methodID: hasNextMethod) else { break }
            // hasNext is actually a Boolean, check via the return value
            // Since callObjectMethod returns jobject, we need to check differently
            // Let's use a direct approach: call the boolean version
            deleteLocalRef(obj: hasNext)

            // Check hasNext via a boolean call
            guard let env2 = getEnv() else { break }
            let hasNextBoolFn = getJniFunction(
                env: env2, index: 55,
                as: (@convention(c) (JNIEnv?, jobject, jmethodID, UnsafeMutableRawPointer?) -> jboolean).self
            )
            let hasNextBool = hasNextBoolFn(env2, iterator, hasNextMethod, nil)
            if hasNextBool == JNI_FALSE { break }

            guard let entry = callObjectMethod(obj: iterator, methodID: nextMethod) else { break }
            guard let keyObj = callObjectMethod(obj: entry, methodID: getKeyMethod) else {
                deleteLocalRef(obj: entry)
                break
            }
            guard let valueObj = callObjectMethod(obj: entry, methodID: getValueMethod) else {
                deleteLocalRef(obj: keyObj)
                deleteLocalRef(obj: entry)
                break
            }

            let key = fromJString(keyObj as? jstring) ?? "\(keyObj!)"
            let value = javaObjectToSwift(valueObj)

            result[key] = value

            deleteLocalRef(obj: keyObj)
            deleteLocalRef(obj: valueObj)
            deleteLocalRef(obj: entry)
        }

        deleteLocalRef(obj: entrySet)
        deleteLocalRef(obj: iterator)
        return result
    }

    /// Convert a Java List to a Swift Array.
    public func javaListToSwiftArray(_ listObj: jobject?) -> [Any?]? {
        guard let listObj = listObj, let env = getEnv() else { return nil }

        let listClass = findClass(name: "java/util/List")
        let sizeMethod = getMethodID(cls: listClass, name: "size", sig: "()I")
        let getMethod = getMethodID(cls: listClass, name: "get", sig: "(I)Ljava/lang/Object;")

        guard let sizeObj = callObjectMethod(obj: listObj, methodID: sizeMethod) else { return [] }
        // sizeMethod returns int, but we used callObjectMethod... need int version
        guard let env2 = getEnv() else { return [] }
        let sizeFn = getJniFunction(
            env: env2, index: 49,
            as: (@convention(c) (JNIEnv?, jobject, jmethodID, UnsafeMutableRawPointer?) -> jint).self
        )
        deleteLocalRef(obj: sizeObj)

        let size = Int(sizeFn(env2, listObj, sizeMethod, nil))
        var result: [Any?] = []
        result.reserveCapacity(size)

        for i in 0..<size {
            let indexArg: jvalue = jvalue(i: jint(i))
            guard let element = callObjectMethod(obj: listObj, methodID: getMethod, args: [indexArg]) else {
                result.append(nil)
                continue
            }
            result.append(javaObjectToSwift(element))
            deleteLocalRef(obj: element)
        }

        return result
    }

    /// Convert a Java Object to a Swift value recursively.
    /// Handles String, Number, Boolean, Map, List, and null.
    public func javaObjectToSwift(_ obj: jobject?) -> Any? {
        guard let obj = obj else { return nil }
        guard let env = getEnv() else { return nil }

        let objClass = getObjectClass(obj: obj)
        guard let objClassName = getClassName(cls: objClass) else {
            return fromJString(obj as? jstring)
        }

        deleteLocalRef(obj: objClass)

        switch objClassName {
        case "java.lang.String":
            return fromJString(obj as? jstring)
        case "java.lang.Integer", "java.lang.Long", "java.lang.Short",
             "java.lang.Byte", "java.lang.Float", "java.lang.Double":
            return javaNumberToSwift(obj)
        case "java.lang.Boolean":
            return javaBooleanToSwift(obj)
        case "java.util.HashMap", "java.util.LinkedHashMap",
             "java.util.TreeMap", "java.util.Hashtable",
             "java.util.AbstractMap", "java.util.Collections$UnmodifiableMap":
            return javaMapToSwiftDict(obj) ?? [:]
        case "java.util.ArrayList", "java.util.LinkedList",
             "java.util.Vector", "java.util.Arrays$ArrayList",
             "java.util.Collections$UnmodifiableRandomAccessList",
             "java.util.Collections$UnmodifiableList":
            return javaListToSwiftArray(obj) ?? []
        default:
            // Try to convert via toString() as a last resort
            if let str = javaToString(obj) {
                return str
            }
            // Return a description placeholder
            return "[JavaObject: \(objClassName)]"
        }
    }

    /// Get the simple class name of a jclass.
    private func getClassName(cls: jclass?) -> String? {
        guard let cls = cls, let env = getEnv() else { return nil }
        let classClass = findClass(name: "java/lang/Class")
        let getNameMethod = getMethodID(cls: classClass, name: "getName", sig: "()Ljava/lang/String;")
        guard let nameObj = callObjectMethod(obj: cls, methodID: getNameMethod) else { return nil }
        let name = fromJString(nameObj as? jstring)
        deleteLocalRef(obj: nameObj)
        return name
    }

    /// Convert a Java Number to an appropriate Swift numeric type.
    private func javaNumberToSwift(_ obj: jobject) -> Any? {
        guard let env = getEnv() else { return nil }
        let numClass = findClass(name: "java/lang/Number")

        // Try intValue first
        let intValueMethod = getMethodID(cls: numClass, name: "intValue", sig: "()I")
        let intValueFn = getJniFunction(
            env: env, index: 49,
            as: (@convention(c) (JNIEnv?, jobject, jmethodID, UnsafeMutableRawPointer?) -> jint).self
        )
        let intVal = intValueFn(env, obj, intValueMethod, nil)

        // Try longValue
        let longValueMethod = getMethodID(cls: numClass, name: "longValue", sig: "()J")
        let longValueFn = getJniFunction(
            env: env, index: 51,
            as: (@convention(c) (JNIEnv?, jobject, jmethodID, UnsafeMutableRawPointer?) -> jlong).self
        )
        let longVal = longValueFn(env, obj, longValueMethod, nil)

        // Try doubleValue for floating point
        let doubleValueMethod = getMethodID(cls: numClass, name: "doubleValue", sig: "()D")
        let doubleValueFn = getJniFunction(
            env: env, index: 53,
            as: (@convention(c) (JNIEnv?, jobject, jmethodID, UnsafeMutableRawPointer?) -> jdouble).self
        )
        let doubleVal = doubleValueFn(env, obj, doubleValueMethod, nil)

        // Return as Int if it's a whole number, otherwise Double
        if doubleVal != Double(intVal) {
            return doubleVal
        }
        return Int(longVal)
    }

    /// Convert a Java Boolean to a Swift Bool.
    private func javaBooleanToSwift(_ obj: jobject) -> Bool {
        guard let env = getEnv() else { return false }
        let boolClass = findClass(name: "java/lang/Boolean")
        let boolValueMethod = getMethodID(cls: boolClass, name: "booleanValue", sig: "()Z")
        let fn = getJniFunction(
            env: env, index: 55,
            as: (@convention(c) (JNIEnv?, jobject, jmethodID, UnsafeMutableRawPointer?) -> jboolean).self
        )
        return fn(env, obj, boolValueMethod, nil) != JNI_FALSE
    }

    /// Call toString() on a Java object.
    private func javaToString(_ obj: jobject) -> String? {
        guard let env = getEnv() else { return nil }
        let objClass = getObjectClass(obj: obj)
        let toStringMethod = getMethodID(cls: objClass, name: "toString", sig: "()Ljava/lang/String;")
        deleteLocalRef(obj: objClass)
        guard let strObj = callObjectMethod(obj: obj, methodID: toStringMethod) else { return nil }
        let result = fromJString(strObj as? jstring)
        deleteLocalRef(obj: strObj)
        return result
    }

    // MARK: - Reference Management

    /// Delete a local JNI reference.
    public func deleteLocalRef(obj: jobject?) {
        guard let obj = obj, let env = getEnv() else { return }
        let fn: jniDeleteLocalRefFn = getJniFunction(env: env, index: 23, as: jniDeleteLocalRefFn.self)
        fn(env, obj)
    }

    /// Create a global reference to a JNI object.
    public func newGlobalRef(obj: jobject?) -> jobject {
        guard let obj = obj, let env = getEnv() else { return nil }
        let fn: jniNewGlobalRefFn = getJniFunction(env: env, index: 21, as: jniNewGlobalRefFn.self)
        return fn(env, obj)
    }

    /// Delete a global JNI reference.
    public func deleteGlobalRef(obj: jobject?) {
        guard let obj = obj, let env = getEnv() else { return }
        let fn: jniDeleteGlobalRefFn = getJniFunction(env: env, index: 22, as: jniDeleteGlobalRefFn.self)
        fn(env, obj)
    }

    // MARK: - Exception Handling

    /// Check if a JNI exception occurred, capture its details, and clear it.
    ///
    /// - Parameter env: The JNIEnv
    /// - Parameter context: Description of what operation caused the exception
    /// - Returns: The exception details if one occurred, nil otherwise
    @discardableResult
    public func checkAndClearException(env: JNIEnv?, context: String) -> JniException? {
        guard let env = env else { return nil }

        let checkFn: jniExceptionCheckFn = getJniFunction(env: env, index: 17, as: jniExceptionCheckFn.self)
        let hasException = checkFn(env)

        guard hasException != JNI_FALSE else { return nil }

        // Get exception details via ExceptionDescribe
        let describeFn: jniExceptionDescribeFn = getJniFunction(env: env, index: 16, as: jniExceptionDescribeFn.self)
        describeFn(env)

        // Get the exception object for the message
        let excFn: jniExceptionOccurredFn = getJniFunction(env: env, index: 15, as: jniExceptionOccurredFn.self)
        let exc = excFn(env)

        var message = "Unknown JNI exception"
        var stackTrace = ""

        if let exc = exc {
            // Call getMessage() on the exception
            let excClass = getObjectClass(obj: exc)
            let getMessageMethod = getMethodID(cls: excClass, name: "getMessage", sig: "()Ljava/lang/String;")
            deleteLocalRef(obj: excClass)

            if let msgObj = callObjectMethod(obj: exc, methodID: getMessageMethod) {
                message = fromJString(msgObj as? jstring) ?? "Unknown"
                deleteLocalRef(obj: msgObj)
            }

            // Call toString() for full info
            if let desc = javaToString(exc) {
                stackTrace = desc
            }

            deleteLocalRef(obj: exc)
        }

        // Clear the exception so JNI calls can continue
        let clearFn: jniExceptionClearFn = getJniFunction(env: env, index: 18, as: jniExceptionClearFn.self)
        clearFn(env)

        print("[JniHelper] Exception in \(context): \(message)")
        return JniException(message: message, stackTrace: stackTrace)
    }

    // MARK: - RuntimeBridge Convenience Methods

    /// The RuntimeBridge Kotlin object class name in JNI notation.
    private static let bridgeClassName = "com/anymex/runtimehost/RuntimeBridge"

    /// Cached class and method references for the RuntimeBridge.
    private var bridgeClass: jclass?
    private var bridgeInstance: jobject?
    private let bridgeLock = NSLock()

    /// Ensure the RuntimeBridge class and INSTANCE are resolved.
    /// Must be called before any bridge method invocation.
    ///
    /// - Returns: true if the bridge is ready for method calls.
    public func ensureBridgeReady() -> Bool {
        bridgeLock.lock()
        defer { bridgeLock.unlock() }

        if bridgeInstance != nil { return true }

        guard let cls = findClass(name: JniHelper.bridgeClassName) else {
            print("[JniHelper] RuntimeBridge class not found")
            return false
        }

        // Kotlin `object` has a static INSTANCE field of type RuntimeBridge
        // Signature: Lcom/anymex/runtimehost/RuntimeBridge;
        guard let instanceFieldID = getStaticFieldID(
            cls: cls,
            name: "INSTANCE",
            sig: "Lcom/anymex/runtimehost/RuntimeBridge;"
        ) else {
            print("[JniHelper] RuntimeBridge.INSTANCE field not found")
            return false
        }

        guard let instance = getStaticObjectField(cls: cls, fieldID: instanceFieldID) else {
            print("[JniHelper] RuntimeBridge.INSTANCE is null")
            return false
        }

        bridgeClass = cls
        bridgeInstance = newGlobalRef(obj: instance)
        deleteLocalRef(obj: instance)

        print("[JniHelper] RuntimeBridge ready")
        return true
    }

    /// Call a method on the RuntimeBridge singleton.
    ///
    /// - Parameters:
    ///   - methodName: The method name on RuntimeBridge
    ///   - sig: JNI method signature
    ///   - args: jvalue arguments to pass
    /// - Returns: The result as a converted Swift value, or nil
    public func callBridgeMethod(methodName: String, sig: String, args: [jvalue] = []) -> Any? {
        guard ensureBridgeReady() else {
            print("[JniHelper] Bridge not ready for method: \(methodName)")
            return nil
        }

        bridgeLock.lock()
        let cls = bridgeClass!
        let instance = bridgeInstance!
        bridgeLock.unlock()

        // Determine if the method is static or instance
        // RuntimeBridge Kotlin object methods become instance methods on INSTANCE
        // Methods marked @JvmStatic also have static counterparts
        // We try instance method first, then static

        if let methodID = getMethodID(cls: cls, name: methodName, sig: sig) {
            let result = callObjectMethod(obj: instance, methodID: methodID, args: args)
            if let result = result {
                let swiftResult = javaObjectToSwift(result)
                deleteLocalRef(obj: result)
                return swiftResult
            }
            // Method returned null
            return nil
        }

        // Try as static method (for @JvmStatic methods)
        if let staticMethodID = getStaticMethodID(cls: cls, name: methodName, sig: sig) {
            let result = callStaticObjectMethod(cls: cls, methodID: staticMethodID, args: args)
            if let result = result {
                let swiftResult = javaObjectToSwift(result)
                deleteLocalRef(obj: result)
                return swiftResult
            }
            return nil
        }

        print("[JniHelper] Method not found: \(methodName) with sig \(sig)")
        return nil
    }

    /// Call a void method on the RuntimeBridge singleton.
    public func callBridgeVoidMethod(methodName: String, sig: String, args: [jvalue] = []) {
        guard ensureBridgeReady() else { return }

        bridgeLock.lock()
        let cls = bridgeClass!
        let instance = bridgeInstance!
        bridgeLock.unlock()

        if let methodID = getMethodID(cls: cls, name: methodName, sig: sig) {
            callVoidMethod(obj: instance, methodID: methodID, args: args)
            return
        }

        if let staticMethodID = getStaticMethodID(cls: cls, name: methodName, sig: sig) {
            callStaticVoidMethod(cls: cls, methodID: staticMethodID, args: args)
        }
    }

    /// Call a boolean-returning method on the RuntimeBridge singleton.
    public func callBridgeBooleanMethod(methodName: String, sig: String, args: [jvalue] = []) -> Bool? {
        guard ensureBridgeReady() else { return nil }

        bridgeLock.lock()
        let cls = bridgeClass!
        let instance = bridgeInstance!
        bridgeLock.unlock()

        // Try instance boolean method
        if let methodID = getMethodID(cls: cls, name: methodName, sig: sig) {
            guard let env = getEnv() else { return nil }
            let fn = getJniFunction(
                env: env, index: 55,
                as: (@convention(c) (JNIEnv?, jobject, jmethodID, UnsafeMutableRawPointer?) -> jboolean).self
            )
            let result: jboolean
            if args.isEmpty {
                result = fn(env, instance, methodID, nil)
            } else {
                let argBuffer = UnsafeMutableBufferPointer<jvalue>.allocate(capacity: args.count)
                for (i, arg) in args.enumerated() {
                    argBuffer[i] = arg
                }
                result = fn(env, instance, methodID, argBuffer.baseAddress)
                argBuffer.deallocate()
            }
            checkAndClearException(env: env, context: "callBridgeBooleanMethod(\(methodName))")
            return result != JNI_FALSE
        }

        // Try static boolean method
        if let staticMethodID = getStaticMethodID(cls: cls, name: methodName, sig: sig) {
            return callStaticBooleanMethod(cls: cls, methodID: staticMethodID, args: args)
        }

        return nil
    }

    /// Call initialize on the RuntimeBridge.
    /// On iOS, there is no Android Context, so we pass null for the context
    /// parameter. The bridge JAR should handle the null case gracefully.
    public func initializeBridge(settings: [String: Any?]?) {
        // RuntimeBridge.initialize(Context, Map<String, Any?>?)
        // On iOS we don't have an Android Context, so we pass null
        let sig = "(Landroid/content/Context;Ljava/util/Map;)V"

        // jvalue union: we need to pass null for Context and a Map for settings
        var args: [jvalue] = []

        // Null context
        var nullVal = jvalue()
        nullVal.l = nil
        args.append(nullVal)

        // Settings map — create a HashMap if we have settings
        if let settings = settings, !settings.isEmpty {
            if let mapObj = createJavaHashMap(from: settings) {
                var mapVal = jvalue()
                mapVal.l = mapObj
                args.append(mapVal)
                callBridgeVoidMethod(methodName: "initialize", sig: sig, args: args)
                deleteLocalRef(obj: mapObj)
            } else {
                var nullMapVal = jvalue()
                nullMapVal.l = nil
                args.append(nullMapVal)
                callBridgeVoidMethod(methodName: "initialize", sig: sig, args: args)
            }
        } else {
            var nullMapVal = jvalue()
            nullMapVal.l = nil
            args.append(nullMapVal)
            callBridgeVoidMethod(methodName: "initialize", sig: sig, args: args)
        }
    }

    // MARK: - Java Object Creation Helpers

    /// Create a java.util.HashMap from a Swift dictionary.
    public func createJavaHashMap(from dict: [String: Any?]) -> jobject {
        guard let env = getEnv() else { return nil }

        let hashMapClass = findClass(name: "java/util/HashMap")
        let initMethod = getMethodID(cls: hashMapClass, name: "<init>", sig: "()V")
        let putMethod = getMethodID(cls: hashMapClass, name: "put", sig: "(Ljava/lang/Object;Ljava/lang/Object;)Ljava/lang/Object;")

        guard let mapObj = newJavaObject(cls: hashMapClass, methodID: initMethod) else {
            return nil
        }

        for (key, value) in dict {
            let keyJStr = toJString(key)
            var keyVal = jvalue()
            keyVal.l = keyJStr

            let valueJObj: jobject?
            var valueVal = jvalue()

            if let strVal = value as? String {
                valueJObj = toJString(strVal)
            } else if let boolVal = value as? Bool {
                // Create Boolean object
                let boolClass = findClass(name: "java/lang/Boolean")
                let boolInit = getMethodID(cls: boolClass, name: "<init>", sig: "(Z)V")
                var zArg = jvalue(z: boolVal ? JNI_TRUE : JNI_FALSE)
                valueJObj = newJavaObject(cls: boolClass, methodID: boolInit, args: [zArg])
            } else if let intVal = value as? Int {
                let intClass = findClass(name: "java/lang/Integer")
                let intInit = getMethodID(cls: intClass, name: "<init>", sig: "(I)V")
                var iArg = jvalue(i: Int32(intVal))
                valueJObj = newJavaObject(cls: intClass, methodID: intInit, args: [iArg])
            } else if let dictVal = value as? [String: Any?] {
                valueJObj = createJavaHashMap(from: dictVal)
            } else if let listVal = value as? [Any?] {
                valueJObj = createJavaArrayList(from: listVal)
            } else {
                valueJObj = nil
            }

            valueVal.l = valueJObj

            callObjectMethod(obj: mapObj, methodID: putMethod, args: [keyVal, valueVal])

            if let k = keyJStr { deleteLocalRef(obj: k) }
            if let v = valueJObj { deleteLocalRef(obj: v) }
        }

        return mapObj
    }

    /// Create a java.util.ArrayList from a Swift array.
    public func createJavaArrayList(from array: [Any?]) -> jobject {
        guard let env = getEnv() else { return nil }

        let listClass = findClass(name: "java/util/ArrayList")
        let initMethod = getMethodID(cls: listClass, name: "<init>", sig: "()V")
        let addMethod = getMethodID(cls: listClass, name: "add", sig: "(Ljava/lang/Object;)Z")

        guard let listObj = newJavaObject(cls: listClass, methodID: initMethod) else {
            return nil
        }

        for element in array {
            let jObj: jobject?
            if let strVal = element as? String {
                jObj = toJString(strVal)
            } else if let dictVal = element as? [String: Any?] {
                jObj = createJavaHashMap(from: dictVal)
            } else if let listVal = element as? [Any?] {
                jObj = createJavaArrayList(from: listVal)
            } else {
                jObj = nil
            }

            var val = jvalue()
            val.l = jObj
            callObjectMethod(obj: listObj, methodID: addMethod, args: [val])
            if let o = jObj { deleteLocalRef(obj: o) }
        }

        return listObj
    }

    /// Allocate a new Java object.
    private func newJavaObject(cls: jclass?, methodID: jmethodID?, args: [jvalue] = []) -> jobject {
        guard let cls = cls, let methodID = methodID, let env = getEnv() else { return nil }
        let fnV = getJniFunction(
            env: env, index: 28,
            as: (@convention(c) (JNIEnv?, jclass, jmethodID, UnsafeMutableRawPointer?) -> jobject).self
        )

        let result: jobject
        if args.isEmpty {
            result = fnV(env, cls, methodID, nil)
        } else {
            let argBuffer = UnsafeMutableBufferPointer<jvalue>.allocate(capacity: args.count)
            for (i, arg) in args.enumerated() {
                argBuffer[i] = arg
            }
            result = fnV(env, cls, methodID, argBuffer.baseAddress)
            argBuffer.deallocate()
        }

        checkAndClearException(env: env, context: "newJavaObject")
        return result
    }

    // MARK: - Cleanup

    /// Release the cached RuntimeBridge references.
    public func cleanup() {
        bridgeLock.lock()
        if let instance = bridgeInstance {
            deleteGlobalRef(obj: instance)
            bridgeInstance = nil
        }
        bridgeClass = nil
        bridgeLock.unlock()

        threadLock.lock()
        threadEnvMap.removeAll()
        threadLock.unlock()
    }
}

// MARK: - jvalue Union

/// JNI jvalue union for passing arguments to variadic JNI methods.
/// Must match the C definition: typedef union jvalue { jboolean z; jbyte b; jchar c; jshort s; jint i; jlong j; jfloat f; jdouble d; jobject l; } jvalue;
public struct jvalue {
    public var z: jboolean = 0
    public var b: jbyte = 0
    public var c: jchar = 0
    public var s: jshort = 0
    public var i: jint = 0
    public var j: jlong = 0
    public var f: jfloat = 0
    public var d: jdouble = 0
    public var l: jobject? = nil

    public init() {}

    public init(z: jboolean) { self.z = z }
    public init(b: jbyte) { self.b = b }
    public init(c: jchar) { self.c = c }
    public init(s: jshort) { self.s = s }
    public init(i: jint) { self.i = i }
    public init(j: jlong) { self.j = j }
    public init(f: jfloat) { self.f = f }
    public init(d: jdouble) { self.d = d }
    public init(l: jobject?) { self.l = l }
}

// MARK: - Objective-C Compatibility Extension

/// Objective-C compatible convenience methods on JniHelper.
/// These methods accept NSObject types (NSString, NSDictionary, NSArray, NSNumber, NSNull)
/// and convert them to JNI types internally.
extension JniHelper {

    /// Call a RuntimeBridge method that returns an Object, using Foundation types.
    ///
    /// - Parameters:
    ///   - name: Method name on RuntimeBridge
    ///   - sig: JNI method signature
    ///   - args: Array of NSObject (NSString, NSNumber, NSDictionary, NSArray, NSNull)
    /// - Returns: Converted result as NSObject, or nil
    @objc public func callBridgeMethodObjC(_ name: String, signature sig: String, args: [Any]?) -> Any? {
        guard ensureBridgeReady() else { return nil }

        let jniArgs = convertToJValues(args)
        let result = callBridgeMethod(methodName: name, sig: sig, args: jniArgs)
        return convertToObjC(result)
    }

    /// Call a RuntimeBridge method that returns a boolean, using Foundation types.
    @objc public func callBridgeBooleanMethodObjC(_ name: String, signature sig: String, args: [Any]?) -> NSNumber? {
        guard ensureBridgeReady() else { return nil }

        let jniArgs = convertToJValues(args)
        let result = callBridgeBooleanMethod(methodName: name, sig: sig, args: jniArgs)
        guard let boolResult = result else { return nil }
        return NSNumber(value: boolResult)
    }

    /// Call a RuntimeBridge void method, using Foundation types.
    @objc public func callBridgeVoidMethodObjC(_ name: String, signature sig: String, args: [Any]?) {
        guard ensureBridgeReady() else { return }
        let jniArgs = convertToJValues(args)
        callBridgeVoidMethod(methodName: name, sig: sig, args: jniArgs)
    }

    /// Convert an array of NSObject to jvalue array for JNI calls.
    /// Handles: NSNull → null, String → jstring, Bool → jboolean,
    /// Int/NSNumber → jint/jlong, NSDictionary → HashMap, NSArray → ArrayList.
    private func convertToJValues(_ args: [Any]?) -> [jvalue] {
        guard let args = args else { return [] }
        return args.map { arg in convertToJValue(arg) }
    }

    /// Convert a single NSObject to jvalue.
    private func convertToJValue(_ arg: Any) -> jvalue {
        if arg is NSNull {
            return jvalue(l: nil)
        }
        if let str = arg as? String {
            return jvalue(l: toJString(str))
        }
        if let num = arg as? NSNumber {
            // Check the ObjC type to determine the right JNI type
            let objCType = String(cString: num.objCType)
            switch objCType {
            case "c", "B": // BOOL / signed char
                return jvalue(z: num.boolValue ? JNI_TRUE : JNI_FALSE)
            case "s": // short
                return jvalue(s: Int16(num.int16Value))
            case "i": // int
                return jvalue(i: num.int32Value)
            case "l", "q": // long / long long
                return jvalue(j: num.int64Value)
            case "f": // float
                return jvalue(f: num.floatValue)
            case "d": // double
                return jvalue(d: num.doubleValue)
            default:
                // Default to long
                return jvalue(j: num.int64Value)
            }
        }
        if let dict = arg as? [String: Any?] {
            let mapObj = createJavaHashMap(from: dict)
            return jvalue(l: mapObj)
        }
        if let array = arg as? [Any?] {
            let listObj = createJavaArrayList(from: array)
            return jvalue(l: listObj)
        }
        // Unknown type, pass as null
        return jvalue(l: nil)
    }

    /// Convert a Swift Any? (from JNI result) to an NSObject for ObjC.
    private func convertToObjC(_ value: Any?) -> Any? {
        guard let value = value else { return nil }
        if let str = value as? String { return str }
        if let num = value as? Int { return NSNumber(value: num) }
        if let num = value as? Double { return NSNumber(value: num) }
        if let num = value as? Float { return NSNumber(value: num) }
        if let bool = value as? Bool { return NSNumber(value: bool) }
        if let dict = value as? [String: Any?] {
            var result: [String: Any] = [:]
            for (k, v) in dict {
                result[k] = convertToObjC(v) ?? NSNull()
            }
            return result
        }
        if let array = value as? [Any?] {
            return array.map { convertToObjC($0) ?? NSNull() }
        }
        return value
    }
}
