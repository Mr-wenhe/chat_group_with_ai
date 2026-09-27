import 'dart:async';

import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/features/chat_group/widgets/member_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/lifecycle_hive.dart';

/// 成员面板的禁言与点名操作。
void main() {
  final alice = testCharacter('a');

  /// 面板挂在一个真实路由上：`点名发言` 内部会 `Navigator.pop`，需要有落点。
  Future<void> pumpSheet(
    WidgetTester tester, {
    required Set<String> mutedIds,
    Future<void> Function(AICharacter, bool)? onToggleMute,
    ValueChanged<AICharacter>? onMention,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => Scaffold(
                      body: MemberSheet(
                        characters: [alice],
                        ownerName: '老冯',
                        senderColor: (_) => Colors.blue,
                        statusText: (_) => '在线',
                        onOpenSettings: (_) {},
                        onDirectChat: (_) {},
                        mutedIds: mutedIds,
                        onToggleMute: onToggleMute,
                        onMention: onMention,
                      ),
                    ),
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('未禁言：副标题不带标记，菜单提供「禁言」与「点名发言」', (tester) async {
    await pumpSheet(
      tester,
      mutedIds: const {},
      onToggleMute: (_, __) async {},
      onMention: (_) {},
    );

    expect(find.text('在线'), findsOneWidget);
    expect(find.textContaining('已禁言'), findsNothing);

    await tester.tap(find.byIcon(Icons.more_vert_rounded));
    await tester.pumpAndSettle();

    expect(find.text('禁言（@ 点名仍可回复）'), findsOneWidget);
    expect(find.text('点名发言'), findsOneWidget);
  });

  testWidgets('已禁言：副标题带标记，菜单改为「取消禁言」', (tester) async {
    await pumpSheet(
      tester,
      mutedIds: {'a'},
      onToggleMute: (_, __) async {},
      onMention: (_) {},
    );

    expect(find.text('已禁言 · 在线'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.more_vert_rounded));
    await tester.pumpAndSettle();

    expect(find.text('取消禁言'), findsOneWidget);
  });

  testWidgets('选择禁言：回调被触发，且标记立即出现（无需重开面板）', (tester) async {
    final toggled = <String>[];
    await pumpSheet(
      tester,
      mutedIds: const {},
      onToggleMute: (character, muted) async {
        expect(muted, isTrue);
        toggled.add(character.id);
      },
      onMention: (_) {},
    );

    await tester.tap(find.byIcon(Icons.more_vert_rounded));
    await tester.pumpAndSettle();
    await tester.tap(find.text('禁言（@ 点名仍可回复）'));
    await tester.pumpAndSettle();

    expect(toggled, ['a']);
    expect(
      find.text('已禁言 · 在线'),
      findsOneWidget,
      reason: '面板内的本地副本应立即反映切换结果',
    );
  });

  testWidgets('选择点名发言：回调被触发并收起面板', (tester) async {
    final mentioned = <String>[];
    await pumpSheet(
      tester,
      mutedIds: const {},
      onToggleMute: (_, __) async {},
      onMention: (character) => mentioned.add(character.id),
    );

    await tester.tap(find.byIcon(Icons.more_vert_rounded));
    await tester.pumpAndSettle();
    await tester.tap(find.text('点名发言'));
    await tester.pumpAndSettle();

    expect(mentioned, ['a']);
    // 点名要把 @ 写进输入框，面板必须收起。
    expect(find.text('open'), findsOneWidget);
  });

  testWidgets('保存失败保留原状态并显示错误，重试成功后再更新', (tester) async {
    var attempts = 0;
    await pumpSheet(
      tester,
      mutedIds: const {},
      onToggleMute: (_, __) async {
        if (attempts++ == 0) throw StateError('disk full');
      },
    );
    for (var attempt = 0; attempt < 2; attempt++) {
      await tester.tap(find.byIcon(Icons.more_vert_rounded));
      await tester.pumpAndSettle();
      expect(find.text('点名发言'), findsNothing);
      await tester.tap(find.text('禁言（@ 点名仍可回复）'));
      await tester.pumpAndSettle();
      if (attempt == 0) {
        expect(find.textContaining('已禁言'), findsNothing);
        expect(find.text('禁言设置保存失败，请重试'), findsOneWidget);
      }
    }
    expect(find.text('已禁言 · 在线'), findsOneWidget);
    expect(find.text('禁言设置保存失败，请重试'), findsNothing);
  });

  testWidgets('等待保存时不显示成功状态且禁止重复提交', (tester) async {
    final saved = Completer<void>();
    var calls = 0;
    await pumpSheet(
      tester,
      mutedIds: const {},
      onToggleMute: (_, __) {
        calls++;
        return saved.future;
      },
      onMention: (_) {},
    );
    await tester.tap(find.byIcon(Icons.more_vert_rounded));
    await tester.pumpAndSettle();
    await tester.tap(find.text('禁言（@ 点名仍可回复）'));
    await tester.pumpAndSettle();
    expect(find.textContaining('已禁言'), findsNothing);
    await tester.tap(find.byIcon(Icons.more_vert_rounded));
    await tester.pumpAndSettle();
    expect(find.text('禁言（@ 点名仍可回复）'), findsNothing);
    expect(calls, 1);
    saved.complete();
    await tester.pumpAndSettle();
    expect(find.text('已禁言 · 在线'), findsOneWidget);
  });

  testWidgets('未提供回调时不显示溢出菜单', (tester) async {
    await pumpSheet(tester, mutedIds: const {});

    expect(find.byIcon(Icons.more_vert_rounded), findsNothing);
    // 私聊入口仍然保留（本批不改变既有可见性）。
    expect(find.byIcon(Icons.chat_bubble_outline_rounded), findsOneWidget);
  });
}
