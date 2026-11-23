import '../security/search_endpoint_validator.dart';

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

}
