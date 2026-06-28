import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:get/get.dart';

import '../../Logger.dart';
import '../../Models/Source.dart';
import '../../Extensions/Extensions.dart';
import '../../Extensions/SourceMethods.dart';
import '../../Runtime/Bridge/BridgeDispatcher.dart';
import '../../Runtime/Bridge/RemoteSidecarBridge.dart';
import '../../Runtime/RuntimeController.dart';
import '../KotatsuDesktop/DesktopKotatsuExtensions.dart';
import '../KotatsuDesktop/DesktopKotatsuSourceMethods.dart';

/// iOS variant of [DesktopKotatsuExtensions].
///
/// Routes Kotatsu extension calls through the remote AnymeX Bridge server
/// over SSH (via [RemoteSidecarBridge] + [BridgeDispatcher] in `remote`
/// mode).
///
/// See [RemoteAniyomiExtensions] for the architectural rationale — this
/// class follows the same pattern.
class RemoteKotatsuExtensions extends DesktopKotatsuExtensions {
  @override
  String get id => 'kotatsu-remote';

  @override
  String get name => 'Kotatsu (Remote Bridge)';

  @override
  bool get requiresPlugin => false;

  @override
  SourceMethods createSourceMethods(Source source) =>
      RemoteKotatsuSourceMethods(source);

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
      debugPrint('RemoteKotatsuExtensions.initialize error: $e\n$s');
    }
  }

  @override
  Future<void> addRepo(String repoUrl, ItemType type) async {
    try {
      await RemoteSidecarBridge()
          .invokeBridgeAction('addRepo', {'repoUrl': repoUrl, 'itemType': type.name});
    } catch (e) {
      Logger.log('RemoteKotatsuExtensions.addRepo: $e');
      rethrow;
    }
  }

  @override
  Future<void> removeRepo(String repoUrl, ItemType type) async {
    try {
      await RemoteSidecarBridge().invokeBridgeAction(
          'removeRepo', {'repoUrl': repoUrl, 'itemType': type.name});
    } catch (e) {
      Logger.log('RemoteKotatsuExtensions.removeRepo: $e');
      rethrow;
    }
  }

  @override
  Future<void> installSource(Source source) async {
    try {
      await RemoteSidecarBridge().invokeBridgeAction('install', {
        'extId': source.id,
        'repoUrl': source.repo ?? '',
      });
      await fetchInstalledAnimeExtensions();
      await fetchInstalledMangaExtensions();
    } catch (e) {
      Logger.log('RemoteKotatsuExtensions.installSource: $e');
      rethrow;
    }
  }

  @override
  Future<void> uninstallSource(Source source) async {
    try {
      await RemoteSidecarBridge()
          .invokeBridgeAction('uninstall', {'extId': source.id});
      await fetchInstalledAnimeExtensions();
      await fetchInstalledMangaExtensions();
    } catch (e) {
      Logger.log('RemoteKotatsuExtensions.uninstallSource: $e');
      rethrow;
    }
  }

  @override
  Future<void> updateSource(Source source) async {
    await installSource(source);
  }
}

/// iOS variant of [DesktopKotatsuSourceMethods]. Inherits all method
/// bodies unchanged — they already route through BridgeDispatcher.
class RemoteKotatsuSourceMethods extends DesktopKotatsuSourceMethods {
  RemoteKotatsuSourceMethods(Source source) : super(source);
}
