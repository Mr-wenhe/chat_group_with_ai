import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:html/parser.dart' as html_parser;

import '../models/search_models.dart';
import '../security/search_endpoint_dns_guard.dart';
import 'search_provider.dart';
import 'search_provider_http_support.dart';

/// Loads the public pages behind DuckDuckGo results and turns their visible
/// text into bounded evidence. The callback is injectable so this behavior can
/// be tested without making network requests.
/// Returns the raw HTML body for a validated public page URL.
typedef DuckDuckGoPageLoader = Future<String?> Function(
  Uri url, {
  CancelToken? cancelToken,
});

class DuckDuckGoResultPageEnricher {
  static const Duration _connectTimeout = searchProviderConnectTimeout;
  static const Duration _receiveTimeout = searchProviderReceiveTimeout;
  static const int _maxPages = 2;
  static const Duration _pageTimeout = Duration(seconds: 3);
  static const int _maxPageExcerptLength = 460;
  static const int _maxOriginalSnippetLength = 300;
  static const String _userAgent = 'chat_group/1.1.0 (search-evidence)';

  DuckDuckGoResultPageEnricher({
    Dio? dio,
    bool? isRelease,
    DuckDuckGoPageLoader? pageLoader,
  })  : _dio = configureSearchProviderDio(dio ??
            Dio(
              BaseOptions(
                connectTimeout: _connectTimeout,
                sendTimeout: _connectTimeout,
                receiveTimeout: _receiveTimeout,
                followRedirects: false,
                maxRedirects: 0,
              ),
            )),
        _isRelease = isRelease ?? kReleaseMode,
        _pageLoader = pageLoader;

  final Dio _dio;
  final bool _isRelease;
  final DuckDuckGoPageLoader? _pageLoader;

  /// Enriches only the first two result links. A page failure is deliberately
  /// non-terminal: the original title/snippet remains valid evidence.
  Future<List<SearchProviderItem>> enrich(
    Iterable<SearchProviderItem> source, {
    CancelToken? cancelToken,
  }) async {
    final items = source.toList(growable: false);
    final enriched = List<SearchProviderItem>.of(items);
    final pageCount = items.length < _maxPages ? items.length : _maxPages;
    for (var index = 0; index < pageCount; index++) {
      if (cancelToken?.isCancelled == true) break;
      final pageText = await _loadPage(items[index].url, cancelToken)
          .timeout(_pageTimeout, onTimeout: () => null);
      if (pageText == null || pageText.isEmpty) continue;
      enriched[index] = _withPageEvidence(items[index], pageText);
    }
    return enriched;
  }

  SearchProviderItem _withPageEvidence(
    SearchProviderItem item,
    String pageText,
  ) {
    final original = sanitizeSearchText(
      item.snippet,
      maxLength: _maxOriginalSnippetLength,
      redactSecrets: true,
      redactOpaqueTokens: true,
    );
    final excerpt = sanitizeSearchText(
      pageText,
      maxLength: _maxPageExcerptLength,
      redactSecrets: true,
      redactOpaqueTokens: true,
    );
    final evidence = [
      if (original.isNotEmpty) original,
      if (excerpt.isNotEmpty) '网页正文：$excerpt',
    ].join(' ');
    return SearchProviderItem(
      title: item.title,
      snippet: evidence,
      url: item.url,
      publishedAt: item.publishedAt,
      providerScore: item.providerScore,
      language: item.language,
      allowInsecureHttp: item.allowInsecureHttp,
    );
  }

  Future<String?> _loadPage(Uri url, CancelToken? cancelToken) async {
    final safeUrl = tryValidateSearchUrl(url);
    if (safeUrl == null) return null;
    try {
      final loader = _pageLoader;
      if (loader != null) {
        final loaded = await loader(safeUrl, cancelToken: cancelToken);
        return loaded == null ? null : _extractVisibleText(loaded);
      }
      await prepareSearchEndpointConnection(
        _dio,
        safeUrl,
        isRelease: _isRelease,
      );
      final response = await _dio.getUri<dynamic>(
        safeUrl,
        options: Options(
          responseType: ResponseType.plain,
          followRedirects: false,
          maxRedirects: 0,
          connectTimeout: _connectTimeout,
          sendTimeout: _connectTimeout,
          receiveTimeout: _receiveTimeout,
          validateStatus: (_) => true,
          headers: const {
            'Accept': 'text/html,application/xhtml+xml',
            'User-Agent': _userAgent,
          },
        ),
        cancelToken: cancelToken,
      );
      if (response.statusCode == null ||
          response.statusCode! < 200 ||
          response.statusCode! >= 300) {
        return null;
      }
      final body = response.data is String ? response.data as String : null;
      if (body == null || _utf8ByteLength(body) > searchProviderMaxResponseBytes) {
        return null;
      }
      return _extractVisibleText(body);
    } on Object {
      // Page retrieval augments a successful search and must never turn it
      // into a provider failure. Cancellation is observed by the next loop.
      return null;
    }
  }

  String _extractVisibleText(String body) {
    final document = html_parser.parse(body);
    document
        .querySelectorAll('script,style,noscript,template,svg,iframe,form')
        .forEach((element) => element.remove());
    final bodyText = document.body?.text.trim() ?? '';
    final text = bodyText.isNotEmpty ? bodyText : (document.text ?? '');
    return sanitizeSearchText(
      text,
      maxLength: _maxPageExcerptLength,
      redactSecrets: true,
      redactOpaqueTokens: true,
    );
  }
}

int _utf8ByteLength(String value) => utf8.encode(value).length;
