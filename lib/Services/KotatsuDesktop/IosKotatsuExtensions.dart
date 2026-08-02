import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import '../../Logger.dart';
import '../../Settings/KvStore.dart';
import '../../Models/Source.dart';
import '../../Extensions/Extensions.dart';
import '../../Extensions/SourceMethods.dart';
import '../../Runtime/RuntimePaths.dart';
import '../../Runtime/RuntimeController.dart';
import '../../Runtime/Bridge/IosFfiBridge.dart';
import '../../Runtime/IosExtensionBase.dart';
import 'DesktopKotatsuSourceMethods.dart';
import '../Mangayomi/http/m_client.dart';

/// iOS Kotatsu extensions — uses embedded JVM via FFI.
class IosKotatsuExtensions extends IosExtensionBase {
  final _client = MClient.init();

  @override
  String get id => 'kotatsu-ios';
  @override
  String get name => 'Kotatsu (iOS)';
  @override
  bool get supportsAnime => false;
  @override
  bool get supportsNovel => false;
  @override
  bool get requiresPlugin => true;
  @override
  SourceMethods createSourceMethods(Source source) => DesktopKotatsuSourceMethods(source);

  Future<String> _getExtensionsPath() async => getExtensionsPath('Kotatsu');

  @override
  Future<void> fetchInstalledMangaExtensions() async {
    try {
      final extPath = await _getExtensionsPath();
      final result = await IosFfiBridge().invokeMethod('kotatsuLoadExtensions', {'folderPath': extPath});
      final list = <KotatsuSource>[];
      if (result is List) {
        for (final e in result) {
          final map = e as Map<String, dynamic>;
          final src = KotatsuSource(
            id: map['id']?.toString() ?? '',
            name: map['name'] as String? ?? '',
            lang: map['lang'] as String?,
            isNsfw: map['isNsfw'] as bool? ?? false,
            repo: '',
          );
          src.managerId = id;
          src.itemType = ItemType.manga;
          list.add(src);
        }
      }
      getInstalledRx(ItemType.manga).value = list;
    } catch (e) {
      Logger.log('Failed to load iOS Kotatsu extensions: $e');
    }
  }

  @override
  Future<void> fetchInstalledAnimeExtensions() async {}
  @override
  Future<void> fetchInstalledNovelExtensions() async {}

  @override
  Future<void> fetchMangaExtensions() async {
    final res = await _fetchExtensions();
    getAvailableRx(ItemType.manga).value = res;
  }
  @override
  Future<void> fetchAnimeExtensions() async {}
  @override
  Future<void> fetchNovelExtensions() async {}

  Future<List<Source>> _fetchExtensions() async {
    final repos = _loadRepos();
    if (repos.isEmpty) return const [];
    getReposRx(ItemType.manga).value = repos;
    final results = await Future.wait(repos.map((r) => _fetchRepo(r)));
    final all = results.expand((e) => e).toList();
    getRawAvailableRx(ItemType.manga).value = List.unmodifiable(all);
    final installedIds = getInstalledRx(ItemType.manga).value.map((e) => e.id).toSet();
    return List.unmodifiable(all.where((s) => !installedIds.contains(s.id)));
  }

  Future<List<Source>> _fetchRepo(Repo repo) async {
    try {
      final res = await _client.get(Uri.parse(repo.url));
      if (res.statusCode != 200) return const [];
      return compute(_parseExtensions, (res.bodyBytes, repo.url));
    } catch (e) {
      Logger.log('Kotatsu repo failed ${repo.url}: $e');
      return const [];
    }
  }

  static List<Source> _parseExtensions((List<int>, String) args) {
    final (bodyBytes, repoUrl) = args;
    try {
      final body = utf8.decode(bodyBytes as Uint8List);
      final data = jsonDecode(body) as List<dynamic>;
      final repoBase = repoUrl.replaceAll('/index.json', '');
      return data.map((e) {
        final map = e as Map<String, dynamic>;
        return KotatsuSource(
          id: map['sourceId']?.toString() ?? '',
          name: map['name'] as String? ?? '',
          lang: map['lang'] as String?,
          isNsfw: map['nsfw'] as bool? ?? false,
          repo: repoUrl,
          apkUrl: '$repoBase/${map['file']}',
          iconUrl: '$repoBase/${map['icon']}',
        );
      }).toList();
    } catch (e) {
      debugPrint('[iOS Kotatsu] Failed to parse: $e');
      return const [];
    }
  }

  @override
  Future<void> installSource(Source source, {String? customPath}) async {
    final ks = source as KotatsuSource;
    try {
      final extPath = await _getExtensionsPath();
      final fileUrl = customPath ?? ks.apkUrl ?? '';
      if (fileUrl.isEmpty) throw Exception('No download URL');
      final tempPath = p.join(extPath, '${ks.id}.zip');
      final outJarPath = p.join(extPath, '${ks.id}.jar');
      final apkRes = await _client.get(Uri.parse(fileUrl));
      if (apkRes.statusCode != 200) throw Exception('Download failed: ${apkRes.statusCode}');
      File(tempPath).writeAsBytesSync(apkRes.bodyBytes);
      await IosFfiBridge().invokeMethod('convertApk', {
        'apkPath': tempPath,
        'outJarPath': outJarPath,
      });
      try { if (File(tempPath).existsSync()) File(tempPath).deleteSync(); } catch (_) {}
      final avail = getAvailableRx(ItemType.manga);
      avail.value = avail.value.where((e) => e.id != ks.id).toList();
      await fetchInstalledMangaExtensions();
    } catch (e) {
      Logger.log('Error installing Kotatsu: $e'); rethrow;
    }
  }

  @override
  Future<void> uninstallSource(Source source) async {
    final ks = source as KotatsuSource;
    try {
      final extPath = await _getExtensionsPath();
      final jarPath = p.join(extPath, '${ks.id}.jar');
      if (File(jarPath).existsSync()) File(jarPath).deleteSync();
      getInstalledRx(ItemType.manga).value =
          getInstalledRx(ItemType.manga).value.where((e) => e.id != ks.id).toList();
    } catch (e) {
      Logger.log('Error uninstalling Kotatsu: $e'); rethrow;
    }
  }

  @override
  Future<void> updateSource(Source source) async => installSource(source);
  @override
  Future<void> cancelRequest(String token) async {}
  @override
  Set<String> get schemes => {'kotatsu'};
  @override
  void handleSchemes(Uri uri) {}

  List<Repo> _loadRepos() {
    final encoded = getVal<List<String>>('kotatsuRepos');
    if (encoded == null || encoded.isEmpty) return const [];
    return encoded.map((e) => Repo.fromJson(jsonDecode(e))).toSet().toList();
  }

  @override
  Future<void> addRepo(String repoUrl, ItemType type) async {
    final repos = _loadRepos();
    if (repos.any((r) => r.url == repoUrl)) return;
    final repo = Repo(url: repoUrl, managerId: id);
    _saveRepos([...repos, repo]);
    final parsed = await _fetchRepo(repo);
    final rx = getAvailableRx(ItemType.manga);
    final existing = rx.value;
    final merged = {for (final s in existing) s.id: s, for (final s in parsed) s.id: s}.values.toList();
    rx.value = List.unmodifiable(merged);
    getReposRx(ItemType.manga).value = [...repos, repo];
  }

  @override
  Future<void> removeRepo(String repoUrl, ItemType type) async {
    final repos = _loadRepos().where((r) => r.url != repoUrl).toList();
    _saveRepos(repos);
    getAvailableRx(ItemType.manga).value =
        getAvailableRx(ItemType.manga).value.where((s) => s.repo != repoUrl).toList();
    getReposRx(ItemType.manga).value = repos;
  }

  void _saveRepos(List<Repo> repos) {
    setVal('kotatsuRepos', repos.toSet().map((e) => jsonEncode(e.toJson())).toList());
  }
}
