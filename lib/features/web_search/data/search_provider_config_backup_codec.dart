import 'package:flutter/foundation.dart';

import '../models/search_provider_config.dart';
import '../security/search_endpoint_validator.dart';
import 'search_credential_repository.dart';

/// Secret-free conversion boundary for Provider metadata backups.
class SearchProviderConfigBackupCodec {
  const SearchProviderConfigBackupCodec._();

  static List<Map<String, dynamic>> backupValue(Object? raw) {
    if (raw is! List) return const [];
    return raw.whereType<Map>().map((item) {
      return <String, dynamic>{
        'id': item['id']?.toString() ?? '',
        'name': item['name']?.toString() ?? '',
        'provider': item['provider']?.toString() ?? '',
        'baseUrl': SearchEndpointValidator.sanitizeForBackup(
          item['baseUrl']?.toString() ?? '',
        ),
        'enabled': item['enabled'] != false,
        'isDefault': item['isDefault'] == true,
        'credentialRequired': item['hasCredential'] == true ||
            item['credentialRequired'] == true ||
            (item['credentialId']?.toString().isNotEmpty ?? false) ||
            (item['legacyApiKey']?.toString().isNotEmpty ?? false),
      };
    }).toList(growable: false);
  }

  static List<Map<String, dynamic>> restoreValue(Object? raw) {
    final values = backupValue(raw);
    return values
        .map((item) => {
              ...item,
              'credentialRequired': item['credentialRequired'] == true,
              'credentialId': '',
              'hasCredential': false,
              // A restored provider is metadata-only until the user binds a
              // new key. Keep it out of the runtime chain until then.
              'requiresAttention': item['credentialRequired'] == true,
            })
        .toList(growable: false);
  }

  static List<Map<String, dynamic>> normalizeExistingValue(
    Object? raw, {
    bool? isRelease,
  }) {
    if (raw is! List) return const [];
    final release = isRelease ?? kReleaseMode;
    final allowDevelopmentFallback =
        !release && !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;
    return raw.whereType<Map>().map((item) {
      var config = SearchProviderConfig.fromMap(
        item,
        allowDevelopmentFallback: allowDevelopmentFallback,
      );
      if (release &&
          config.credentialId ==
              SearchCredentialRepository.developmentHiveCredentialId) {
        config = config.copyWith(
          credentialId: '',
          hasCredential: false,
          clearDevelopmentLegacyApiKey: true,
        );
      }
      return config.toMap(
        includeDevelopmentFallback: allowDevelopmentFallback,
      );
    }).toList(growable: false);
  }
}
