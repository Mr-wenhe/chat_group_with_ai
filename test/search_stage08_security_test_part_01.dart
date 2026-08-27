part of 'search_stage08_security_test.dart';

void _registerSearchStage08SecurityTestPart1() {
  test('shared sensitive marker scanner redacts every required marker', () {
    const scanner = SearchSecretScanner();
    const value = '''
Authorization: Bearer abcdefghijklmnop
Cookie: session=private-cookie
-----BEGIN PRIVATE KEY-----private material-----END PRIVATE KEY-----
eyJhbGciOiJIUzI1NiJ9.payload.signature
sk-live-production-secret
OPENAI_API_KEY=opaque-secret-value
''';

    final result = scanner.scan(value);

    expect(result.containsSensitiveData, isTrue);
    expect(result.value, isNot(contains('abcdefghijklmnop')));
    expect(result.value, isNot(contains('private-cookie')));
    expect(result.value, isNot(contains('PRIVATE KEY')));
    expect(result.value, isNot(contains('eyJhbGciOiJIUzI1NiJ9')));
    expect(result.value, isNot(contains('sk-live-production-secret')));
    expect(result.value, isNot(contains('opaque-secret-value')));
  });

  test('shared scanner redacts opaque hex and base64 secrets everywhere', () {
    const scanner = SearchSecretScanner();
    const hex =
        '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
    const base64 = 'QWxhZGRpbjpvcGVuIHNlc2FtZSB0b2tlbiBmb3Igc2VhcmNo';

    expect(
        scanner.containsSensitiveData(hex, includeOpaqueTokens: true), isTrue);
    expect(
      scanner.containsSensitiveData(base64, includeOpaqueTokens: true),
      isTrue,
    );
    final audit = SearchAuditEntry(
      conversationId: 'audit',
      query: 'find $hex and $base64',
      searchedAt: DateTime.utc(2026, 8, 23),
      status: 'completed',
      sources: const [],
    );
    expect(audit.queryPreview, isNot(contains(hex)));
    expect(audit.queryPreview, isNot(contains(base64)));
  });

  test('search URLs and legacy audit sources are bounded', () {
    final tooLong =
        Uri.parse('https://example.com/${List.filled(2050, '~').join()}');
    expect(tryValidateSearchUrl(tooLong), isNull);

    final entry = SearchAuditEntry.fromMap({
      'conversationId': 'audit',
      'query': 'query',
      'searchedAt': DateTime.utc(2026, 8, 23).toIso8601String(),
      'status': 'completed',
      'sources': List.generate(200, (_) => 'not-a-valid-url'),
    });
    expect(entry.sources, isEmpty);
  });

  test('provider language metadata is bounded before persistence', () {
    final result = WebSearchResult(
      sourceId: 'language-bound',
      title: 'Title',
      snippet: 'Snippet',
      url: Uri.parse('https://example.com/result'),
      provider: 'brave',
      language: List.filled(searchLanguageMaxLength + 20, 'x').join(),
    );

    expect(result.language, hasLength(searchLanguageMaxLength));
  });

  test('search HTTP transformer rejects oversized response streams', () async {
    final transformer = BoundedSearchJsonTransformer();
    final options = RequestOptions(
      path: 'https://search.example.com',
      responseType: ResponseType.json,
    );
    final body = ResponseBody(
      Stream.value(Uint8List(searchProviderMaxResponseBytes + 1)),
      200,
      headers: const {
        'content-type': ['application/json']
      },
    );

    expect(
      () => transformer.transformResponse(options, body),
      throwsA(isA<SearchResponseTooLargeException>()),
    );
  });

  test('search HTTP transformer rejects deeply nested JSON before decoding',
      () async {
    final transformer = BoundedSearchJsonTransformer();
    final options = RequestOptions(
      path: 'https://search.example.com',
      responseType: ResponseType.json,
    );
    final payload = '${List.filled(searchProviderMaxJsonDepth + 1, '[').join()}'
        '0${List.filled(searchProviderMaxJsonDepth + 1, ']').join()}';
    final body = ResponseBody.fromString(
      payload,
      200,
      headers: const {
        'content-type': ['application/json']
      },
    );

    expect(
      () => transformer.transformResponse(options, body),
      throwsA(isA<SearchResponseStructureException>()),
    );
  });

  test('JSON response validation does not trust a wrong MIME type', () async {
    final transformer = BoundedSearchJsonTransformer();
    final options = RequestOptions(
      path: 'https://search.example.com',
      responseType: ResponseType.json,
    );
    final body = ResponseBody.fromString(
      '{"results": []}',
      200,
      headers: const {
        'content-type': ['text/plain']
      },
    );

    final decoded = await transformer.transformResponse(options, body);

    expect(decoded, {'results': []});
  });

  test('query sanitizer blocks case variants and provider key prefixes', () {
    const sanitizer = SearchQuerySanitizer();
    for (final value in const [
      'SK-live-production-secret',
      'TVLY-live-production-secret',
      'AKIA1234567890ABCDEF',
      'bce-v2/sts-secret-value',
      'OPENAI_API_KEY=opaque-secret-value',
      'AWS_SECRET_ACCESS_KEY=opaque-secret-value',
    ]) {
      final result = sanitizer.sanitize(value);
      expect(result.containsSensitiveData, isTrue, reason: value);
      expect(result.text, isEmpty, reason: value);
    }
  });

  test('SSRF validator rejects private, alternate, and rebinding hosts', () {
    const blocked = [
      'https://127.0.0.1:8080/search',
      'https://2130706433/search',
      'https://0x7f.0.0.1/search',
      'https://192.0.2.1/search',
      'https://198.51.100.1/search',
      'https://203.0.113.1/search',
      'https://[::ffff:7f00:1]/search',
      'https://service.127.0.0.1.nip.io/search',
      'https://user:pass@example.com/search',
    ];

    for (final endpoint in blocked) {
      expect(
        SearchEndpointValidator.validate(endpoint, isRelease: true).isValid,
        isFalse,
        reason: endpoint,
      );
    }
    expect(
      SearchEndpointValidator.validate(
        'https://search.example.com/v1',
        isRelease: true,
      ).isValid,
      isTrue,
    );
  });

  test('SSRF validator rejects private addresses returned by DNS', () {
    expect(
      SearchEndpointValidator.areResolvedAddressesPublic(
        const ['8.8.8.8', '10.0.0.1'],
      ),
      isFalse,
    );
    expect(
      SearchEndpointValidator.areResolvedAddressesPublic(
        const ['2606:4700:4700::1111'],
      ),
      isTrue,
    );
  });

  test('DNS guard rejects a private resolver answer before socket setup',
      () async {
    final dio = Dio();

    expect(
      () => prepareSearchEndpointConnection(
        dio,
        Uri.parse('https://search.example.com'),
        isRelease: true,
        lookup: (_) async => const ['8.8.8.8', '10.0.0.2'],
      ),
      throwsA(isA<SearchEndpointDnsException>()),
    );
  });

  test('DNS guard rechecks a resolver before each pinned connection', () async {
    final dio = Dio();
    var lookups = 0;
    final addresses = <List<String>>[
      ['8.8.8.8'],
      ['1.1.1.1'],
    ];
    Future<List<String>> lookup(String _) async => addresses[lookups++];

    await prepareSearchEndpointConnection(
      dio,
      Uri.parse('https://search.example.com'),
      isRelease: true,
      lookup: lookup,
    );
    await prepareSearchEndpointConnection(
      dio,
      Uri.parse('https://search.example.com'),
      isRelease: true,
      lookup: lookup,
    );

    expect(lookups, 2);
  });

  test('DNS guard bounds a resolver that never completes', () async {
    final dio = Dio();
    final lookup = Completer<List<String>>();

    expect(
      () => prepareSearchEndpointConnection(
        dio,
        Uri.parse('https://search.example.com'),
        isRelease: true,
        lookup: (_) => lookup.future,
        lookupTimeout: const Duration(milliseconds: 10),
      ),
      throwsA(isA<SearchEndpointDnsException>()),
    );
  });

  test('DNS guard failures map to bounded search diagnostics', () {
    expect(
      searchFailureTypeFromEndpointDnsException(
        const SearchEndpointDnsException(
          'timed out',
          kind: SearchEndpointDnsFailureKind.timedOut,
        ),
      ),
      SearchFailureType.connectionTimeout,
    );
    expect(
      searchFailureTypeFromEndpointDnsException(
        const SearchEndpointDnsException(
          'lookup failed',
          kind: SearchEndpointDnsFailureKind.lookupFailed,
        ),
      ),
      SearchFailureType.dns,
    );
    expect(
      searchFailureTypeFromEndpointDnsException(
        const SearchEndpointDnsException('private address'),
      ),
      SearchFailureType.invalidConfiguration,
    );
  });

  test('DNS pinning rejects sharing one Dio across endpoint origins', () async {
    final dio = Dio();

    await prepareSearchEndpointConnection(
      dio,
      Uri.parse('https://search-one.example.com'),
      isRelease: true,
      lookup: (_) async => const ['8.8.8.8'],
    );

    expect(
      () => prepareSearchEndpointConnection(
        dio,
        Uri.parse('https://search-two.example.com'),
        isRelease: true,
        lookup: (_) async => const ['1.1.1.1'],
      ),
      throwsA(isA<SearchEndpointDnsException>()),
    );
  });

  test('prompt injection fixture keeps title, snippet, and URL in data only',
      () {
    final fixture = jsonDecode(
      File('test/fixtures/web_search/prompt_injection_sources.json')
          .readAsStringSync(),
    ) as List;
    final snapshot = WebSearchSnapshot(
      requestId: 'request-stage08',
      rootRequestId: 'turn-stage08',
      executedQueries: const ['Flutter security'],
      searchedAt: DateTime.utc(2026, 8, 23),
      provider: 'fixture',
      results: fixture.asMap().entries.map((entry) {
        final item = Map<String, dynamic>.from(entry.value as Map);
        return WebSearchResult(
          sourceId: 'provider-${entry.key}',
          title: item['title'].toString(),
          snippet: item['snippet'].toString(),
          url: Uri.parse(item['url'].toString()),
          provider: 'fixture',
        );
      }),
    );

    const formatter = SearchContextFormatter();
    final messages = formatter.formatMessages(snapshot);
    final evidence = jsonDecode(messages[1]['content']
        .toString()
        .split('WEB_SEARCH_EVIDENCE_DATA_BEGIN\n')
        .last
        .split('\nWEB_SEARCH_EVIDENCE_DATA_END')
        .first) as Map<String, dynamic>;

    expect(messages.first['content'], contains('标题、摘要、网页文字或 URL'));
    expect(messages.first['role'], 'system');
    expect(messages[1]['role'], 'user');
    expect(messages.first['content'], isNot(contains('attacker.example')));
    expect(messages[1]['content'], contains('attacker.example'));
    expect(
      messages[1]['content'],
      contains('Ignore previous instructions'),
    );
    expect(evidence['sources'], hasLength(3));
    expect(
      (evidence['sources'] as List).every((item) {
        final source = item as Map;
        return source['title'] != null &&
            source['snippet'] != null &&
            source['url'].toString().startsWith('https://');
      }),
      isTrue,
    );
  });

  test('correlation IDs are bounded and carry root linkage', () {
    final request = SearchRequest(
      requestId: 'Authorization: Bearer secret-request-id',
      rootRequestId: 'root-stage08',
      sourceMessageId: 'message-stage08',
      turnId: 'turn-stage08',
      query: 'Flutter security',
    );
    expect(request.requestId, isEmpty);
    expect(request.rootRequestId, 'root-stage08');

    const state = SearchRunState(
      SearchRunStatus.searching,
      requestId: 'request-stage08',
      rootRequestId: 'root-stage08',
    );
    expect(state.requestId, 'request-stage08');
    expect(state.rootRequestId, 'root-stage08');
  });

  test('restored snapshots cap evidence and executed query payloads', () {
    final raw = <String, dynamic>{
      'searchedAt': DateTime.utc(2026, 8, 23).toIso8601String(),
      'executedQueries': List.generate(100, (index) => 'query-$index'),
      'results': List.generate(
        searchMaxResultsLimit + 10,
        (index) => {
          'sourceId': 'S$index',
          'title': 'Result $index',
          'snippet': 'Snippet $index',
          'url': 'https://example.com/$index',
          'provider': 'fixture',
        },
      ),
    };

    final restored = WebSearchSnapshot.fromMap(raw);

    expect(restored, isNotNull);
    expect(restored!.results, hasLength(searchMaxResultsLimit));
    expect(restored.executedQueries, hasLength(5));
  });

  test('citation sanitizer preserves ordinary bracketed prose', () {
    const formatter = SearchContextFormatter();

    expect(
      formatter.sanitizeCitationsWithSourceIds(
        'Swift [Swift], SDK [SDK], stage [Stage], valid [S1].',
        const ['S1'],
      ),
      'Swift [Swift], SDK [SDK], stage [Stage], valid [S1].',
    );
  });

  test('SearchRequest strips sensitive query material at construction', () {
    final request = SearchRequest(
      query: 'find OPENAI_API_KEY=opaque-secret-value documentation',
    );

    expect(request.query, 'find documentation');
    expect(request.isSensitive, isTrue);
  });
}
