// 冒烟测试：仅验证 Flutter 测试环境可用，不依赖 Hive / 数据库。
// 业务核心逻辑由 test/sse_parser_test.dart、test/character_presets_test.dart、
// test/conversation_export_service_test.dart 等纯逻辑单测覆盖。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('Flutter 测试环境可用（冒烟测试）', (WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: Text('chat_group_smoke')),
      ),
    );
    expect(find.text('chat_group_smoke'), findsOneWidget);
  });
}
