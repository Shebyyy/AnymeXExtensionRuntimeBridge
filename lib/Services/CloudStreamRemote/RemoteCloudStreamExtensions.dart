import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:get/get.dart';

import '../../Logger.dart';
import '../../Models/Source.dart';
import '../../Extensions/Extensions.dart';
import '../../Extensions/SourceMethods.dart';
import '../../Runtime/Bridge/RemoteSidecarBridge.dart';
import '../../Runtime/RuntimeController.dart';
import '../CloudStream/Models/CloudStreamSource.dart';
import '../CloudStreamDesktop/DesktopCloudStreamExtensions.dart';
import '../CloudStreamDesktop/DesktopCloudStreamSourceMethods.dart';

/// iOS variant of [DesktopCloudStreamExtensions].
///
/// Routes CloudStream extension calls through the remote AnymeX Bridge
/// server over SSH (via [RemoteSidecarBridge]).
///
/// KEY DIFFERENCES from [DesktopCloudStreamExtensions]:
///   - Repo/install management is forwarded to the remote server.
///   - fetchInstalled* / fetchAvailable* use the server's `listInstalled` /
///     `listAvailable` actions instead of the Desktop base class methods
///     (which read from local KvStore and local JAR — both empty on iOS).
///   - getReposRx fetches from the server's `listRepos` action.
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

  // ----------------------------------------------------------------
  // fetchInstalled* — use server's listInstalled action
  // ----------------------------------------------------------------

  @override
  Future<void> fetchInstalledAnimeExtensions() async {
    installedAnimeExtensions.value =
        await _loadInstalledFromServer(ItemType.anime);
    installedAnimeExtensions.refresh();
  }

  @override
  Future<void> fetchInstalledMangaExtensions() async {}

  @override
  Future<void> fetchInstalledNovelExtensions() async {}

  Future<List<Source>> _loadInstalledFromServer(ItemType type) async {
    try {
      final result = await RemoteSidecarBridge().invokeBridgeAction(
        'listInstalled',
        {'type': type.name},
      );
      final extensions = result['extensions'] as List? ?? [];
      // Filter to only CloudStream extensions — the server returns all runtimes.
      final csExtensions = extensions.where((e) {
        final map = e as Map<String, dynamic>;
        final mid = map['managerId'] ?? map['runtime'];
        final metaMid = (map['meta'] as Map?)?['managerId'] ?? (map['meta'] as Map?)?['runtime'];
        return mid == 'cloudstream' || metaMid == 'cloudstream';
      }).toList();
      return _parseCloudStreamExtensions(csExtensions, type);
    } catch (e) {
      Logger.log('RemoteCloudStreamExtensions._loadInstalledFromServer: $e');
      return [];
    }
  }

  // ----------------------------------------------------------------
  // fetchAvailable* — use server's listAvailable action
  // ----------------------------------------------------------------

  @override
  Future<void> fetchAnimeExtensions() async {
    final available = await _loadAvailableFromServer(ItemType.anime);

    // Filter out already-installed extensions.
    final installedNames = installedAnimeExtensions.value
        .map((e) => _normalizeName(e.name))
        .toSet();
    final installedInternalNames = installedAnimeExtensions.value
        .map((e) => (e as CloudStreamSource).internalName)
        .where((name) => name != null)
        .map((name) => _normalizeName(name))
        .toSet();

    availableAnimeExtensions.value = available.where((s) {
      final source = s as CloudStreamSource;
      final normName = _normalizeName(source.name);
      final normInternalName = _normalizeName(source.internalName);
      return !installedNames.contains(normName) &&
          !installedInternalNames.contains(normInternalName) &&
          !installedNames.contains(normInternalName) &&
          !installedInternalNames.contains(normName);
    }).toList();
  }

  @override
  Future<void> fetchMangaExtensions() async {}

  @override
  Future<void> fetchNovelExtensions() async {}

  Future<List<Source>> _loadAvailableFromServer(ItemType type) async {
    try {
      final result = await RemoteSidecarBridge().invokeBridgeAction(
        'listAvailable',
        {'type': type.name},
      );
      final extensions = result['extensions'] as List? ?? [];

      // Only include CloudStream extensions (managerId == 'cloudstream').
      final csExtensions = extensions.where((e) {
        final map = e as Map<String, dynamic>;
        final mid = map['managerId'] ?? map['runtime'];
        return mid == 'cloudstream';
      }).toList();

      return _parseCloudStreamExtensions(csExtensions, type);
    } catch (e) {
      Logger.log('RemoteCloudStreamExtensions._loadAvailableFromServer: $e');
      return [];
    }
  }

  /// Parse server response extensions into CloudStreamSource objects.
  List<Source> _parseCloudStreamExtensions(List extensions, ItemType type) {
    final parsed = <Source>[];

    for (final e in extensions) {
      final map = e as Map<String, dynamic>;

      // listInstalled puts metadata in `meta`, listAvailable puts it flat.
      final meta = map['meta'] as Map<String, dynamic>? ?? map;

      final internalName =
          meta['internalName'] as String? ?? meta['name'] as String?;
      final rawLang = meta['lang'] as String?;
      final lang = (rawLang == null || rawLang.trim().isEmpty)
          ? 'ALL'
          : rawLang;

      final source = CloudStreamSource(
        id: (map['extId'] ?? meta['id'])?.toString().toLowerCase() ?? '',
        name: meta['name'] as String?,
        lang: lang,
        version: meta['version']?.toString() ?? '1.0.0',
        isNsfw: meta['isNsfw'] as bool? ?? false,
        baseUrl: meta['baseUrl'] as String?,
        itemType: ItemType.anime,
        iconUrl: meta['iconUrl'] as String? ??
            'https://raw.githubusercontent.com/recloudstream/cloudstream/master/app/src/main/res/mipmap-xxxhdpi/ic_launcher.png',
        internalName: internalName,
        repo: (map['repoUrl'] ?? meta['repoUrl']) as String?,
        pluginUrl: meta['fileUrl'] as String?,
        jarUrl: meta['jarUrl'] as String?,
      );
      source.managerId = id;

      parsed.add(source);
    }

    return parsed;
  }

  String _normalizeName(String? name) {
    if (name == null) return '';
    return name.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '').toLowerCase();
  }

  // ----------------------------------------------------------------
  // Repo management — forwarded to server
  // ----------------------------------------------------------------

  @override
  Future<void> addRepo(String repoUrl, ItemType type) async {
    try {
      await RemoteSidecarBridge()
          .invokeBridgeAction('addRepo', {'repoUrl': repoUrl});
      await fetchAnimeExtensions();
    } catch (e) {
      Logger.log('RemoteCloudStreamExtensions.addRepo: $e');
      rethrow;
    }
  }

  @override
  Future<void> removeRepo(String repoUrl, ItemType type) async {
    try {
      await RemoteSidecarBridge()
          .invokeBridgeAction('removeRepo', {'repoUrl': repoUrl});
      await fetchAnimeExtensions();
    } catch (e) {
      Logger.log('RemoteCloudStreamExtensions.removeRepo: $e');
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
      Logger.log('RemoteCloudStreamExtensions._refreshReposFromServer: $e');
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
      await fetchInstalledAnimeExtensions();
      await fetchAnimeExtensions();
    } catch (e) {
      Logger.log('RemoteCloudStreamExtensions.installSource: $e');
      rethrow;
    }
  }

  @override
  Future<void> uninstallSource(Source source) async {
    try {
      await RemoteSidecarBridge()
          .invokeBridgeAction('uninstall', {'extId': source.id});
      await fetchInstalledAnimeExtensions();
      await fetchAnimeExtensions();
    } catch (e) {
      Logger.log('RemoteCloudStreamExtensions.uninstallSource: $e');
      rethrow;
    }
  }

  @override
  Future<void> updateSource(Source source) async {
    await installSource(source);
  }

  @override
  Future<void> cancelRequest(String token) async {}
}

/// iOS variant of [DesktopCloudStreamSourceMethods]. Inherits all method
/// bodies unchanged — they already route through BridgeDispatcher.
class RemoteCloudStreamSourceMethods extends DesktopCloudStreamSourceMethods {
  RemoteCloudStreamSourceMethods(Source source) : super(source);
}
