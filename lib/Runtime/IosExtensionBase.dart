import 'dart:async';
import 'dart:io';
import 'package:get/get.dart';
import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;

import '../Extensions/Extensions.dart';
import '../Logger.dart';
import 'RuntimePaths.dart';
import 'RuntimeController.dart';
import 'Bridge/IosFfiBridge.dart';

abstract class IosExtensionBase extends Extension {
  @override
  Future<void> initialize() async {
    if (!Get.isRegistered<RuntimeController>()) {
      Get.put(RuntimeController());
    }

    final paths = RuntimePaths();
    final controller = RuntimeController.it;

    if (controller.isReady.value) {
      final bridgeJarPath = await paths.bridgePath;
      final extDir = await paths.extensionsDir;
      final toolsDir = await paths.toolsDir;

      // Build classpath: runtime JAR + extension dir
      final classpath = '$bridgeJarPath:${extDir.path}';
      await IosFfiBridge().initialize(classpath);
      Logger.log('[IosExtensionBase] iOS JVM bridge initialized for $id');
    } else {
      Logger.log("[IosExtensionBase] Bridge initialization deferred for $id: Runtime not ready.");
    }

    await super.initialize();
  }

  Future<String> getToolsPath() async {
    final dir = await RuntimePaths().toolsDir;
    return dir.path;
  }

  Future<String> getExtensionsPath(String subFolder) async {
    final dir = await RuntimePaths().extensionsDir;
    final targetDir = Directory(p.join(dir.path, subFolder));
    if (!await targetDir.exists()) {
      await targetDir.create(recursive: true);
    }
    return targetDir.path;
  }

  Future<void> extractZip(String archivePath, String targetDir) async {
    final bytes = await File(archivePath).readAsBytes();
    final archive = ZipDecoder().decodeBytes(bytes);

    final directory = Directory(targetDir);
    if (!await directory.exists()) {
      await directory.create(recursive: true);
    }

    for (final file in archive) {
      final filename = file.name;
      if (file.isFile) {
        final data = file.content as List<int>;
        final outFile = File(p.join(targetDir, filename));
        await outFile.parent.create(recursive: true);
        await outFile.writeAsBytes(data);
      } else {
        await Directory(p.join(targetDir, filename)).create(recursive: true);
      }
    }
  }

  /// Invoke a method on the iOS JVM bridge (delegates to IosFfiBridge).
  Future<dynamic> invokeBridgeMethod(String method, Map<String, dynamic> args, {
    Duration timeout = const Duration(seconds: 120),
  }) async {
    return IosFfiBridge().invokeMethod(method, args, timeout: timeout);
  }

  /// Cancel a request on the iOS JVM bridge.
  Future<bool> cancelBridgeRequest(String id) async {
    try {
      final result = await invokeBridgeMethod('cancel', {'id': id});
      return result == true || result == 'true';
    } catch (e) {
      Logger.log('[IosExtensionBase] cancelRequest failed: $e');
      return false;
    }
  }
}
