import 'dart:io';
import 'package:flutter/services.dart';
import 'Logger.dart';
import 'Settings/KvStore.dart';
import 'Settings/AnymeXBridgeSettings.dart';
import 'Runtime/RuntimeDownloader.dart';
import 'Runtime/Bridge/BridgeDispatcher.dart';
import 'Runtime/RuntimeController.dart';
import 'Runtime/RuntimePaths.dart';
import 'dart:async';

class AnymeXRuntimeBridge {
  static const _channel = MethodChannel('anymeXBridge');

  static AnymeXBridgeSettings settings = AnymeXBridgeSettings();

  static final Map<String, String> cookiesMap = {};
  static final Map<String, String> userAgentMap = {};

  static bool get isSupportedPlatform => !Platform.isIOS;

  /// Setup the AnymeX Runtime Bridge (Android APK or Desktop JRE/JAR).
  /// This handles downloading, tracking progress, and initialization.
  /// Set [force] to true to re-download the Bridge JAR/APK (useful for updates).
  /// Note: The JRE is only downloaded if missing, regardless of [force].
  static Future<void> setupRuntime(
      {String? customDownloadUrl,
      bool force = false,
      String? localApkPath,
      AnymeXBridgeSettings? settings}) async {
    if (!isSupportedPlatform) return;
    if (settings != null) {
      AnymeXRuntimeBridge.settings = settings;
    }
    await RuntimeDownloader().setupRuntime(
        customUrl: customDownloadUrl, force: force, localApkPath: localApkPath);
  }

  /// Explicitly sets and loads a custom local APK.
  /// This path is persisted and will be used automatically on future app restarts.
  static Future<bool> useLocalApk(String path) async {
    if (!Platform.isAndroid) return false;
    final exists = await File(path).exists();
    if (!exists) {
      Logger.log("useLocalApk: File does not exist at $path");
      return false;
    }

    try {
      setVal('runtime_host_path', path);
    } catch (e) {
      Logger.log('Failed to save runtime host APK path to KvStore: $e');
    }

    return await loadAnymeXRuntimeHost(path);
  }

  /// Checks if the runtime files already exist and initializes the bridge if they do.
  /// Call this on app startup to auto-load the bridge.
  static Future<void> checkAndInitialize(
      {AnymeXBridgeSettings? settings}) async {
    if (!isSupportedPlatform) return;
    if (settings != null) {
      AnymeXRuntimeBridge.settings = settings;
    }

    final paths = RuntimePaths();

    String? savedPath;
    try {
      savedPath = getVal<String>('runtime_host_path');
    } catch (_) {}

    final bridgePath = (savedPath != null && await File(savedPath).exists())
        ? savedPath
        : await paths.bridgePath;

    final bridgeFile = File(bridgePath);
    bool exists = await bridgeFile.exists();

    if (!Platform.isAndroid) {
      final jreDir = await paths.jreDir;
      exists = exists && await jreDir.exists();
    }

    if (exists) {
      if (Platform.isAndroid) {
        await loadAnymeXRuntimeHost(bridgePath);
      } else {
        controller.setReady(true);
      }
      Logger.log(
          "AnymeX Bridge auto-detected and initialized from: $bridgePath");
    }
  }

  static RuntimeController get controller => RuntimeController.it;

  static Completer<bool>? _loadCompleter;

  /// Standard MethodChannel call for Android only
  static Future<bool> loadAnymeXRuntimeHost(String apkPath,
      {Map<String, dynamic>? settings}) async {
    if (!Platform.isAndroid) return false;

    if (_loadCompleter != null) {
      Logger.log("AnymeX Bridge is already loading, waiting for completion...");
      return _loadCompleter!.future;
    }

    _loadCompleter = Completer<bool>();

    final finalSettings = settings ?? AnymeXRuntimeBridge.settings.toJson();

    try {
      final result =
          await _channel.invokeMethod<bool>('loadAnymeXRuntimeHost', {
        'path': apkPath,
        'settings': finalSettings,
      });
      final bool isLoaded = result ?? false;

      if (isLoaded) {
        try {
          setVal('runtime_host_path', apkPath);
        } catch (e) {
          Logger.log('Failed to save runtime host APK path to KvStore: $e');
        }
      }

      _loadCompleter!.complete(isLoaded);
      return isLoaded;
    } catch (e) {
      print('Failed to load Runtime Host APK from $apkPath: $e');
      _loadCompleter?.complete(false);
      return false;
    } finally {
      _loadCompleter = null;
    }
  }

  /// Checks if the AnymeXBridgeHost is already loaded into memory.
  static Future<bool> isLoaded() async {
    if (Platform.isAndroid) {
      try {
        final result = await _channel.invokeMethod<bool>('isLoaded');
        return result ?? false;
      } catch (e) {
        return false;
      }
    }
    return controller.isReady.value;
  }

  /// Cancels an active request in the Runtime Host using its [token].
  static Future<bool> cancelRequest(String token) async {
    if (Platform.isAndroid) {
      try {
        final result = await _channel.invokeMethod<bool>('cancelRequest', {
          'token': token,
        });
        return result ?? false;
      } catch (e) {
        print('Failed to cancel request for token $token: $e');
        return false;
      }
    } else {
      return await BridgeDispatcher().cancelRequest(token);
    }
  }

  /// Pushes a set of cookies for the given [url] into the native OkHttp
  /// CookieJar used by all extensions (Aniyomi, CloudStream, Kotatsu).
  /// [url]          – origin URL the cookies belong to.
  /// [cookieString] – the raw `Set-Cookie` / `Cookie` header string,
  static Future<void> setCookies(String url, String cookieString) async {
    try {
      final host = Uri.parse(url).host;
      if (host.isNotEmpty) {
        cookiesMap[host] = cookieString;
      }
    } catch (_) {}
    if (!isSupportedPlatform) return;
    if (Platform.isAndroid) {
      try {
        await _channel.invokeMethod<void>('setCookies', {
          'url': url,
          'cookieString': cookieString,
        });
      } catch (e) {
        Logger.log('setCookies failed: $e');
      }
    } else {
      try {
        await BridgeDispatcher().invokeMethod('setCookies', {
          'url': url,
          'cookieString': cookieString,
        });
      } catch (e) {
        Logger.log('setCookies (desktop) failed: $e');
      }
    }
  }

  /// Updates the User-Agent that all extensions will use when making requests
  /// to the given [url]'s domain.
  /// [url]       – origin URL whose domain this UA should apply to.
  /// [userAgent] – the User-Agent string captured from the WebView solve.
  static Future<void> setUserAgent(String url, String userAgent) async {
    try {
      final host = Uri.parse(url).host;
      if (host.isNotEmpty) {
        userAgentMap[host] = userAgent;
      }
    } catch (_) {}
    if (!isSupportedPlatform) return;
    if (Platform.isAndroid) {
      try {
        await _channel.invokeMethod<void>('setUserAgent', {
          'url': url,
          'userAgent': userAgent,
        });
      } catch (e) {
        Logger.log('setUserAgent failed: $e');
      }
    } else {
      try {
        await BridgeDispatcher().invokeMethod('setUserAgent', {
          'url': url,
          'userAgent': userAgent,
        });
      } catch (e) {
        Logger.log('setUserAgent (desktop) failed: $e');
      }
    }
  }

  static String get installedVersion =>
      getVal<String>('runtime_host_installed_version', defaultValue: '') ?? '';
  static String get installedReleaseTitle =>
      getVal<String>('runtime_host_installed_release_title',
          defaultValue: '') ??
      '';
  static bool get isPluginInstalled => installedVersion.isNotEmpty;

  static void setInstalledRelease(String version, String title) {
    setVal('runtime_host_installed_version', version);
    setVal('runtime_host_installed_release_title', title);
  }
}
