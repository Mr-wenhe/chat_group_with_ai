import 'dart:convert';

import '../models/search_models.dart' as domain;
import '../security/search_query_sanitizer.dart';
import '../security/search_secret_scanner.dart';
import 'search_prompts.dart';

class SearchContextBundle {
  final String evidenceJson;
  final String prompt;
  final List<String> sourceIds;

  const SearchContextBundle({
    required this.evidenceJson,
    required this.prompt,
    required this.sourceIds,
  });
}

/// Formats a snapshot without promoting external text to instructions.
class SearchContextFormatter {
  static const int defaultMaxSnippetCharacters = 800;
  static const int defaultMaxTotalCharacters = 6000;
  static const int defaultMaxSources = 5;
  static const int _maxTitleCharacters = 300;
  static const int _maxUrlCharacters = 2048;
  static const int _maxQueryCharacters = 240;
  static const int _minimumBudget = 64;

  final int maxSnippetCharacters;
  final int maxTotalCharacters;
  final int maxSources;
  final SearchQuerySanitizer sanitizer;

  const SearchContextFormatter({
    this.maxSnippetCharacters = defaultMaxSnippetCharacters,
    this.maxTotalCharacters = defaultMaxTotalCharacters,
    this.maxSources = defaultMaxSources,
    this.sanitizer = const SearchQuerySanitizer(),
  })  : assert(maxSnippetCharacters >= 0),
        assert(maxTotalCharacters >= _minimumBudget),
        assert(maxSources >= 0);

  SearchContextBundle format(domain.WebSearchSnapshot snapshot) {
    if (snapshot.hasFailure) {
      final prompt = SearchPrompts.buildFailurePrompt(
        failureType: snapshot.failure?.type.name ?? 'unknown',
        searchedAt: snapshot.searchedAt,
      );
      return SearchContextBundle(
        evidenceJson: _emptyEvidenceJson(snapshot),
        prompt: prompt,
        sourceIds: const [],
      );
    }
    if (!snapshot.hasResults) {
      final prompt = SearchPrompts.buildNoResultsPrompt(
        safeQueryPreview: _queryPreview(snapshot.executedQueries),
        searchedAt: snapshot.searchedAt,
      );
      return SearchContextBundle(
        evidenceJson: _emptyEvidenceJson(snapshot),
        prompt: prompt,
        sourceIds: const [],
      );
    }

    final evidence = _fitEvidence(
      searchedAt: snapshot.searchedAt,
      queries: snapshot.executedQueries,
      provider: snapshot.provider,
      results: snapshot.results
          .map(
            (result) => _EvidenceResult(
              title: result.title,
              url: result.url.toString(),
              publishedAt: result.publishedAt,
              snippet: result.snippet,
              displayHost: result.displayHost,
            ),
          )
          .toList(growable: false),
    );
    return SearchContextBundle(
      evidenceJson: evidence.json,
      prompt: _promptWithEvidence(evidence.json),
      sourceIds: evidence.sourceIds,
    );
  }

  String formatEvidenceJson(domain.WebSearchSnapshot snapshot) =>
      format(snapshot).evidenceJson;

  String formatPrompt(domain.WebSearchSnapshot snapshot) =>
      format(snapshot).prompt;

  List<Map<String, dynamic>> formatMessages(domain.WebSearchSnapshot snapshot) {
    final bundle = format(snapshot);
    return _messagesFor(bundle);
  }

  String sanitizeCitations(
    String answer,
    domain.WebSearchSnapshot snapshot,
  ) =>
      _sanitizeCitations(answer, format(snapshot).sourceIds.toSet());

  /// Removes citation markers when no snapshot can authorize them.
  ///
  /// A model may emit `[S1]` even when policy, consent, or a Provider failure
  /// produced no evidence. Those markers must not look like valid sources.
  String sanitizeCitationsWithSourceIds(
    String answer,
    Iterable<String> sourceIds,
  ) =>
      _sanitizeCitations(answer, sourceIds.toSet());

  List<Map<String, dynamic>> _messagesFor(SearchContextBundle bundle) {
    if (bundle.sourceIds.isEmpty) {
      return [
        {'role': 'system', 'content': bundle.prompt},
      ];
    }
    return [
      // Rules are isolated from the data block, so a malicious title/snippet
      // cannot become part of the rule text.
      {'role': 'system', 'content': SearchPrompts.promptD},
      {
        // Search results are untrusted evidence, not instructions. A user-role
        // block keeps provider text from inheriting system authority.
        'role': 'user',
        'content': 'WEB_SEARCH_EVIDENCE_DATA_BEGIN\n'
            '${bundle.evidenceJson}\n'
            'WEB_SEARCH_EVIDENCE_DATA_END',
      },
    ];
  }

  String _promptWithEvidence(String evidenceJson) =>
      '${SearchPrompts.promptD}\n\n'
      'WEB_SEARCH_EVIDENCE_DATA_BEGIN\n'
      '$evidenceJson\n'
      'WEB_SEARCH_EVIDENCE_DATA_END';

  _FittedEvidence _fitEvidence({
    required DateTime searchedAt,
    required Iterable<String> queries,
    required String provider,
    required List<_EvidenceResult> results,
  }) {
    final candidates = results.take(maxSources).toList(growable: true);
    while (true) {
      final base = _encode(
        searchedAt: searchedAt,
        queries: queries,
        provider: provider,
        results: candidates,
        snippetLimit: 0,
      );
      if (base.json.length <= maxTotalCharacters) {
        final snippetLimit = _largestSnippetLimit(
          searchedAt: searchedAt,
          queries: queries,
          provider: provider,
          results: candidates,
          baseLimit: maxSnippetCharacters,
        );
        final fitted = _encode(
          searchedAt: searchedAt,
          queries: queries,
          provider: provider,
          results: candidates,
          snippetLimit: snippetLimit,
        );
        return fitted;
      }
      if (candidates.isEmpty) {
        return _boundedEmptyEvidence(
          searchedAt: searchedAt,
          queries: queries,
          provider: provider,
        );
      }
      // Dropping the last item preserves the final search ordering and keeps
      // S1…Sn contiguous without ever truncating JSON into invalid syntax.
      candidates.removeLast();
    }
  }

  int _largestSnippetLimit({
    required DateTime searchedAt,
    required Iterable<String> queries,
    required String provider,
    required List<_EvidenceResult> results,
    required int baseLimit,
  }) {
    var low = 0;
    var high = baseLimit;
    while (low < high) {
      final middle = (low + high + 1) ~/ 2;
      final encoded = _encode(
        searchedAt: searchedAt,
        queries: queries,
        provider: provider,
        results: results,
        snippetLimit: middle,
      );
      if (encoded.json.length <= maxTotalCharacters) {
        low = middle;
      } else {
        high = middle - 1;
      }
    }
    return low;
  }

  _FittedEvidence _encode({
    required DateTime searchedAt,
    required Iterable<String> queries,
    required String provider,
    required List<_EvidenceResult> results,
    required int snippetLimit,
  }) {
    final sourceMaps = <Map<String, dynamic>>[];
    for (var index = 0; index < results.length; index++) {
      final result = results[index];
      sourceMaps.add({
        // IDs are assigned only from this final snapshot order; no model
        // output or caller-supplied citation can introduce a source ID.
        'source_id': 'S${index + 1}',
        'title': _truncate(result.title, _maxTitleCharacters),
        'url': _truncate(result.url, _maxUrlCharacters),
        'published_at': result.publishedAt?.toUtc().toIso8601String(),
        'snippet': _truncate(result.snippet, snippetLimit),
        'display_host': _truncate(result.displayHost, 120),
      });
    }
    final data = <String, dynamic>{
      'searched_at': searchedAt.toUtc().toIso8601String(),
      'queries': queries
          .map((query) => sanitizer.sanitize(query).text)
          .map((query) => _truncate(query, _maxQueryCharacters))
          .where((query) => query.isNotEmpty)
          .toList(growable: false),
      'provider': _truncate(provider, 120),
      'sources': sourceMaps,
    };
    return _FittedEvidence(
      json: jsonEncode(data),
      sourceIds: List.unmodifiable(
        List<String>.generate(sourceMaps.length, (index) => 'S${index + 1}'),
      ),
    );
  }

  String _emptyEvidenceJson(domain.WebSearchSnapshot snapshot) =>
      _boundedEmptyEvidence(
        searchedAt: snapshot.searchedAt,
        queries: snapshot.executedQueries,
        provider: snapshot.provider,
      ).json;

  _FittedEvidence _boundedEmptyEvidence({
    required DateTime searchedAt,
    required Iterable<String> queries,
    required String provider,
  }) {
    final full = _encode(
      searchedAt: searchedAt,
      queries: queries,
      provider: provider,
      results: const [],
      snippetLimit: 0,
    );
    if (full.json.length <= maxTotalCharacters) return full;
    return const _FittedEvidence(
      json: '{"searched_at":"","queries":[],"provider":"","sources":[]}',
      sourceIds: [],
    );
  }

  String _queryPreview(Iterable<String> queries) => queries
      .map((query) => sanitizer.sanitize(query).text)
      .map((query) => _truncate(query, _maxQueryCharacters))
      .firstWhere((query) => query.isNotEmpty, orElse: () => '');

  static String _truncate(String value, int maxLength) {
    final normalized = value
        .replaceAll(
          RegExp(r'<script\b[^>]*>[\s\S]*?(?:</script\s*>|$)',
              caseSensitive: false),
          ' ',
        )
        .replaceAll(
          RegExp(r'<style\b[^>]*>[\s\S]*?(?:</style\s*>|$)',
              caseSensitive: false),
          ' ',
        )
        .replaceAll(RegExp(r'<[^>]+>'), ' ')
        .replaceAll(RegExp(r'[\u0000-\u001F\u007F]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    final secretSafe = const SearchSecretScanner().redact(normalized);
    if (secretSafe.length <= maxLength) return secretSafe;
    return secretSafe.substring(0, maxLength).trimRight();
  }

  static String _sanitizeCitations(String answer, Set<String> allowed) {
    final allowedIds =
        allowed.map(_canonicalCitationId).where((id) => id.isNotEmpty).toSet();
    return answer.replaceAllMapped(_citationCandidatePattern, (match) {
      final raw = match.group(0)!;
      final candidate = raw.substring(1, raw.length - 1).trim();
      final id = _canonicalCitationId(candidate);
      return id.isNotEmpty && allowedIds.contains(id) ? '[$id]' : '';
    });
  }

  static String _canonicalCitationId(String value) {
    final normalized = value.trim();
    if (normalized.length < 2 || normalized[0].toUpperCase() != 'S') {
      return '';
    }
    final suffix = normalized.substring(1);
    if (!RegExp(r'^\d+$').hasMatch(suffix)) return '';
    return 'S$suffix';
  }

  static final _citationCandidatePattern =
      RegExp(r'\[\s*[sS](?:\d+|\s[^\]]*)?\s*\]');
}

class _EvidenceResult {
  final String title;
  final String url;
  final DateTime? publishedAt;
  final String snippet;
  final String displayHost;

  const _EvidenceResult({
    required this.title,
    required this.url,
    required this.publishedAt,
    required this.snippet,
    required this.displayHost,
  });
}

class _FittedEvidence {
  final String json;
  final List<String> sourceIds;

  const _FittedEvidence({required this.json, required this.sourceIds});
}
