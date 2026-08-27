import '../models/search_models.dart';

/// Secret-like material that must never be sent to a search Provider.
enum SearchSecretType {
  apiKey,
  bearerToken,
  jwt,
  pemPrivateKey,
  longHexToken,
  longBase64Token,
  localPath,
}

class SearchSecretFinding {
  final SearchSecretType type;
  final int start;
  final int end;

  const SearchSecretFinding({
    required this.type,
    required this.start,
    required this.end,
  });

  int get length => end - start;
}

/// The only query representation that may cross the search boundary.
class SanitizedSearchQuery {
  final String text;
  final List<SearchSecretFinding> findings;
  final bool wasTruncated;
  final bool wasMarkupStripped;

  SanitizedSearchQuery({
    required this.text,
    Iterable<SearchSecretFinding> findings = const [],
    this.wasTruncated = false,
    this.wasMarkupStripped = false,
  }) : findings = List.unmodifiable(findings);

  bool get containsSensitiveData => findings.isNotEmpty;
  bool get isSensitive => containsSensitiveData;

  /// There is no safe request when redaction removed the whole query.
  bool get blocked => text.trim().isEmpty && containsSensitiveData;

  bool get wasModified =>
      containsSensitiveData || wasTruncated || wasMarkupStripped;
}

/// Deterministic, local-only query redaction.
///
/// This class deliberately does not call a model. It also does not expose the
/// matched value in its result, so findings can safely be used in diagnostics.
class SearchQuerySanitizer {
  static const int defaultMaxQueryLength = searchQueryMaxLength;

  final int maxQueryLength;

  const SearchQuerySanitizer({
    this.maxQueryLength = defaultMaxQueryLength,
  }) : assert(maxQueryLength > 0);

  SanitizedSearchQuery sanitize(String? value) {
    final input = value?.trim() ?? '';
    if (input.isEmpty) return SanitizedSearchQuery(text: '');

    final markupSafe = _stripScriptStyle(input);
    final selected = _selectFindings(markupSafe);
    var redacted = markupSafe;
    for (final finding in selected.reversed) {
      redacted = redacted.replaceRange(finding.start, finding.end, ' ');
    }
    redacted = _normalizeWhitespace(redacted);

    final wasTruncated = redacted.length > maxQueryLength;
    if (wasTruncated) {
      redacted = _safeSubstring(redacted, maxQueryLength).trimRight();
    }

    return SanitizedSearchQuery(
      text: redacted,
      findings: selected,
      wasTruncated: wasTruncated,
      wasMarkupStripped: markupSafe != input,
    );
  }

  List<SearchSecretFinding> scan(String? value) => sanitize(value).findings;

  bool containsSensitiveData(String? value) => scan(value).isNotEmpty;

  /// Produces the second local query candidate. It is intentionally
  /// deterministic and never attempts to invent an entity or a date.
  String deterministicFallback(String value) {
    var candidate = _normalizeWhitespace(value);
    candidate = candidate
        .replaceFirst(RegExp(r'^\s*(请帮我|帮我|麻烦|请)\s*'), '')
        .replaceFirst(
          RegExp(r'^(联网)?(搜索|查一下|查查|搜一下)\s*'),
          '',
        )
        .trim();
    if (candidate.isEmpty) return '';
    if (candidate != value.trim()) return candidate;

    final lower = candidate.toLowerCase();
    if (lower.contains('latest')) {
      return candidate.replaceFirst(
        RegExp('latest', caseSensitive: false),
        'release notes',
      );
    }
    if (lower.contains('current')) {
      return candidate.replaceFirst(
        RegExp('current', caseSensitive: false),
        'up-to-date',
      );
    }
    if (!candidate.contains('官方') && !lower.contains('official')) {
      return '$candidate 官方';
    }
    return candidate;
  }

  List<SearchSecretFinding> _selectFindings(String input) {
    final candidates = <SearchSecretFinding>[];
    for (final pattern in _patterns) {
      for (final match in pattern.pattern.allMatches(input)) {
        if (match.start == match.end) continue;
        candidates.add(
          SearchSecretFinding(
            type: pattern.type,
            start: match.start,
            end: match.end,
          ),
        );
      }
    }

    candidates.sort((a, b) {
      final position = a.start.compareTo(b.start);
      if (position != 0) return position;
      return b.end.compareTo(a.end);
    });

    final selected = <SearchSecretFinding>[];
    for (final candidate in candidates) {
      final overlaps = selected.any(
        (existing) =>
            candidate.start < existing.end && existing.start < candidate.end,
      );
      if (!overlaps) selected.add(candidate);
    }
    return selected;
  }

  static String _normalizeWhitespace(String value) => value
      .replaceAll(RegExp(r'[\u0000-\u001F\u007F]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  static String _stripScriptStyle(String value) => value
      .replaceAll(
        RegExp(r'<script\b[^>]*>[\s\S]*?(?:</script\s*>|$)',
            caseSensitive: false),
        ' ',
      )
      .replaceAll(
        RegExp(r'<style\b[^>]*>[\s\S]*?(?:</style\s*>|$)',
            caseSensitive: false),
        ' ',
      );

  static String _safeSubstring(String value, int maxLength) {
    if (value.length <= maxLength) return value;
    var end = maxLength;
    if (end > 0 && _isHighSurrogate(value.codeUnitAt(end - 1))) end--;
    return value.substring(0, end);
  }

  static bool _isHighSurrogate(int codeUnit) =>
      codeUnit >= 0xD800 && codeUnit <= 0xDBFF;

  static final List<_SecretPattern> _patterns = [
    _SecretPattern(
      SearchSecretType.pemPrivateKey,
      RegExp(
        r'-----BEGIN [^-]+-----[\s\S]*?-----END [^-]+-----',
        caseSensitive: false,
      ),
    ),
    _SecretPattern(
      SearchSecretType.bearerToken,
      RegExp(r'\bbearer\s+[A-Za-z0-9._~+/=-]+', caseSensitive: false),
    ),
    _SecretPattern(
      SearchSecretType.jwt,
      RegExp(
        r'\beyJ[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]{5,}\b',
      ),
    ),
    _SecretPattern(
      SearchSecretType.apiKey,
      RegExp(
        r'\b(?:sk|pk|tvly|pplx|gsk|xai|hf|r8)-[A-Za-z0-9][A-Za-z0-9_./-]{7,}',
        caseSensitive: false,
      ),
    ),
    _SecretPattern(
      SearchSecretType.apiKey,
      RegExp(r'\b(?:AKIA|ASIA)[0-9A-Z]{16}\b', caseSensitive: false),
    ),
    _SecretPattern(
      SearchSecretType.apiKey,
      RegExp(
        r'\bbce-v[23]/[A-Za-z0-9][A-Za-z0-9_./-]{7,}',
        caseSensitive: false,
      ),
    ),
    _SecretPattern(
      SearchSecretType.apiKey,
      RegExp(r'\b(?:AK|SK)\s*[:=]\s*[^\s,;]+', caseSensitive: false),
    ),
    _SecretPattern(
      SearchSecretType.apiKey,
      RegExp(
        r'''\b(?:[A-Za-z0-9]+[_-])*(?:api[-_ ]?key|access[-_ ]?key|access[-_ ]?token|client[-_ ]?secret|secret[-_ ]?access[-_ ]?key|session[-_ ]?token|private[-_ ]?key|password|authorization|cookie)\s*[:=]\s*["']?(?:bearer\s+)?[^\s,;"']+''',
        caseSensitive: false,
      ),
    ),
    _SecretPattern(
      SearchSecretType.longHexToken,
      RegExp(r'(?<![\w])[0-9a-f]{32,}(?![\w])', caseSensitive: false),
    ),
    _SecretPattern(
      SearchSecretType.longBase64Token,
      RegExp(r'(?<![\w])[A-Za-z0-9+/=_-]{40,}(?![\w])'),
    ),
    _SecretPattern(
      SearchSecretType.localPath,
      RegExp(
        r'''(?:file://|[A-Za-z]:[\\/]|\\\\|/(?:Users|Volumes|home|tmp|var|private|mnt|opt|data)/)[^\s"'<>]+''',
        caseSensitive: false,
      ),
    ),
  ];
}

class _SecretPattern {
  final SearchSecretType type;
  final RegExp pattern;

  const _SecretPattern(this.type, this.pattern);
}
