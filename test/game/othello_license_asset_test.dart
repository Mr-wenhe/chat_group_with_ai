import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('上游 MIT 许可随 Flutter 资源打包', () async {
    final license = await rootBundle.loadString(
      'lib/features/game/othello/LICENSE',
    );

    expect(license, contains('Copyright (c) 2025 Play Coop Games'));
    expect(license, contains('MIT License'));
    expect(license, contains('THE SOFTWARE IS PROVIDED "AS IS"'));
  });
}
