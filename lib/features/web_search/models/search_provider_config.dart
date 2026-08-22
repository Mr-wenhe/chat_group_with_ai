import 'search_models.dart';
import '../security/search_endpoint_validator.dart';

/// The only Hive/app-settings marker reserved for a non-release development
/// credential fallback. It is intentionally different from the API-config
/// fallback marker so the two credential domains cannot cross-read each other.
const String searchDevelopmentFallbackCredentialId =
    'development-hive-web-search';

/// Search provider metadata persisted in Hive's heterogeneous app-settings
/// box. Secrets are never part of the normal serialized representation.
class SearchProviderConfig {
  final String id;
  final String name;
  final SearchProviderKind provider;
  final String baseUrl;
  final bool enabled;
  final bool isDefault;
  final String credentialId;
  final bool hasCredential;
  final String? _developmentLegacyApiKey;

  const SearchProviderConfig({
    required this.id,
    required this.name,
    required this.provider,
    required this.baseUrl,
    this.enabled = true,
    this.isDefault = false,
    this.credentialId = '',
    this.hasCredential = false,
    String? developmentLegacyApiKey,
  }) : _developmentLegacyApiKey = developmentLegacyApiKey;

  /// Development-only compatibility accessor. Callers must check the
  /// resolver's release boundary before using it.
  String? get developmentLegacyApiKey => _developmentLegacyApiKey;

  factory SearchProviderConfig.fromMap(
    Map<dynamic, dynamic> map, {
    bool allowDevelopmentFallback = false,
  }) {
    final providerName = map['provider']?.toString();
    final provider = SearchProviderKind.values.firstWhere(
      (value) => value.name == providerName,
      orElse: () => SearchProviderKind.gateway,
    );
    final credentialId = map['credentialId']?.toString() ?? '';
    final fallback = allowDevelopmentFallback &&
            credentialId == searchDevelopmentFallbackCredentialId
        ? _optionalText(map['legacyApiKey'])
        : null;
    return SearchProviderConfig(
      id: map['id']?.toString() ?? '',
      name: map['name']?.toString() ?? '',
      provider: provider,
      baseUrl: map['baseUrl']?.toString() ?? '',
      enabled: map['enabled'] != false,
      isDefault: map['isDefault'] == true,
      credentialId: credentialId,
      hasCredential: map['hasCredential'] == true,
      developmentLegacyApiKey: fallback,
    );
  }

  /// Serializes metadata. The development fallback is opt-in and is only
  /// called by the non-release persistence path after secure storage failed.
  Map<String, dynamic> toMap({bool includeDevelopmentFallback = false}) {
    final result = <String, dynamic>{
      'id': id,
      'name': name,
      'provider': provider.name,
      'baseUrl': baseUrl,
      'enabled': enabled,
      'isDefault': isDefault,
      'credentialId': credentialId,
      'hasCredential': hasCredential,
    };
    if (includeDevelopmentFallback &&
        credentialId == searchDevelopmentFallbackCredentialId &&
        _developmentLegacyApiKey?.isNotEmpty == true) {
      result['legacyApiKey'] = _developmentLegacyApiKey;
    }
    return result;
  }

  /// Export representation used by backups. It intentionally carries only
  /// the fact that a credential needs rebinding, never its ID or value.
  Map<String, dynamic> toBackupMap() => {
        'id': id,
        'name': name,
        'provider': provider.name,
        'baseUrl': SearchEndpointValidator.sanitizeForBackup(baseUrl),
        'enabled': enabled,
        'isDefault': isDefault,
        'credentialRequired':
            hasCredential || _developmentLegacyApiKey?.isNotEmpty == true,
      };

  SearchProviderConfig copyWith({
    String? id,
    String? name,
    SearchProviderKind? provider,
    String? baseUrl,
    bool? enabled,
    bool? isDefault,
    String? credentialId,
    bool? hasCredential,
    String? developmentLegacyApiKey,
    bool clearDevelopmentLegacyApiKey = false,
  }) {
    return SearchProviderConfig(
      id: id ?? this.id,
      name: name ?? this.name,
      provider: provider ?? this.provider,
      baseUrl: baseUrl ?? this.baseUrl,
      enabled: enabled ?? this.enabled,
      isDefault: isDefault ?? this.isDefault,
      credentialId: credentialId ?? this.credentialId,
      hasCredential: hasCredential ?? this.hasCredential,
      developmentLegacyApiKey: clearDevelopmentLegacyApiKey
          ? null
          : developmentLegacyApiKey ?? _developmentLegacyApiKey,
    );
  }

  static String? _optionalText(Object? value) {
    if (value == null) return null;
    final text = value.toString();
    return text.isEmpty ? null : text;
  }
}
