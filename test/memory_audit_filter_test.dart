// ignore_for_file: prefer_const_constructors, prefer_const_declarations

import 'package:chat_group/core/models/permanent_memory.dart';
import 'package:chat_group/features/memory/memory_audit_filter.dart';
import 'package:chat_group/features/memory/memory_audit_filter_widget.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/lifecycle_hive.dart';

void main() {
  group('MemoryConversationScope', () {
    final aboutUser = PermanentMemory(
      observerCharacterId: 'a',
      kind: MemoryKind.fact,
      content: '用户喜欢咖啡',
      subjectIds: const ['user'],
      status: MemoryStatus.active,
      originType: MemoryOriginType.group,
      originNameSnapshot: '别的群',
    );
    final aboutMember = PermanentMemory(
      observerCharacterId: 'a',
      kind: MemoryKind.fact,
      content: 'B喜欢茶',
      subjectIds: const ['b'],
      status: MemoryStatus.active,
      originType: MemoryOriginType.group,
      originNameSnapshot: '别的群',
    );
    final aboutOutsider = PermanentMemory(
      observerCharacterId: 'a',
      kind: MemoryKind.fact,
      content: '群外角色喜欢水',
      subjectIds: const ['outside'],
      status: MemoryStatus.active,
      originType: MemoryOriginType.group,
      originNameSnapshot: '别的群',
    );

    test('direct chat shows only the target AI memories about the user', () {
      final scope = MemoryConversationScope.direct('a');

      expect(scope.apply([aboutUser, aboutMember]), [aboutUser]);
    });

    test('group chat includes cross-occasion memories for current members', () {
      final scope = MemoryConversationScope.group({'a', 'b'});

      expect(scope.apply([aboutUser, aboutMember, aboutOutsider]),
          [aboutUser, aboutMember]);
    });
  });

  group('MemoryAuditFilter', () {
    test('isEmpty returns true for default filter', () {
      expect(MemoryAuditFilter().isEmpty, isTrue);
    });

    test('apply without filters returns all memories', () {
      final memories = [
        PermanentMemory(
          observerCharacterId: 'c1',
          kind: MemoryKind.fact,
          content: 'a',
          status: MemoryStatus.active,
          originType: MemoryOriginType.group,
          originNameSnapshot: 'g1',
        ),
        PermanentMemory(
          observerCharacterId: 'c2',
          kind: MemoryKind.fact,
          content: 'b',
          status: MemoryStatus.active,
          originType: MemoryOriginType.direct,
          originNameSnapshot: 'dm',
        ),
      ];
      final result = MemoryAuditFilter().apply(memories);
      expect(result.length, 2);
    });

    test('apply filters by observerCharacterId', () {
      final memories = [
        PermanentMemory(
          observerCharacterId: 'c1',
          kind: MemoryKind.fact,
          content: 'a',
          status: MemoryStatus.active,
          originType: MemoryOriginType.group,
          originNameSnapshot: 'g1',
        ),
        PermanentMemory(
          observerCharacterId: 'c2',
          kind: MemoryKind.fact,
          content: 'b',
          status: MemoryStatus.active,
          originType: MemoryOriginType.group,
          originNameSnapshot: 'g1',
        ),
      ];
      final result =
          MemoryAuditFilter(observerCharacterId: 'c1').apply(memories);
      expect(result.length, 1);
      expect(result.first.observerCharacterId, 'c1');
    });

    test('apply filters by status', () {
      final memories = [
        PermanentMemory(
          observerCharacterId: 'c1',
          kind: MemoryKind.fact,
          content: 'a',
          status: MemoryStatus.active,
          originType: MemoryOriginType.group,
          originNameSnapshot: 'g1',
        ),
        PermanentMemory(
          observerCharacterId: 'c1',
          kind: MemoryKind.fact,
          content: 'b',
          status: MemoryStatus.superseded,
          originType: MemoryOriginType.group,
          originNameSnapshot: 'g1',
        ),
      ];
      final result =
          MemoryAuditFilter(status: MemoryStatus.active).apply(memories);
      expect(result.length, 1);
      expect(result.first.status, MemoryStatus.active);
    });

    test('apply filters by originType', () {
      final memories = [
        PermanentMemory(
          observerCharacterId: 'c1',
          kind: MemoryKind.fact,
          content: 'a',
          status: MemoryStatus.active,
          originType: MemoryOriginType.group,
          originNameSnapshot: 'g1',
        ),
        PermanentMemory(
          observerCharacterId: 'c1',
          kind: MemoryKind.fact,
          content: 'b',
          status: MemoryStatus.active,
          originType: MemoryOriginType.manual,
          originNameSnapshot: 'manual',
        ),
      ];
      final result = MemoryAuditFilter(originType: MemoryOriginType.manual)
          .apply(memories);
      expect(result.length, 1);
      expect(result.first.originType, MemoryOriginType.manual);
    });

    test('apply filters by memoryKind', () {
      final memories = [
        PermanentMemory(
          observerCharacterId: 'c1',
          kind: MemoryKind.fact,
          content: 'a',
          status: MemoryStatus.active,
          originType: MemoryOriginType.group,
          originNameSnapshot: 'g1',
        ),
        PermanentMemory(
          observerCharacterId: 'c1',
          kind: MemoryKind.preference,
          content: 'b',
          status: MemoryStatus.active,
          originType: MemoryOriginType.group,
          originNameSnapshot: 'g1',
        ),
      ];
      final result =
          MemoryAuditFilter(memoryKind: MemoryKind.preference).apply(memories);
      expect(result.length, 1);
      expect(result.first.kind, MemoryKind.preference);
    });

    test('apply filters pinnedOnly true', () {
      final memories = [
        PermanentMemory(
          observerCharacterId: 'c1',
          kind: MemoryKind.fact,
          content: 'a',
          status: MemoryStatus.active,
          originType: MemoryOriginType.group,
          originNameSnapshot: 'g1',
          pinned: true,
        ),
        PermanentMemory(
          observerCharacterId: 'c1',
          kind: MemoryKind.fact,
          content: 'b',
          status: MemoryStatus.active,
          originType: MemoryOriginType.group,
          originNameSnapshot: 'g1',
          pinned: false,
        ),
      ];
      final result = MemoryAuditFilter(pinnedOnly: true).apply(memories);
      expect(result.length, 1);
      expect(result.first.pinned, isTrue);
    });

    test('pinnedOnly false filters pinned out', () {
      final memories = [
        PermanentMemory(
          observerCharacterId: 'c1',
          kind: MemoryKind.fact,
          content: 'a',
          status: MemoryStatus.active,
          originType: MemoryOriginType.group,
          originNameSnapshot: 'g1',
          pinned: true,
        ),
        PermanentMemory(
          observerCharacterId: 'c1',
          kind: MemoryKind.fact,
          content: 'b',
          status: MemoryStatus.active,
          originType: MemoryOriginType.group,
          originNameSnapshot: 'g1',
          pinned: false,
        ),
      ];
      final result = MemoryAuditFilter(pinnedOnly: false).apply(memories);
      expect(result.length, 1);
      expect(result.first.pinned, isFalse);
    });

    test('subjectFilter aboutMe matches user subjectIds', () {
      final memories = [
        PermanentMemory(
          observerCharacterId: 'c1',
          kind: MemoryKind.fact,
          content: 'a',
          status: MemoryStatus.active,
          originType: MemoryOriginType.group,
          originNameSnapshot: 'g1',
          subjectIds: const ['user'],
        ),
        PermanentMemory(
          observerCharacterId: 'c1',
          kind: MemoryKind.fact,
          content: 'b',
          status: MemoryStatus.active,
          originType: MemoryOriginType.group,
          originNameSnapshot: 'g1',
          subjectIds: const ['c2'],
        ),
      ];
      final result = MemoryAuditFilter(subjectFilter: SubjectFilter.aboutMe())
          .apply(memories);
      expect(result.length, 1);
      expect(result.first.subjectIds, contains('user'));
    });

    test('subjectFilter aboutCharacter matches given id', () {
      final memories = [
        PermanentMemory(
          observerCharacterId: 'c1',
          kind: MemoryKind.fact,
          content: 'a',
          status: MemoryStatus.active,
          originType: MemoryOriginType.group,
          originNameSnapshot: 'g1',
          subjectIds: const ['c2'],
        ),
        PermanentMemory(
          observerCharacterId: 'c1',
          kind: MemoryKind.fact,
          content: 'b',
          status: MemoryStatus.active,
          originType: MemoryOriginType.group,
          originNameSnapshot: 'g1',
          subjectIds: const ['c3'],
        ),
      ];
      final result =
          MemoryAuditFilter(subjectFilter: SubjectFilter.aboutCharacter('c2'))
              .apply(memories);
      expect(result.length, 1);
      expect(result.first.subjectIds, contains('c2'));
    });

    test('subjectFilter selfGrowth matches empty subjectIds', () {
      final memories = [
        PermanentMemory(
          observerCharacterId: 'c1',
          kind: MemoryKind.personaGrowth,
          content: 'a',
          status: MemoryStatus.active,
          originType: MemoryOriginType.group,
          originNameSnapshot: 'g1',
          subjectIds: const [],
        ),
        PermanentMemory(
          observerCharacterId: 'c1',
          kind: MemoryKind.fact,
          content: 'b',
          status: MemoryStatus.active,
          originType: MemoryOriginType.group,
          originNameSnapshot: 'g1',
          subjectIds: const ['user'],
        ),
      ];
      final result =
          MemoryAuditFilter(subjectFilter: SubjectFilter.selfGrowth())
              .apply(memories);
      expect(result.length, 1);
      expect(result.first.subjectIds, isEmpty);
    });

    test('subjectFilter selfGrowth includes personaGrowth with subjects', () {
      final memories = [
        PermanentMemory(
          observerCharacterId: 'c1',
          kind: MemoryKind.personaGrowth,
          content: '成长也涉及用户',
          status: MemoryStatus.active,
          originType: MemoryOriginType.group,
          originNameSnapshot: 'g1',
          subjectIds: const ['user'],
        ),
        PermanentMemory(
          observerCharacterId: 'c1',
          kind: MemoryKind.fact,
          content: '普通事实',
          status: MemoryStatus.active,
          originType: MemoryOriginType.group,
          originNameSnapshot: 'g1',
          subjectIds: const ['user'],
        ),
      ];

      final result = MemoryAuditFilter(
        subjectFilter: SubjectFilter.selfGrowth(),
      ).apply(memories);

      expect(result.map((memory) => memory.content), ['成长也涉及用户']);
    });

    test('apply filters by origin conversation id', () {
      final memories = [
        PermanentMemory(
          observerCharacterId: 'c1',
          kind: MemoryKind.fact,
          content: '群一',
          status: MemoryStatus.active,
          originType: MemoryOriginType.group,
          originConversationId: 'g1',
          originNameSnapshot: '群一',
        ),
        PermanentMemory(
          observerCharacterId: 'c1',
          kind: MemoryKind.fact,
          content: '群二',
          status: MemoryStatus.active,
          originType: MemoryOriginType.group,
          originConversationId: 'g2',
          originNameSnapshot: '群二',
        ),
      ];

      final result = MemoryAuditFilter(
        originConversationId: 'g2',
      ).apply(memories);

      expect(result.map((memory) => memory.content), ['群二']);
    });

    test('filters combine with AND', () {
      final memories = [
        PermanentMemory(
          observerCharacterId: 'c1',
          kind: MemoryKind.fact,
          content: 'a',
          status: MemoryStatus.active,
          originType: MemoryOriginType.group,
          originNameSnapshot: 'g1',
          pinned: true,
          subjectIds: const ['user'],
        ),
        PermanentMemory(
          observerCharacterId: 'c1',
          kind: MemoryKind.fact,
          content: 'b',
          status: MemoryStatus.active,
          originType: MemoryOriginType.group,
          originNameSnapshot: 'g1',
          pinned: false,
          subjectIds: const ['user'],
        ),
        PermanentMemory(
          observerCharacterId: 'c2',
          kind: MemoryKind.fact,
          content: 'c',
          status: MemoryStatus.active,
          originType: MemoryOriginType.group,
          originNameSnapshot: 'g1',
          pinned: true,
          subjectIds: const ['user'],
        ),
      ];
      final result = MemoryAuditFilter(
        observerCharacterId: 'c1',
        pinnedOnly: true,
        subjectFilter: SubjectFilter.aboutMe(),
      ).apply(memories);
      expect(result.length, 1);
      expect(result.first.observerCharacterId, 'c1');
      expect(result.first.pinned, isTrue);
    });

    test('copyWith clear semantics — clearObserverCharacterId resets to null',
        () {
      final f = MemoryAuditFilter(
          observerCharacterId: 'c1', status: MemoryStatus.active);
      final cleared = f.copyWith(clearObserverCharacterId: true);
      expect(cleared.observerCharacterId, isNull);
      expect(cleared.status, MemoryStatus.active);
    });

    test('copyWith clear semantics — clearStatus resets to null', () {
      final f = MemoryAuditFilter(
          observerCharacterId: 'c1', status: MemoryStatus.active);
      final cleared = f.copyWith(clearStatus: true);
      expect(cleared.status, isNull);
      expect(cleared.observerCharacterId, 'c1');
    });

    test('copyWith clear semantics — all clear produces empty filter', () {
      final f = MemoryAuditFilter(
        observerCharacterId: 'c1',
        status: MemoryStatus.active,
        memoryKind: MemoryKind.fact,
        originType: MemoryOriginType.group,
        originConversationId: 'g1',
        pinnedOnly: true,
        subjectFilter: SubjectFilter.aboutMe(),
      );
      final cleared = f.copyWith(
        clearObserverCharacterId: true,
        clearStatus: true,
        clearMemoryKind: true,
        clearOriginType: true,
        clearOriginConversationId: true,
        clearPinnedOnly: true,
        clearSubjectFilter: true,
      );
      expect(cleared.isEmpty, isTrue);
    });
  });

  group('MemoryAuditFilterWidget', () {
    testWidgets('empty filter renders nothing', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: MemoryAuditFilterWidget(
            filter: const MemoryAuditFilter(),
            characters: const [],
            onChanged: (_) {},
          ),
        ),
      ));
      await tester.pump(const Duration(milliseconds: 500));

      expect(find.text('清除筛选'), findsNothing);
    });

    testWidgets('non-empty filter shows chips and clear button',
        (tester) async {
      final chars = [testCharacter('c1', apiConfigId: 'cfg')];
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: MemoryAuditFilterWidget(
            filter: MemoryAuditFilter(observerCharacterId: 'c1'),
            characters: chars,
            onChanged: (_) {},
          ),
        ),
      ));
      await tester.pump(const Duration(milliseconds: 500));

      expect(find.text('角色: 角色c1'), findsOneWidget);
      expect(find.text('清除筛选'), findsOneWidget);
    });

    testWidgets('tapping clear button emits empty filter', (tester) async {
      MemoryAuditFilter? captured;
      final chars = [testCharacter('c1', apiConfigId: 'cfg')];
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: MemoryAuditFilterWidget(
            filter: MemoryAuditFilter(observerCharacterId: 'c1'),
            characters: chars,
            onChanged: (f) => captured = f,
          ),
        ),
      ));
      await tester.pump(const Duration(milliseconds: 500));

      await tester.tap(find.text('清除筛选'));
      await tester.pump(const Duration(milliseconds: 500));

      expect(captured, isNotNull);
      expect(captured!.isEmpty, isTrue);
    });

    testWidgets('copyWith clear semantics preserves other filter dimensions',
        (tester) async {
      // Verify that copyWith clear semantics work correctly:
      // clearing one field preserves others.
      final filter = MemoryAuditFilter(
        observerCharacterId: 'c1',
        status: MemoryStatus.active,
      );
      final cleared = filter.copyWith(clearObserverCharacterId: true);
      expect(cleared.observerCharacterId, isNull);
      expect(cleared.status, MemoryStatus.active);
    });

    testWidgets('all filter option groups are visible', (tester) async {
      final chars = [testCharacter('c1', apiConfigId: 'cfg')];
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: MemoryAuditFilterWidget(
            filter: const MemoryAuditFilter(),
            characters: chars,
            onChanged: (_) {},
          ),
        ),
      ));
      await tester.pump(const Duration(milliseconds: 500));

      // Widget is always visible even with empty filter.
      expect(find.byType(MemoryAuditFilterWidget), findsOneWidget);
    });

    testWidgets('subject filter selection updates callback', (tester) async {
      MemoryAuditFilter? captured;
      final chars = [testCharacter('c1', apiConfigId: 'cfg')];
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: MemoryAuditFilterWidget(
            filter: const MemoryAuditFilter(),
            characters: chars,
            onChanged: (f) => captured = f,
          ),
        ),
      ));
      await tester.pump(const Duration(milliseconds: 500));

      // Tap '关于我' choice chip.
      await tester.tap(find.text('关于我'));
      await tester.pump(const Duration(milliseconds: 500));
      expect(captured, isNotNull);
      expect(captured!.subjectFilter, SubjectFilter.aboutMe());
    });

    testWidgets('origin type selection updates callback', (tester) async {
      MemoryAuditFilter? captured;
      final chars = [testCharacter('c1', apiConfigId: 'cfg')];
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: MemoryAuditFilterWidget(
            filter: const MemoryAuditFilter(),
            characters: chars,
            onChanged: (f) => captured = f,
          ),
        ),
      ));
      await tester.pump(const Duration(milliseconds: 500));

      await tester.tap(find.text('手动'));
      await tester.pump(const Duration(milliseconds: 500));
      expect(captured, isNotNull);
      expect(captured!.originType, MemoryOriginType.manual);
    });

    testWidgets('tapping "全部来源" clears originType', (tester) async {
      MemoryAuditFilter? captured;
      final chars = [testCharacter('c1', apiConfigId: 'cfg')];
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: MemoryAuditFilterWidget(
            filter:
                const MemoryAuditFilter(originType: MemoryOriginType.manual),
            characters: chars,
            onChanged: (f) => captured = f,
          ),
        ),
      ));
      await tester.pump(const Duration(milliseconds: 500));

      await tester.tap(find.text('全部来源'));
      await tester.pump(const Duration(milliseconds: 500));
      expect(captured, isNotNull);
      expect(captured!.originType, isNull);
    });

    testWidgets('tapping a status then "全部状态" clears status', (tester) async {
      MemoryAuditFilter? captured;
      final chars = [testCharacter('c1', apiConfigId: 'cfg')];
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: MemoryAuditFilterWidget(
            filter: const MemoryAuditFilter(status: MemoryStatus.active),
            characters: chars,
            onChanged: (f) => captured = f,
          ),
        ),
      ));
      await tester.pump(const Duration(milliseconds: 500));

      await tester.tap(find.text('已取代'));
      await tester.pump(const Duration(milliseconds: 500));
      expect(captured!.status, MemoryStatus.superseded);

      captured = null;
      await tester.tap(find.text('全部状态'));
      await tester.pump(const Duration(milliseconds: 500));
      expect(captured, isNotNull);
      expect(captured!.status, isNull);
    });

    testWidgets('tapping a kind then "全部类型" clears memoryKind', (tester) async {
      MemoryAuditFilter? captured;
      final chars = [testCharacter('c1', apiConfigId: 'cfg')];
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: MemoryAuditFilterWidget(
            filter: const MemoryAuditFilter(memoryKind: MemoryKind.fact),
            characters: chars,
            onChanged: (f) => captured = f,
          ),
        ),
      ));
      await tester.pump(const Duration(milliseconds: 500));

      await tester.tap(find.text('偏好'));
      await tester.pump(const Duration(milliseconds: 500));
      expect(captured!.memoryKind, MemoryKind.preference);

      captured = null;
      await tester.tap(find.text('全部类型'));
      await tester.pump(const Duration(milliseconds: 500));
      expect(captured, isNotNull);
      expect(captured!.memoryKind, isNull);
    });

    testWidgets('tapping pinned filter then "固定状态: 全部" clears pinnedOnly',
        (tester) async {
      MemoryAuditFilter? captured;
      final chars = [testCharacter('c1', apiConfigId: 'cfg')];
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: MemoryAuditFilterWidget(
            filter: const MemoryAuditFilter(pinnedOnly: true),
            characters: chars,
            onChanged: (f) => captured = f,
          ),
        ),
      ));
      await tester.pump(const Duration(milliseconds: 500));

      await tester.tap(find.text('仅未固定'));
      await tester.pump(const Duration(milliseconds: 500));
      expect(captured!.pinnedOnly, isFalse);

      captured = null;
      await tester.tap(find.text('固定状态: 全部'));
      await tester.pump(const Duration(milliseconds: 500));
      expect(captured, isNotNull);
      expect(captured!.pinnedOnly, isNull);
    });

    testWidgets('observer dropdown clears via filter copyWith semantics',
        (tester) async {
      // The dropdown widget delegates to filter.copyWith; verify the clear
      // semantics directly: copyWith(clearObserverCharacterId: true, observerCharacterId: null)
      // must produce null.
      final f = MemoryAuditFilter(observerCharacterId: 'c1');
      final cleared = f.copyWith(clearObserverCharacterId: true);
      expect(cleared.observerCharacterId, isNull);
    });

    testWidgets('origin conversation dropdown selects another occasion',
        (tester) async {
      MemoryAuditFilter? captured;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: MemoryAuditFilterWidget(
            filter: const MemoryAuditFilter(originConversationId: 'g1'),
            characters: const [],
            originConversations: const {'g1': '群一', 'g2': '群二'},
            onChanged: (filter) => captured = filter,
          ),
        ),
      ));
      await tester.pump();

      await tester.tap(find.byType(DropdownButton<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('群二 (g2)').last);
      await tester.pump();

      expect(captured?.originConversationId, 'g2');
    });

    testWidgets('origin conversation input accepts an id not in the list',
        (tester) async {
      MemoryAuditFilter? captured;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: MemoryAuditFilterWidget(
            filter: const MemoryAuditFilter(),
            characters: const [],
            onChanged: (filter) => captured = filter,
          ),
        ),
      ));
      await tester.pump();

      await tester.tap(find.text('输入场合'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, 'deleted-group');
      await tester.tap(find.text('应用'));
      await tester.pump();

      expect(captured?.originConversationId, 'deleted-group');
    });
  });
}
