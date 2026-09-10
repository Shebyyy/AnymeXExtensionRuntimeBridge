import 'dart:convert';
import 'package:http/http.dart' as http;

import '../../Extensions/SourceMethods.dart';
import '../../Logger.dart';
import '../../Models/DEpisode.dart';
import '../../Models/DMedia.dart';
import '../../Models/Page.dart';
import '../../Models/Pages.dart';
import '../../Models/Source.dart';
import '../../Models/SourceParams.dart';
import '../../Models/SourcePreference.dart';
import '../../Models/Video.dart';
import 'JsEngine/NuvioJsEngine.dart';
import 'Models/NuvioSource.dart';

class NuvioSourceMethods implements SourceMethods {
  final NuvioSource _source;
  final http.Client _client = http.Client();

  static const String _defaultTmdbKey = '439c478a771f35c05022f9feabcca01c';

  NuvioSourceMethods(Source source) : _source = source as NuvioSource;

  @override
  Source get source => _source;

  String get _apiKey => _defaultTmdbKey;

  Map<String, String> get _headers => {
        'User-Agent':
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
                '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
        'Accept': 'application/json',
      };

  @override
  Future<Pages> getPopular(int page, {SourceParams? parameters}) async {
    try {
      final uri = Uri.parse(
          'https://api.themoviedb.org/3/trending/all/day?api_key=$_apiKey&page=$page');
      final res = await _client.get(uri, headers: _headers);

      if (res.statusCode != 200) return Pages(list: const []);

      final data = jsonDecode(res.body);
      final results = (data['results'] as List?) ?? const [];
      final totalPages = (data['total_pages'] as int?) ?? 1;

      final list = results
          .whereType<Map>()
          .map((item) => _mapTmdbToMedia(item))
          .whereType<DMedia>()
          .toList();

      return Pages(list: list, hasNextPage: page < totalPages);
    } catch (e) {
      Logger.log("Nuvio getPopular error: $e");
      return Pages(list: const []);
    }
  }

  @override
  Future<Pages> getLatestUpdates(int page, {SourceParams? parameters}) async {
    try {
      final uri = Uri.parse(
          'https://api.themoviedb.org/3/movie/now_playing?api_key=$_apiKey&page=$page');
      final res = await _client.get(uri, headers: _headers);

      if (res.statusCode != 200) return Pages(list: const []);

      final data = jsonDecode(res.body);
      final results = (data['results'] as List?) ?? const [];
      final totalPages = (data['total_pages'] as int?) ?? 1;

      final list = results
          .whereType<Map>()
          .map((item) => _mapTmdbToMedia(item, forcedType: 'movie'))
          .whereType<DMedia>()
          .toList();

      return Pages(list: list, hasNextPage: page < totalPages);
    } catch (e) {
      Logger.log("Nuvio getLatestUpdates error: $e");
      return Pages(list: const []);
    }
  }

  @override
  Future<Pages> search(String query, int page, List filters,
      {SourceParams? parameters}) async {
    if (query.trim().isEmpty) return Pages(list: const []);

    try {
      final encoded = Uri.encodeComponent(query.trim());
      final uri = Uri.parse(
          'https://api.themoviedb.org/3/search/multi?api_key=$_apiKey&query=$encoded&page=$page');
      final res = await _client.get(uri, headers: _headers);

      if (res.statusCode != 200) return Pages(list: const []);

      final data = jsonDecode(res.body);
      final results = (data['results'] as List?) ?? const [];
      final totalPages = (data['total_pages'] as int?) ?? 1;

      final list = results
          .whereType<Map>()
          .map((item) => _mapTmdbToMedia(item))
          .whereType<DMedia>()
          .toList();

      return Pages(list: list, hasNextPage: page < totalPages);
    } catch (e) {
      Logger.log("Nuvio search error: $e");
      return Pages(list: const []);
    }
  }

  DMedia? _mapTmdbToMedia(Map item, {String? forcedType}) {
    final mediaType = forcedType ?? item['media_type']?.toString();
    if (mediaType != 'movie' && mediaType != 'tv') return null;

    final id = item['id'];
    if (id == null) return null;

    final title = item['title'] ?? item['name'] ?? item['original_title'] ?? item['original_name'];
    final poster = item['poster_path']?.toString();
    final cover = poster != null ? 'https://image.tmdb.org/t/p/w500$poster' : null;
    final overview = item['overview']?.toString();

    return DMedia(
      title: title?.toString(),
      url: '$id;$mediaType',
      cover: cover,
      description: overview,
    );
  }

  @override
  Future<DMedia> getDetail(DMedia media, {SourceParams? parameters}) async {
    final rawUrl = media.url ?? '';
    final parts = rawUrl.split(';');
    final tmdbId = parts[0];
    final mediaType = parts.length > 1 ? parts[1].toLowerCase() : 'movie';

    try {
      if (mediaType == 'tv') {
        final uri = Uri.parse(
            'https://api.themoviedb.org/3/tv/$tmdbId?api_key=$_apiKey');
        final res = await _client.get(uri, headers: _headers);
        if (res.statusCode != 200) return media;

        final data = jsonDecode(res.body);
        final title = data['name'] ?? data['original_name'] ?? media.title;
        final poster = data['poster_path']?.toString();
        final cover = poster != null ? 'https://image.tmdb.org/t/p/w500$poster' : media.cover;
        final description = data['overview']?.toString() ?? media.description;
        final genres = (data['genres'] as List?)
                ?.map((g) => g['name']?.toString() ?? '')
                .where((g) => g.isNotEmpty)
                .toList() ??
            media.genre ??
            [];

        final episodes = <DEpisode>[];
        final seasons = (data['seasons'] as List?) ?? const [];

        for (final s in seasons) {
          final sNum = s['season_number'];
          if (sNum == null || (sNum is int && sNum < 1)) continue;

          try {
            final sUri = Uri.parse(
                'https://api.themoviedb.org/3/tv/$tmdbId/season/$sNum?api_key=$_apiKey');
            final sRes = await _client.get(sUri, headers: _headers);
            if (sRes.statusCode == 200) {
              final sData = jsonDecode(sRes.body);
              final epList = (sData['episodes'] as List?) ?? const [];

              for (final ep in epList) {
                final epNum = ep['episode_number']?.toString() ?? '1';
                final epName = ep['name']?.toString() ?? '';
                final epStill = ep['still_path']?.toString();
                final thumb = epStill != null ? 'https://image.tmdb.org/t/p/w500$epStill' : null;

                episodes.add(
                  DEpisode(
                    episodeNumber: epNum,
                    name: 'S$sNum E$epNum${epName.isNotEmpty ? " - $epName" : ""}',
                    thumbnail: thumb,
                    description: ep['overview']?.toString(),
                    dateUpload: ep['air_date']?.toString(),
                    url: '$tmdbId;tv;$sNum;$epNum',
                  ),
                );
              }
            }
          } catch (se) {
            Logger.log("Nuvio season $sNum fetch error: $se");
          }
        }

        return DMedia(
          title: title,
          url: media.url,
          cover: cover,
          description: description,
          genre: genres,
          episodes: episodes,
        );
      } else {
        // movie
        final uri = Uri.parse(
            'https://api.themoviedb.org/3/movie/$tmdbId?api_key=$_apiKey');
        final res = await _client.get(uri, headers: _headers);

        String? title = media.title;
        String? cover = media.cover;
        String? description = media.description;
        List<String> genres = media.genre ?? [];

        if (res.statusCode == 200) {
          final data = jsonDecode(res.body);
          title = data['title'] ?? data['original_title'] ?? title;
          final poster = data['poster_path']?.toString();
          if (poster != null) cover = 'https://image.tmdb.org/t/p/w500$poster';
          description = data['overview']?.toString() ?? description;
          genres = (data['genres'] as List?)
                  ?.map((g) => g['name']?.toString() ?? '')
                  .where((g) => g.isNotEmpty)
                  .toList() ??
              genres;
        }

        final singleEpisode = DEpisode(
          episodeNumber: '1',
          name: title ?? 'Full Movie',
          thumbnail: cover,
          url: '$tmdbId;movie;1;1',
        );

        return DMedia(
          title: title,
          url: media.url,
          cover: cover,
          description: description,
          genre: genres,
          episodes: [singleEpisode],
        );
      }
    } catch (e) {
      Logger.log("Nuvio getDetail error: $e");
      return media;
    }
  }

  @override
  Future<List<Video>> getVideoList(DEpisode episode,
      {SourceParams? parameters}) async {
    final rawUrl = episode.url ?? '';
    final parts = rawUrl.split(';');
    String tmdbId = parts.isNotEmpty ? parts[0] : '';
    String mediaType = parts.length > 1 ? parts[1].toLowerCase() : 'movie';
    int season = parts.length > 2 ? int.tryParse(parts[2]) ?? 1 : 1;
    int epNum = parts.length > 3 ? int.tryParse(parts[3]) ?? 1 : 1;

    if (episode.sortMap != null && episode.sortMap!['season'] != null) {
      final s = int.tryParse(episode.sortMap!['season']!);
      if (s != null && s > 0) season = s;
    }
    final epParsed = double.tryParse(episode.episodeNumber)?.toInt();
    if (epParsed != null && epParsed > 0) {
      epNum = epParsed;
    }

    if (int.tryParse(tmdbId) == null && rawUrl.contains('themoviedb.org')) {
      final match = RegExp(r'themoviedb\.org/(movie|tv)/(\d+)').firstMatch(rawUrl);
      if (match != null) {
        mediaType = match.group(1)!;
        tmdbId = match.group(2)!;
      }
    }

    if (tmdbId.isEmpty) return const [];

    final engine = NuvioJsEngine.instance;

    if (_source.sourceCode != null && _source.sourceCode!.isNotEmpty) {
      await engine.loadModule(
        moduleId: _source.id ?? '',
        sourceCode: _source.sourceCode!,
      );
    } else if (_source.sourceCodeUrl != null && _source.sourceCodeUrl!.isNotEmpty) {
      final res = await _client.get(Uri.parse(_source.sourceCodeUrl!));
      if (res.statusCode == 200) {
        _source.sourceCode = res.body;
        await engine.loadModule(
          moduleId: _source.id ?? '',
          sourceCode: res.body,
        );
      }
    }

    try {
      final streams = await engine.getStreams(
        moduleId: _source.id ?? '',
        tmdbId: int.tryParse(tmdbId) ?? tmdbId,
        mediaType: mediaType,
        season: season,
        episode: epNum,
      );

      final videoList = <Video>[];

      for (final s in streams) {
        if (s is! Map) continue;

        final streamUrl = s['url']?.toString() ?? '';
        if (streamUrl.isEmpty) continue;

        final title = s['title']?.toString() ??
            s['name']?.toString() ??
            '${_source.name} Stream';
        final quality = s['quality']?.toString() ?? 'Auto';

        Map<String, String>? headers;
        if (s['headers'] is Map) {
          headers = (s['headers'] as Map).map(
            (k, v) => MapEntry(k.toString(), v.toString()),
          );
        }

        videoList.add(
          Video(
            title,
            streamUrl,
            quality,
            headers: headers,
            extraData: Map<String, dynamic>.from(s),
          ),
        );
      }

      return videoList;
    } catch (e) {
      Logger.log("Nuvio getVideoList error: $e");
      return const [];
    }
  }

  @override
  Stream<Video>? getVideoListStream(DEpisode episode,
          {SourceParams? parameters}) =>
      null;

  @override
  Future<void> stopHttpServer() async {}

  @override
  Future<List<PageUrl>> getPageList(DEpisode episode,
          {SourceParams? parameters}) async =>
      const [];

  @override
  Future<String?> getNovelContent(String chapterTitle, String chapterId,
          {SourceParams? parameters}) async =>
      null;

  @override
  Future<List<dynamic>> getFilterList() async => const [];

  @override
  Future<void> cancelRequest(String token) async {}

  @override
  Future<List<SourcePreference>> getPreference() async => const [];

  @override
  Future<bool> setPreference(SourcePreference pref, dynamic value) async => true;
}
