import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import '../../Logger.dart';

// FFI type definitions
/// int32_t anymex_ios_jvm_init(const char* classpath)
typedef _IosJvmInitNative = Int32 Function(Pointer<Utf8> classpath);
typedef _IosJvmInitDart = int Function(Pointer<Utf8> classpath);

/// const char* anymex_ios_jvm_call(const char* method, const char* argsJson)
typedef _IosJvmCallNative = Pointer<Utf8> Function(Pointer<Utf8> method, Pointer<Utf8> argsJson);
typedef _IosJvmCallDart = Pointer<Utf8> Function(Pointer<Utf8> method, Pointer<Utf8> argsJson);

/// void anymex_ios_jvm_destroy()
typedef _IosJvmDestroyNative = Void Function();
typedef _IosJvmDestroyDart = void Function();

/// bool anymex_ios_jvm_is_initialized()
typedef _IosJvmIsInitializedNative = Bool Function();
typedef _IosJvmIsInitializedDart = bool Function();

/// int32_t anymex_ios_jvm_set_cookies(const char* url, const char* cookieString)
typedef _IosJvmSetCookiesNative = Int32 Function(Pointer<Utf8> url, Pointer<Utf8> cookieString);
typedef _IosJvmSetCookiesDart = int Function(Pointer<Utf8> url, Pointer<Utf8> cookieString);

/// int32_t anymex_ios_jvm_set_user_agent(const char* url, const char* userAgent)
typedef _IosJvmSetUserAgentNative = Int32 Function(Pointer<Utf8> url, Pointer<Utf8> userAgent);
typedef _IosJvmSetUserAgentDart = int Function(Pointer<Utf8> url, Pointer<Utf8> userAgent);

/// int32_t anymex_ios_jvm_set_property(const char* key, const char* value)
typedef _IosJvmSetPropertyNative = Int32 Function(Pointer<Utf8> key, Pointer<Utf8> value);
typedef _IosJvmSetPropertyDart = int Function(Pointer<Utf8> key, Pointer<Utf8> value);

/// const char* anymex_ios_jvm_get_property(const char* key)
typedef _IosJvmGetPropertyNative = Pointer<Utf8> Function(Pointer<Utf8> key);
typedef _IosJvmGetPropertyDart = Pointer<Utf8> Function(Pointer<Utf8> key);

/// const char* anymex_ios_jvm_get_last_error()
typedef _IosJvmGetLastErrorNative = Pointer<Utf8> Function();
typedef _IosJvmGetLastErrorDart = Pointer<Utf8> Function();

class IosFfiBridge {
  static final IosFfiBridge _instance = IosFfiBridge._internal();
  factory IosFfiBridge() => _instance;
  IosFfiBridge._internal();

  bool _initialized = false;
  late DynamicLibrary _lib;

  // FFI function pointers
  late _IosJvmInitDart _init;
  late _IosJvmCallDart _call;
  late _IosJvmDestroyDart _destroy;
  late _IosJvmIsInitializedDart _isInitialized;
  late _IosJvmSetCookiesDart _setCookies;
  late _IosJvmSetUserAgentDart _setUserAgent;
  late _IosJvmSetPropertyDart _setProperty;
  late _IosJvmGetPropertyDart _getProperty;
  late _IosJvmGetLastErrorDart _getLastError;

  /// Load FFI symbols from the process (statically linked)
  void _loadSymbols() {
    _lib = DynamicLibrary.process();

    _init = _lib.lookupFunction<_IosJvmInitNative, _IosJvmInitDart>('anymex_ios_jvm_init');
    _call = _lib.lookupFunction<_IosJvmCallNative, _IosJvmCallDart>('anymex_ios_jvm_call');
    _destroy = _lib.lookupFunction<_IosJvmDestroyNative, _IosJvmDestroyDart>('anymex_ios_jvm_destroy');
    _isInitialized = _lib.lookupFunction<_IosJvmIsInitializedNative, _IosJvmIsInitializedDart>('anymex_ios_jvm_is_initialized');
    _setCookies = _lib.lookupFunction<_IosJvmSetCookiesNative, _IosJvmSetCookiesDart>('anymex_ios_jvm_set_cookies');
    _setUserAgent = _lib.lookupFunction<_IosJvmSetUserAgentNative, _IosJvmSetUserAgentDart>('anymex_ios_jvm_set_user_agent');
    _setProperty = _lib.lookupFunction<_IosJvmSetPropertyNative, _IosJvmSetPropertyDart>('anymex_ios_jvm_set_property');
    _getProperty = _lib.lookupFunction<_IosJvmGetPropertyNative, _IosJvmGetPropertyDart>('anymex_ios_jvm_get_property');
    _getLastError = _lib.lookupFunction<_IosJvmGetLastErrorNative, _IosJvmGetLastErrorDart>('anymex_ios_jvm_get_last_error');
  }

  /// Initialize the iOS JVM with the given classpath.
  /// [classpath] should be a colon-separated list of JAR paths and directories.
  Future<void> initialize(String classpath) async {
    if (_initialized) return;

    _loadSymbols();

    Logger.log('[IosFfiBridge] Initializing JVM...');
    Logger.log('[IosFfiBridge] Classpath: $classpath');

    final classpathPtr = classpath.toNativeUtf8();
    try {
      final result = _init(classpathPtr);
      if (result == 0) {
        _initialized = true;
        Logger.log('[IosFfiBridge] JVM initialized successfully.');
      } else {
        final error = _getLastErrorUft8();
        throw StateError('Failed to initialize iOS JVM (code: $result). Error: $error');
      }
    } finally {
      malloc.free(classpathPtr);
    }
  }

  String _getLastErrorUft8() {
    try {
      final ptr = _getLastError();
      if (ptr.address == 0) return 'Unknown error';
      return ptr.toDartString();
    } catch (e) {
      return 'Failed to get error: $e';
    }
  }

  /// Invoke a method on the IosExtensionLoader Java class.
  /// [method] is the Java method name (e.g. 'loadExtensions', 'getPopular').
  /// [args] is a map that will be JSON-serialized and passed to the Java side.
  Future<dynamic> invokeMethod(String method, Map<String, dynamic> args, {
    Duration timeout = const Duration(seconds: 120),
  }) async {
    if (!_initialized) {
      throw StateError('IosFfiBridge is not initialized. Call initialize() first.');
    }

    // Run in an isolate to avoid blocking the UI thread
    return await Isolate.run(() => _invokeMethodIsolate(method, args, timeout));
  }

  /// Isolate-safe invocation - each isolate calls FFI directly (static linking works across isolates)
  Future<dynamic> _invokeMethodIsolate(
    String method,
    Map<String, dynamic> args,
    Duration timeout,
  ) async {
    // Re-lookup symbols in this isolate's context
    _loadSymbols();

    final methodPtr = method.toNativeUtf8();
    final argsPtr = jsonEncode(args).toNativeUtf8();

    try {
      final resultPtr = _call(methodPtr, argsPtr);

      if (resultPtr.address == 0) {
        final error = _getLastErrorUft8();
        throw StateError('IosFfiBridge.call returned null for method "$method". Error: $error');
      }

      final resultJson = resultPtr.toDartString();

      // Parse the result - Java side returns JSON
      try {
        return jsonDecode(resultJson);
      } catch (e) {
        // If it's not valid JSON, return as plain string
        return resultJson;
      }
    } finally {
      malloc.free(methodPtr);
      malloc.free(argsPtr);
    }
  }

  /// Set cookies for a URL in the JVM's cookie store.
  Future<void> setCookies(String url, String cookieString) async {
    if (!_initialized) return;

    final urlPtr = url.toNativeUtf8();
    final cookiePtr = cookieString.toNativeUtf8();
    try {
      final result = _setCookies(urlPtr, cookiePtr);
      if (result != 0) {
        Logger.log('[IosFfiBridge] setCookies failed: $result');
      }
    } finally {
      malloc.free(urlPtr);
      malloc.free(cookiePtr);
    }
  }

  /// Set User-Agent for a URL in the JVM's HTTP config.
  Future<void> setUserAgent(String url, String userAgent) async {
    if (!_initialized) return;

    final urlPtr = url.toNativeUtf8();
    final uaPtr = userAgent.toNativeUtf8();
    try {
      final result = _setUserAgent(urlPtr, uaPtr);
      if (result != 0) {
        Logger.log('[IosFfiBridge] setUserAgent failed: $result');
      }
    } finally {
      malloc.free(urlPtr);
      malloc.free(uaPtr);
    }
  }

  /// Set a Java system property.
  Future<void> setProperty(String key, String value) async {
    if (!_initialized) return;

    final keyPtr = key.toNativeUtf8();
    final valPtr = value.toNativeUtf8();
    try {
      _setProperty(keyPtr, valPtr);
    } finally {
      malloc.free(keyPtr);
      malloc.free(valPtr);
    }
  }

  /// Get a Java system property.
  String? getProperty(String key) {
    if (!_initialized) return null;

    final keyPtr = key.toNativeUtf8();
    try {
      final ptr = _getProperty(keyPtr);
      if (ptr.address == 0) return null;
      return ptr.toDartString();
    } finally {
      malloc.free(keyPtr);
    }
  }

  /// Check if the JVM is initialized.
  bool checkInitialized() {
    try {
      _loadSymbols();
      return _isInitialized();
    } catch (e) {
      return false;
    }
  }

  /// Destroy the JVM and clean up.
  void dispose() {
    if (_initialized) {
      try {
        _destroy();
        Logger.log('[IosFfiBridge] JVM destroyed.');
      } catch (e) {
        Logger.log('[IosFfiBridge] Error destroying JVM: $e');
      }
      _initialized = false;
    }
  }
}
