import 'dart:io';

import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/models/message.dart';
import 'package:chat_group/features/search/global_search_page.dart';
import 'package:chat_group/providers/providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/lifecycle_hive.dart';

void main() {
  late Directory directory;
  late DatabaseService db;

  setUp(() async {
    directory = await openLifecycleHive();
    db = DatabaseService();
    await db.messageBox.put(
      'm1',
      Message(
        id: 'm1',
        groupId: 'g1',
        senderId: 'c1',
        senderType: 'ai',
        content: '林黛玉来了',
        timestamp: DateTime(2026, 7, 1),
      ),
    );
  });

  tearDown(() => closeLifecycleHive(directory, db));

  Future<void> search(WidgetTester tester, String query) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [databaseServiceProvider.overrideWithValue(db)],
        child: const MaterialApp(home: GlobalSearchPage()),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, query);
    await tester.tap(find.byIcon(Icons.arrow_forward_rounded));
    await tester.pumpAndSettle();
  }

  /// 返回结果正文里被高亮的那几段文字。
  List<String?> highlightedRuns(WidgetTester tester) {
    final text = tester.widget<Text>(
      find.byWidgetPredicate(
        (widget) =>
            widget is Text &&
            widget.textSpan?.toPlainText() == '林黛玉来了',
      ),
    );
    return (text.textSpan! as TextSpan)
        .children!
        .whereType<TextSpan>()
        .where((span) => span.style?.fontWeight == FontWeight.bold)
        .map((span) => span.text)
        .toList();
  }

  testWidgets('pinyin hit highlights the character it landed on',
      (tester) async {
    await search(tester, 'lin');

    expect(find.byType(ListTile), findsOneWidget);
    expect(highlightedRuns(tester), ['林']);
  });

  testWidgets('initial-letter hit highlights every matched character',
      (tester) async {
    await search(tester, 'ldy');

    expect(find.byType(ListTile), findsOneWidget);
    expect(highlightedRuns(tester), ['林黛玉']);
  });
}
