class MoneyMicros {
  static String editingText(int? micros) =>
      micros == null ? '' : (micros / 1000000).toStringAsFixed(6);

  static String display(int micros) => (micros / 1000000).toStringAsFixed(6);

  static int? parseUsd(String raw) {
    final value = raw.trim();
    if (value.isEmpty) return null;
    if (!RegExp(r'^\d+(?:\.\d{0,6})?$').hasMatch(value)) {
      throw const FormatException('金额最多保留 6 位小数');
    }
    final parts = value.split('.');
    final whole = int.parse(parts.first);
    final fractionalText = parts.length == 1 ? '' : parts.last;
    final fraction = int.parse(fractionalText.padRight(6, '0'));
    final micros = whole * 1000000 + fraction;
    return micros == 0 ? null : micros;
  }
}
