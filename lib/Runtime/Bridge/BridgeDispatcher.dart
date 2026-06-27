import 'package:get/get.dart';
import 'JniBridge.dart';
import 'SidecarBridge.dart';
import 'RemoteSidecarBridge.dart';
import '../../ExtensionManager.dart';

/// Bridge transport modes.
///   - [jni]     Android: in-process JNI via MethodChannel
///   - [sidecar] Desktop: local `java -jar` subprocess
///   - [remote]  iOS (or any platform): SSH to a remote bridge server
enum BridgeType { jni, sidecar, remote }

class BridgeDispatcher {
  static final BridgeDispatcher _instance = BridgeDispatcher._internal();
  factory BridgeDispatcher() => _instance;
  BridgeDispatcher._internal();

  BridgeType get _mode {
    if (Get.isRegistered<ExtensionManager>()) {
      return Get.find<ExtensionManager>().bridgeType.value;
    }
    return BridgeType.sidecar;
  }

  void setMode(BridgeType mode) {
    if (Get.isRegistered<ExtensionManager>()) {
      Get.find<ExtensionManager>().bridgeType.value = mode;
    }
    print('Bridge Mode set to: $mode');
  }

  BridgeType get mode => _mode;

  Future<void> initialize(String bridgeJarPath) async {
    switch (_mode) {
      case BridgeType.jni:
        await JniBridge().initialize(bridgeJarPath);
        break;
      case BridgeType.sidecar:
        await SidecarBridge().initialize(bridgeJarPath);
        break;
      case BridgeType.remote:
        // No-op: RemoteSidecarBridge.configure() must be called separately
        // (it doesn't need a JAR path — the server manages the JAR).
        await RemoteSidecarBridge().initialize(bridgeJarPath);
        break;
    }
  }

  Future<dynamic> invokeMethod(
    String method,
    Map<String, dynamic> args, {
    Duration timeout = const Duration(seconds: 60),
  }) async {
    switch (_mode) {
      case BridgeType.jni:
        return await JniBridge().invokeMethod(method, args);
      case BridgeType.sidecar:
        return await SidecarBridge().invokeMethod(method, args, timeout: timeout);
      case BridgeType.remote:
        return await RemoteSidecarBridge().invokeMethod(method, args, timeout: timeout);
    }
  }

  Stream<dynamic> invokeStreamMethod(String method, Map<String, dynamic> args) {
    switch (_mode) {
      case BridgeType.jni:
        return const Stream.empty();
      case BridgeType.sidecar:
        return SidecarBridge().invokeStreamMethod(method, args);
      case BridgeType.remote:
        return RemoteSidecarBridge().invokeStreamMethod(method, args);
    }
  }

  Future<bool> cancelRequest(String id) async {
    switch (_mode) {
      case BridgeType.jni:
        return JniBridge().cancelRequest(id);
      case BridgeType.sidecar:
        return SidecarBridge().cancelRequest(id);
      case BridgeType.remote:
        return RemoteSidecarBridge().cancelRequest(id);
    }
  }

  void dispose() {
    switch (_mode) {
      case BridgeType.jni:
        JniBridge().dispose();
        break;
      case BridgeType.sidecar:
        SidecarBridge().dispose();
        break;
      case BridgeType.remote:
        RemoteSidecarBridge().dispose();
        break;
    }
  }
}
