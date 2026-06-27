import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../Logger.dart';
import '../Settings/KvStore.dart';
import 'Bridge/RemoteSidecarBridge.dart';

/// Persistent settings for the remote AnymeX Bridge server.
///
/// On iOS (where the local JVM runtime can't run), the app connects to a
/// remote bridge server over SSH. This class persists:
///   - [host]      bridge server hostname (default: anymex.duckdns.org)
///   - [port]      bridge server SSH port (default: 3022)
///   - [username]  SSH username (default: 'anymex' — server ignores this,
///                 user identity comes from the public key fingerprint)
///   - [privateKeyPem] ed25519 SSH private key (PEM) — generated on first
///                 connect, persisted to platform Secure Storage so the
///                 user keeps the same identity across app launches.
///
/// The in-memory [RemoteBridgeConfig] (which holds a parsed [SSHKeyPair])
/// is built from this class via [toSSHConfig].
class RemoteBridgeSettings {
  static const _kHost = 'remote_bridge_host';
  static const _kPort = 'remote_bridge_port';
  static const _kUsername = 'remote_bridge_username';
  static const _kPrivateKey = 'remote_bridge_private_key';
  static const _kConnectedAt = 'remote_bridge_connected_at';

  static const _secureStorage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock),
  );

  /// Default bridge server (user can edit in settings).
  static const String defaultHost = 'anymex.duckdns.org';
  static const int defaultPort = 3022;
  static const String defaultUsername = 'anymex';

  final String host;
  final int port;
  final String username;
  final String? privateKeyPem;

  RemoteBridgeSettings({
    required this.host,
    required this.port,
    required this.username,
    this.privateKeyPem,
  });

  /// Load saved settings from KvStore + Secure Storage.
  /// Returns defaults if nothing is saved yet.
  static Future<RemoteBridgeSettings> load() async {
    String host =
        getVal<String>(_kHost, defaultValue: defaultHost) ?? defaultHost;
    int port = getVal<int>(_kPort, defaultValue: defaultPort) ?? defaultPort;
    String username = getVal<String>(_kUsername, defaultValue: defaultUsername) ??
        defaultUsername;

    if (port < 1 || port > 65535) port = defaultPort;
    if (host.trim().isEmpty) host = defaultHost;

    String? privateKeyPem;
    try {
      privateKeyPem = await _secureStorage.read(key: _kPrivateKey);
    } catch (e) {
      Logger.log('RemoteBridgeSettings: failed to read private key: $e');
    }

    return RemoteBridgeSettings(
      host: host,
      port: port,
      username: username,
      privateKeyPem: privateKeyPem,
    );
  }

  /// Whether a saved SSH key exists (i.e. user has connected before).
  Future<bool> get hasSavedKey async {
    try {
      final k = await _secureStorage.read(key: _kPrivateKey);
      return k != null && k.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  /// Persist host/port/username (NOT the key — key goes to Secure Storage).
  Future<void> save() async {
    setVal(_kHost, host);
    setVal(_kPort, port);
    setVal(_kUsername, username);
  }

  /// Persist a freshly generated/imported private key (PEM) to Secure Storage.
  Future<void> savePrivateKey(String pem) async {
    try {
      await _secureStorage.write(key: _kPrivateKey, value: pem);
    } catch (e) {
      Logger.log('RemoteBridgeSettings: failed to write private key: $e');
      rethrow;
    }
  }

  /// Forget the saved key (used by "Disconnect" button).
  Future<void> clearPrivateKey() async {
    try {
      await _secureStorage.delete(key: _kPrivateKey);
    } catch (e) {
      Logger.log('RemoteBridgeSettings: failed to delete private key: $e');
    }
  }

  /// Mark the time of last successful connection (for UI display).
  Future<void> markConnected() async {
    setVal(_kConnectedAt, DateTime.now().millisecondsSinceEpoch);
  }

  /// Last successful connection time, or null.
  DateTime? get lastConnectedAt {
    final ms = getVal<int>(_kConnectedAt);
    if (ms == null || ms == 0) return null;
    try {
      return DateTime.fromMillisecondsSinceEpoch(ms);
    } catch (_) {
      return null;
    }
  }

  /// Build the in-memory config for passing to RemoteSidecarBridge.configure().
  /// Returns null if no private key is saved.
  RemoteBridgeConfig? toSSHConfig() {
    if (privateKeyPem == null || privateKeyPem!.isEmpty) return null;
    return RemoteBridgeConfig.fromPem(
      host: host,
      port: port,
      username: username,
      privateKeyPem: privateKeyPem!,
    );
  }

  /// Serialise for logging/debugging. Never includes the private key.
  Map<String, dynamic> toRedactedJson() => {
        'host': host,
        'port': port,
        'username': username,
        'hasPrivateKey': privateKeyPem != null && privateKeyPem!.isNotEmpty,
      };

  @override
  String toString() =>
      'RemoteBridgeSettings(${jsonEncode(toRedactedJson())})';

  RemoteBridgeSettings copyWith({
    String? host,
    int? port,
    String? username,
    String? privateKeyPem,
    bool clearKey = false,
  }) {
    return RemoteBridgeSettings(
      host: host ?? this.host,
      port: port ?? this.port,
      username: username ?? this.username,
      privateKeyPem:
          clearKey ? null : (privateKeyPem ?? this.privateKeyPem),
    );
  }

  // Helper so unit tests can poke the secure-storage layer directly.
  static Future<String?> readSecure(String key) async {
    try {
      return await _secureStorage.read(key: key);
    } on PlatformException catch (e) {
      Logger.log('RemoteBridgeSettings.readSecure($key): ${e.message}');
      return null;
    }
  }

  static Future<void> writeSecure(String key, String value) async {
    try {
      await _secureStorage.write(key: key, value: value);
    } on PlatformException catch (e) {
      Logger.log('RemoteBridgeSettings.writeSecure($key): ${e.message}');
      rethrow;
    }
  }
}
