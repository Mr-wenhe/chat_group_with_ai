import 'dart:io';

import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/features/settings/settings_page.dart';
import 'package:chat_group/features/settings/token_usage_detail_page.dart';
import 'package:chat_group/features/settings/work_folder_grants_page.dart';
import 'package:chat_group/providers/providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/lifecycle_hive.dart';

class _WidgetTestDatabaseService extends DatabaseService {
  @override
  Future<String> effectiveAiProcessingDirPath() async => '/tmp/ai_files';
}

void main() {
  late Directory hiveDirectory;
  late DatabaseService db;

  setUp(() async {
    hiveDirectory = await openLifecycleHive();
    db = _WidgetTestDatabaseService();
  });

  tearDown(() => closeLifecycleHive(hiveDirectory));

  Widget app(Widget home) => ProviderScope(
        overrides: [databaseServiceProvider.overrideWithValue(db)],
        child: MaterialApp(home: home),
      );

  /// Both lists live at the bottom of the settings page, so the finder has to
  /// scroll the page's own ListView before it can be tapped.
  Future<void> scrollTo(WidgetTester tester, Finder finder) async {
    await tester.scrollUntilVisible(
      finder,
      400,
      scrollable: find.byWidgetPredicate(
        (widget) =>
            widget is Scrollable && widget.axisDirection == AxisDirection.down,
      ),
    );
    await tester.pump(const Duration(milliseconds: 200));
  }

  testWidgets('settings page exposes the folder list through its own page',
      (tester) async {
    await tester.pumpWidget(app(const SettingsPage()));
    await tester.pump(const Duration(milliseconds: 300));

    final entry = find.byKey(const Key('work-folder-grants-entry'));
    await scrollTo(tester, entry);
    expect(entry, findsOneWidget);
    // The list itself stays off the settings page.
    expect(find.byKey(const Key('work-folder-grants-list')), findsNothing);

    await tester.tap(entry);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.runAsync(() async {});
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(WorkFolderGrantsPage), findsOneWidget);
    expect(find.byKey(const Key('work-folder-add')), findsOneWidget);
  });

  testWidgets('settings page keeps totals and links to the token breakdown',
      (tester) async {
    await tester.runAsync(() => db.recordTokenUsage(
          characterId: 'c1',
          groupId: 'g1',
          inputTokens: 412376715,
          outputTokens: 30635886,
          cachedTokens: 1486674,
        ));

    await tester.pumpWidget(app(const SettingsPage()));
    await tester.pump(const Duration(milliseconds: 300));

    final entry = find.byKey(const Key('token-usage-detail-entry'));
    await scrollTo(tester, entry);
    // Totals are abbreviated with unit suffixes instead of raw digits.
    expect(find.text('412376715'), findsNothing);
    expect(find.text('4.12 亿'), findsWidgets);
    expect(find.text('3063.59 万'), findsWidgets);
    // The per-group and per-character lists are not on the settings page.
    expect(find.byKey(const Key('token-usage-by-group')), findsNothing);

    await tester.tap(entry);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(TokenUsageDetailPage), findsOneWidget);
    expect(find.byKey(const Key('token-usage-by-group')), findsOneWidget);
    expect(find.byKey(const Key('token-usage-by-character')), findsOneWidget);
  });
}
