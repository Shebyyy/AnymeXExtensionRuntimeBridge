import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:collection/collection.dart';
import 'package:http/http.dart' as http;

import '../../Extensions/Extensions.dart';
import '../../Extensions/SourceMethods.dart';
import '../../Logger.dart';
import '../../Models/Source.dart';
import '../../Settings/KvStore.dart';
import 'Models/NuvioSource.dart';
import 'NuvioSourceMethods.dart';

class NuvioExtensions extends Extension {
  static final _client = http.Client();

  @override
  String get id => 'nuvio';

  @override
  String get name => 'Nuvio';

  @override
  bool get supportsNovel => false;

  @override
  SourceMethods createSourceMethods(Source source) => NuvioSourceMethods(source);

  @override
  Future<void> fetchAnimeExtensions() async {
    final res = await _fetchExtensions(ItemType.anime);
    getAvailableRx(ItemType.anime).value = res;
  }

  @override
  Future<void> fetchMangaExtensions() async {
    getAvailableRx(ItemType.manga).value = const [];
  }

  @override
  Future<void> fetchNovelExtensions() async {
    getAvailableRx(ItemType.novel).value = const [];
  }

  @override
  Future<void> fetchInstalledAnimeExtensions() async {
    final installed = _loadInstalled(ItemType.anime);
    getInstalledRx(ItemType.anime).value = installed;
  }

  @override
  Future<void> fetchInstalledMangaExtensions() async {
    getInstalledRx(ItemType.manga).value = const [];
  }

  @override
  Future<void> fetchInstalledNovelExtensions() async {
    getInstalledRx(ItemType.novel).value = const [];
  }

  @override
  Future<void> addRepo(String repoUrl, ItemType type) async {
    try {
      final uri = Uri.tryParse(repoUrl.trim());
      if (uri == null || !uri.hasScheme) {
        throw Exception("Invalid repo URL");
      }

      final normalizedUrl = repoUrl.trim().endsWith('/')
          ? '${repoUrl.trim()}manifest.json'
          : repoUrl.trim();

      final repos = _loadRepos(type);
      if (repos.any((r) => r.url == normalizedUrl)) {
        return;
      }

      final res = await _client.get(Uri.parse(normalizedUrl));
      if (res.statusCode != 200) {
        throw Exception("Failed to fetch repo manifest (status: ${res.statusCode})");
      }

      final decoded = jsonDecode(res.body);

      final parsed = await compute(
        _parseExtensions,
        (res.body, normalizedUrl, type, id),
      );

      String? repoName;
      String? repoAuthor;

      if (decoded is Map<String, dynamic>) {
        repoName = decoded['name']?.toString();
        repoAuthor = decoded['author']?.toString();
      }

      final repo = Repo(
        url: normalizedUrl,
        name: repoName ?? repoAuthor ?? 'Nuvio Repository',
        managerId: id,
        extensions: parsed.length.toString(),
      );

      final updatedRepos = List<Repo>.from(repos)..add(repo);
      _saveRepos(updatedRepos, type);

      final rx = getAvailableRx(type);
      final existing = rx.value;

      final merged = {
        for (final s in existing) s.id: s,
        for (final s in parsed) s.id: s,
      }.values.toList(growable: false);

      rx.value = List.unmodifiable(merged);
      getReposRx(type).value = updatedRepos;
    } catch (e) {
      Logger.log("Failed to add Nuvio repo $repoUrl: $e");
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

      final rx = getAvailableRx(type);
      rx.value = rx.value.where((s) => s.repo != repoUrl).toList();

      getReposRx(type).value = repos;
    } catch (e) {
      Logger.log("Failed to remove Nuvio repo $repoUrl: $e");
    }
  }

  Future<List<Source>> _fetchExtensions(ItemType type) async {
    final repos = _loadRepos(type);
    if (repos.isEmpty) return const [];

    getReposRx(type).value = repos;

    final results = await Future.wait(
      repos.map((r) => _fetchRepo(r, type)),
    );

    final allSources = results.expand((e) => e).toList(growable: false);

    final installed = getInstalledRx(type).value;
    final installedIds = installed.map((e) => e.id).toSet();

    _detectUpdates(allSources, type);
    getRawAvailableRx(type).value = List.unmodifiable(allSources);

    return List.unmodifiable(
      allSources.where((s) => !installedIds.contains(s.id)),
    );
  }

  Future<List<Source>> _fetchRepo(Repo repo, ItemType type) async {
    try {
      final res = await _client.get(Uri.parse(repo.url));
      if (res.statusCode != 200) return const [];

      return compute(
        _parseExtensions,
        (res.body, repo.url, type, id),
      );
    } catch (e) {
      Logger.log("Nuvio repo failed ${repo.url}: $e");
      return const [];
    }
  }

  static List<Source> parseExtensions(
      String body, String repoUrl, ItemType itemType, String managerId) {
    return _parseExtensions((body, repoUrl, itemType, managerId));
  }

  static List<Source> _parseExtensions(
      (String body, String repoUrl, ItemType itemType, String managerId) args) {
    final (body, repoUrl, itemType, managerId) = args;

    if (itemType != ItemType.anime) return const [];

    try {
      final decoded = jsonDecode(body);
      if (decoded is! Map<String, dynamic>) return const [];

      final scrapers = decoded['scrapers'];
      if (scrapers is! List) return const [];

      final repoName = decoded['name']?.toString() ?? 'Nuvio';
      final repoAuthor = decoded['author']?.toString() ?? 'Unknown';

      // Base URL resolution
      String baseUrl;
      if (repoUrl.contains('manifest.json')) {
        baseUrl = repoUrl.substring(0, repoUrl.lastIndexOf('manifest.json'));
      } else if (repoUrl.endsWith('/')) {
        baseUrl = repoUrl;
      } else {
        baseUrl = '$repoUrl/';
      }

      final sources = <Source>[];

      for (final s in scrapers) {
        if (s is! Map<String, dynamic>) continue;

        final id = s['id']?.toString() ?? '';
        if (id.isEmpty) continue;

        final name = s['name']?.toString() ?? id;
        final filename = s['filename']?.toString() ?? '';
        final cleanFilename = filename.startsWith('/') ? filename.substring(1) : filename;
        final scriptUrl = cleanFilename.isNotEmpty ? '$baseUrl$cleanFilename' : null;

        final langList = s['contentLanguage'] is List
            ? (s['contentLanguage'] as List).map((e) => e.toString()).toList()
            : const ['en'];
        final lang = langList.isNotEmpty ? langList.first : 'en';

        final supportedTypes = s['supportedTypes'] is List
            ? (s['supportedTypes'] as List).map((e) => e.toString()).toList()
            : const ['movie', 'tv'];

        final formats = s['formats'] is List
            ? (s['formats'] as List).map((e) => e.toString()).toList()
            : const ['mp4', 'mkv', 'm3u8'];

        final iconUrl = s['logo']?.toString() ?? s['iconUrl']?.toString() ?? '';
        final version = s['version']?.toString() ?? '1.0.0';

        sources.add(
          NuvioSource(
            id: '$id@$repoUrl',
            name: name,
            baseUrl: baseUrl,
            lang: lang,
            iconUrl: iconUrl,
            version: version,
            versionLast: version,
            itemType: ItemType.anime,
            repo: repoUrl,
            managerId: managerId,
            description: s['description']?.toString() ?? 'From $repoName by $repoAuthor',
            author: s['author']?.toString() ?? repoAuthor,
            supportedTypes: supportedTypes,
            filename: filename,
            formats: formats,
            contentLanguage: langList,
            sourceCodeUrl: scriptUrl,
          ),
        );
      }

      return sources;
    } catch (e) {
      return const [];
    }
  }

  @override
  Future<void> installSource(Source source) async {
    final s = source as NuvioSource;

    try {
      NuvioSource? remote;
      final list = getRawAvailableRx(ItemType.anime).value;
      final found = list.firstWhereOrNull((e) => e.id == s.id);
      if (found != null) {
        remote = found as NuvioSource;
      }

      final target = remote ?? s;

      if (target.sourceCodeUrl == null || target.sourceCodeUrl!.isEmpty) {
        throw Exception("Missing sourceCodeUrl for Nuvio extension");
      }

      final res = await _client.get(Uri.parse(target.sourceCodeUrl!));
      if (res.statusCode != 200) {
        throw Exception("Failed to download Nuvio scraper code (status: ${res.statusCode})");
      }

      final installed = NuvioSource.fromJson(target.toJson())
        ..sourceCode = res.body
        ..hasUpdate = false
        ..versionLast = null;

      final installedList = _loadInstalled(ItemType.anime);
      installedList.removeWhere((e) => e.id == s.id);
      installedList.add(installed);

      _saveInstalled(installedList, ItemType.anime);
      getInstalledRx(ItemType.anime).value = List.unmodifiable(installedList);

      final avail = getAvailableRx(ItemType.anime);
      avail.value = avail.value.where((e) => e.id != s.id).toList();
    } catch (e) {
      Logger.log("Install Nuvio source failed ${s.id}: $e");
      rethrow;
    }
  }

  @override
  Future<void> uninstallSource(Source source) async {
    final s = source as NuvioSource;

    try {
      final type = ItemType.anime;
      final installed = _loadInstalled(type);

      installed.removeWhere((e) => e.id == s.id);
      _saveInstalled(installed, type);
      getInstalledRx(type).value = List.unmodifiable(installed);

      final raw = getRawAvailableRx(type).value;
      final installedIds = installed.map((e) => e.id).toSet();

      getAvailableRx(type).value = List.unmodifiable(
        raw.where((e) => !installedIds.contains(e.id)),
      );
    } catch (e) {
      Logger.log("Uninstall Nuvio source failed ${s.id}: $e");
    }
  }

  @override
  Future<void> updateSource(Source source) async {
    await installSource(source);
  }

  void _detectUpdates(List<Source> available, ItemType type) {
    final installed = _loadInstalled(type);
    if (installed.isEmpty || available.isEmpty) return;

    final repoMap = {for (final s in available) s.id: s};
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
      _saveInstalled(installed, type);
      getInstalledRx(type).value = List.unmodifiable(installed);
    }
  }

  List<Repo> _loadRepos(ItemType type) {
    final encoded = getVal<List<String>>('$id${type.name}Repos');
    if (encoded == null || encoded.isEmpty) return const [];

    return encoded
        .map((e) => Repo.fromJson(jsonDecode(e)))
        .toList(growable: false);
  }

  void _saveRepos(List<Repo> repos, ItemType type) {
    final key = '$id${type.name}Repos';
    setVal(
      key,
      repos.map((e) => jsonEncode(e.toJson())).toList(growable: false),
    );
  }

  List<NuvioSource> _loadInstalled(ItemType type) {
    final encoded = getVal<List<String>>('$id-Installed-${type.name}');
    if (encoded == null || encoded.isEmpty) return [];

    final list = <NuvioSource>[];
    for (final e in encoded) {
      try {
        list.add(NuvioSource.fromJson(jsonDecode(e))..managerId = id);
      } catch (_) {}
    }

    return list;
  }

  void _saveInstalled(List<NuvioSource> list, ItemType type) {
    final key = '$id-Installed-${type.name}';
    setVal(
      key,
      list.map((e) => jsonEncode(e.toJson())).toList(growable: false),
    );
  }

  @override
  Set<String> get schemes => {"nuvio"};

  @override
  void handleSchemes(Uri uri) {
    final url = uri.queryParameters["url"];
    if (url != null && url.isNotEmpty) {
      addRepo(url, ItemType.anime);
    }
  }
}
