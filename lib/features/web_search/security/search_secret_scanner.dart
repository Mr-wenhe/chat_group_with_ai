/// Shared, deterministic scanner for values that must not cross a search
/// persistence, logging, or prompt boundary.
///
/// The scanner never returns a matched value. Callers receive only a redacted
/// string and a boolean, so a diagnostic can safely use the result.
class SearchSecretScanResult {
  final String value;
  final bool containsSensitiveData;

  const SearchSecretScanResult({
    required this.value,
    required this.containsSensitiveData,
  });
}

class SearchSecretScanner {
  static const redaction = '[REDACTED]';

  const SearchSecretScanner();

  SearchSecretScanResult scan(
    String? raw, {
    bool includeOpaqueTokens = false,
  }) {
    final value = raw ?? '';
    final matches = <_SecretSpan>[];
    for (final pattern in _patterns) {
      for (final match in pattern.allMatches(value)) {
        if (match.start != match.end) {
          matches.add(_SecretSpan(match.start, match.end));
        }
      }
    }
    if (includeOpaqueTokens) {
      for (final pattern in _opaqueTokenPatterns) {
        for (final match in pattern.allMatches(value)) {
          if (match.start != match.end &&
              _hasOpaqueTokenSignal(match.group(0)!)) {
            matches.add(_SecretSpan(match.start, match.end));
          }
        }
      }
    }
    if (matches.isEmpty) {
      return SearchSecretScanResult(
        value: value,
        containsSensitiveData: false,
      );
    }

    matches.sort((left, right) {
      final byStart = left.start.compareTo(right.start);
      return byStart == 0 ? right.end.compareTo(left.end) : byStart;
    });
    final selected = <_SecretSpan>[];
    for (final match in matches) {
      final overlaps = selected.any(
        (existing) => match.start < existing.end && existing.start < match.end,
      );
      if (!overlaps) selected.add(match);
    }

    var redacted = value;
    for (final match in selected.reversed) {
      redacted = redacted.replaceRange(match.start, match.end, redaction);
    }
    return SearchSecretScanResult(
      value: redacted,
      containsSensitiveData: true,
    );
  }

  String redact(
    String? raw, {
    bool includeOpaqueTokens = false,
  }) =>
      scan(raw, includeOpaqueTokens: includeOpaqueTokens).value;

  bool containsSensitiveData(
    String? raw, {
    bool includeOpaqueTokens = false,
  }) =>
      scan(raw, includeOpaqueTokens: includeOpaqueTokens).containsSensitiveData;

  /// Query parameter names are metadata, but a credential-like name is enough
  /// to make retaining the corresponding value unsafe.
  bool isSensitiveParameter(String name) {
    final normalized = name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
    return normalized.contains('cookie') ||
        normalized.contains('authorization') ||
        normalized.contains('apikey') ||
        normalized.contains('token') ||
        normalized.contains('secret') ||
        normalized.contains('credential') ||
        normalized.contains('password') ||
        normalized == 'key' ||
        normalized.endsWith('key');
  }

  static final List<RegExp> _patterns = [
    RegExp(
      r'-----BEGIN [^-]+-----[\s\S]*?-----END [^-]+-----',
      caseSensitive: false,
    ),
    RegExp(
      r'\b(?:authorization|proxy-authorization|cookie|set-cookie)\s*:\s*[^\r\n]+',
      caseSensitive: false,
      multiLine: true,
    ),
    RegExp(
      r'''\b(?:[A-Za-z0-9]+[_-])*(?:api[-_ ]?key|access[-_ ]?key|access[-_ ]?token|client[-_ ]?secret|subscription[-_ ]?key|secret[-_ ]?access[-_ ]?key|session[-_ ]?token|private[-_ ]?key|credential|password|secret|token|authorization|proxy[-_ ]?authorization|cookie|set[-_ ]?cookie)\s*[:=]\s*["']?(?:bearer\s+)?[^\s,;}"']+''',
      caseSensitive: false,
    ),
    RegExp(
      r'\b(?:cookie|set-cookie)\s*[:=]\s*[^\r\n]+',
      caseSensitive: false,
      multiLine: true,
    ),
    RegExp(r'\bbearer\s+[A-Za-z0-9._~+/=-]{8,}', caseSensitive: false),
    RegExp(
      r'\beyJ[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]{5,}\b',
    ),
    RegExp(
      r'\b(?:sk|pk|tvly|pplx|gsk|xai|hf|r8)-[A-Za-z0-9][A-Za-z0-9_./-]{7,}',
      caseSensitive: false,
    ),
    RegExp(
      r'\bbce-v[23]/[A-Za-z0-9][A-Za-z0-9_./-]{7,}',
      caseSensitive: false,
    ),
    RegExp(r'\bAIza[A-Za-z0-9_-]{20,}', caseSensitive: false),
    RegExp(r'\b(?:AKIA|ASIA)[0-9A-Z]{16}\b', caseSensitive: false),
  ];

  /// These patterns are deliberately opt-in. A generic Base64-looking word is
  /// not reliable enough to reject an arbitrary chat backup, but it is unsafe
  /// when it originates from an untrusted search provider or search audit.
  static final List<RegExp> _opaqueTokenPatterns = [
    RegExp(r'(?<![\w])[0-9a-f]{32,}(?![\w])', caseSensitive: false),
    RegExp(r'(?<![\w])[A-Za-z0-9+/=_-]{40,}(?![\w])'),
  ];
}

class _SecretSpan {
  final int start;
  final int end;

  const _SecretSpan(this.start, this.end);
}

/// Avoid treating a deliberately long but ordinary repeated word as a secret.
/// Opaque tokens normally contain at least two distinct character classes.
bool _hasOpaqueTokenSignal(String value) {
  var characterClasses = 0;
  if (RegExp(r'[a-z]').hasMatch(value)) characterClasses++;
  if (RegExp(r'[A-Z]').hasMatch(value)) characterClasses++;
  if (RegExp(r'[0-9]').hasMatch(value)) characterClasses++;
  if (RegExp(r'[+/=_-]').hasMatch(value)) characterClasses++;
  return characterClasses >= 2;
}
