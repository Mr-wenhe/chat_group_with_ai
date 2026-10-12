import 'package:chat_group/features/settings/token_usage_detail_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<void> pumpPage(
    WidgetTester tester, {
    required Map<String, dynamic> byGroup,
    required Map<String, dynamic> byCharacter,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: TokenUsageDetailPage(
          byGroup: byGroup,
          byCharacter: byCharacter,
          groupNameOf: (groupId) => groupId == 'g1' ? '综合讨论组' : groupId,
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('renders per-group rows with resolved names and short totals',
      (tester) async {
    await pumpPage(
      tester,
      byGroup: {
        'g1': {'input': 20000, 'output': 2000, 'cached': 5000, 'count': 12},
      },
      byCharacter: const {},
    );

    expect(find.byKey(const Key('token-usage-by-group')), findsOneWidget);
    expect(find.text('各群消耗'), findsOneWidget);
    expect(find.text('综合讨论组'), findsOneWidget);
    expect(find.text('12 次 · 缓存 25.0%'), findsOneWidget);
    expect(find.text('2.2 万'), findsOneWidget);
  });

  testWidgets('renders per-character rows', (tester) async {
    await pumpPage(
      tester,
      byGroup: const {},
      byCharacter: {
        'c1': {'input': 3000000, 'output': 100},
      },
    );

    expect(find.byKey(const Key('token-usage-by-character')), findsOneWidget);
    expect(find.text('各角色消耗'), findsOneWidget);
    expect(find.text('c1'), findsOneWidget);
    expect(find.text('300.01 万'), findsOneWidget);
  });

  testWidgets('tolerates entries with missing numbers', (tester) async {
    await pumpPage(
      tester,
      byGroup: {
        'g1': {'count': 3},
      },
      byCharacter: {'c1': 'not-a-map'},
    );

    expect(find.text('3 次 · 缓存 0.0%'), findsOneWidget);
    expect(find.text('0'), findsNWidgets(2));
  });

  testWidgets('shows an empty state when nothing was recorded', (tester) async {
    await pumpPage(tester, byGroup: const {}, byCharacter: const {});

    expect(find.text('暂无消耗记录。'), findsOneWidget);
    expect(find.text('各群消耗'), findsNothing);
    expect(find.text('各角色消耗'), findsNothing);
  });
}
