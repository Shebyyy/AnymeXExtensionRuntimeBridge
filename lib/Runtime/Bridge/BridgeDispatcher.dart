import 'dart:io';
import 'package:get/get.dart';
import 'JniBridge.dart';
import 'SidecarBridge.dart';
import 'IosFfiBridge.dart';
import '../../ExtensionManager.dart';

enum BridgeType { jni, sidecar, ios }

class BridgeDispatcher {
  static final BridgeDispatcher _instance = BridgeDispatcher._internal();
  factory BridgeDispatcher() => _instance;
  BridgeDispatcher._internal();

  BridgeType get _mode {
    if (Platform.isIOS) return BridgeType.ios;
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
    if (_mode == BridgeType.ios) {
      // iOS JVM is initialized by IosExtensionBase, no-op here
      return;
    } else if (_mode == BridgeType.jni) {
      await JniBridge().initialize(bridgeJarPath);
    } else {
      await SidecarBridge().initialize(bridgeJarPath);
    }
  }

  Future<dynamic> invokeMethod(
    String method,
    Map<String, dynamic> args, {
    Duration timeout = const Duration(seconds: 60),
  }) async {
    if (_mode == BridgeType.ios) {
      return await IosFfiBridge().invokeMethod(method, args, timeout: timeout);
    } else if (_mode == BridgeType.jni) {
      return await JniBridge().invokeMethod(method, args);
    } else {
      return await SidecarBridge().invokeMethod(method, args, timeout: timeout);
    }
  }

  Stream<dynamic> invokeStreamMethod(String method, Map<String, dynamic> args) {
    if (_mode == BridgeType.ios || _mode == BridgeType.jni) {
      return const Stream.empty();
    } else {
      return SidecarBridge().invokeStreamMethod(method, args);
    }
  }

  Future<bool> cancelRequest(String id) async {
    if (_mode == BridgeType.ios) {
      return IosFfiBridge().cancelRequest(id);
    } else if (_mode == BridgeType.jni) {
      return JniBridge().cancelRequest(id);
    } else {
      return SidecarBridge().cancelRequest(id);
    }
  }

  void dispose() {
    if (_mode == BridgeType.ios) {
      IosFfiBridge().dispose();
    } else if (_mode == BridgeType.jni) {
      JniBridge().dispose();
    } else {
      SidecarBridge().dispose();
    }
  }
}
