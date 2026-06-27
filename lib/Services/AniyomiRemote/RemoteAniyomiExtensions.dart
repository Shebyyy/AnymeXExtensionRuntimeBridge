import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:get/get.dart';

import '../../Logger.dart';
import '../../Models/Source.dart';
import '../../Extensions/Extensions.dart';
import '../../Extensions/SourceMethods.dart';
import '../../Runtime/Bridge/BridgeDispatcher.dart';
import '../../Runtime/RuntimeController.dart';
import '../Aniyomi/Models/Source.dart';
import '../AniyomiDesktop/DesktopAniyomiExtensions.dart';
import '../AniyomiDesktop/DesktopAniyomiSourceMethods.dart';

/// iOS variant of [DesktopAniyomiExtensions].
///
/// Routes Aniyomi extension calls through the remote AnymeX Bridge server
/// over SSH (via [RemoteSidecarBridge] + [BridgeDispatcher] in `remote` mode).
///
/// Differences from [DesktopAniyomiExtensions]:
///   - Does NOT require a local JRE or local `bridge.jar` — the remote
///     server runs the JAR.
///   - Does NOT call `BridgeDispatcher().initialize(jarPath)` — the remote
///     bridge is configured separately at app startup.
///   - Repo/install management is forwarded to the remote server (which
///     maintains per-user state via SSH key fingerprint).
class RemoteAniyomiExtensions extends DesktopAniyomiExtensions {
  @override
  String get id => 'aniyomi-remote';

  @override
  String get name => 'Aniyomi (Remote Bridge)';

  @override
  bool get supportsNovel => false;

  @override
  bool get requiresPlugin => false; // remote — no local plugin needed

  @override
  SourceMethods createSourceMethods(Source source) =>
      RemoteAniyomiSourceMethods(source);

  @override
  Future<void> initialize() async {
    // Ensure RuntimeController is registered (the base class expects it for
    // the isReady flag — we set it true because the remote bridge handles
    // readiness on the server side).
    if (!Get.isRegistered<RuntimeController>()) {
      Get.put(RuntimeController());
    }
    final controller = RuntimeController.it;
    controller.setReady(true);

    // Skip the DesktopExtensionBase.initialize() body — it calls
    // BridgeDispatcher().initialize(jarPath) which we don't want (no local
    // JAR). Instead jump straight to the Extension.initialize() body that
    // fetches installed/available extension lists.
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
      debugPrint('RemoteAniyomiExtensions.initialize error: $e\n$s');
    }
  }

  // fetchInstalledAnimeExtensions / fetchInstalledMangaExtensions are
  // inherited from DesktopAniyomiExtensions — they call
  // BridgeDispatcher().invokeMethod('loadExtensions', {folderPath: ...}).
  //
  // On the remote server, the `folderPath` is irrelevant — the server
  // manages its own per-user extension folder. The server's `invoke`
  // action handler ignores `folderPath` and just returns the user's
  // currently-loaded source list. So the inherited methods "just work".

  @override
  Future<void> addRepo(String repoUrl, ItemType type) async {
    try {
      await BridgeDispatcher().invokeMethod('addRepo', {
        'repoUrl': repoUrl,
        'itemType': type.name,
      });
    } catch (e) {
      Logger.log('RemoteAniyomiExtensions.addRepo: $e');
      rethrow;
    }
  }

  @override
  Future<void> removeRepo(String repoUrl, ItemType type) async {
    try {
      await BridgeDispatcher().invokeMethod('removeRepo', {
        'repoUrl': repoUrl,
        'itemType': type.name,
      });
    } catch (e) {
      Logger.log('RemoteAniyomiExtensions.removeRepo: $e');
      rethrow;
    }
  }

  @override
  Future<void> installSource(Source source, {String? customPath}) async {
    try {
      await BridgeDispatcher().invokeMethod('install', {
        'extId': source.id,
        'repoUrl': source.repo ?? '',
        if (customPath != null) 'customPath': customPath,
      });
      // Refresh installed list after install.
      await fetchInstalledAnimeExtensions();
      await fetchInstalledMangaExtensions();
    } catch (e) {
      Logger.log('RemoteAniyomiExtensions.installSource: $e');
      rethrow;
    }
  }

  @override
  Future<void> uninstallSource(Source source) async {
    try {
      await BridgeDispatcher().invokeMethod('uninstall', {
        'extId': source.id,
      });
      await fetchInstalledAnimeExtensions();
      await fetchInstalledMangaExtensions();
    } catch (e) {
      Logger.log('RemoteAniyomiExtensions.uninstallSource: $e');
      rethrow;
    }
  }

  @override
  Future<void> updateSource(Source source) async {
    // Remote bridge treats install as update (server re-downloads the APK
    // and hot-reloads the JAR).
    await installSource(source);
  }
}

/// iOS variant of [DesktopAniyomiSourceMethods] — identical to the desktop
/// version (both route through BridgeDispatcher), but named explicitly so
/// the extension tree is self-documenting.
///
/// All the actual method bodies (getPopular, getDetail, getVideoList, etc.)
/// are inherited unchanged from [DesktopAniyomiSourceMethods].
class RemoteAniyomiSourceMethods extends DesktopAniyomiSourceMethods {
  RemoteAniyomiSourceMethods(Source source) : super(source);

  // No overrides needed — the desktop class already routes everything
  // through BridgeDispatcher().invokeMethod(), which will use the `remote`
  // mode once ExtensionManager.setBridgeType(BridgeType.remote) is called.

  // The only reason this class exists is so RemoteAniyomiExtensions can
  // return a typed instance from createSourceMethods(), and so that
  // future iOS-specific tweaks (e.g. different timeout for slow mobile
  // networks) have a clear home.
}
