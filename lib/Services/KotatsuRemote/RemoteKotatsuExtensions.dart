import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:get/get.dart';

import '../../Logger.dart';
import '../../Models/Source.dart';
import '../../Extensions/Extensions.dart';
import '../../Extensions/SourceMethods.dart';
import '../../Runtime/Bridge/RemoteSidecarBridge.dart';
import '../../Runtime/RuntimeController.dart';
import '../Kotatsu/Models/Source.dart';
import '../KotatsuDesktop/DesktopKotatsuExtensions.dart';
import '../KotatsuDesktop/DesktopKotatsuSourceMethods.dart';

/// iOS variant of [DesktopKotatsuExtensions].
///
/// Routes Kotatsu extension calls through the remote AnymeX Bridge server
/// over SSH (via [RemoteSidecarBridge]).
///
/// KEY DIFFERENCES from [DesktopKotatsuExtensions]:
///   - Repo/install management is forwarded to the remote server.
///   - fetchInstalled* / fetchAvailable* use the server's `listInstalled` /
///     `listAvailable` actions instead of the Desktop base class methods
///     (which read from local KvStore and local JAR — both empty on iOS).
///   - getReposRx fetches from the server's `listRepos` action.
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

  // ----------------------------------------------------------------
  // fetchInstalled* — use server's listInstalled action
  // ----------------------------------------------------------------

  @override
  Future<void> fetchInstalledAnimeExtensions() async {}

  @override
  Future<void> fetchInstalledNovelExtensions() async {}

  @override
  Future<void> fetchInstalledMangaExtensions() async {
    final installed = await _loadInstalledFromServer(ItemType.manga);
    await setInstalled(ItemType.manga, installed);
  }

  Future<List<Source>> _loadInstalledFromServer(ItemType type) async {
    try {
      final result = await RemoteSidecarBridge().invokeBridgeAction(
        'listInstalled',
        {'type': type.name, 'runtime': 'kotatsu'},
      );
      final extensions = result['extensions'] as List? ?? [];
      // Double-filter client-side as safety net (server should already filter).
      final kotatsuExts = extensions.where((e) {
        final map = e as Map<String, dynamic>;
        final mid = map['managerId'] ?? map['runtime'];
        final metaMid = (map['meta'] as Map?)?['managerId'] ?? (map['meta'] as Map?)?['runtime'];
        return mid == 'kotatsu' || metaMid == 'kotatsu';
      }).toList();
      return _parseKotatsuExtensions(kotatsuExts, type);
    } catch (e) {
      Logger.log('RemoteKotatsuExtensions._loadInstalledFromServer: $e');
      return [];
    }
  }

  // ----------------------------------------------------------------
  // fetchAvailable* — use server's listAvailable action
  // ----------------------------------------------------------------

  @override
  Future<void> fetchAnimeExtensions() async {}

  @override
  Future<void> fetchNovelExtensions() async {}

  @override
  Future<void> fetchMangaExtensions() async {
    final allAvailable = await _loadAvailableFromServer(ItemType.manga);

    // Filter out installed ones.
    final installedIds =
        getInstalledRx(ItemType.manga).value.map((e) => e.id).toSet();
    getAvailableRx(ItemType.manga).value =
        allAvailable.where((s) => !installedIds.contains(s.id)).toList();
  }

  Future<List<Source>> _loadAvailableFromServer(ItemType type) async {
    try {
      final result = await RemoteSidecarBridge().invokeBridgeAction(
        'listAvailable',
        {'type': type.name, 'runtime': 'kotatsu'},
      );
      final extensions = result['extensions'] as List? ?? [];

      // Double-filter client-side as safety net (server should already filter).
      final kotatsuExtensions = extensions.where((e) {
        final map = e as Map<String, dynamic>;
        final mid = map['managerId'] ?? map['runtime'];
        return mid == 'kotatsu';
      }).toList();

      return _parseKotatsuExtensions(kotatsuExtensions, type);
    } catch (e) {
      Logger.log('RemoteKotatsuExtensions._loadAvailableFromServer: $e');
      return [];
    }
  }

  /// Parse server response extensions into KotatsuSource objects.
  List<Source> _parseKotatsuExtensions(List extensions, ItemType type) {
    final parsed = <KotatsuSource>[];

    for (final e in extensions) {
      final map = e as Map<String, dynamic>;

      // listInstalled puts metadata in `meta`, listAvailable puts it flat.
      final meta = map['meta'] as Map<String, dynamic>? ?? map;

      final source = KotatsuSource(
        id: (map['extId'] ?? meta['id'])?.toString(),
        name: meta['name'] as String?,
        baseUrl: meta['baseUrl'] as String?,
        lang: meta['lang'] as String?,
        isNsfw: meta['isNsfw'] as bool? ?? false,
        version: meta['version'] as String?,
        itemType: type,
        repo: (map['repoUrl'] ?? meta['repoUrl']) as String?,
      );
      source.managerId = id;

      parsed.add(source);
    }

    return parsed;
  }

  // ----------------------------------------------------------------
  // Repo management — forwarded to server
  // ----------------------------------------------------------------

  @override
  Future<void> addRepo(String repoUrl, ItemType type) async {
    try {
      await RemoteSidecarBridge()
          .invokeBridgeAction('addRepo', {'repoUrl': repoUrl});
      await fetchInstalledMangaExtensions();
      await fetchMangaExtensions();
    } catch (e) {
      Logger.log('RemoteKotatsuExtensions.addRepo: $e');
      rethrow;
    }
  }

  @override
  Future<void> removeRepo(String repoUrl, ItemType type) async {
    try {
      await RemoteSidecarBridge()
          .invokeBridgeAction('removeRepo', {'repoUrl': repoUrl});
      await fetchInstalledMangaExtensions();
      await fetchMangaExtensions();
    } catch (e) {
      Logger.log('RemoteKotatsuExtensions.removeRepo: $e');
      rethrow;
    }
  }

  @override
  Rx<List<Repo>> getReposRx(ItemType type) {
    _refreshReposFromServer(type);
    return super.getReposRx(type);
  }

  Future<void> _refreshReposFromServer(ItemType type) async {
    try {
      final result =
          await RemoteSidecarBridge().invokeBridgeAction('listRepos', {});
      final repos = (result['repos'] as List? ?? [])
          .map((r) => Repo(
                url: (r as Map<String, dynamic>)['repoUrl'] as String? ?? '',
                managerId: id,
              ))
          .toList();
      super.getReposRx(type).value = repos;
    } catch (e) {
      Logger.log('RemoteKotatsuExtensions._refreshReposFromServer: $e');
    }
  }

  // ----------------------------------------------------------------
  // Install / Uninstall / Update — forwarded to server
  // ----------------------------------------------------------------

  @override
  Future<void> installSource(Source source) async {
    try {
      await RemoteSidecarBridge().invokeBridgeAction('install', {
        'extId': source.id,
        'repoUrl': source.repo ?? '',
      });
      await fetchInstalledMangaExtensions();
      await fetchMangaExtensions();
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
      await fetchInstalledMangaExtensions();
      await fetchMangaExtensions();
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
