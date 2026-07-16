import 'dart:convert';

import '../../../Extensions/SourceMethods.dart';
import '../../../Logger.dart';
import '../../../Models/DEpisode.dart';
import '../../../Models/DMedia.dart';
import '../../../Models/Page.dart';
import '../../../Models/Pages.dart';
import '../../../Models/Source.dart';
import '../../../Models/SourceParams.dart';
import '../../../Models/SourcePreference.dart';
import '../../../Models/Video.dart';
import 'LegadoRuleEngine.dart';
import 'Models/LegadoSource.dart';

/// SourceMethods implementation for Legado book sources.
/// Uses LegadoRuleEngine to evaluate rules for search, detail, TOC, and content.
class LegadoSourceMethods extends SourceMethods {
  @override
  final Source source;
  late final LegadoSource _legadoSource;
  late final LegadoRuleEngine _engine;

  LegadoSourceMethods(this.source) {
    if (source is LegadoSource) {
      _legadoSource = source as LegadoSource;
    } else {
      // Create a minimal LegadoSource from base Source fields
      _legadoSource = LegadoSource(
        bookSourceUrl: source.baseUrl,
        bookSourceName: source.name,
      );
      _legadoSource.id = source.id;
      _legadoSource.name = source.name;
      _legadoSource.baseUrl = source.baseUrl;
      _legadoSource.itemType = ItemType.novel;
    }
    _engine = LegadoRuleEngine(_legadoSource);
  }

  // ============================================================
  // SEARCH
  // ============================================================

  @override
  Future<Pages> search(String query, int page, List<dynamic> filters,
      {SourceParams? parameters}) async {
    final searchUrl = _legadoSource.searchUrl;
    if (searchUrl == null || searchUrl.isEmpty) {
      return Pages(list: [], hasNextPage: false);
    }

    try {
      // Resolve URL template — handle @js: searchUrl specially
      ResolvedUrl resolved;
      if (searchUrl.startsWith('@js:')) {
        // JavaScript-based searchUrl: evaluate JS to construct the URL
        final jsCode = searchUrl.substring(4);
        resolved = await _engine.resolveJsSearchUrl(
          jsCode,
          key: query,
          page: page,
        );
      } else {
        // Standard URL template
        resolved = _engine.resolveUrlTemplate(
          searchUrl,
          key: query,
          page: page,
        );
      }

      // Fetch the search page
      final content = await _engine.fetchUrl(
        resolved.url,
        extraHeaders: resolved.headers,
        body: resolved.body,
        method: resolved.method,
      );

      // Parse search results using ruleSearch
      final ruleSearch = _legadoSource.ruleSearch;
      if (ruleSearch == null) return Pages(list: [], hasNextPage: false);

      // Get the list of book elements
      final bookListRule = ruleSearch.bookList ?? '';
      if (bookListRule.isEmpty) return Pages(list: [], hasNextPage: false);

      final elements = await _engine.evalRuleList(content, bookListRule);

      final books = <DMedia>[];
      for (final element in elements) {
        try {
          final title = await _evalField(element, ruleSearch.name, content);
          final url = await _evalField(element, ruleSearch.bookUrl, content);
          final coverUrl = await _evalField(element, ruleSearch.coverUrl, content);
          final author = await _evalField(element, ruleSearch.author, content);
          final intro = await _evalField(element, ruleSearch.intro, content);
          final genre = await _evalField(element, ruleSearch.kind, content);

          if (url.isNotEmpty) {
            books.add(DMedia(
              title: title,
              url: _engine.resolveUrl(url),
              cover: coverUrl.isNotEmpty ? _engine.resolveUrl(coverUrl) : '',
              author: author,
              description: intro,
              genre: genre.isNotEmpty ? genre.split(RegExp(r'[,，\s]+')) : [],
            ));
          }
        } catch (e) {
          Logger.log('Legado: search item parse failed: $e');
          continue;
        }
      }

      // Determine hasNextPage - simple heuristic
      bool hasNextPage = false;
      if (books.isNotEmpty && page > 0) {
        // If we got results and this isn't the first page, there might be more
        hasNextPage = books.length >= 10;
      } else if (books.isNotEmpty) {
        hasNextPage = books.length >= 10;
      }

      return Pages(list: books, hasNextPage: hasNextPage);
    } catch (e) {
      Logger.log('Legado: search failed: $e');
      return Pages(list: [], hasNextPage: false);
    }
  }

  // ============================================================
  // POPULAR / LATEST
  // ============================================================

  @override
  Future<Pages> getPopular(int page, {SourceParams? parameters}) async {
    final exploreUrl = _legadoSource.exploreUrl;
    if (exploreUrl == null || exploreUrl.isEmpty) {
      return Pages(list: [], hasNextPage: false);
    }

    try {
      // Parse explore URL - format: "Name::URL\nName2::URL2" or JSON
      final firstExplore = _parseFirstExploreUrl(exploreUrl);
      if (firstExplore.isEmpty) {
        return Pages(list: [], hasNextPage: false);
      }

      final resolved = firstExplore.startsWith('@js:')
          ? await _engine.resolveJsSearchUrl(
              firstExplore.substring(4),
              page: page,
            )
          : _engine.resolveUrlTemplate(firstExplore, page: page);
      final content = await _engine.fetchUrl(
        resolved.url,
        extraHeaders: resolved.headers,
        body: resolved.body,
        method: resolved.method,
      );

      // Use ruleExplore or fallback to ruleSearch
      final ruleExplore = _legadoSource.ruleExplore;
      final ruleSearch = _legadoSource.ruleSearch;
      final bookListRule = ruleExplore?.bookList ?? ruleSearch?.bookList ?? '';
      if (bookListRule.isEmpty) return Pages(list: [], hasNextPage: false);

      final elements = await _engine.evalRuleList(content, bookListRule);

      final books = <DMedia>[];
      for (final element in elements) {
        try {
          final title = await _evalField(element, ruleExplore?.name ?? ruleSearch?.name, content);
          final url = await _evalField(element, ruleExplore?.bookUrl ?? ruleSearch?.bookUrl, content);
          final coverUrl = await _evalField(element, ruleExplore?.coverUrl ?? ruleSearch?.coverUrl, content);
          final author = await _evalField(element, ruleExplore?.author ?? ruleSearch?.author, content);
          final intro = await _evalField(element, ruleExplore?.intro ?? ruleSearch?.intro, content);

          if (url.isNotEmpty) {
            books.add(DMedia(
              title: title,
              url: _engine.resolveUrl(url),
              cover: coverUrl.isNotEmpty ? _engine.resolveUrl(coverUrl) : '',
              author: author,
              description: intro,
            ));
          }
        } catch (e) {
          continue;
        }
      }

      return Pages(list: books, hasNextPage: books.length >= 10);
    } catch (e) {
      Logger.log('Legado: getPopular failed: $e');
      return Pages(list: [], hasNextPage: false);
    }
  }

  @override
  Future<Pages> getLatestUpdates(int page, {SourceParams? parameters}) async {
    // Legado doesn't have a distinct "latest" endpoint;
    // use explore with showLatestNovels if available
    return getPopular(page, parameters: parameters);
  }

  // ============================================================
  // BOOK DETAIL
  // ============================================================

  @override
  Future<DMedia> getDetail(DMedia media, {SourceParams? parameters}) async {
    final ruleBookInfo = _legadoSource.ruleBookInfo;
    final ruleToc = _legadoSource.ruleToc;
    if (ruleBookInfo == null) return media;

    try {
      // Fetch the book detail page
      final content = await _engine.fetchUrl(media.url ?? '');

      // Run init rule if present
      String processedContent = content;
      if (ruleBookInfo.init != null && ruleBookInfo.init!.isNotEmpty) {
        final initResult = await _engine.evalRule(content, ruleBookInfo.init!);
        if (initResult.isNotEmpty) {
          processedContent = initResult;
        }
      }

      // Extract book info fields
      final name = await _engine.evalRule(processedContent, ruleBookInfo.name ?? '');
      final author = await _engine.evalRule(processedContent, ruleBookInfo.author ?? '');
      final coverUrl = await _engine.evalRule(processedContent, ruleBookInfo.coverUrl ?? '');
      final intro = await _engine.evalRule(processedContent, ruleBookInfo.intro ?? '');
      final kind = await _engine.evalRule(processedContent, ruleBookInfo.kind ?? '');
      final tocUrl = await _engine.evalRule(processedContent, ruleBookInfo.tocUrl ?? '');

      // Determine TOC URL - might be same page or different
      final actualTocUrl = tocUrl.isNotEmpty ? _engine.resolveUrl(tocUrl) : (media.url ?? '');

      // Fetch chapters from TOC page
      List<DEpisode> chapters = [];
      if (ruleToc != null) {
        chapters = await _fetchChapters(actualTocUrl, ruleToc, processedContent);
      }

      return DMedia(
        title: name.isNotEmpty ? name : media.title,
        url: media.url,
        cover: coverUrl.isNotEmpty ? _engine.resolveUrl(coverUrl) : media.cover,
        description: intro.isNotEmpty ? intro : media.description,
        author: author.isNotEmpty ? author : media.author,
        genre: kind.isNotEmpty ? kind.split(RegExp(r'[,，\s]+')) : media.genre,
        episodes: chapters,
      );
    } catch (e) {
      Logger.log('Legado: getDetail failed: $e');
      return media;
    }
  }

  /// Fetch chapter list with pagination support via nextTocUrl
  Future<List<DEpisode>> _fetchChapters(
    String tocUrl,
    RuleToc ruleToc,
    String initialContent,
  ) async {
    final chapters = <DEpisode>[];
    final chapterListRule = ruleToc.chapterList ?? '';
    if (chapterListRule.isEmpty) return chapters;

    var currentUrl = tocUrl;
    var content = initialContent;
    final visitedUrls = <String>{};
    int pageCount = 0;
    const maxPages = 20; // Safety limit for TOC pagination

    while (currentUrl.isNotEmpty && pageCount < maxPages) {
      if (visitedUrls.contains(currentUrl)) break;
      visitedUrls.add(currentUrl);

      if (pageCount > 0) {
        // Fetch next TOC page
        try {
          content = await _engine.fetchUrl(currentUrl);
        } catch (e) {
          break;
        }
      }

      // Parse chapters from this TOC page
      final elements = await _engine.evalRuleList(content, chapterListRule);

      for (final element in elements) {
        try {
          final chapterName = await _engine.evalRuleOnElement(element, ruleToc.chapterName ?? '');
          final chapterUrl = await _engine.evalRuleOnElement(element, ruleToc.chapterUrl ?? '');

          if (chapterUrl.isNotEmpty) {
            chapters.add(DEpisode(
              name: chapterName.isNotEmpty ? chapterName : 'Chapter',
              url: _engine.resolveUrl(chapterUrl),
              episodeNumber: (chapters.length + 1).toString(),
            ));
          }
        } catch (e) {
          continue;
        }
      }

      // Check for next TOC page
      if (ruleToc.nextTocUrl != null && ruleToc.nextTocUrl!.isNotEmpty) {
        final nextUrl = await _engine.evalRule(content, ruleToc.nextTocUrl!);
        if (nextUrl.isNotEmpty && nextUrl != currentUrl) {
          currentUrl = _engine.resolveUrl(nextUrl);
        } else {
          break;
        }
      } else {
        break;
      }

      pageCount++;
    }

    // Handle isReverseOrder
    if (ruleToc.isReverseOrder != null) {
      final shouldReverse = ruleToc.isReverseOrder!.toLowerCase() == 'true' ||
          ruleToc.isReverseOrder == '1';
      if (shouldReverse) {
        return chapters.reversed.toList();
      }
    }

    // Check for leading - in chapterList rule (reverse)
    if (chapterListRule.startsWith('-')) {
      return chapters.reversed.toList();
    }

    return chapters;
  }

  // ============================================================
  // CHAPTER CONTENT
  // ============================================================

  @override
  Future<String?> getNovelContent(String chapterTitle, String chapterId,
      {SourceParams? parameters}) async {
    final ruleContent = _legadoSource.ruleContent;
    if (ruleContent == null) return null;

    try {
      final content = await _engine.fetchUrl(chapterId);
      var result = await _engine.evalRule(content, ruleContent.content ?? '');

      // Handle nextContentUrl for multi-page chapters
      if (ruleContent.nextContentUrl != null && ruleContent.nextContentUrl!.isNotEmpty) {
        final visitedUrls = <String>{chapterId};
        var nextUrl = await _engine.evalRule(content, ruleContent.nextContentUrl!);
        int pageCount = 0;
        const maxPages = 50;

        while (nextUrl.isNotEmpty && pageCount < maxPages) {
          final resolvedNext = _engine.resolveUrl(nextUrl);
          if (visitedUrls.contains(resolvedNext)) break;
          visitedUrls.add(resolvedNext);

          try {
            final nextContent = await _engine.fetchUrl(resolvedNext);
            final nextResult = await _engine.evalRule(nextContent, ruleContent.content ?? '');
            if (nextResult.isNotEmpty) {
              result = '$result\n$nextResult';
            }

            nextUrl = await _engine.evalRule(nextContent, ruleContent.nextContentUrl!);
          } catch (e) {
            break;
          }
          pageCount++;
        }
      }

      // Apply replaceRegex for ad/content cleanup
      if (ruleContent.replaceRegex != null && ruleContent.replaceRegex!.isNotEmpty) {
        result = _applyReplaceRegex(result, ruleContent.replaceRegex!);
      }

      // Clean up HTML to plain text
      result = _htmlToPlainText(result);

      return result.isNotEmpty ? result : null;
    } catch (e) {
      Logger.log('Legado: getNovelContent failed: $e');
      return null;
    }
  }

  /// Apply ##regex##replacement patterns
  String _applyReplaceRegex(String content, String replaceRegex) {
    // Format: ##regex##replacement##regex2##replacement2...
    final parts = replaceRegex.split('##');
    var result = content;

    for (int i = 0; i < parts.length - 1; i += 2) {
      final pattern = parts[i];
      final replacement = i + 1 < parts.length ? parts[i + 1] : '';
      if (pattern.isNotEmpty) {
        try {
          result = result.replaceAll(RegExp(pattern), replacement);
        } catch (e) {
          Logger.log('Legado: replaceRegex failed for "$pattern": $e');
        }
      }
    }

    return result;
  }

  /// Convert HTML content to plain text, preserving paragraph breaks
  String _htmlToPlainText(String html) {
    try {
      // Replace <br>, <p>, <div> with newlines
      var text = html;
      text = text.replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n');
      text = text.replaceAll(RegExp(r'</p>', caseSensitive: false), '\n');
      text = text.replaceAll(RegExp(r'</div>', caseSensitive: false), '\n');
      // Remove remaining HTML tags
      text = text.replaceAll(RegExp(r'<[^>]+>'), '');
      // Decode HTML entities
      text = _decodeHtmlEntities(text);
      // Clean up excessive newlines
      text = text.replaceAll(RegExp(r'\n{3,}'), '\n\n');
      return text.trim();
    } catch (e) {
      return html;
    }
  }

  String _decodeHtmlEntities(String text) {
    return text
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll('&apos;', "'")
        .replaceAll('&nbsp;', ' ')
        .replaceAllMapped(RegExp(r'&#(\d+);'), (m) {
      final code = int.tryParse(m.group(1) ?? '');
      return code != null ? String.fromCharCode(code) : '';
    });
  }

  // ============================================================
  // PAGE LIST / VIDEO LIST (not used for novels)
  // ============================================================

  @override
  Future<List<PageUrl>> getPageList(DEpisode episode,
      {SourceParams? parameters}) async {
    // Not applicable for novels
    return [];
  }

  @override
  Future<List<Video>> getVideoList(DEpisode episode,
      {SourceParams? parameters}) async {
    // Not applicable for novels
    return [];
  }

  @override
  Future<void> cancelRequest(String token) async {
    // TODO: Implement cancellation
  }

  @override
  Future<List<SourcePreference>> getPreference() async {
    // Legado sources don't have preferences in the same way
    return [];
  }

  @override
  Future<bool> setPreference(SourcePreference pref, dynamic value) async {
    return false;
  }

  // ============================================================
  // HELPER METHODS
  // ============================================================

  /// Evaluate a field rule on an element, with fallback to the full content
  Future<String> _evalField(
    RuleElement element,
    String? rule,
    String fullContent,
  ) async {
    if (rule == null || rule.isEmpty) return '';

    // First try to evaluate on the element
    var result = await _engine.evalRuleOnElement(element, rule);
    if (result.isEmpty) {
      // Fallback: evaluate on full content
      result = await _engine.evalRule(fullContent, rule);
    }
    return result;
  }

  /// Parse the first explore URL from the exploreUrl field
  String _parseFirstExploreUrl(String exploreUrl) {
    // Format 1: "Name::URL\nName2::URL2"
    if (exploreUrl.contains('::')) {
      final lines = exploreUrl.split('\n');
      for (final line in lines) {
        final parts = line.split('::');
        if (parts.length >= 2) {
          return parts[1].trim();
        }
      }
    }

    // Format 2: JSON array [{title, url, style}]
    try {
      final decoded = jsonDecode(exploreUrl);
      if (decoded is List && decoded.isNotEmpty) {
        final first = decoded.first;
        if (first is Map && first.containsKey('url')) {
          return first['url'].toString();
        }
      }
    } catch (_) {}

    // Format 3: Just a URL
    if (exploreUrl.startsWith('http') || exploreUrl.startsWith('/')) {
      return exploreUrl;
    }

    return '';
  }
}
