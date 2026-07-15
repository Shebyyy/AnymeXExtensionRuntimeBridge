import '../../../Models/Source.dart';

class CloudStreamSource extends Source {
  String? internalName;
  String? pluginUrl;
  String? jarUrl;
  bool hasSettings;

  CloudStreamSource({
    super.id,
    super.name,
    super.baseUrl,
    super.lang,
    super.isNsfw,
    super.iconUrl,
    super.version,
    super.versionLast,
    super.itemType,
    super.repo,
    super.managerId,
    super.hasUpdate,
    this.internalName,
    this.pluginUrl,
    this.jarUrl,
    this.hasSettings = false,
  });

  factory CloudStreamSource.fromJson(Map<String, dynamic> json) {
    final language = json['language'] as String?;
    return CloudStreamSource(
      id: json['id']?.toString().toLowerCase() ??
          json['name']?.toString().toLowerCase() ??
          '',
      name: json['name'],
      baseUrl: json['url'],
      lang: (language == null || language.trim().isEmpty) ? 'ALL' : language,
      iconUrl: json['iconUrl'],
      isNsfw: json['isNsfw'] ?? false,
      version: json['version']?.toString() ?? "1.0.0",
      versionLast: json['versionLast'] ?? "1.0.0",
      repo: json['repo'],
      managerId: 'cloudstream',
      hasUpdate: json['hasUpdate'] ?? false,
      itemType: ItemType.anime,
      jarUrl: json['jarUrl'] ?? json['jar'],
      internalName: json['internalName'] ?? json['name'],
      pluginUrl: json['pluginUrl'] ?? json['plugin'] ?? json['url'],
      hasSettings: json['hasSettings'] as bool? ?? false,
    );
  }

  @override
  Map<String, dynamic> toJson() {
    final map = super.toJson();
    map['internalName'] = internalName;
    map['plugin'] = pluginUrl;
    return map;
  }

  @override
  String get uniqueId => '${id}_$internalName';
}
