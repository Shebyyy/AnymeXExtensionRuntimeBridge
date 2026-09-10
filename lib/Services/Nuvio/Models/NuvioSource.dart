import '../../../Models/Source.dart';

class NuvioSource extends Source {
  String? description;
  String? author;
  List<String> supportedTypes;
  String? filename;
  List<String> formats;
  List<String> contentLanguage;
  String? sourceCode;
  String? sourceCodeUrl;
  bool hasSettings;
  bool enabled;

  NuvioSource({
    super.id,
    super.name,
    super.baseUrl,
    super.lang,
    super.isNsfw = false,
    super.iconUrl,
    super.version,
    super.versionLast,
    super.itemType = ItemType.anime,
    super.repo,
    super.managerId = 'nuvio',
    super.hasUpdate = false,
    super.supportsLatest = true,
    super.supportsPopular = true,
    this.description,
    this.author,
    this.supportedTypes = const ['movie', 'tv'],
    this.filename,
    this.formats = const ['mp4', 'mkv', 'm3u8'],
    this.contentLanguage = const ['en'],
    this.sourceCode,
    this.sourceCodeUrl,
    this.hasSettings = false,
    this.enabled = true,
  });

  factory NuvioSource.fromJson(Map<String, dynamic> json) {
    List<String> parseList(dynamic val, [List<String> fallback = const []]) {
      if (val is List) return val.map((e) => e.toString()).toList();
      return fallback;
    }

    return NuvioSource(
      id: json['id']?.toString() ?? '',
      name: json['name']?.toString() ?? '',
      baseUrl: json['baseUrl']?.toString() ?? '',
      lang: (json['contentLanguage'] is List && (json['contentLanguage'] as List).isNotEmpty)
          ? json['contentLanguage'][0].toString()
          : (json['lang']?.toString() ?? 'en'),
      isNsfw: json['isNsfw'] == true || json['isNsfw']?.toString() == 'true',
      iconUrl: json['logo']?.toString() ?? json['iconUrl']?.toString() ?? '',
      version: json['version']?.toString() ?? '1.0.0',
      versionLast: json['versionLast']?.toString() ?? json['version']?.toString() ?? '1.0.0',
      itemType: ItemType.anime,
      repo: json['repo']?.toString(),
      managerId: json['managerId']?.toString() ?? 'nuvio',
      hasUpdate: json['hasUpdate'] == true,
      supportsLatest: true,
      supportsPopular: true,
      description: json['description']?.toString(),
      author: json['author']?.toString(),
      supportedTypes: parseList(json['supportedTypes'], const ['movie', 'tv']),
      filename: json['filename']?.toString(),
      formats: parseList(json['formats'], const ['mp4', 'mkv', 'm3u8']),
      contentLanguage: parseList(json['contentLanguage'], const ['en']),
      sourceCode: json['sourceCode']?.toString(),
      sourceCodeUrl: json['sourceCodeUrl']?.toString(),
      hasSettings: json['hasSettings'] == true,
      enabled: json['enabled'] != false,
    );
  }

  @override
  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'baseUrl': baseUrl,
        'lang': lang,
        'isNsfw': isNsfw,
        'iconUrl': iconUrl,
        'version': version,
        'versionLast': versionLast,
        'itemType': itemType?.name,
        'repo': repo,
        'managerId': managerId,
        'hasUpdate': hasUpdate,
        'supportsLatest': supportsLatest,
        'supportsPopular': supportsPopular,
        'description': description,
        'author': author,
        'supportedTypes': supportedTypes,
        'filename': filename,
        'formats': formats,
        'contentLanguage': contentLanguage,
        'sourceCode': sourceCode,
        'sourceCodeUrl': sourceCodeUrl,
        'hasSettings': hasSettings,
        'enabled': enabled,
      };
}
