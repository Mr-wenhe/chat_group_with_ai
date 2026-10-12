/// Chinese numeral scales for token counts. Raw token totals run to nine or ten
/// digits, which overflows the settings card rows, so anything above ten
/// thousand is rendered as 万 / 亿 instead.
const int _wan = 10000;
const int _yi = 10000 * _wan;

/// Formats a token count for display: `412376715` → `4.12 亿`,
/// `412376` → `41.24 万`, `4856` → `4856`.
///
/// Fractions keep at most two decimals and drop trailing zeros, so an exact
/// scale reads as `1 亿` rather than `1.00 亿`.
String formatTokenCount(int count) {
  if (count < _wan) return '$count';
  if (count >= _yi) return '${_formatScale(count / _yi)} 亿';
  // 万 is the largest scale below 亿, so a value that rounds up to 10000 万 must
  // promote instead: 99999999 renders as 1 亿, not 10000 万.
  if (_roundToDisplay(count / _wan) >= _wan) {
    return '${_formatScale(count / _yi)} 亿';
  }
  return '${_formatScale(count / _wan)} 万';
}

String _formatScale(double value) {
  final text = _roundToDisplay(value).toStringAsFixed(2);
  if (text.endsWith('.00')) return text.substring(0, text.length - 3);
  if (text.endsWith('0')) return text.substring(0, text.length - 1);
  return text;
}

/// Rounds to the two decimals actually displayed, so the scale decision matches
/// what the user sees rather than the unrounded ratio.
double _roundToDisplay(double value) => (value * 100).roundToDouble() / 100;

/// Share of the input tokens served from the prompt cache.
String formatCacheHitPercent(int cachedTokens, int inputTokens) {
  if (inputTokens <= 0) return '0.0%';
  return '${(cachedTokens / inputTokens * 100).toStringAsFixed(1)}%';
}
