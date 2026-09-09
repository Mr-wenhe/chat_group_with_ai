import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:html/dom.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:uuid/uuid.dart';

import 'package:chat_group/features/ai_governance/search_failure_classifier.dart';

import '../models/search_failure.dart';
import '../models/search_models.dart';
import '../security/search_endpoint_dns_guard.dart';
import '../security/search_secret_scanner.dart';
import 'search_provider.dart';
import 'search_provider_http_support.dart';

/// Keyless HTML search against a public DuckDuckGo result page.
///
/// The page is treated as untrusted evidence. Login, CAPTCHA, and paywall
/// pages become an explicit provider failure so a later visible-browser route
/// can take over without attempting to bypass the challenge.
class KeylessHtmlSearchProvider implements SearchProvider {
  static const String endpoint = 'https://html.duckduckgo.com/html/';
  static const String searchPath = '/html/';
  static const String bingEndpoint = 'https://www.bing.com/search';
  static const String bingSearchPath = '/search';
  static const String userAgent = 'chat_group/1.1.0 (keyless-search)';
  static const Duration connectTimeout = searchProviderConnectTimeout;
  static const Duration receiveTimeout = searchProviderReceiveTimeout;
  static const int maxResponseBytes = searchProviderMaxResponseBytes;
  static const int maxResultCandidates = searchProviderMaxResultCandidates;
  static const String healthProbeQuery = 'Flutter official documentation';

  KeylessHtmlSearchProvider({
    Dio? dio,
    Dio? bingDio,
    Uuid? uuid,
    bool? isRelease,
  })  : _dio = configureSearchProviderDio(dio ??
            Dio(
              BaseOptions(
                connectTimeout: connectTimeout,
                sendTimeout: connectTimeout,
                receiveTimeout: receiveTimeout,
                followRedirects: false,
                maxRedirects: 0,
              ),
            )),
        _bingDio = configureSearchProviderDio(bingDio ??
            Dio(
              BaseOptions(
                connectTimeout: connectTimeout,
                sendTimeout: connectTimeout,
                receiveTimeout: receiveTimeout,
                followRedirects: false,
                maxRedirects: 0,
              ),
            )),
        _uuid = uuid ?? const Uuid(),
        _isRelease = isRelease ?? kReleaseMode;

  final Dio _dio;
  final Dio _bingDio;
  final Uuid _uuid;
  final bool _isRelease;
  static final Uri _endpoint = Uri.parse(endpoint);

  @override
  SearchProviderKind get kind => SearchProviderKind.keylessHtml;

  @override
  Future<SearchProviderResponse> search(
    SearchRequest request, {
    required String? credential,
    CancelToken? cancelToken,
  }) async {
    if (kIsWeb) return webSearchUnsupportedResponse();
    final query = request.query.trim();
    if (query.isEmpty) return _noResults();

    final primary = await _searchEndpoint(
      dio: _dio,
      endpoint: _endpoint,
      request: request,
      query: query,
      cancelToken: cancelToken,
    );
    if (primary.failure == null || cancelToken?.isCancelled == true) {
      return primary;
    }

    // ponytail: one public HTML fallback covers regional/challenge responses;
    // a dedicated Dio keeps release DNS pinning scoped to one origin.
    final bing = await _searchEndpoint(
      dio: _bingDio,
      endpoint: Uri.parse(bingEndpoint),
      request: request,
      query: query,
      cancelToken: cancelToken,
      isBing: true,
    );
    if (bing.items.isNotEmpty) {
      return SearchProviderResponse(
        items: bing.items,
        providerRequestId: bing.providerRequestId,
        sourceProvider: 'Bing HTML（无 Key）',
        correctedQuery: bing.correctedQuery,
        moreResultsAvailable: bing.moreResultsAvailable,
        degraded: true,
        statusCode: bing.statusCode,
      );
    }
    return bing;
  }

  Future<SearchProviderResponse> _searchEndpoint({
    required Dio dio,
    required Uri endpoint,
    required SearchRequest request,
    required String query,
    required CancelToken? cancelToken,
    bool isBing = false,
  }) async {
    try {
      await prepareSearchEndpointConnection(
        dio,
        endpoint,
        isRelease: _isRelease,
      );
      final response = await dio.getUri<dynamic>(
        endpoint.replace(queryParameters: {'q': query}),
        options: Options(
          responseType: ResponseType.plain,
          followRedirects: false,
          maxRedirects: 0,
          connectTimeout: connectTimeout,
          sendTimeout: connectTimeout,
          receiveTimeout: receiveTimeout,
          validateStatus: (_) => true,
          headers: const {
            'Accept': 'text/html,application/xhtml+xml',
            'User-Agent': userAgent,
          },
        ),
        cancelToken: cancelToken,
      );
      return _parseResponse(request, response, isBing: isBing);
    } on DioException catch (error) {
      return _dioFailure(error);
    } on SearchEndpointDnsException catch (error) {
      return _failure(searchFailureTypeFromEndpointDnsException(error));
    } on SearchResponseTooLargeException {
      return _failure(SearchFailureType.invalidResponse);
    } on FormatException {
      return _failure(SearchFailureType.invalidResponse);
    } on Object {
      return _failure(SearchFailureType.unknown);
    }
  }

  @override
  Future<SearchHealthResult> testConnection({
    required String? credential,
    required String probeQuery,
  }) async {
    final stopwatch = Stopwatch()..start();
    final requestId = _uuid.v4();
    final response = await search(
      SearchRequest(
        requestId: requestId,
        rootRequestId: requestId,
        turnId: requestId,
        query: _safeProbeQuery(probeQuery),
        maxResults: searchProviderProbeMaxResults,
      ),
      credential: credential,
    );
    return SearchHealthResult(
      requestId: requestId,
      isHealthy: response.failure == null && response.items.isNotEmpty,
      latencyMs: stopwatch.elapsedMilliseconds,
      failure: response.failure,
      providerRequestId: response.providerRequestId,
    );
  }

  SearchProviderResponse _parseResponse(
    SearchRequest request,
    Response<dynamic> response, {
    bool isBing = false,
  }) {
    final requestId = providerRequestId(response: response);
    final statusCode = response.statusCode;
    if (statusCode == null || statusCode < 200 || statusCode >= 300) {
      return _failure(
        searchFailureTypeFromStatusCode(statusCode ?? 0),
        statusCode: statusCode,
        providerRequestId: requestId,
      );
    }

    final body = _responseBody(response.data);
    if (body == null || utf8.encode(body).length > maxResponseBytes) {
      return _failure(
        SearchFailureType.invalidResponse,
        statusCode: statusCode,
        providerRequestId: requestId,
      );
    }
    final document = html_parser.parse(body);
    if (_isChallengePage(document)) {
      return _failure(
        SearchFailureType.invalidResponse,
        statusCode: statusCode,
        providerRequestId: requestId,
      );
    }

    final items = _itemsFrom(document, request.maxResults, isBing: isBing);
    if (items.isEmpty) {
      return SearchProviderResponse(
        items: const [],
        providerRequestId: requestId,
        statusCode: statusCode,
        failure: buildSearchFailure(
          type: SearchFailureType.noResults,
          statusCode: statusCode,
          providerRequestId: requestId,
        ),
      );
    }
    return SearchProviderResponse(
      items: items,
      providerRequestId: requestId,
      moreResultsAvailable:
          _hasMoreResults(document, request.maxResults, isBing: isBing),
      sourceProvider: isBing ? 'Bing HTML（无 Key）' : null,
      statusCode: statusCode,
    );
  }

  List<SearchProviderItem> _itemsFrom(
    Document document,
    int requestedMax, {
    required bool isBing,
  }) {
    final maxResults = boundedSearchProviderMaxResults(requestedMax);
    final nodes = _resultNodes(document, isBing: isBing);
    final items = <SearchProviderItem>[];
    final seenUrls = <String>{};
    for (var index = 0;
        index < nodes.length && index < maxResultCandidates;
        index++) {
      if (items.length >= maxResults) break;
      final node = nodes[index];
      final titleLink = _titleLink(node, isBing: isBing);
      final url = _resolveResultUrl(titleLink?.attributes['href']);
      if (url == null || !seenUrls.add(canonicalProviderUrl(url))) continue;
      final title = _cleanText(titleLink?.text ?? '');
      final snippet = _cleanText(_snippet(node, isBing: isBing)?.text ?? '');
      if (title.isEmpty && snippet.isEmpty) continue;
      items.add(
        SearchProviderItem(
          title: title,
          snippet: snippet,
          url: url,
        ),
      );
    }
    return items;
  }

  List<Element> _resultNodes(Document document, {required bool isBing}) {
    if (isBing) {
      return document.querySelectorAll('li.b_algo');
    }
    final known = document.querySelectorAll('.result');
    if (known.isNotEmpty) return known;
    final dataTestResults = document.querySelectorAll('[data-testid="result"]');
    if (dataTestResults.isNotEmpty) return dataTestResults;

    // A small selector fallback tolerates a provider class rename without
    // accepting arbitrary page links as search results.
    final anchors = <Element>{
      ...document.querySelectorAll('a.result__a'),
      ...document.querySelectorAll('a[data-testid="result-title-a"]'),
    };
    final parents = <Element>[];
    for (final anchor in anchors) {
      final parent = _resultContainer(anchor);
      if (parent != null && !parents.contains(parent)) parents.add(parent);
    }
    return parents;
  }

  Element? _resultContainer(Element anchor) {
    var current = anchor.parent;
    for (var depth = 0; current != null && depth < 6; depth++) {
      if (current.localName == 'article' || current.localName == 'div') {
        return current;
      }
      current = current.parent;
    }
    return null;
  }

  Element? _titleLink(Element node, {required bool isBing}) => isBing
      ? node.querySelector('h2 a')
      : node.querySelector('a.result__a') ??
          node.querySelector('a[data-testid="result-title-a"]') ??
          node.querySelector('h2 a');

  Element? _snippet(Element node, {required bool isBing}) => isBing
      ? node.querySelector('.b_caption p') ?? node.querySelector('p')
      : node.querySelector('.result__snippet') ??
          node.querySelector('[data-testid="result-snippet"]') ??
          node.querySelector('p');

  bool _hasMoreResults(
    Document document,
    int requestedMax, {
    required bool isBing,
  }) {
    final maxResults = boundedSearchProviderMaxResults(requestedMax);
    return _resultNodes(document, isBing: isBing).length > maxResults;
  }

  bool _isChallengePage(Document document) {
    final challengeNodes = document.querySelectorAll(
      '[id*="captcha"], [class*="captcha"], '
      '[id*="challenge"], [class*="challenge"], '
      '[id*="paywall"], [class*="paywall"]',
    );
    if (challengeNodes.isNotEmpty) return true;
    // CSS attribute matching can be case-sensitive for HTML class names. A
    // bounded attribute scan catches an uppercase provider marker without
    // inspecting or executing page scripts.
    const attributeMarkers = ['captcha', 'challenge', 'paywall'];
    if (document.querySelectorAll('*').any((element) {
      final attributes = '${element.id} '
              '${element.attributes['class'] ?? ''}'
          .toLowerCase();
      return attributeMarkers.any(attributes.contains);
    })) {
      return true;
    }

    final title =
        _cleanText(document.querySelector('title')?.text ?? '').toLowerCase();
    final heading =
        _cleanText(document.querySelector('h1')?.text ?? '').toLowerCase();
    final markerText = '$title $heading';
    const markers = [
      'captcha',
      'verify you are human',
      'unusual traffic',
      'robot check',
      '验证码',
      '人机验证',
      'paywall',
      'login',
      'sign in',
      'sign in to continue',
      'log in to continue',
      '登录',
      '登录后继续',
    ];
    return markers.any(markerText.contains);
  }

  Uri? _resolveResultUrl(String? raw) {
    final value = raw?.trim() ?? '';
    if (value.isEmpty) return null;
    var parsed = Uri.tryParse(value);
    if (parsed == null) return null;
    if (parsed.scheme.isEmpty && value.startsWith('//')) {
      parsed = Uri.tryParse('https:$value');
    }
    if (parsed != null && parsed.scheme.isEmpty && value.startsWith('/')) {
      // Some DuckDuckGo deployments emit a root-relative wrapper instead of
      // the protocol-relative form. Resolve it against the fixed HTTPS
      // endpoint; the wrapper target still crosses the public HTTPS validator
      // below before becoming evidence.
      parsed = _endpoint.resolveUri(parsed);
    }
    if (parsed == null || parsed.scheme.isEmpty) return null;

    // DuckDuckGo sometimes wraps a public result in /l/?uddg=. Resolve only
    // that known wrapper; every resulting URL still crosses the HTTPS/public
    // URL validator before it can enter the normalized response.
    if ((parsed.host == 'duckduckgo.com' ||
            parsed.host == 'html.duckduckgo.com') &&
        parsed.path == '/l/') {
      final target = parsed.queryParameters['uddg'];
      if (target == null || target.trim().isEmpty) return null;
      parsed = Uri.tryParse(target);
    }
    return tryValidateSearchUrl(parsed);
  }

  String? _responseBody(dynamic data) {
    if (data is String) return data;
    if (data is List<int>) {
      // The bounded Dio transformer normally enforces this first, but custom
      // adapters and tests may provide raw bytes directly. Check before UTF-8
      // decoding so a bypass cannot allocate an oversized String.
      if (data.length > maxResponseBytes) return null;
      return utf8.decode(data, allowMalformed: false);
    }
    return null;
  }

  String _cleanText(String value) => sanitizeSearchText(
        value,
        maxLength: searchSnippetMaxLength,
        redactSecrets: true,
        redactOpaqueTokens: true,
      );

  String _safeProbeQuery(String value) {
    final safe = const SearchSecretScanner().redact(value).trim();
    return safe.isEmpty ? healthProbeQuery : safe;
  }

  SearchProviderResponse _noResults() => SearchProviderResponse(
        items: const [],
        failure: buildSearchFailure(type: SearchFailureType.noResults),
      );

  SearchProviderResponse _dioFailure(DioException error) {
    final response = error.response;
    final statusCode = response?.statusCode;
    // Preserve an HTTP upgrade signal such as 429 even if Dio rejected the
    // body while enforcing the byte limit. The status is safer and more
    // actionable than exposing any untrusted response text.
    if (statusCode != null && (statusCode < 200 || statusCode >= 300)) {
      return _failure(
        searchFailureTypeFromStatusCode(statusCode),
        statusCode: statusCode,
        providerRequestId: providerRequestId(response: response),
      );
    }
    if (error.error is SearchResponseTooLargeException) {
      return _failure(
        SearchFailureType.invalidResponse,
        statusCode: statusCode,
        providerRequestId: providerRequestId(response: response),
      );
    }
    return _failure(
      statusCode == null
          ? searchFailureTypeFromDioException(error)
          : searchFailureTypeFromStatusCode(statusCode),
      statusCode: statusCode,
      providerRequestId: providerRequestId(response: response),
    );
  }

  SearchProviderResponse _failure(
    SearchFailureType type, {
    int? statusCode,
    String? providerRequestId,
  }) {
    return SearchProviderResponse(
      items: const [],
      statusCode: statusCode,
      providerRequestId: providerRequestId,
      failure: buildSearchFailure(
        type: type,
        statusCode: statusCode,
        providerRequestId: providerRequestId,
      ),
    );
  }
}
