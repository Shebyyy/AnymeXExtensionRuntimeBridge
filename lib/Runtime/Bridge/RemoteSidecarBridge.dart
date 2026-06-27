import 'dart:async';
import 'dart:convert';
// RemoteSidecarBridge.dart — drop-in replacement for SidecarBridge.dart
//
// WHAT THIS FILE DOES
// -------------------
// Replaces the local `java -jar bridge.jar` subprocess with a remote SSH
// exec channel. iOS (and desktop) connect to an AnymeX Bridge Server
// (mini-services/anymex-bridge) that runs the JAR for them.
//
// WHY
// ---
// iOS cannot run a JVM. By moving the JAR to a server and talking to it
// over SSH, iOS gets full Aniyomi + CloudStream extension support.
//
// WIRE PROTOCOL (one JSON object per line over an SSH exec channel)
// -----------------------------------------------------------------
// iOS -> server:
//   {"id":"<reqId>","action":"hello"|"addRepo"|"removeRepo"|"listRepos"|
//    "listAvailable"|"listInstalled"|"install"|"uninstall"|"invoke"|
//    "invokeStream"|"cancel","payload":{...}}
//
// server -> iOS:
//   {"id":"<reqId>","status":"ok"|"error"|"partial"|"completed"|"log",
//    "data":...,"error":"..."}
//
// AUTHENTICATION
// --------------
// The user's SSH public key fingerprint IS their user identity on the
// server. The server uses BYO-key model: any key is accepted and mapped
// to a user record (created on first connect).
//
// INSTALLATION (pubspec.yaml)
// ---------------------------
//   dependencies:
//     dartssh2: ^2.9.6
//
// USAGE
// -----
// Replace `SidecarBridge` with `RemoteSidecarBridge` in your DI graph.
// Configure once at app start:
//
//   await RemoteSidecarBridge().configure(
//     host: 'bridge.example.com',
//     port: 3022,
//     username: 'anymex',  // ignored by server, but required by SSH
//     keyPair: myKeyPair,  // dartssh2 SSHKeyPair (load from secure storage)
//   );
//
// Then call the same methods as the old SidecarBridge:
//   await bridge.initialize('/path/irrelevant');  // kept for API compat
//   await bridge.invokeMethod('search', {...});
//   bridge.invokeStreamMethod('loadVideos', {...});
//
// MANAGEMENT ACTIONS (new API, not in local SidecarBridge):
//   await bridge.addRepo('https://repo.example.com/index.min.json');
//   await bridge.removeRepo(url);
//   await bridge.listRepos();
//   await bridge.listAvailable();
//   await bridge.listInstalled();
//   await bridge.install('gogoanime', repoUrl);
//   await bridge.uninstall('gogoanime');

import 'package:dartssh2/dartssh2.dart';

/// Configuration for connecting to a remote AnymeX Bridge server.
///
/// Pass EITHER a pre-parsed [keyPair] (for callers that already have one)
/// OR a [privateKeyPem] string (PEM text loaded from secure storage).
/// If both are provided, [keyPair] wins.
class RemoteBridgeConfig {
  final String host;
  final int port;
  final String username;
  final SSHKeyPair? keyPair;
  final String? privateKeyPem;
  final Duration connectTimeout;

  const RemoteBridgeConfig({
    required this.host,
    required this.port,
    required this.username,
    SSHKeyPair? keyPair,
    this.privateKeyPem,
    this.connectTimeout = const Duration(seconds: 15),
  }) : keyPair = keyPair;

  /// Construct from a PEM string. The actual parse into an [SSHKeyPair]
  /// happens lazily inside [RemoteSidecarBridge.configure].
  factory RemoteBridgeConfig.fromPem({
    required String host,
    required int port,
    required String username,
    required String privateKeyPem,
    Duration connectTimeout = const Duration(seconds: 15),
  }) {
    return RemoteBridgeConfig(
      host: host,
      port: port,
      username: username,
      privateKeyPem: privateKeyPem,
      connectTimeout: connectTimeout,
    );
  }
}

class RemoteSidecarBridge {
  static final RemoteSidecarBridge _instance = RemoteSidecarBridge._internal();
  factory RemoteSidecarBridge() => _instance;
  RemoteSidecarBridge._internal();

  SSHClient? _client;
  SSHSession? _session;
  StreamController<String>? _incomingLines;
  final _completers = <String, Completer<dynamic>>{};
  final _streamControllers = <String, StreamController<dynamic>>{};
  bool _initialized = false;
  int _requestId = 0;
  RemoteBridgeConfig? _config;

  /// Connect to the bridge server and open a persistent exec channel.
  Future<void> configure(RemoteBridgeConfig config) async {
    if (_initialized && _config == config) return;
    _config = config;

    // Resolve the SSHKeyPair: either the caller passed one in, or we parse
    // the PEM string now.
    final SSHKeyPair keyPair;
    if (config.keyPair != null) {
      keyPair = config.keyPair!;
    } else if (config.privateKeyPem != null &&
        config.privateKeyPem!.isNotEmpty) {
      // dartssh2 2.10+: SSHKeyPair.fromPem returns List<SSHKeyPair>
      // (a single PEM can contain multiple keys). We take the first.
      final parsed = SSHKeyPair.fromPem(config.privateKeyPem!);
      if (parsed.isEmpty) {
        throw StateError('Failed to parse any SSH key from privateKeyPem');
      }
      keyPair = parsed.first;
    } else {
      throw StateError(
        'RemoteBridgeConfig needs either keyPair or privateKeyPem',
      );
    }

    final socket = await SSHSocket.connect(
      config.host,
      config.port,
      timeout: config.connectTimeout,
    );
    _client = SSHClient(
      socket,
      username: config.username,
      identities: [keyPair],
      // Server uses BYO-key model: accept any host key the first time.
      // For production, ship a pinned host key fingerprint.
      disableHostkeyVerification: true,
    );

    // Open ONE exec channel for the whole app lifetime. The server treats
    // any command as "start bridge protocol"; we send an empty string.
    _session = await _client!.execute('anymex-bridge');

    // Split the stdout stream into line-delimited JSON.
    _incomingLines = StreamController<String>();
    _session!.stdout
        .cast<List<int>>()
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .listen(_handleResponse, onError: (e) => print('[remote-bridge] stdout err: $e'));

    _session!.stderr
        .cast<List<int>>()
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .listen((line) => print('[remote-bridge] [server] $line'));

    _initialized = true;

    // Ping to make sure the channel is alive.
    try {
      await invokeBridgeAction('hello', {}).timeout(const Duration(seconds: 5));
    } catch (e) {
      print('[remote-bridge] hello failed (non-fatal): $e');
    }
  }

  /// API-compat with SidecarBridge.initialize(). Path is ignored — the
  /// server manages the JAR location itself.
  Future<void> initialize(String bridgeJarPath) async {
    if (!_initialized) {
      throw StateError('RemoteSidecarBridge not configured. Call configure() first.');
    }
  }

  bool get isInitialized => _initialized;

  /// Send a management action (addRepo/install/etc.) and await the single
  /// response. Returns the `data` field of the response, or throws on error.
  Future<dynamic> invokeBridgeAction(
    String action,
    Map<String, dynamic> payload, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final id = (_requestId++).toString();
    final completer = Completer<dynamic>();
    _completers[id] = completer;

    _send({'id': id, 'action': action, 'payload': payload});

    return completer.future.timeout(timeout, onTimeout: () {
      _completers.remove(id);
      throw TimeoutException('Action "$action" (id: $id) timed out', timeout);
    });
  }

  /// Same shape as SidecarBridge.invokeMethod — but wraps the inner JAR
  /// request inside an `invoke` envelope so the server can install-gate.
  Future<dynamic> invokeMethod(
    String method,
    Map<String, dynamic> args, {
    Duration timeout = const Duration(seconds: 60),
  }) async {
    _ensureReady();

    final parameters = args['parameters'] as Map?;
    final token = parameters?['token'] as String?;
    final id = token ?? (_requestId++).toString();
    final extId = args['extId'] as String? ?? args['extensionId'] as String?;

    final completer = Completer<dynamic>();
    _completers[id] = completer;

    _send({
      'id': id,
      'action': 'invoke',
      'payload': {
        'extId': extId,
        'method': method,
        'args': args,
        'innerId': id,
      },
    });

    return completer.future.timeout(timeout, onTimeout: () {
      _completers.remove(id);
      // Best-effort cancel on the server side
      _send({
        'id': (_requestId++).toString(),
        'action': 'cancel',
        'payload': {'innerId': id},
      });
      throw TimeoutException(
        'Remote invoke "$method" (id: $id) timed out after ${timeout.inSeconds}s',
        timeout,
      );
    });
  }

  /// Same shape as SidecarBridge.invokeStreamMethod — wraps the request
  /// inside an `invokeStream` envelope.
  Stream<dynamic> invokeStreamMethod(String method, Map<String, dynamic> args) {
    _ensureReady();

    final parameters = args['parameters'] as Map?;
    final token = parameters?['token'] as String?;
    final id = token ?? (_requestId++).toString();
    final extId = args['extId'] as String? ?? args['extensionId'] as String?;

    final controller = StreamController<dynamic>();
    _streamControllers[id] = controller;

    _send({
      'id': id,
      'action': 'invokeStream',
      'payload': {
        'extId': extId,
        'method': method,
        'args': args,
        'innerId': id,
      },
    });

    return controller.stream;
  }

  // ----------------------------------------------------------------
  // Management API (new — replaces local ExtensionManager logic that
  // previously touched the local filesystem).
  // ----------------------------------------------------------------

  Future<void> addRepo(String repoUrl) async {
    await invokeBridgeAction('addRepo', {'repoUrl': repoUrl});
  }

  Future<void> removeRepo(String repoUrl) async {
    await invokeBridgeAction('removeRepo', {'repoUrl': repoUrl});
  }

  Future<List<Map<String, dynamic>>> listRepos() async {
    final res = await invokeBridgeAction('listRepos', {});
    return (res['repos'] as List?)?.cast<Map<String, dynamic>>() ?? [];
  }

  Future<List<Map<String, dynamic>>> listAvailable() async {
    final res = await invokeBridgeAction('listAvailable', {});
    return (res['extensions'] as List?)?.cast<Map<String, dynamic>>() ?? [];
  }

  Future<List<Map<String, dynamic>>> listInstalled() async {
    final res = await invokeBridgeAction('listInstalled', {});
    return (res['extensions'] as List?)?.cast<Map<String, dynamic>>() ?? [];
  }

  Future<void> install(String extId, String repoUrl) async {
    await invokeBridgeAction('install', {'extId': extId, 'repoUrl': repoUrl});
  }

  Future<void> uninstall(String extId) async {
    await invokeBridgeAction('uninstall', {'extId': extId});
  }

  // ----------------------------------------------------------------
  // Internals
  // ----------------------------------------------------------------

  void _ensureReady() {
    if (!_initialized || _session == null) {
      throw StateError('RemoteSidecarBridge is not initialized.');
    }
  }

  void _send(Map<String, dynamic> request) {
    final line = jsonEncode(request);
    _session!.stdin.add(utf8.encode('$line\n'));
  }

  void _handleResponse(String line) {
    if (line.isEmpty) return;
    try {
      final response = jsonDecode(line) as Map<String, dynamic>;
      final id = response['id']?.toString();
      final status = response['status']?.toString();
      final data = response['data'];
      final error = response['error']?.toString();

      if (id == null) return;

      if (_completers.containsKey(id)) {
        if (status == 'ok' || status == 'completed') {
          _completers.remove(id)!.complete(data);
        } else if (status == 'error') {
          _completers.remove(id)!.completeError(error ?? 'Unknown error');
        } else if (status == 'partial' || status == 'log') {
          // Swallow for non-stream invokes; could log if you want.
        }
      } else if (_streamControllers.containsKey(id)) {
        final controller = _streamControllers[id]!;
        if (status == 'completed') {
          _streamControllers.remove(id)!.close();
        } else if (status == 'error') {
          _streamControllers.remove(id)!.addError(error ?? 'Unknown error');
        } else {
          controller.add(data);
        }
      }
    } catch (e) {
      print('[remote-bridge] failed to decode response: $line');
    }
  }

  Future<bool> cancelRequest(String id) async {
    _completers.remove(id)?.completeError('Request cancelled');
    _streamControllers.remove(id)?.addError('Request cancelled');
    _streamControllers.remove(id)?.close();

    final payload = {
      'id': (_requestId++).toString(),
      'action': 'cancel',
      'payload': {'innerId': id},
    };
    _send(payload);
    return true;
  }

  void dispose() {
    _incomingLines?.close();
    _session?.close();
    _client?.close();
    _initialized = false;
    for (var completer in _completers.values) {
      if (!completer.isCompleted) completer.completeError('Bridge disposed');
    }
    for (var controller in _streamControllers.values) {
      controller.addError('Bridge disposed');
      controller.close();
    }
    _completers.clear();
    _streamControllers.clear();
  }
}
