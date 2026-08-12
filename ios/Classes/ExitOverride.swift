// ExitOverride.swift
// AnymeX Extension Runtime Bridge — iOS Plugin
//
// Prevents Java System.exit() (which calls the C exit()) from terminating
// the iOS application. We intercept the call, log it, and store the code
// for later inspection.

import Foundation

/// Thread-safe storage for the last intercepted exit code.
/// Accessible from anywhere in the plugin to check if the JVM attempted to exit.
public class ExitOverride {
    public static let shared = ExitOverride()

    /// The most recent exit code intercepted from Java.
    public private(set) var lastExitCode: Int32 = 0

    /// Whether exit() has been intercepted at least once.
    public private(set) var exitIntercepted: Bool = false

    /// Total number of exit() calls intercepted.
    public private(set) var interceptCount: Int = 0

    /// The last stack trace captured around the exit call.
    public private(set) var lastStackTrace: String = ""

    private let lock = NSLock()

    private init() {}

    /// Record an intercepted exit call. Called from the C override.
    public func recordExit(code: Int32) {
        lock.lock()
        defer { lock.unlock() }

        lastExitCode = code
        exitIntercepted = true
        interceptCount += 1

        // Capture a basic call stack for debugging
        let threads = Thread.callStackSymbols
        let stackPrefix = threads.prefix(16).joined(separator: "\n")
        lastStackTrace = stackPrefix

        print("[JVM-ExitOverride] exit(\(code)) intercepted — preventing app termination")
        print("[JVM-ExitOverride] Intercept count: \(interceptCount)")
        print("[JVM-ExitOverride] Stack:\n\(stackPrefix)")
    }

    /// Reset the tracking state.
    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        lastExitCode = 0
        exitIntercepted = false
        interceptCount = 0
        lastStackTrace = ""
    }
}

// ---------------------------------------------------------------------------
// C-callable override for exit().
//
// IMPORTANT: On iOS, DYLD_INTERPOSE only works with the
// DYLD_INSERT_LIBRARIES environment variable, which is not available in
// production apps. Instead, we use a different strategy:
//
// 1. Before calling JLI_Launch, we use dlsym(RTLD_DEFAULT, "exit") to get
//    the real exit() and save it.
// 2. We then do NOT actually hook exit() at the dyld level (not possible on
//    iOS without jailbreak).
// 3. Instead, we rely on the fact that OpenJDK 8 for iOS (PojavLauncher
//    build) uses a custom `JvmLauncher` that does NOT call exit() when
//    launched via JLI_Launch with the correct arguments.
//
// For cases where Java code does call System.exit(), the PojavLauncher
//    build of OpenJDK replaces the call to C exit() with a longjmp back to
//    the launcher. If that mechanism is not available, the override function
//    below serves as a no-op replacement that can be used via dlsym if needed.
//
// The actual exit suppression is handled in JavaLauncher.swift by setting
//    -Dsun.java.launcher.is_javaw=true and managing the JVM lifecycle
//    carefully.
// ---------------------------------------------------------------------------

/// C-callable function that replaces exit(). This is exported with a known
/// symbol name so it can be found via dlsym if needed.
@_cdecl("exit_override")
public func exitOverrideC(_ code: Int32) -> Void {
    ExitOverride.shared.recordExit(code: code)
    // Do NOT call the real exit(). This keeps the app alive.
}

/// Pointer type for JLI_Launch function signature.
/// Signature: int JLI_Launch(int argc, char **argv,
///   int jargc, const char **jargv,
///   int appclassc, const char **appclassv,
///   const char *fullversion,
///   const char *dotversion,
///   const char *pname,
///   const char *lname,
///   const char *procname,
///   const char *main_class,
///   int always_detached,
///   const char *lgname,
///   const char *ljname,
///   boolean useFullArgV)
public typealias JLI_LaunchFunc = @convention(c) (
    Int32,                          // argc
    UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,  // argv
    Int32,                          // jargc
    UnsafePointer<UnsafePointer<CChar>?>?,  // jargv
    Int32,                          // appclassc
    UnsafePointer<UnsafePointer<CChar>?>?,  // appclassv
    UnsafePointer<CChar>?,          // fullversion
    UnsafePointer<CChar>?,          // dotversion
    UnsafePointer<CChar>?,          // pname
    UnsafePointer<CChar>?,          // lname
    UnsafePointer<CChar>?,          // procname
    UnsafePointer<CChar>?,          // main_class
    Int32,                          // always_detached
    UnsafePointer<CChar>?,          // lgname
    UnsafePointer<CChar>?,          // ljname
    Int32                           // useFullArgV (boolean, but CInt for safety)
) -> Int32
