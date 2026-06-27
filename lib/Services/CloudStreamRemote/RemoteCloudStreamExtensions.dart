import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:get/get.dart';

import '../../Logger.dart';
import '../../Models/Source.dart';
import '../../Extensions/Extensions.dart';
import '../../Extensions/SourceMethods.dart';
import '../../Runtime/Bridge/BridgeDispatcher.dart';
import '../../Runtime/RuntimeController.dart';
import '../CloudStreamDesktop/DesktopCloudStreamExtensions.dart';
import '../CloudStreamDesktop/DesktopCloudStreamSourceMethods.dart';

/// iOS variant of [DesktopCloudStreamExtensions].
///
/// Routes CloudStream extension calls through the remote AnymeX Bridge
/// server over SSH (via [RemoteSidecarBridge] + [BridgeDispatcher] in
/// `remote` mode).
///
/// See [RemoteAniyomiExtensions] for the architectural rationale — this
/// class follows the same pattern.
class RemoteCloudStreamExtensions extends DesktopCloudStreamExtensions {
  @override
  String get id => 'cloudstream-remote';

  @override
  String get name => 'CloudStream (Remote Bridge)';

  @override
  bool get requiresPlugin => false;

  @override
  SourceMethods createSourceMethods(Source source) =>
      RemoteCloudStreamSourceMethods(source);

  @override
  Future<void> initialize() async {
    if (!Get.isRegistered<RuntimeController>()) {
      Get.put(RuntimeController());
    }
    RuntimeController.it.setReady(true);

    try {
      if (supportsAnime) {
        await fetchInstalledAnimeExtensions();
        unawaited(fetchAnimeExtensions());
      }
      if (supportsManga) {
        await fetchInstalledMangaExtensions();
        unawaited(fetchMangaExtensions());
      }
      if (supportsNovel) {
        await fetchInstalledNovelExtensions();
        unawaited(fetchNovelExtensions());
      }
    } catch (e, s) {
      debugPrint('RemoteCloudStreamExtensions.initialize error: $e\n$s');
    }
  }

  @override
  Future<void> addRepo(String repoUrl, ItemType type) async {
    try {
      await BridgeDispatcher()
          .invokeMethod('addRepo', {'repoUrl': repoUrl, 'itemType': type.name});
    } catch (e) {
      Logger.log('RemoteCloudStreamExtensions.addRepo: $e');
      rethrow;
    }
  }

  @override
  Future<void> removeRepo(String repoUrl, ItemType type) async {
    try {
      await BridgeDispatcher().invokeMethod(
          'removeRepo', {'repoUrl': repoUrl, 'itemType': type.name});
    } catch (e) {
      Logger.log('RemoteCloudStreamExtensions.removeRepo: $e');
      rethrow;
    }
  }

  @override
  Future<void> installSource(Source source) async {
    try {
      await BridgeDispatcher().invokeMethod('install', {
        'extId': source.id,
        'repoUrl': source.repo ?? '',
      });
      await fetchInstalledAnimeExtensions();
      await fetchInstalledMangaExtensions();
    } catch (e) {
      Logger.log('RemoteCloudStreamExtensions.installSource: $e');
      rethrow;
    }
  }

  @override
  Future<void> uninstallSource(Source source) async {
    try {
      await BridgeDispatcher()
          .invokeMethod('uninstall', {'extId': source.id});
      await fetchInstalledAnimeExtensions();
      await fetchInstalledMangaExtensions();
    } catch (e) {
      Logger.log('RemoteCloudStreamExtensions.uninstallSource: $e');
      rethrow;
    }
  }

  @override
  Future<void> updateSource(Source source) async {
    await installSource(source);
  }
}

/// iOS variant of [DesktopCloudStreamSourceMethods]. Inherits all method
/// bodies unchanged — they already route through BridgeDispatcher.
class RemoteCloudStreamSourceMethods extends DesktopCloudStreamSourceMethods {
  RemoteCloudStreamSourceMethods(Source source) : super(source);
}
