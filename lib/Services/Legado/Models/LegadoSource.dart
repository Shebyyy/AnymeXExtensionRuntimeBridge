import '../../../Models/Source.dart';

/// Legado book source data model.
/// Mirrors the JSON structure of Legado 书源 (BookSource).
class LegadoSource extends Source {
  String? bookSourceUrl;
  String? bookSourceName;
  int? bookSourceType;
  String? bookSourceGroup;
  String? bookSourceComment;
  String? bookUrlPattern;
  int? customOrder;
  bool? enabled;
  bool? enabledExplore;
  bool? enabledCookieJar;
  String? header;
  String? searchUrl;
  String? exploreUrl;
  String? loginUrl;
  String? loginCheckJs;
  String? loginUi;
  String? concurrentRate;
  int? respondTime;
  int? lastUpdateTime;
  int? weight;

  RuleSearch? ruleSearch;
  RuleExplore? ruleExplore;
  RuleBookInfo? ruleBookInfo;
  RuleToc? ruleToc;
  RuleContent? ruleContent;

  /// Raw JSON for persistence
  Map<String, dynamic>? rawJson;

  LegadoSource({
    this.bookSourceUrl,
    this.bookSourceName,
    this.bookSourceType,
    this.bookSourceGroup,
    this.bookSourceComment,
    this.bookUrlPattern,
    this.customOrder,
    this.enabled,
    this.enabledExplore,
    this.enabledCookieJar,
    this.header,
    this.searchUrl,
    this.exploreUrl,
    this.loginUrl,
    this.loginCheckJs,
    this.loginUi,
    this.concurrentRate,
    this.respondTime,
    this.lastUpdateTime,
    this.weight,
    this.ruleSearch,
    this.ruleExplore,
    this.ruleBookInfo,
    this.ruleToc,
    this.ruleContent,
  }) : super(
          id: bookSourceUrl ?? '',
          name: bookSourceName ?? '',
          baseUrl: bookSourceUrl ?? '',
          lang: _extractLang(bookSourceGroup),
          isNsfw: false,
          itemType: ItemType.novel,
          version: '1.0.0',
        );

  factory LegadoSource.fromJson(Map<String, dynamic> json) {
    return LegadoSource(
      bookSourceUrl: json['bookSourceUrl'] as String?,
      bookSourceName: json['bookSourceName'] as String?,
      bookSourceType: json['bookSourceType'] as int?,
      bookSourceGroup: json['bookSourceGroup'] as String?,
      bookSourceComment: json['bookSourceComment'] as String?,
      bookUrlPattern: json['bookUrlPattern'] as String?,
      customOrder: json['customOrder'] as int?,
      enabled: json['enabled'] as bool?,
      enabledExplore: json['enabledExplore'] as bool?,
      enabledCookieJar: json['enabledCookieJar'] as bool?,
      header: json['header'] as String?,
      searchUrl: json['searchUrl'] as String?,
      exploreUrl: json['exploreUrl'] as String?,
      loginUrl: json['loginUrl'] as String?,
      loginCheckJs: json['loginCheckJs'] as String?,
      loginUi: json['loginUi'] as String?,
      concurrentRate: json['concurrentRate'] as String?,
      respondTime: json['respondTime'] as int?,
      lastUpdateTime: json['lastUpdateTime'] as int?,
      weight: json['weight'] as int?,
      ruleSearch: json['ruleSearch'] != null
          ? RuleSearch.fromJson(
              Map<String, dynamic>.from(json['ruleSearch'] as Map))
          : null,
      ruleExplore: json['ruleExplore'] != null
          ? RuleExplore.fromJson(
              Map<String, dynamic>.from(json['ruleExplore'] as Map))
          : null,
      ruleBookInfo: json['ruleBookInfo'] != null
          ? RuleBookInfo.fromJson(
              Map<String, dynamic>.from(json['ruleBookInfo'] as Map))
          : null,
      ruleToc: json['ruleToc'] != null
          ? RuleToc.fromJson(
              Map<String, dynamic>.from(json['ruleToc'] as Map))
          : null,
      ruleContent: json['ruleContent'] != null
          ? RuleContent.fromJson(
              Map<String, dynamic>.from(json['ruleContent'] as Map))
          : null,
    )
      ..rawJson = json
      ..id = json['bookSourceUrl'] ?? ''
      ..name = json['bookSourceName'] ?? ''
      ..baseUrl = json['bookSourceUrl'] ?? ''
      ..lang = _extractLang(json['bookSourceGroup'] as String?)
      ..itemType = ItemType.novel;
  }

  @override
  Map<String, dynamic> toJson() {
    final json = <String, dynamic>{
      'bookSourceUrl': bookSourceUrl,
      'bookSourceName': bookSourceName,
      'bookSourceType': bookSourceType,
      'bookSourceGroup': bookSourceGroup,
      'bookSourceComment': bookSourceComment,
      'bookUrlPattern': bookUrlPattern,
      'customOrder': customOrder,
      'enabled': enabled,
      'enabledExplore': enabledExplore,
      'enabledCookieJar': enabledCookieJar,
      'header': header,
      'searchUrl': searchUrl,
      'exploreUrl': exploreUrl,
      'loginUrl': loginUrl,
      'loginCheckJs': loginCheckJs,
      'loginUi': loginUi,
      'concurrentRate': concurrentRate,
      'respondTime': respondTime,
      'lastUpdateTime': lastUpdateTime,
      'weight': weight,
    };
    if (ruleSearch != null) json['ruleSearch'] = ruleSearch!.toJson();
    if (ruleExplore != null) json['ruleExplore'] = ruleExplore!.toJson();
    if (ruleBookInfo != null) json['ruleBookInfo'] = ruleBookInfo!.toJson();
    if (ruleToc != null) json['ruleToc'] = ruleToc!.toJson();
    if (ruleContent != null) json['ruleContent'] = ruleContent!.toJson();
    return json;
  }

  static String? _extractLang(String? group) {
    if (group == null) return 'all';
    final g = group.toLowerCase();
    if (g.contains('english') || g.contains('英文')) return 'en';
    if (g.contains('chinese') || g.contains('中文')) return 'zh';
    if (g.contains('japanese') || g.contains('日文')) return 'ja';
    if (g.contains('korean') || g.contains('韩文')) return 'ko';
    if (g.contains('french') || g.contains('法文')) return 'fr';
    if (g.contains('spanish') || g.contains('西班牙')) return 'es';
    if (g.contains('russian') || g.contains('俄文')) return 'ru';
    return 'all';
  }
}

/// Rule for search results page
class RuleSearch {
  String? bookList;
  String? name;
  String? author;
  String? coverUrl;
  String? bookUrl;
  String? intro;
  String? kind;
  String? wordCount;
  String? lastChapter;
  String? checkKeyWord;

  RuleSearch({
    this.bookList,
    this.name,
    this.author,
    this.coverUrl,
    this.bookUrl,
    this.intro,
    this.kind,
    this.wordCount,
    this.lastChapter,
    this.checkKeyWord,
  });

  factory RuleSearch.fromJson(Map<String, dynamic> json) {
    return RuleSearch(
      bookList: json['bookList'] as String?,
      name: json['name'] as String?,
      author: json['author'] as String?,
      coverUrl: json['coverUrl'] as String?,
      bookUrl: json['bookUrl'] as String?,
      intro: json['intro'] as String?,
      kind: json['kind'] as String?,
      wordCount: json['wordCount'] as String?,
      lastChapter: json['lastChapter'] as String?,
      checkKeyWord: json['checkKeyWord'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
        'bookList': bookList,
        'name': name,
        'author': author,
        'coverUrl': coverUrl,
        'bookUrl': bookUrl,
        'intro': intro,
        'kind': kind,
        'wordCount': wordCount,
        'lastChapter': lastChapter,
        'checkKeyWord': checkKeyWord,
      };
}

/// Rule for explore/discover page - same fields as RuleSearch
class RuleExplore {
  String? bookList;
  String? name;
  String? author;
  String? coverUrl;
  String? bookUrl;
  String? intro;
  String? kind;
  String? wordCount;
  String? lastChapter;

  RuleExplore({
    this.bookList,
    this.name,
    this.author,
    this.coverUrl,
    this.bookUrl,
    this.intro,
    this.kind,
    this.wordCount,
    this.lastChapter,
  });

  factory RuleExplore.fromJson(Map<String, dynamic> json) {
    return RuleExplore(
      bookList: json['bookList'] as String?,
      name: json['name'] as String?,
      author: json['author'] as String?,
      coverUrl: json['coverUrl'] as String?,
      bookUrl: json['bookUrl'] as String?,
      intro: json['intro'] as String?,
      kind: json['kind'] as String?,
      wordCount: json['wordCount'] as String?,
      lastChapter: json['lastChapter'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
        'bookList': bookList,
        'name': name,
        'author': author,
        'coverUrl': coverUrl,
        'bookUrl': bookUrl,
        'intro': intro,
        'kind': kind,
        'wordCount': wordCount,
        'lastChapter': lastChapter,
      };
}

/// Rule for book detail page
class RuleBookInfo {
  String? init;
  String? name;
  String? author;
  String? coverUrl;
  String? intro;
  String? kind;
  String? wordCount;
  String? lastChapter;
  String? tocUrl;
  String? canReName;

  RuleBookInfo({
    this.init,
    this.name,
    this.author,
    this.coverUrl,
    this.intro,
    this.kind,
    this.wordCount,
    this.lastChapter,
    this.tocUrl,
    this.canReName,
  });

  factory RuleBookInfo.fromJson(Map<String, dynamic> json) {
    return RuleBookInfo(
      init: json['init'] as String?,
      name: json['name'] as String?,
      author: json['author'] as String?,
      coverUrl: json['coverUrl'] as String?,
      intro: json['intro'] as String?,
      kind: json['kind'] as String?,
      wordCount: json['wordCount'] as String?,
      lastChapter: json['lastChapter'] as String?,
      tocUrl: json['tocUrl'] as String?,
      canReName: json['canReName'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
        'init': init,
        'name': name,
        'author': author,
        'coverUrl': coverUrl,
        'intro': intro,
        'kind': kind,
        'wordCount': wordCount,
        'lastChapter': lastChapter,
        'tocUrl': tocUrl,
        'canReName': canReName,
      };
}

/// Rule for table of contents
class RuleToc {
  String? chapterList;
  String? chapterName;
  String? chapterUrl;
  String? isVip;
  String? isVolume;
  String? nextTocUrl;
  String? updateTime;
  String? isReverseOrder;

  RuleToc({
    this.chapterList,
    this.chapterName,
    this.chapterUrl,
    this.isVip,
    this.isVolume,
    this.nextTocUrl,
    this.updateTime,
    this.isReverseOrder,
  });

  factory RuleToc.fromJson(Map<String, dynamic> json) {
    return RuleToc(
      chapterList: json['chapterList'] as String?,
      chapterName: json['chapterName'] as String?,
      chapterUrl: json['chapterUrl'] as String?,
      isVip: json['isVip'] as String?,
      isVolume: json['isVolume'] as String?,
      nextTocUrl: json['nextTocUrl'] as String?,
      updateTime: json['updateTime'] as String?,
      isReverseOrder: json['isReverseOrder'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
        'chapterList': chapterList,
        'chapterName': chapterName,
        'chapterUrl': chapterUrl,
        'isVip': isVip,
        'isVolume': isVolume,
        'nextTocUrl': nextTocUrl,
        'updateTime': updateTime,
        'isReverseOrder': isReverseOrder,
      };
}

/// Rule for chapter content page
class RuleContent {
  String? content;
  String? title;
  String? replaceRegex;
  String? nextContentUrl;
  String? sourceRegex;
  String? webJs;
  String? imageStyle;

  RuleContent({
    this.content,
    this.title,
    this.replaceRegex,
    this.nextContentUrl,
    this.sourceRegex,
    this.webJs,
    this.imageStyle,
  });

  factory RuleContent.fromJson(Map<String, dynamic> json) {
    return RuleContent(
      content: json['content'] as String?,
      title: json['title'] as String?,
      replaceRegex: json['replaceRegex'] as String?,
      nextContentUrl: json['nextContentUrl'] as String?,
      sourceRegex: json['sourceRegex'] as String?,
      webJs: json['webJs'] as String?,
      imageStyle: json['imageStyle'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
        'content': content,
        'title': title,
        'replaceRegex': replaceRegex,
        'nextContentUrl': nextContentUrl,
        'sourceRegex': sourceRegex,
        'webJs': webJs,
        'imageStyle': imageStyle,
      };
}
