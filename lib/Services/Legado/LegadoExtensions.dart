import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:get/get.dart';
import 'package:http/http.dart' as http;

import '../../Extensions/Extensions.dart';
import '../../Extensions/SourceMethods.dart';
import '../../Logger.dart';
import '../../Models/Source.dart';
import '../../Settings/KvStore.dart';
import 'LegadoSourceMethods.dart';
import 'Models/LegadoSource.dart';

/// Extension manager for Legado book sources.
/// Fetches, installs, and manages Legado 书源 (BookSource) from JSON URLs.
class LegadoExtensions extends Extension {
  static final _client = http.Client();

  @override
  String get id => 'legado';

  @override
  String get name => 'Legado';

  @override
  bool get supportsAnime => false;

  @override
  bool get supportsManga => false;

  @override
  bool get supportsNovel => true;

  @override
  SourceMethods createSourceMethods(Source source) =>
      LegadoSourceMethods(source);

  // Default book source URLs
  static const List<String> defaultSourceUrls = [
    'https://raw.githubusercontent.com/rektpartyaftermath/Legado-booksource-collection/main/AllBooksource.json',
    'https://github.com/ZWolken/Light-Novel-Yuedu-Source/releases/latest/download/Japan_based_bookSource.json',
    'https://github.com/ZWolken/Light-Novel-Yuedu-Source/releases/latest/download/China_based_bookSource.json',
    'https://github.com/ZWolken/Light-Novel-Yuedu-Source/releases/latest/download/Japanese_original_bookSource.json',
    'https://github.com/ZWolken/Light-Novel-Yuedu-Source/releases/latest/download/All_bookSource.json',
  ];

  @override
  Future<void> fetchAnimeExtensions() async {
    // Legado only supports novels
  }

  @override
  Future<void> fetchMangaExtensions() async {
    // Legado only supports novels
  }

  @override
  Future<void> fetchNovelExtensions() async {
    final repos = _loadRepos(ItemType.novel);
    if (repos.isEmpty) {
      // Use default source URLs on first run
      getReposRx(ItemType.novel).value =
          defaultSourceUrls.map((url) => Repo(url: url, managerId: id)).toList();
    }

    final repoList = getReposRx(ItemType.novel).value;
    if (repoList.isEmpty) return;

    final results = await Future.wait(
      repoList.map((r) => _fetchRepo(r.url)),
    );

    final all = results.expand((e) => e).toList(growable: false);

    final installed = _loadInstalled();
    final installedIds = installed.map((e) => e.id).toSet();

    _detectUpdates(all);

    getRawAvailableRx(ItemType.novel).value = List.unmodifiable(all);

    getAvailableRx(ItemType.novel).value = List.unmodifiable(
      all.where((s) => !installedIds.contains(s.id)),
    );
  }

  Future<List<Source>> _fetchRepo(String repoUrl) async {
    try {
      final uri = Uri.parse(repoUrl);
      final res = await _client.get(uri);
      if (res.statusCode != 200) return const [];

      return compute(_parseSources, res.body);
    } catch (e) {
      Logger.log("Legado: Repo failed $repoUrl: $e");
      return const [];
    }
  }

  static List<Source> _parseSources(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is! List) return const [];

      final sources = <Source>[];
      for (final e in decoded) {
        try {
          final ext = Map<String, dynamic>.from(e as Map);
          final source = LegadoSource.fromJson(ext);
          // Only include text/novel type sources (bookSourceType 0 or null)
          final type = source.bookSourceType ?? 0;
          if (type == 0) {
            sources.add(source);
          }
        } catch (_) {
          continue;
        }
      }

      return sources;
    } catch (e) {
      Logger.log("Legado: Parse failed: $e");
      return const [];
    }
  }

  @override
  Future<void> fetchInstalledAnimeExtensions() async {}

  @override
  Future<void> fetchInstalledMangaExtensions() async {}

  @override
  Future<void> fetchInstalledNovelExtensions() async {
    getInstalledRx(ItemType.novel).value = _loadInstalled();
  }

  @override
  Future<void> installSource(Source source) async {
    try {
      final legado = source as LegadoSource;

      final list = _loadInstalled();
      list.removeWhere((e) => e.id == legado.id);
      list.add(legado);

      _saveInstalled(list);
      getInstalledRx(ItemType.novel).value = List.unmodifiable(list);

      final avail = getAvailableRx(ItemType.novel);
      avail.value = avail.value.where((e) => e.id != legado.id).toList();
    } catch (e) {
      Logger.log("Legado: Install failed ${source.id}: $e");
      rethrow;
    }
  }

  @override
  Future<void> uninstallSource(Source source) async {
    try {
      final installed = _loadInstalled();
      installed.removeWhere((e) => e.id == source.id);

      _saveInstalled(installed);
      getInstalledRx(ItemType.novel).value = List.unmodifiable(installed);

      final raw = getRawAvailableRx(ItemType.novel).value;
      final installedIds = installed.map((e) => e.id).toSet();

      getAvailableRx(ItemType.novel).value = List.unmodifiable(
        raw.where((e) => !installedIds.contains(e.id)),
      );
    } catch (e) {
      Logger.log("Legado: Uninstall failed ${source.id}: $e");
    }
  }

  @override
  Future<void> updateSource(Source source) async {
    // For Legado, updates are detected from repo refreshes
    // Re-install the source from the latest repo data
    final avail = getRawAvailableRx(ItemType.novel).value;
    final updated = avail.firstWhereOrNull((s) => s.id == source.id);
    if (updated != null && updated is LegadoSource) {
      await installSource(updated..hasUpdate = false);
    }
  }

  void _detectUpdates(List<Source> available) {
    final installed = _loadInstalled();
    final repoMap = {for (var s in available) s.id: s};

    bool changed = false;

    for (var i = 0; i < installed.length; i++) {
      final inst = installed[i];
      final repo = repoMap[inst.id];
      if (repo == null) continue;

      if (compareVersions(repo.version ?? "0", inst.version ?? "0") > 0) {
        installed[i] = inst
          ..hasUpdate = true
          ..versionLast = repo.version;
        changed = true;
      }
    }

    if (changed) {
      _saveInstalled(installed);
      getInstalledRx(ItemType.novel).value = List.unmodifiable(installed);
    }
  }

  @override
  Future<void> addRepo(String repoUrl, ItemType type) async {
    try {
      final uri = Uri.tryParse(repoUrl);
      if (uri == null || !uri.hasScheme) {
        throw Exception("Invalid URL");
      }

      final repos = _loadRepos(type);
      if (repos.any((r) => r.url == repoUrl)) return;

      // Fetch sources from the new repo immediately
      final newSources = await _fetchRepo(repoUrl);
      if (newSources.isEmpty) {
        throw Exception("Failed to fetch repo — no sources found");
      }

      final repo = Repo(url: repoUrl, managerId: id);
      final updatedRepos = List<Repo>.from(repos)..add(repo);
      _saveRepos(updatedRepos, type);
      getReposRx(type).value = updatedRepos;

      // Merge new sources into the available list
      final installed = _loadInstalled();
      final installedIds = installed.map((e) => e.id).toSet();

      final rawRx = getRawAvailableRx(type);
      final existingRaw = rawRx.value;
      final mergedRaw = {
        for (final s in existingRaw) s.id: s,
        for (final s in newSources) s.id: s,
      }.values.toList(growable: false);

      rawRx.value = List.unmodifiable(mergedRaw);

      final availRx = getAvailableRx(type);
      final mergedAvail = mergedRaw.where((s) => !installedIds.contains(s.id)).toList();
      availRx.value = List.unmodifiable(mergedAvail);
    } catch (e) {
      Logger.log("Legado: Failed to add repo $repoUrl: $e");
      rethrow;
    }
  }

  @override
  Future<void> removeRepo(String repoUrl, ItemType type) async {
    try {
      final repos = _loadRepos(type)
          .where((r) => r.url != repoUrl)
          .toList(growable: false);

      _saveRepos(repos, type);
      getReposRx(type).value = repos;

      final rx = getAvailableRx(type);
      rx.value = rx.value.where((s) => s.repo != repoUrl).toList();
    } catch (e) {
      Logger.log("Legado: Failed to remove repo $repoUrl: $e");
    }
  }

  // ============================================================
  // PERSISTENCE
  // ============================================================

  List<LegadoSource> _loadInstalled() {
    try {
      final encoded = getVal<List<String>>('$id-Installed-novel');
      if (encoded == null) return [];

      return encoded.map((e) {
        try {
          return LegadoSource.fromJson(
            Map<String, dynamic>.from(jsonDecode(e)),
          );
        } catch (_) {
          return null;
        }
      }).whereType<LegadoSource>().toList();
    } catch (e) {
      return [];
    }
  }

  void _saveInstalled(List<LegadoSource> list) {
    setVal(
      '$id-Installed-novel',
      list.map((e) => jsonEncode(e.toJson())).toList(),
    );
  }

  List<Repo> _loadRepos(ItemType type) {
    try {
      final encoded = getVal<List<String>>('$id${type.name}Repos');
      if (encoded == null) return [];

      return encoded.map((e) {
        try {
          return Repo.fromJson(Map<String, dynamic>.from(jsonDecode(e)));
        } catch (_) {
          return null;
        }
      }).whereType<Repo>().toList();
    } catch (e) {
      return [];
    }
  }

  void _saveRepos(List<Repo> repos, ItemType type) {
    setVal(
      '$id${type.name}Repos',
      repos.map((e) => jsonEncode(e.toJson())).toList(),
    );
  }

  @override
  Set<String> get schemes => {'legado'};

  @override
  void handleSchemes(Uri uri) {
    if (uri.host == 'add-repo') {
      final repoUrl = uri.queryParameters['url'] ?? uri.queryParameters['repo_url'];
      if (repoUrl != null && repoUrl.isNotEmpty) {
        addRepo(repoUrl, ItemType.novel);
      }
    }
  }
}
