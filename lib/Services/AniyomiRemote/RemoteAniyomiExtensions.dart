import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:get/get.dart';

import '../../Logger.dart';
import '../../Models/Source.dart';
import '../../Extensions/Extensions.dart';
import '../../Extensions/SourceMethods.dart';
import '../../Runtime/Bridge/RemoteSidecarBridge.dart';
import '../../Runtime/RuntimeController.dart';
import '../Aniyomi/Models/Source.dart';
import '../AniyomiDesktop/DesktopAniyomiExtensions.dart';
import '../AniyomiDesktop/DesktopAniyomiSourceMethods.dart';

/// iOS variant of [DesktopAniyomiExtensions].
///
/// Routes Aniyomi extension calls through the remote AnymeX Bridge server
/// over SSH (via [RemoteSidecarBridge]).
///
/// KEY DIFFERENCES from [DesktopAniyomiExtensions]:
///   - Repo/install management is forwarded to the remote server (which
///     maintains per-user state via SSH key fingerprint).
///   - fetchInstalled* / fetchAvailable* use the server's `listInstalled` /
///     `listAvailable` actions instead of the Desktop base class methods
///     (which read from local KvStore and local JAR — both empty on iOS).
///   - getReposRx fetches from the server's `listRepos` action.
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

  // ----------------------------------------------------------------
  // fetchInstalled* — use server's listInstalled action
  // ----------------------------------------------------------------

  @override
  Future<void> fetchInstalledAnimeExtensions() async {
    getInstalledRx(ItemType.anime).value =
        await _loadInstalledFromServer(ItemType.anime);
  }

  @override
  Future<void> fetchInstalledMangaExtensions() async {
    getInstalledRx(ItemType.manga).value =
        await _loadInstalledFromServer(ItemType.manga);
  }

  @override
  Future<void> fetchInstalledNovelExtensions() async {}

  Future<List<Source>> _loadInstalledFromServer(ItemType type) async {
    try {
      final result = await RemoteSidecarBridge().invokeBridgeAction(
        'listInstalled',
        {'type': type.name},
      );
      final extensions = result['extensions'] as List? ?? [];
      // Filter to only Aniyomi extensions — the server returns all runtimes.
      final aniyomiExtensions = extensions.where((e) {
        final map = e as Map<String, dynamic>;
        final mid = map['managerId'] ?? map['runtime'];
        final metaMid = (map['meta'] as Map?)?['managerId'] ?? (map['meta'] as Map?)?['runtime'];
        return mid == 'aniyomi' || metaMid == 'aniyomi';
      }).toList();
      return _parseAniyomiExtensions(aniyomiExtensions, type);
    } catch (e) {
      Logger.log('RemoteAniyomiExtensions._loadInstalledFromServer: $e');
      return [];
    }
  }

  // ----------------------------------------------------------------
  // fetchAvailable* — use server's listAvailable action
  // ----------------------------------------------------------------

  @override
  Future<void> fetchAnimeExtensions() async {
    getAvailableRx(ItemType.anime).value =
        await _loadAvailableFromServer(ItemType.anime);
  }

  @override
  Future<void> fetchMangaExtensions() async {
    getAvailableRx(ItemType.manga).value =
        await _loadAvailableFromServer(ItemType.manga);
  }

  @override
  Future<void> fetchNovelExtensions() async {}

  Future<List<Source>> _loadAvailableFromServer(ItemType type) async {
    try {
      final result = await RemoteSidecarBridge().invokeBridgeAction(
        'listAvailable',
        {'type': type.name},
      );
      final extensions = result['extensions'] as List? ?? [];

      // Filter to ONLY Aniyomi extensions — the server's listAvailable
      // returns all runtimes mixed together (aniyomi + cloudstream + kotatsu).
      // Without this filter, CloudStream/Kotatsu extensions would appear
      // under the Aniyomi tab and install would fail (wrong extId/repoUrl).
      final aniyomiExtensions = extensions.where((e) {
        final map = e as Map<String, dynamic>;
        final mid = map['managerId'] ?? map['runtime'];
        return mid == 'aniyomi';
      }).toList();

      // Filter out already-installed extensions.
      final installedIds =
          getInstalledRx(type).value.map((e) => e.id).toSet();

      return _parseAniyomiExtensions(
        aniyomiExtensions.where((e) {
          final map = e as Map<String, dynamic>;
          // The server sends `installed: bool` — use that, but also
          // double-check against our local installed list.
          return map['installed'] != true &&
              !installedIds.contains(map['id']?.toString());
        }).toList(),
        type,
      );
    } catch (e) {
      Logger.log('RemoteAniyomiExtensions._loadAvailableFromServer: $e');
      return [];
    }
  }

  /// Parse server response extensions into ASource objects.
  ///
  /// The server's `listAvailable` and `listInstalled` both return extension
  /// objects with fields like: id, name, fullName, pkg, file, version, type,
  /// itemType, managerId, runtime, lang, isNsfw, baseUrl, fileUrl, iconUrl,
  /// repoUrl, installed.
  ///
  /// The `listInstalled` response wraps metadata inside a `meta` sub-object
  /// plus top-level fields like extId, repoUrl, runtime, itemType.
  List<Source> _parseAniyomiExtensions(List extensions, ItemType type) {
    final parsed = <ASource>[];

    for (final e in extensions) {
      final map = e as Map<String, dynamic>;

      // listInstalled puts metadata in `meta`, listAvailable puts it flat.
      final meta = map['meta'] as Map<String, dynamic>? ?? map;

      final detectedType = _itemTypeFromServer(meta) ?? type;
      if (detectedType != type) continue;

      final source = ASource(
        id: (map['extId'] ?? meta['id'])?.toString(),
        name: meta['name'] as String?,
        lang: meta['lang'] as String?,
        pkgName: meta['pkg'] as String?,
        version: meta['version'] as String?,
        isNsfw: meta['isNsfw'] as bool? ?? false,
        baseUrl: meta['baseUrl'] as String?,
        itemType: detectedType,
        iconUrl: meta['iconUrl'] as String?,
        repo: (map['repoUrl'] ?? meta['repoUrl']) as String?,
      );
      source.managerId = id;

      // For available extensions, store the file URL so we can construct
      // the APK URL later if needed (the server handles actual download).
      if (meta['file'] != null) {
        source.apkName = meta['file'] as String?;
      }

      parsed.add(source);
    }

    return parsed;
  }

  /// Convert server itemType int/string to ItemType enum.
  ItemType? _itemTypeFromServer(Map<String, dynamic> meta) {
    final itemTypeVal = meta['itemType'];
    if (itemTypeVal is int && itemTypeVal >= 0 && itemTypeVal <= 2) {
      return ItemType.values[itemTypeVal];
    }
    final typeStr = meta['type'] as String?;
    if (typeStr == 'anime') return ItemType.anime;
    if (typeStr == 'manga') return ItemType.manga;
    if (typeStr == 'novel') return ItemType.novel;
    return null;
  }

  // ----------------------------------------------------------------
  // Repo management — forwarded to server
  // ----------------------------------------------------------------

  @override
  Future<void> addRepo(String repoUrl, ItemType type) async {
    try {
      await RemoteSidecarBridge().invokeBridgeAction('addRepo', {
        'repoUrl': repoUrl,
      });
      // Refresh available list after adding a repo.
      await fetchAnimeExtensions();
      await fetchMangaExtensions();
    } catch (e) {
      Logger.log('RemoteAniyomiExtensions.addRepo: $e');
      rethrow;
    }
  }

  @override
  Future<void> removeRepo(String repoUrl, ItemType type) async {
    try {
      await RemoteSidecarBridge().invokeBridgeAction('removeRepo', {
        'repoUrl': repoUrl,
      });
      await fetchAnimeExtensions();
      await fetchMangaExtensions();
    } catch (e) {
      Logger.log('RemoteAniyomiExtensions.removeRepo: $e');
      rethrow;
    }
  }

  @override
  Rx<List<Repo>> getReposRx(ItemType type) {
    // Fetch repos from server asynchronously and return current value.
    // The Rx will be updated when fetchAnimeExtensions refreshes.
    _refreshReposFromServer(type);
    return super.getReposRx(type);
  }

  Future<void> _refreshReposFromServer(ItemType type) async {
    try {
      final result =
          await RemoteSidecarBridge().invokeBridgeAction('listRepos', {});
      final allRepos = result['repos'] as List? ?? [];

      // The server's listRepos returns ALL repos without a runtime tag.
      // We need to determine which repos belong to Aniyomi. We do this
      // by checking the repo URL against the available extensions — only
      // repos that actually provide Aniyomi extensions should be listed.
      // For now, include all repos and let the extension list filter by
      // managerId. The UI will show all repos under each tab, but
      // extensions are correctly filtered.
      final repos = allRepos
          .map((r) => Repo(
                url: (r as Map<String, dynamic>)['repoUrl'] as String? ?? '',
                managerId: id,
              ))
          .toList();
      super.getReposRx(type).value = repos;
    } catch (e) {
      Logger.log('RemoteAniyomiExtensions._refreshReposFromServer: $e');
    }
  }

  // ----------------------------------------------------------------
  // Install / Uninstall / Update — forwarded to server
  // ----------------------------------------------------------------

  @override
  Future<void> installSource(Source source, {String? customPath}) async {
    try {
      await RemoteSidecarBridge().invokeBridgeAction('install', {
        'extId': source.id,
        'repoUrl': source.repo ?? '',
      });
      // Refresh both lists after install.
      await fetchInstalledAnimeExtensions();
      await fetchInstalledMangaExtensions();
      await fetchAnimeExtensions();
      await fetchMangaExtensions();
    } catch (e) {
      Logger.log('RemoteAniyomiExtensions.installSource: $e');
      rethrow;
    }
  }

  @override
  Future<void> uninstallSource(Source source) async {
    try {
      await RemoteSidecarBridge().invokeBridgeAction('uninstall', {
        'extId': source.id,
      });
      await fetchInstalledAnimeExtensions();
      await fetchInstalledMangaExtensions();
      await fetchAnimeExtensions();
      await fetchMangaExtensions();
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
}
