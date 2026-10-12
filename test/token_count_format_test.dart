import 'package:chat_group/features/settings/token_count_format.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('formatTokenCount', () {
    test('keeps counts below ten thousand as-is', () {
      expect(formatTokenCount(0), '0');
      expect(formatTokenCount(4856), '4856');
      expect(formatTokenCount(9999), '9999');
    });

    test('renders ten thousand and above in 万', () {
      expect(formatTokenCount(10000), '1 万');
      expect(formatTokenCount(12345), '1.23 万');
      expect(formatTokenCount(412376), '41.24 万');
      expect(formatTokenCount(30635886), '3063.59 万');
    });

    test('renders one hundred million and above in 亿', () {
      expect(formatTokenCount(100000000), '1 亿');
      expect(formatTokenCount(148667400), '1.49 亿');
      expect(formatTokenCount(412376715), '4.12 亿');
    });

    test('drops trailing zeros in the fraction', () {
      expect(formatTokenCount(100000000), '1 亿');
      expect(formatTokenCount(14000000), '1400 万');
      expect(formatTokenCount(120000000), '1.2 亿');
    });

    test('promotes a 万 value that rounds up to a whole 亿', () {
      expect(formatTokenCount(99999999), '1 亿');
    });
  });

  group('formatCacheHitPercent', () {
    test('reports one decimal of the input share', () {
      expect(formatCacheHitPercent(1486674, 412376715), '0.4%');
      expect(formatCacheHitPercent(50, 100), '50.0%');
    });

    test('treats a missing input total as zero', () {
      expect(formatCacheHitPercent(0, 0), '0.0%');
    });
  });
}
