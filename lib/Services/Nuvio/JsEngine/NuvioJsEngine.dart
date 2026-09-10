import 'dart:async';
import 'dart:convert';

import 'package:flutter_qjs/flutter_qjs.dart';

import '../../../Logger.dart';
import '../../JsEngine.dart';
import '../../LnReader/js_cheerio.dart';
import '../../LnReader/js_polyfills.dart';
import '../../Sora/JsEngine/FetchV2.dart';
import 'crypto_js.dart';

class NuvioJsEngine {
  NuvioJsEngine._internal();
  static final NuvioJsEngine instance = NuvioJsEngine._internal();

  late final JavascriptRuntime _runtime;
  Completer<void>? _initCompleter;
  final Set<String> _loadedModules = {};

  Future<void> init() {
    if (_initCompleter?.isCompleted ?? false) {
      return _initCompleter!.future;
    }

    if (_initCompleter != null) {
      return _initCompleter!.future;
    }

    _initCompleter = Completer<void>();
    _doInit();
    return _initCompleter!.future;
  }

  Future<void> _doInit() async {
    try {
      _runtime = await JsEngineEnv.instance.init();

      final setToGlobalObject = _runtime
          .evaluate("(key, val) => { globalThis[key] = val; }")
          .rawResult;

      (setToGlobalObject as JSInvokable).invoke([
        'sendMessage',
        (String channelName, dynamic message) {
          final channelFunctions = JavascriptRuntime
              .channelFunctionsRegistered[_runtime.getEngineInstanceId()]!;

          if (channelFunctions.containsKey(channelName)) {
            dynamic parsed;
            if (message is String) {
              try {
                parsed = jsonDecode(message);
              } catch (_) {
                parsed = message;
              }
            } else {
              parsed = message;
            }
            return channelFunctions[channelName]!.call(parsed);
          }
        }
      ]);

      // 1. Setup Fetch
      final fetch = FetchV2(_runtime);
      _runtime.onMessage('bridge', (dynamic args) async {
        final data = args;
        if (data is Map && data['type'] == 'fetchv2') {
          return await fetch.handle(data);
        }
        throw Exception('Unknown bridge call');
      });

      _runtime.evaluate(r'''
        var fjs = {
          bridge_call: function(data) {
            const payload = (typeof data === 'object') ? JSON.stringify(data) : data;
            return sendMessage('bridge', payload);
          }
        };
      ''');

      await fetch.inject();

      // Transparent fetch supporting both fetch(url, options) and fetchv2 with Headers polyfill
      _runtime.evaluate(r'''
        function createHeaders(raw) {
          const map = new Map();
          if (raw && typeof raw === 'object') {
            for (const [k, v] of Object.entries(raw)) {
              if (v != null) {
                map.set(String(k).toLowerCase(), String(v));
              }
            }
          }
          const obj = {
            get: function(k) {
              const key = String(k).toLowerCase();
              return map.has(key) ? map.get(key) : null;
            },
            has: function(k) {
              return map.has(String(k).toLowerCase());
            },
            forEach: function(cb) {
              map.forEach(cb);
            }
          };
          if (raw && typeof raw === 'object') {
            Object.assign(obj, raw);
          }
          return obj;
        }

        async function nuvioFetch(url, options = {}) {
          let headers = {};
          let method = "GET";
          let body = null;
          let redirect = "follow";
          if (options && typeof options === 'object') {
            headers = options.headers || {};
            method = options.method || "GET";
            body = options.body || null;
            redirect = options.redirect || "follow";
          }
          const payload = JSON.stringify({
            type: "fetchv2",
            url: String(url),
            headers,
            method,
            body,
            redirect
          });
          const res = await sendMessage("bridge", payload);
          const headerObj = createHeaders(res.headers);
          return {
            status: res.status,
            headers: headerObj,
            ok: res.status >= 200 && res.status < 300,
            json: () => Promise.resolve(JSON.parse(res.body)),
            text: () => Promise.resolve(res.body)
          };
        }
        globalThis.fetch = nuvioFetch;
        globalThis.fetchv2 = nuvioFetch;
      ''');

      // 2. Setup Cheerio
      final cheerio = JsCheerio(_runtime);
      cheerio.init();

      // 3. Setup Polyfills (URL, URLSearchParams, FormData, dayjs)
      final polyfills = JsPolyfills(_runtime);
      polyfills.init();

      // 4. Injected Base64 (atob, btoa) & Global shims
      _runtime.evaluate(r'''
        globalThis.global = globalThis;
        globalThis.window = globalThis;

        if (typeof globalThis.atob === 'undefined') {
          globalThis.atob = function(str) {
            const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=';
            let output = '';
            str = String(str).replace(/=+$/, '');
            for (let bc = 0, bs = 0, buffer, idx = 0; buffer = str.charAt(idx++); ~buffer && (bs = bc % 4 ? bs * 64 + buffer : buffer, bc++ % 4) ? output += String.fromCharCode(255 & bs >> (-2 * bc & 6)) : 0) {
              buffer = chars.indexOf(buffer);
            }
            return output;
          };
        }

        if (typeof globalThis.btoa === 'undefined') {
          globalThis.btoa = function(str) {
            const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=';
            let output = '';
            for (let block = 0, charCode, idx = 0, map = chars; str.charAt(idx | 0) || (map = '=', idx % 1); output += map.charAt(63 & block >> 8 - idx % 1 * 8)) {
              charCode = str.charCodeAt(idx += 3/4);
              if (charCode > 0xFF) throw new Error("'btoa' failed: The string to be encoded contains characters outside of the Latin1 range.");
              block = block << 8 | charCode;
            }
            return output;
          };
        }
      ''');

      // 5. Injected CryptoJS
      _runtime.evaluate(cryptoJsSource);

      // 6. CommonJS require resolver
      _runtime.evaluate(r'''
        globalThis.require = function(name) {
          if (name.includes('cheerio')) {
            return {
              load: function(html) { return load(html); },
              default: { load: function(html) { return load(html); } }
            };
          }
          if (name.includes('crypto-js') || name === 'crypto') {
            return globalThis.CryptoJS;
          }
          if (name === 'util') {
            return {
              promisify: function(fn) {
                return function(...args) {
                  return new Promise((resolve, reject) => {
                    fn(...args, (err, res) => {
                      if (err) reject(err);
                      else resolve(res);
                    });
                  });
                };
              }
            };
          }
          if (name === 'ws') {
            return class WebSocketStub {
              constructor(url) { this.url = url; }
              on() {}
              send() {}
              close() {}
            };
          }
          return {};
        };
      ''');

      _initCompleter?.complete();
    } catch (e, stack) {
      Logger.log("NuvioJsEngine init error: $e");
      _initCompleter?.completeError(e, stack);
      _initCompleter = null;
    }
  }

  String _sanitizeModuleId(String id) {
    return id.replaceAll(RegExp(r'[^a-zA-Z0-9_]'), '_');
  }

  Future<void> loadModule({
    required String moduleId,
    required String sourceCode,
    bool force = false,
  }) async {
    await init();

    final safeId = _sanitizeModuleId(moduleId);
    if (!force && _loadedModules.contains(safeId)) {
      return;
    }

    final wrapped = '''
      globalThis['__nuvio_$safeId'] = (() => {
        var module = { exports: {} };
        var exports = module.exports;
        try {
          $sourceCode
        } catch (e) {
          console.log("[Nuvio] Error executing module $safeId: " + e);
        }
        return module.exports;
      })();
    ''';

    _runtime.evaluate(wrapped);
    _loadedModules.add(safeId);
  }

  Future<List<dynamic>> getStreams({
    required String moduleId,
    required dynamic tmdbId,
    required String mediaType,
    int? season,
    int? episode,
  }) async {
    await init();

    final safeId = _sanitizeModuleId(moduleId);

    final js = '''
      (async () => {
        const mod = globalThis['__nuvio_$safeId'] || {};
        const fn = mod.getStreams || (typeof getStreams === 'function' ? getStreams : null);
        if (typeof fn !== 'function') {
          throw new Error("getStreams function not found in module '$safeId'");
        }
        const res = await fn($tmdbId, '$mediaType', ${season ?? 1}, ${episode ?? 1});
        return Array.isArray(res) ? res : (res ? [res] : []);
      })()
    ''';

    final result = await _runtime.handlePromise(_runtime.evaluate(js));
    final raw = result.rawResult;

    if (raw is List) {
      return raw;
    } else if (raw is String) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is List) return decoded;
      } catch (_) {}
    }

    return const [];
  }
}
