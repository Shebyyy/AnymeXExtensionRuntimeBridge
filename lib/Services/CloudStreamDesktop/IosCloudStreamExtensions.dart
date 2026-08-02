import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:get/get.dart';
import 'package:archive/archive_io.dart';

import '../../Logger.dart';
import '../../Settings/KvStore.dart';
import 'package:collection/collection.dart';
import '../../Models/Source.dart';
import '../../Extensions/Extensions.dart';
import '../../Extensions/SourceMethods.dart';
import '../../Runtime/RuntimePaths.dart';
import '../../Runtime/RuntimeController.dart';
import '../../Runtime/Bridge/IosFfiBridge.dart';
import '../../Runtime/IosExtensionBase.dart';
import 'DesktopCloudStreamSourceMethods.dart';

List<dynamic> _decodeJsonList(String body) => jsonDecode(body) as List<dynamic>;
Map<String, dynamic> _decodeJsonMap(String body) => jsonDecode(body) as Map<String, dynamic>;
String _normalizeName(String? name) {
  if (name == null) return '';
  return name.replaceAll(RegExp(r'[^a-zA-Z0-9 ]'), '').trim();
}

/// iOS CloudStream extensions — uses embedded JVM via FFI.
class IosCloudStreamExtensions extends IosExtensionBase {
  final _client = http.Client();

  @override
  String get id => 'cloudstream-ios';
  @override
  String get name => 'CloudStream (iOS)';
  @override
  bool get supportsNovel => false;
  @override
  bool get supportsManga => false;
  @override
  bool get requiresPlugin => true;
  @override
  SourceMethods createSourceMethods(Source source) => DesktopCloudStreamSourceMethods(source);

  Future<String> _getExtensionsPath() async => getExtensionsPath('CloudStream');

  @override
  Future<void> fetchInstalledAnimeExtensions() async {
    try {
      final extPath = await _getExtensionsPath();
      final result = await IosFfiBridge().invokeMethod('csLoadExtensions', {'folderPath': extPath});
      final list = <CloudStreamSource>[];
      if (result is List) {
        for (final e in result) {
          final map = e as Map<String, dynamic>;
          final src = CloudStreamSource(
            id: map['name']?.toString() ?? '',
            name: _normalizeName(map['name']?.toString()),
            internalName: map['name']?.toString() ?? '',
            type: map['type']?.toString() ?? '',
            iconUrl: getVal<String>('ios_cs_icon_${map['name']}') ?? '',
            isNsfw: map['isNsfw'] as bool? ?? false,
            repo: '',
          );
          src.managerId = id;
          src.itemType = ItemType.anime;
          list.add(src);
        }
      }
      getInstalledRx(ItemType.anime).value = list;
    } catch (e) {
      Logger.log('Failed to load iOS CloudStream extensions: $e');
    }
  }

  @override
  Future<void> fetchInstalledMangaExtensions() async {}
  @override
  Future<void> fetchInstalledNovelExtensions() async {}

  @override
  Future<void> fetchAnimeExtensions() async {
    final res = await _fetchExtensions(ItemType.anime);
    getAvailableRx(ItemType.anime).value = res;
  }
  @override
  Future<void> fetchMangaExtensions() async {}
  @override
  Future<void> fetchNovelExtensions() async {}

  Future<List<Source>> _fetchExtensions(ItemType type) async {
    final repos = _loadRepos(type);
    if (repos.isEmpty) return const [];
    getReposRx(type).value = repos;
    final results = await Future.wait(repos.map((r) => _fetchRepo(r)));
    final all = results.expand((e) => e).toList();
    getRawAvailableRx(type).value = List.unmodifiable(all);
    final installedIds = getInstalledRx(type).value.map((e) => e.id).toSet();
    return List.unmodifiable(all.where((s) => !installedIds.contains(s.id)));
  }

  Future<List<Source>> _fetchRepo(Repo repo) async {
    try {
      final res = await _client.get(Uri.parse(repo.url));
      if (res.statusCode != 200) return const [];
      final data = jsonDecode(res.body) as List<dynamic>;
      final repoBase = repo.url.replaceAll('/repo.min.json', '').replaceAll('/extensions.json', '');
      return data.map((e) {
        final map = e as Map<String, dynamic>;
        return CloudStreamSource(
          id: map['name']?.toString() ?? '',
          name: _normalizeName(map['name']?.toString()),
          internalName: map['name']?.toString() ?? '',
          type: map['type']?.toString() ?? '',
          tvType: map['tvType']?.toString() ?? '',
          iconUrl: map['iconUrl']?.toString() ?? '$repoBase/${map['name']}.png',
          isNsfw: map['isNsfw'] as bool? ?? false,
          repo: repo.url,
        );
      }).toList();
    } catch (e) {
      Logger.log('CS repo failed ${repo.url}: $e');
      return const [];
    }
  }

  @override
  Future<void> installSource(Source source, {String? customPath}) async {
    final cs = source as CloudStreamSource;
    try {
      final extPath = await _getExtensionsPath();
      final fileUrl = customPath ?? cs.apkUrl ?? '';
      if (fileUrl.isEmpty) throw Exception('No download URL');

      final tempPath = p.join(extPath, '${cs.internalName}.apk');
      final res = await _client.get(Uri.parse(fileUrl));
      if (res.statusCode != 200) throw Exception('Download failed: ${res.statusCode}');
      await File(tempPath).writeAsBytes(res.bodyBytes);

      await IosFfiBridge().invokeMethod('csLoadPlugin', {'path': tempPath});
      if (cs.iconUrl != null) setVal('ios_cs_icon_${cs.internalName}', cs.iconUrl);

      final avail = getAvailableRx(ItemType.anime);
      avail.value = avail.value.where((e) => e.id != cs.id).toList();
      await fetchInstalledAnimeExtensions();
    } catch (e) {
      Logger.log('Error installing CS source: $e');
      rethrow;
    }
  }

  @override
  Future<void> uninstallSource(Source source) async {
    final cs = source as CloudStreamSource;
    try {
      await IosFfiBridge().invokeMethod('csUnloadPlugin', {'internalName': cs.internalName});
      KvStore.remove('ios_cs_icon_${cs.internalName}');
      final installed = getInstalledRx(ItemType.anime).value.where((e) => e.id != cs.id).toList();
      getInstalledRx(ItemType.anime).value = installed;
    } catch (e) {
      Logger.log('Error uninstalling CS: $e'); rethrow;
    }
  }

  @override
  Future<void> updateSource(Source source) async => installSource(source);
  @override
  Future<void> cancelRequest(String token) async {}
  @override
  Set<String> get schemes => {'cloudstream'};
  @override
  void handleSchemes(Uri uri) {}

  List<Repo> _loadRepos(ItemType type) {
    final encoded = getVal<List<String>>('cloudstreamRepos');
    if (encoded == null || encoded.isEmpty) return const [];
    return encoded.map((e) => Repo.fromJson(jsonDecode(e))).toSet().toList();
  }

  @override
  Future<void> addRepo(String repoUrl, ItemType type) async {
    final repos = _loadRepos(type);
    if (repos.any((r) => r.url == repoUrl)) return;
    final repo = Repo(url: repoUrl, managerId: id);
    _saveRepos([...repos, repo], type);
    final parsed = await _fetchRepo(repo);
    final rx = getAvailableRx(type);
    final existing = rx.value;
    final merged = {for (final s in existing) s.id: s, for (final s in parsed) s.id: s}.values.toList();
    rx.value = List.unmodifiable(merged);
    getReposRx(type).value = [...repos, repo];
  }

  @override
  Future<void> removeRepo(String repoUrl, ItemType type) async {
    final repos = _loadRepos(type).where((r) => r.url != repoUrl).toList();
    _saveRepos(repos, type);
    getAvailableRx(type).value = getAvailableRx(type).value.where((s) => s.repo != repoUrl).toList();
    getReposRx(type).value = repos;
  }

  void _saveRepos(List<Repo> repos, ItemType type) {
    setVal('cloudstreamRepos', repos.toSet().map((e) => jsonEncode(e.toJson())).toList());
  }
}
