part of 'search_provider_config_delete_repair_test.dart';

void _registerSearchProviderConfigDeleteRepairTestPart2() {
  test('malformed repair state is diagnosable without being overwritten',
      () async {
    final settings = SearchProviderConfigStore(
      box: box,
      credentials: SearchCredentialRepository(
        store: _MemoryCredentialStore(),
        secureStorageAvailable: true,
      ),
      isRelease: true,
    );
    await box.put(SearchProviderConfigStore.credentialRepairKey, {
      'broken-entry': 'not-a-repair-map',
      7: {'credentialId': 'credential.web-search.numeric-key'},
    });

    expect(settings.hasMalformedCredentialRepairState, isTrue);
    expect(settings.pendingCredentialRepairIds, ['broken-entry']);
    expect(await settings.retryPendingCredentialRepairs(), isEmpty);
    expect(
      box.get(SearchProviderConfigStore.credentialRepairKey),
      isA<Map>(),
    );
  });

  test('endpoint validation is strict in release and explicit for local dev',
      () {
    final cases = <String, bool>{
      'https://api.example.com/v1': true,
      'http://api.example.com/v1': false,
      'file:///tmp/search': false,
      'javascript:alert(1)': false,
      'https://user:pass@example.com': false,
      'https://example.com/search?api_key=secret': false,
      'https://127.0.0.1:8080/v1': false,
      'https://10.0.0.5/v1': false,
      'https://169.254.169.254/latest': false,
      'https://[::1]:8080/v1': false,
      'https://2130706433/v1': false,
      'https://0x7f000001/v1': false,
      'https://0177.0.0.1/v1': false,
    };
    for (final entry in cases.entries) {
      final result = SearchEndpointValidator.validate(
        entry.key,
        isRelease: true,
      );
      expect(result.isValid, entry.value, reason: entry.key);
    }

    expect(
      SearchEndpointValidator.validate(
        'http://127.0.0.1:8080/v1',
        isRelease: false,
        allowLocalDevelopmentGateway: true,
      ).isValid,
      isTrue,
    );

    expect(
      SearchEndpointValidator.sanitizeForBackup(
        'https://example.com/v1?api_key=secret#fragment',
      ),
      'https://example.com/v1',
    );
  });
}
