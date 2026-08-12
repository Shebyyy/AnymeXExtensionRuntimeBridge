// JavaLauncher.swift
// AnymeX Extension Runtime Bridge — iOS Plugin
//
// Loads the embedded OpenJDK 8 JVM (from PojavLauncher) inside the iOS app
// bundle and starts it via JLI_Launch() through dlopen/dlsym.
//
// Architecture:
// 1. Locate libjli.dylib (and its dependency libjvm.dylib) inside the app bundle
// 2. dlopen libjli.dylib and resolve JLI_Launch symbol
// 3. Build C-style argv with all necessary JVM flags
// 4. Call JLI_Launch to start the JVM on the main thread
// 5. After JLI_Launch returns, the JVM is running and ready for JNI calls

import Foundation
import os.log

/// Callback types for status reporting.
public typealias LauncherStatusCallback = (_ status: LauncherStatus, _ message: String) -> Void

@objc public enum LauncherStatus: Int {
    case loading = 0
    case locatingJdk = 1
    case loadingDylibs = 2
    case launchingJvm = 3
    case ready = 4
    case error = 5
}

/// Manages the lifecycle of the embedded OpenJDK 8 JVM on iOS.
public class JavaLauncher: NSObject {

    // MARK: - Public State

    private var _isJvmRunning: Bool = false
    @objc public var isJvmRunning: Bool {
        return _isJvmRunning
    }
    public private(set) var javaHome: String = ""
    public private(set) var bridgeJarPath: String = ""

    // MARK: - Private State

    private var jliHandle: UnsafeMutableRawPointer?
    private var jvmHandle: UnsafeMutableRawPointer?
    private var jliLaunch: JLI_LaunchFunc?
    private var statusCallback: LauncherStatusCallback?
    private let launchLock = NSLock()
    private let queue = DispatchQueue(label: "com.anymex.javalauncher", qos: .userInitiated)

    /// Re-entry guard: JLI_Launch calls the process main() again after
    /// starting the JVM. We detect this via a file-level flag in main.swift.
    /// On iOS (Flutter), we don't control main.swift, so we use a static
    /// flag that persists across the JLI_Launch re-entry.
    public static var isReentry: Bool = false

    @objc public override init() { super.init() }

    // MARK: - Status Reporting

    public func onStatus(_ callback: LauncherStatusCallback?) {
        statusCallback = callback
    }

    private func report(_ status: LauncherStatus, _ message: String) {
        print("[JavaLauncher] \(status): \(message)")
        statusCallback?(status, message)
    }

    // MARK: - Public API

    /// Start the JVM with the given configuration.
    ///
    /// - Parameters:
    ///   - javaHome: Path to the bundled OpenJDK directory (containing lib/)
    ///   - bridgeJarPath: Path to the RuntimeBridge JAR file
    ///   - extraArgs: Additional JVM arguments
    /// - Returns: true if the JVM started successfully
    public func startJvm(javaHome: String, bridgeJarPath: String, extraArgs: [String] = []) -> Bool {
        launchLock.lock()
        defer { launchLock.unlock() }

        if isJvmRunning {
            report(.ready, "JVM is already running")
            return true
        }

        self.javaHome = javaHome
        self.bridgeJarPath = bridgeJarPath

        report(.loading, "Starting JVM launch sequence")

        // Step 1: Validate paths
        guard FileManager.default.fileExists(atPath: javaHome) else {
            report(.error, "Java home not found: \(javaHome)")
            return false
        }

        guard FileManager.default.fileExists(atPath: bridgeJarPath) else {
            report(.error, "Bridge JAR not found: \(bridgeJarPath)")
            return false
        }

        report(.locatingJdk, "Validating JDK at \(javaHome)")

        // Step 2: Locate required dylibs
        // PojavLauncher JRE8 layout:
        //   java-8-openjdk/lib/jli/libjli.dylib
        //   java-8-openjdk/lib/server/libjvm.dylib
        let libDir = (javaHome as NSString).appendingPathComponent("lib")
        let jliPath = (libDir as NSString).appendingPathComponent("jli/libjli.dylib")
        let jvmPath = (libDir as NSString).appendingPathComponent("server/libjvm.dylib")

        // Fallback locations for non-standard layouts
        let altJliFlat = (libDir as NSString).appendingPathComponent("libjli.dylib")
        let altJvmFlat = (libDir as NSString).appendingPathComponent("libjvm.dylib")
        let bundleJli = Bundle.main.bundlePath + "/Frameworks/libjli.dylib"
        let bundleJvm = Bundle.main.bundlePath + "/Frameworks/libjvm.dylib"
        let openjdkJli = Bundle.main.bundlePath + "/OpenJDK/lib/jli/libjli.dylib"
        let openjdkJvm = Bundle.main.bundlePath + "/OpenJDK/lib/server/libjvm.dylib"

        var effectiveJliPath = jliPath
        var effectiveJvmPath = jvmPath

        // Search for libjli.dylib in known locations
        for candidate in [jliPath, altJliFlat, bundleJli, openjdkJli] {
            if FileManager.default.fileExists(atPath: candidate) {
                effectiveJliPath = candidate
                break
            }
        }

        // Search for libjvm.dylib in known locations
        if !FileManager.default.fileExists(atPath: jvmPath) {
            for candidate in [jvmPath, altJvmFlat, bundleJvm, openjdkJvm] {
                if FileManager.default.fileExists(atPath: candidate) {
                    effectiveJvmPath = candidate
                    break
                }
            }
        }

        guard FileManager.default.fileExists(atPath: effectiveJliPath) else {
            report(.error, "libjli.dylib not found. Searched: \(jliPath)")
            return false
        }

        report(.loadingDylibs, "Found libjli.dylib at \(effectiveJliPath)")

        // Step 3: Load dylibs
        // Load libjvm.dylib first (dependency of libjli.dylib)
        if FileManager.default.fileExists(atPath: effectiveJvmPath) {
            jvmHandle = dlopen(effectiveJvmPath, RTLD_NOW | RTLD_GLOBAL)
            if jvmHandle == nil {
                let dlError = String(cString: dlerror())
                report(.error, "Failed to load libjvm.dylib: \(dlError)")
                return false
            }
            print("[JavaLauncher] Loaded libjvm.dylib from \(effectiveJvmPath)")
        }

        jliHandle = dlopen(effectiveJliPath, RTLD_NOW)
        if jliHandle == nil {
            let dlError = String(cString: dlerror())
            report(.error, "Failed to dlopen libjli.dylib: \(dlError)")
            return false
        }
        print("[JavaLauncher] Loaded libjli.dylib from \(effectiveJliPath)")

        // Step 4: Resolve JLI_Launch symbol
        guard let launchSym = dlsym(jliHandle, "JLI_Launch") else {
            let dlError = String(cString: dlerror())
            report(.error, "Failed to resolve JLI_Launch: \(dlError)")
            return false
        }
        jliLaunch = unsafeBitCast(launchSym, to: JLI_LaunchFunc.self)
        print("[JavaLauncher] Resolved JLI_Launch symbol")

        // Step 5: Build JVM arguments
        let frameworksPath = Bundle.main.privateFrameworksPath ?? Bundle.main.bundlePath
        let appSupportPath = NSSearchPathForDirectoriesInDomains(
            .applicationSupportDirectory, .userDomainMask, true
        ).first ?? "/tmp"
        let tmpDir = NSTemporaryDirectory()

        // The main class for the RuntimeBridge JAR — it just needs to exist.
        // The actual bridge communication happens via JNI after the JVM is up.
        let mainClass = "com.anymex.runtimehost.RuntimeBridge"

        var jvmArgs: [String] = [
            "\(javaHome)/bin/java",
            "-XstartOnFirstThread",          // CRITICAL for iOS
            "-Djava.library.path=\(frameworksPath)",
            "-Djava.class.path=\(bridgeJarPath)",
            "-Djna.boot.library.path=\(frameworksPath)",
            "-XX:+UnlockExperimentalVMOptions",
            "-XX:+DisablePrimordialThreadGuardPages",
            "-Djava.awt.headless=true",
            "-XX:-UseCompressedClassPointers",
            "-noverify",
            "-Dsun.java.launcher.is_javaw=true",  // Suppress exit() behavior
            "-Dios.working.dir=\(appSupportPath)",
            "-Djava.io.tmpdir=\(tmpDir)",
            "-Duser.home=\(appSupportPath)",
            "-Xmx256m",
            "-Xms32m",
            "-XX:MaxHeapFreeRatio=50",
            "-XX:MinHeapFreeRatio=10",
            "-XX:NewSize=16m",
            "-XX:MaxNewSize=64m",
            "-XX:+UseSerialGC",
            "-Dfile.encoding=UTF-8",
        ]

        // Add any extra args
        jvmArgs.append(contentsOf: extraArgs)

        // Append the main class as the last argument
        jvmArgs.append(mainClass)

        report(.launchingJvm, "Launching JVM with \(jvmArgs.count) arguments")
        print("[JavaLauncher] JVM args: \(jvmArgs)")

        // Step 6: Convert to C-style argv
        let cArgs = jvmArgs.map { $0.withCString { strdup($0) } }
        var cArgv = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: cArgs.count + 1)
        for (i, arg) in cArgs.enumerated() {
            cArgv[i] = arg
        }
        cArgv[cArgs.count] = nil

        defer {
            for arg in cArgs { free(arg) }
            cArgv.deallocate()
        }

        // Step 7: Launch JVM
        //
        // JLI_Launch signature:
        // int JLI_Launch(int argc, char **argv,
        //   int jargc, const char **jargv,
        //   int appclassc, const char **appclassv,
        //   const char *fullversion, const char *dotversion,
        //   const char *pname, const char *lname,
        //   const char *procname, const char *main_class,
        //   int always_detached,
        //   const char *lgname, const char *ljname,
        //   boolean useFullArgV)
        //
        // Most of these are optional. We pass NULL/0 for unused ones.
        // The critical ones are argc, argv, and main_class.

        let argc = Int32(cArgs.count)
        let mainClassCStr = (mainClass as NSString).utf8String

        JavaLauncher.isReentry = false

        print("[JavaLauncher] Calling JLI_Launch...")

        let launchResult = jliLaunch?(
            argc,
            cArgv,
            0,          // jargc
            nil,        // jargv
            0,          // appclassc
            nil,        // appclassv
            nil,        // fullversion
            nil,        // dotversion
            "java",     // pname
            "openjdk",  // lname
            "java",     // procname
            mainClassCStr,  // main_class
            0,          // always_detached
            nil,        // lgname
            nil,        // ljname
            1           // useFullArgV
        )

        let resultCode = launchResult ?? -1
        print("[JavaLauncher] JLI_Launch returned: \(resultCode)")
        print("[JavaLauncher] Re-entry detected: \(JavaLauncher.isReentry)")
        print("[JavaLauncher] Exit override intercepted: \(ExitOverride.shared.exitIntercepted)")

        // Check if the JVM started successfully.
        // JLI_Launch may return 0 on success or a positive value.
        // On PojavLauncher's build, it returns 0 after starting the JVM.
        // A return of -1 or negative typically means failure.
        // The JVM is considered running if JLI_Launch didn't crash
        // and the exit override wasn't triggered with a non-zero code.

        let jvmStarted = resultCode >= 0 && !ExitOverride.shared.exitIntercepted

        if jvmStarted {
            _isJvmRunning = true
            report(.ready, "JVM started successfully (result=\(resultCode))")
        } else {
            let exitInfo = ExitOverride.shared.exitIntercepted
                ? " (exit \(ExitOverride.shared.lastExitCode) intercepted)"
                : ""
            report(.error, "JVM failed to start (result=\(resultCode))\(exitInfo)")
        }

        return isJvmRunning
    }

    /// Start the JVM asynchronously and report status via callback.
    @objc public func startJvmAsync(
        javaHome: String,
        bridgeJarPath: String,
        extraArgs: [String],
        completion: @escaping (Bool) -> Void
    ) {
        queue.async { [weak self] in
            guard let self = self else {
                completion(false)
                return
            }
            let success = self.startJvm(
                javaHome: javaHome,
                bridgeJarPath: bridgeJarPath,
                extraArgs: extraArgs
            )
            DispatchQueue.main.async {
                completion(success)
            }
        }
    }

    /// Stop the JVM. On iOS, we can't truly destroy a JVM created via
    /// JLI_Launch, so we just mark it as stopped and clean up references.
    public func stopJvm() {
        launchLock.lock()
        defer { launchLock.unlock() }

        guard isJvmRunning else { return }

        print("[JavaLauncher] Stopping JVM...")

        // Note: We cannot call DestroyJavaVM here because we obtained the
        // JVM via JLI_Launch, not JNI_CreateJavaVM. The PojavLauncher
        // approach is to simply let the JVM be garbage collected when the
        // process exits. On iOS, the app lifecycle handles this.

        // Close dylib handles (this doesn't actually unload them on iOS
        // since they're RTLD_GLOBAL, but it's good practice)
        if let handle = jliHandle {
            dlclose(handle)
            jliHandle = nil
        }
        jvmHandle = nil
        jliLaunch = nil
        _isJvmRunning = false

        print("[JavaLauncher] JVM marked as stopped")
    }

    // MARK: - Bundle Discovery Helpers

    /// Search for the OpenJDK directory inside the app bundle.
    /// Checks several known locations where it might be bundled.
    ///
    /// - Returns: The path to the JDK directory, or nil if not found.
    @objc public static func findJavaHome() -> String? {
        let bundlePath = Bundle.main.bundlePath
        let frameworksPath = Bundle.main.privateFrameworksPath

        // Common locations to search for OpenJDK
        let searchPaths: [String] = [
            "\(bundlePath)/OpenJDK",
            "\(bundlePath)/java_home",
            "\(bundlePath)/Frameworks/OpenJDK",
            "\(bundlePath)/Frameworks/java_home",
            "\(frameworksPath ?? "")/OpenJDK",
            "\(frameworksPath ?? "")/java_home",
        ]

        // Check for lib/server/libjvm.dylib or lib/jli/libjli.dylib in each candidate
        // PojavLauncher layout: lib/jli/libjli.dylib + lib/server/libjvm.dylib
        for candidate in searchPaths {
            let libDir = (candidate as NSString).appendingPathComponent("lib")
            let jvmCheck1 = (libDir as NSString).appendingPathComponent("server/libjvm.dylib")
            let jvmCheck2 = (libDir as NSString).appendingPathComponent("libjvm.dylib")
            let jliCheck = (libDir as NSString).appendingPathComponent("jli/libjli.dylib")
            let jliCheckFlat = (libDir as NSString).appendingPathComponent("libjli.dylib")

            let hasJvm = FileManager.default.fileExists(atPath: jvmCheck1)
                || FileManager.default.fileExists(atPath: jvmCheck2)
            let hasJli = FileManager.default.fileExists(atPath: jliCheck)
                || FileManager.default.fileExists(atPath: jliCheckFlat)

            if hasJvm || hasJli {
                print("[JavaLauncher] Found JDK at: \(candidate)")
                return candidate
            }
        }

        // Also check if libjli.dylib is directly in Frameworks
        if let fw = frameworksPath {
            let directJli = (fw as NSString).appendingPathComponent("libjli.dylib")
            if FileManager.default.fileExists(atPath: directJli) {
                // The JDK libs are flat in Frameworks
                print("[JavaLauncher] Found JDK libs flat in Frameworks: \(fw)")
                return fw
            }
        }

        return nil
    }

    /// Search for the RuntimeBridge JAR inside the app bundle.
    ///
    /// - Returns: The path to the bridge JAR, or nil if not found.
    @objc public static func findBridgeJar() -> String? {
        let bundlePath = Bundle.main.bundlePath

        // Search for JAR files that might be the bridge
        let searchPaths: [String] = [
            "\(bundlePath)/Frameworks/runtime-bridge.jar",
            "\(bundlePath)/Frameworks/bridge.jar",
            "\(bundlePath)/runtime-bridge.jar",
            "\(bundlePath)/bridge.jar",
        ]

        for candidate in searchPaths {
            if FileManager.default.fileExists(atPath: candidate) {
                print("[JavaLauncher] Found bridge JAR at: \(candidate)")
                return candidate
            }
        }

        // Search more broadly in Frameworks for any JAR
        if let fwPath = Bundle.main.privateFrameworksPath {
            if let files = try? FileManager.default.contentsOfDirectory(atPath: fwPath) {
                for file in files {
                    if file.hasSuffix(".jar") && file.contains("bridge") {
                        let fullPath = (fwPath as NSString).appendingPathComponent(file)
                        print("[JavaLauncher] Found bridge JAR (search): \(fullPath)")
                        return fullPath
                    }
                    // Also accept any JAR that might contain RuntimeBridge
                    if file.hasSuffix(".jar") {
                        let fullPath = (fwPath as NSString).appendingPathComponent(file)
                        // Could be the one — we return the first JAR found
                        // as a fallback (the caller should know the exact name)
                    }
                }
            }
        }

        return nil
    }
}
