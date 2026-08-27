import 'search_models.dart';
import '../security/search_endpoint_validator.dart';

/// The only Hive/app-settings marker reserved for a non-release development
/// credential fallback. It is intentionally different from the API-config
/// fallback marker so the two credential domains cannot cross-read each other.
const String searchDevelopmentFallbackCredentialId =
    'development-hive-web-search';

/// Whether a configured provider must have a credential before it can be
/// saved or routed. The local development Gateway is intentionally the only
/// configurable exception; DuckDuckGo is always keyless.
bool searchProviderRequiresCredential(
  SearchProviderKind provider, {
  required bool isRelease,
}) =>
    switch (provider) {
      SearchProviderKind.gateway => isRelease,
      SearchProviderKind.tavily || SearchProviderKind.brave => true,
      SearchProviderKind.duckDuckGoInstantAnswer => false,
    };

/// Search provider metadata persisted in Hive's heterogeneous app-settings
/// box. Secrets are never part of the normal serialized representation.
class SearchProviderConfig {
  static const int maxIdLength = 128;
  static const int maxNameLength = 80;
  static const int maxBaseUrlLength = 2048;
  static const int maxCredentialIdLength = 256;
  static const int maxCredentialLength = 512;
  static const int maxCredentialRevisionLength = 128;
  static final _controlCharacterPattern = RegExp(r'[\u0000-\u001F\u007F]');
  final String id;
  final String name;
  final SearchProviderKind provider;
  final String baseUrl;
  final bool enabled;
  final bool isDefault;
  final String credentialId;
  final bool hasCredential;
  final bool requiresAttention;

  /// True when a credential was present in the source configuration but is
  /// intentionally absent after restore. It is metadata only, never a key.
  final bool credentialRequired;
  final String credentialRevision;

  /// True when persisted metadata contained a credential binding that exceeded
  /// the safe bound. The binding is intentionally not copied into a new key;
  /// keeping this marker prevents a malformed record from becoming an
  /// apparently keyless, silently orphaned configuration.
  final bool invalidCredentialBinding;
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
    this.requiresAttention = false,
    this.credentialRequired = false,
    this.credentialRevision = '',
    this.invalidCredentialBinding = false,
    String? developmentLegacyApiKey,
  }) : _developmentLegacyApiKey = developmentLegacyApiKey;

  /// Development-only compatibility accessor. Callers must check the
  /// resolver's release boundary before using it.
  String? get developmentLegacyApiKey => _developmentLegacyApiKey;

  factory SearchProviderConfig.fromMap(
    Map<dynamic, dynamic> map, {
    bool allowDevelopmentFallback = false,
  }) {
    final providerName = _boundedText(map['provider'], maxLength: 32);
    final provider = SearchProviderKind.values.firstWhere(
      (value) => value.name == providerName,
      orElse: () => SearchProviderKind.gateway,
    );
    final rawCredentialId = map['credentialId']?.toString().trim() ?? '';
    final rawLegacyApiKey = map['legacyApiKey']?.toString().trim() ?? '';
    final oversizedLegacyFallback = allowDevelopmentFallback &&
        rawCredentialId == searchDevelopmentFallbackCredentialId &&
        rawLegacyApiKey.length > maxCredentialLength;
    final invalidCredentialBinding = map['credentialBindingInvalid'] == true ||
        rawCredentialId.length > maxCredentialIdLength ||
        (map['hasCredential'] == true && rawCredentialId.isEmpty) ||
        oversizedLegacyFallback;
    final credentialId = invalidCredentialBinding ? '' : rawCredentialId;
    final fallback = allowDevelopmentFallback &&
            credentialId == searchDevelopmentFallbackCredentialId
        ? _optionalText(rawLegacyApiKey)
        : null;
    final credentialRequired = map['credentialRequired'] == true ||
        map['hasCredential'] == true ||
        credentialId.isNotEmpty ||
        invalidCredentialBinding ||
        fallback?.isNotEmpty == true;
    return SearchProviderConfig(
      id: canonicalizeId(map['id']) ?? '',
      name: _boundedText(map['name'], maxLength: maxNameLength),
      provider: provider,
      baseUrl: _boundedText(map['baseUrl'], maxLength: maxBaseUrlLength),
      enabled: map['enabled'] != false,
      isDefault: map['isDefault'] == true,
      credentialId: credentialId,
      hasCredential: map['hasCredential'] == true,
      requiresAttention:
          map['requiresAttention'] == true || invalidCredentialBinding,
      credentialRequired: credentialRequired,
      credentialRevision: _boundedText(
        map['credentialRevision'],
        maxLength: maxCredentialRevisionLength,
      ),
      invalidCredentialBinding: invalidCredentialBinding,
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
      'requiresAttention': requiresAttention,
      'credentialRequired': credentialRequired,
      'credentialRevision': credentialRevision,
      'credentialBindingInvalid': invalidCredentialBinding,
    };
    if (includeDevelopmentFallback &&
        credentialId == searchDevelopmentFallbackCredentialId &&
        _developmentLegacyApiKey?.isNotEmpty == true &&
        _developmentLegacyApiKey!.length <= maxCredentialLength) {
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
        'credentialRequired': credentialRequired ||
            hasCredential ||
            invalidCredentialBinding ||
            _developmentLegacyApiKey?.isNotEmpty == true,
        'requiresAttention': requiresAttention,
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
    bool? requiresAttention,
    bool? credentialRequired,
    String? credentialRevision,
    bool? invalidCredentialBinding,
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
      requiresAttention: requiresAttention ?? this.requiresAttention,
      credentialRequired: credentialRequired ?? this.credentialRequired,
      credentialRevision: credentialRevision ?? this.credentialRevision,
      invalidCredentialBinding:
          invalidCredentialBinding ?? this.invalidCredentialBinding,
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

  /// Returns a canonical ID only when the input is already canonical. A
  /// caller must reject whitespace/control-character variants instead of
  /// silently mapping them onto the same secure-storage key.
  static String? canonicalizeId(Object? value) {
    final text = value?.toString() ?? '';
    if (text.isEmpty ||
        text != text.trim() ||
        text.length > maxIdLength ||
        _controlCharacterPattern.hasMatch(text)) {
      return null;
    }
    return text;
  }

  static String _boundedText(Object? value, {required int maxLength}) {
    final text = value?.toString().trim() ?? '';
    return text.length <= maxLength ? text : '';
  }
}
