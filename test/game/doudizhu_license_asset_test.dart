import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('斗地主上游 MIT 许可证可作为 Flutter 资源读取', () async {
    final license = await rootBundle.loadString(
      'lib/features/game/doudizhu/LICENSE',
    );

    expect(license, contains('Copyright (c) 2026 justa-cai'));
    expect(license, contains('MIT License'));
    expect(license, contains('THE SOFTWARE IS PROVIDED "AS IS"'));
  });
}
