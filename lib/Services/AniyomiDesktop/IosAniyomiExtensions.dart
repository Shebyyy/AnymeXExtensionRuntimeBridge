import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:collection/collection.dart';
import '../Aniyomi/PbDecoder.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

import '../../Logger.dart';
import '../../Settings/KvStore.dart';
import '../../Models/Source.dart';
import '../../Extensions/Extensions.dart';
import '../../Extensions/SourceMethods.dart';
import '../../Runtime/RuntimeController.dart';
import '../../Runtime/Bridge/IosFfiBridge.dart';
import '../../Runtime/IosExtensionBase.dart';
import 'package:get/get.dart';
import '../Aniyomi/Models/Source.dart';
import 'DesktopAniyomiSourceMethods.dart';

/// iOS version of Aniyomi extensions.
/// Uses the embedded JVM via FFI instead of Sidecar/JNI.
class IosAniyomiExtensions extends IosExtensionBase {
  @override
  String get id => 'aniyomi-ios';

  @override
  String get name => 'Aniyomi (iOS)';

  @override
  bool get supportsNovel => false;

  @override
  bool get requiresPlugin => true;

  @override
  SourceMethods createSourceMethods(Source source) =>
      DesktopAniyomiSourceMethods(source);

  Future<String> _getExtensionsPath() async => getExtensionsPath('Aniyomi');

  // ── Fetch installed ──────────────────────────────────────────────
  @override
  Future<void> fetchInstalledAnimeExtensions() async {
    final list = await _loadInstalled(ItemType.anime);
    getInstalledRx(ItemType.anime).value = list;
    _detectUpdates(getRawAvailableRx(ItemType.anime).value.whereType<ASource>().toList(), ItemType.anime);
  }

  @override
  Future<void> fetchInstalledMangaExtensions() async {
    final list = await _loadInstalled(ItemType.manga);
    getInstalledRx(ItemType.manga).value = list;
    _detectUpdates(getRawAvailableRx(ItemType.manga).value.whereType<ASource>().toList(), ItemType.manga);
  }

  @override
  Future<void> fetchInstalledNovelExtensions() async {}

  Future<List<Source>> _loadInstalled(ItemType type) async {
    try {
      final extPath = await _getExtensionsPath();
      final result = await IosFfiBridge().invokeMethod('loadExtensions', {
        'folderPath': extPath,
      });

      final parsed = <ASource>[];
      for (final e in (result as List)) {
        final map = e as Map<String, dynamic>;
        final detectedType = map['type'] == 'anime' ? ItemType.anime : ItemType.manga;
        if (detectedType != type) continue;

        final className = map['className'] as String;
        final pkgName = (map['pkgName'] as String?)?.isNotEmpty == true
            ? map['pkgName'] as String
            : (className.contains('.')
                ? className.substring(0, className.lastIndexOf('.'))
                : className);

        final aSource = ASource(
          id: map['id']?.toString() ?? className,
          name: map['name'] as String?,
          lang: map['lang'] as String?,
          pkgName: pkgName,
          version: getVal<String>('ios_ext_version_$pkgName') ?? map['version'] as String? ?? '1.0.0',
          isNsfw: map['isNsfw'] as bool? ?? false,
          baseUrl: map['baseUrl'] as String?,
          itemType: detectedType,
          iconUrl: getVal<String>('ios_ext_icon_$pkgName') ?? 'https://aniyomi.org/img/logo-128px.png',
        );
        aSource.managerId = id;
        parsed.add(aSource);
      }
      return parsed;
    } catch (e) {
      Logger.log('Failed to load iOS extensions: $e');
      return [];
    }
  }

  // ── Fetch available (from repos) ────────────────────────────────
  @override
  Future<void> fetchAnimeExtensions() async {
    getAvailableRx(ItemType.anime).value = await _fetchExtensions(ItemType.anime);
  }

  @override
  Future<void> fetchMangaExtensions() async {
    getAvailableRx(ItemType.manga).value = await _fetchExtensions(ItemType.manga);
  }

  @override
  Future<void> fetchNovelExtensions() async {}

  Future<List<Source>> _fetchExtensions(ItemType type) async {
    final repos = _loadRepos(type);
    if (repos.isEmpty) return const [];
    getReposRx(type).value = repos;
    final client = HttpClient();
    final results = await Future.wait(repos.map((r) => _fetchRepo(r, type, client)));
    client.close();
    final all = results.expand((e) => e).toList(growable: false);
    final installedIds = getInstalledRx(type).value.map((e) => e.id).toSet();
    _detectUpdates(all.whereType<ASource>().toList(), type);
    getRawAvailableRx(type).value = List.unmodifiable(all);
    return List.unmodifiable(all.where((s) => !installedIds.contains(s.id)));
  }

  Future<List<Source>> _fetchRepo(Repo repo, ItemType type, HttpClient client) async {
    try {
      final req = await client.getUrl(Uri.parse(repo.url));
      final res = await req.close();
      if (res.statusCode != 200) return const [];
      final builder = BytesBuilder();
      await for (final chunk in res) { builder.add(chunk); }
      return compute(_parseExtensions, (builder.takeBytes(), repo.url, type));
    } catch (e) {
      Logger.log('Repo failed ${repo.url}: $e');
      return const [];
    }
  }

  static List<Source> _parseExtensions((Uint8List, String, ItemType) args) {
    final (bodyBytes, repoUrl, targetType) = args;
    try {
      var bytes = bodyBytes as List<int>;
      if (bytes.length >= 2 && bytes[0] == 0x1F && bytes[1] == 0x8B) {
        try { bytes = gzip.decode(bytes); } catch (_) {}
      }
      final isJson = bytes.isNotEmpty && (bytes[0] == 0x7B || bytes[0] == 0x5B);
      final List<dynamic> decoded;
      if (isJson) {
        final parsed = jsonDecode(utf8.decode(bytes));
        if (parsed is! List) return const [];
        decoded = parsed;
      } else {
        decoded = PbDecoder.decodeIndex(bytes);
      }
      final baseIconUrl = repoUrl
          .replaceAll('/index.min.json', '')
          .replaceAll('/index.pb.gz', '')
          .replaceAll('/index.pb', '');
      final sources = <Source>[];
      for (final item in decoded) {
        final map = item as Map<String, dynamic>;
        final name = map['name'] as String? ?? '';
        var detectedType = name.startsWith('Aniyomi: ') ? ItemType.anime
            : name.startsWith('Tachiyomi: ') ? ItemType.manga : null;
        if (detectedType == null) {
          final pkg = map['pkg'] as String? ?? '';
          detectedType = pkg.contains('.anime.') ? ItemType.anime
              : pkg.contains('.manga.') ? ItemType.manga : targetType;
        }
        if (detectedType != targetType) continue;
        sources.add(ASource(
          id: map['sources'] is List && (map['sources'] as List).isNotEmpty
              ? (map['sources'] as List).first['id']?.toString() ?? '' : '',
          name: name.startsWith('Aniyomi: ') ? name.substring(9)
              : name.startsWith('Tachiyomi: ') ? name.substring(10) : name,
          pkgName: map['pkg'], apkName: map['apk'], lang: map['lang'],
          version: map['version'], isNsfw: map['isNsfw'] ?? false,
          itemType: detectedType, repo: repoUrl,
          iconUrl: '$baseIconUrl/icon/${map['pkg']}.png',
        ));
      }
      final Map<String, List<ASource>> grouped = {};
      for (final s in sources) {
        final key = (s as ASource).pkgName ?? s.name ?? 'unknown';
        grouped.putIfAbsent(key, () => []).add(s);
      }
      final filtered = <ASource>[];
      for (final group in grouped.values) {
        if (group.length > 1) {
          final allSource = group.firstWhere((s) => s.lang == 'all',
              orElse: () => group.firstWhere((s) => s.lang == 'en', orElse: () => group.first));
          for (final s in group) { s.langs = group; }
          filtered.add(allSource);
        } else { filtered.add(group.first); }
      }
      return List.unmodifiable(filtered);
    } catch (e) {
      debugPrint('[iOS Aniyomi] Failed to parse extensions from $repoUrl: $e');
      return const [];
    }
  }

  void _detectUpdates(List<ASource> available, ItemType type) {
    final installed = getInstalledRx(type).value.whereType<ASource>().toList();
    bool changed = false;
    for (var i = 0; i < installed.length; i++) {
      final inst = installed[i];
      final repo = available.firstWhereOrNull((s) {
        if (inst.pkgName != null && inst.pkgName!.isNotEmpty) return s.pkgName == inst.pkgName;
        return s.id == inst.id || s.name == inst.name;
      });
      if (repo == null) continue;
      if (compareVersions(repo.version ?? '0', inst.version ?? '0') > 0) {
        installed[i] = inst..hasUpdate = true..apkName = repo.apkName..iconUrl = repo.iconUrl..versionLast = repo.version;
        changed = true;
      }
    }
    if (changed) getInstalledRx(type).value = List.unmodifiable(installed);
  }

  @override
  Future<void> addRepo(String repoUrl, ItemType type) async {
    final uri = Uri.tryParse(repoUrl);
    if (uri == null || !uri.hasScheme) throw Exception('Invalid repo URL');
    final repos = _loadRepos(type);
    if (repos.any((r) => r.url == repoUrl)) return;
    final client = HttpClient();
    final req = await client.getUrl(uri);
    final res = await req.close();
    client.close();
    if (res.statusCode != 200) throw Exception('Failed to fetch repo');
    final repo = Repo(url: repoUrl, managerId: id);
    final updatedRepos = List<Repo>.from(repos)..add(repo);
    _saveRepos(updatedRepos, type);
    final builder = BytesBuilder();
    await for (final chunk in res) { builder.add(chunk); }
    final parsed = await compute(_parseExtensions, (builder.takeBytes(), repoUrl, type));
    final rx = getAvailableRx(type);
    final existing = rx.value;
    final merged = {for (final s in existing) s.id: s, for (final s in parsed) s.id: s}.values.toList(growable: false);
    rx.value = List.unmodifiable(merged);
    getReposRx(type).value = updatedRepos;
  }

  @override
  Future<void> removeRepo(String repoUrl, ItemType type) async {
    final repos = _loadRepos(type).where((r) => r.url != repoUrl).toList(growable: false);
    _saveRepos(repos, type);
    getAvailableRx(type).value = getAvailableRx(type).value.where((s) => s.repo != repoUrl).toList();
    getReposRx(type).value = repos;
  }

  List<Repo> _loadRepos(ItemType type) {
    final newKey = 'aniyomi${type.name}Repos';
    final oldKey = 'aniyomi${type.name}ReposV2';
    final encoded = getVal<List<String>>(newKey) ?? getVal<List<String>>(oldKey);
    if (encoded == null || encoded.isEmpty) return const [];
    return encoded.map((e) => Repo.fromJson(jsonDecode(e))).toSet().toList(growable: false);
  }

  void _saveRepos(List<Repo> repos, ItemType type) {
    setVal('aniyomi${type.name}Repos', repos.toSet().map((e) => jsonEncode(e.toJson())).toList(growable: false));
  }

  @override
  Future<void> installSource(Source source, {String? customPath}) async {
    var aSource = source as ASource;
    if (aSource.apkUrl == null || aSource.apkUrl!.isEmpty) {
      final type = aSource.itemType ?? ItemType.anime;
      final repoMatch = getAvailableRx(type).value.whereType<ASource>().firstWhereOrNull((s) =>
          (s.pkgName != null && s.pkgName == aSource.pkgName) || s.id == aSource.id || s.name == aSource.name);
      if (repoMatch != null) { aSource.apkName = repoMatch.apkName; aSource.iconUrl = repoMatch.iconUrl; aSource.repo = repoMatch.repo; }
    }
    if (aSource.apkUrl == null || aSource.apkUrl!.isEmpty) return Future.error('Source APK URL is required.');
    try {
      final pkgName = aSource.pkgName ?? aSource.apkName?.replaceAll('.apk', '') ?? 'unknown_ext';
      final extDir = await _getExtensionsPath();
      final tempZipPath = p.join(extDir, '$pkgName.zip');
      final outJarPath = p.join(extDir, '$pkgName.jar');

      // Download APK
      final client = HttpClient();
      final req = await client.getUrl(Uri.parse(aSource.apkUrl!));
      final res = await req.close();
      client.close();
      if (res.statusCode != 200) throw Exception('Failed to download extension APK: HTTP ${res.statusCode}');
      final builder = BytesBuilder();
      await for (final chunk in res) { builder.add(chunk); }
      File(tempZipPath).writeAsBytesSync(builder.takeBytes());

      // Convert APK → JAR via embedded JVM (dex2jar inside the runtime JAR)
      Logger.log('[iOS] Converting APK to JAR via embedded JVM...');
      await IosFfiBridge().invokeMethod('convertApk', {
        'apkPath': tempZipPath,
        'outJarPath': outJarPath,
      });

      if (aSource.iconUrl != null) setVal('ios_ext_icon_$pkgName', aSource.iconUrl);
      final versionToSave = aSource.hasUpdate == true ? aSource.versionLast : aSource.version;
      if (versionToSave != null) setVal('ios_ext_version_$pkgName', versionToSave);

      try {
        if (File(tempZipPath).existsSync()) File(tempZipPath).deleteSync();
      } catch (_) {}

      final avail = getAvailableRx(aSource.itemType!);
      avail.value = avail.value.where((e) => e.id != aSource.id).toList();
      if (aSource.itemType == ItemType.anime) { await fetchInstalledAnimeExtensions(); } else { await fetchInstalledMangaExtensions(); }
    } catch (e) {
      Logger.log('Error installing iOS source: $e');
      rethrow;
    }
  }

  @override
  Future<void> uninstallSource(Source source) async {
    final s = source as ASource;
    final pkgName = s.pkgName;
    if (pkgName == null || pkgName.isEmpty) throw Exception('Source ID required');
    try {
      try { await IosFfiBridge().invokeMethod('unloadExtension', {'sourceId': s.id}); } catch (_) {}
      final extPath = await _getExtensionsPath();
      final jarPath = p.join(extPath, '$pkgName.jar');
      if (File(jarPath).existsSync()) File(jarPath).deleteSync();
      KvStore.remove('ios_ext_icon_$pkgName');
      KvStore.remove('ios_ext_version_$pkgName');
      final raw = getRawAvailableRx(s.itemType!).value;
      final installed = getInstalledRx(s.itemType!).value.where((e) => e.id != s.id).toList();
      getInstalledRx(s.itemType!).value = installed;
      final installedIds = installed.map((e) => e.id).toSet();
      getAvailableRx(s.itemType!).value = List.unmodifiable(raw.where((e) => !installedIds.contains(e.id)));
    } catch (e) {
      Logger.log('Error uninstalling $pkgName: $e');
      rethrow;
    }
  }

  @override
  Future<void> updateSource(Source source) async => installSource(source);

  @override
  Future<void> cancelRequest(String token) async {}

  @override
  Set<String> get schemes => {'aniyomi', 'tachiyomi'};

  @override
  void handleSchemes(Uri uri) {
    final url = uri.queryParameters['url'];
    if (url != null && url.isNotEmpty) {
      addRepo(url, uri.scheme == 'aniyomi' ? ItemType.anime : ItemType.manga);
    }
  }
}