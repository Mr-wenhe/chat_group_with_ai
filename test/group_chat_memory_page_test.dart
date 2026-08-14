import 'dart:io';

import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/permanent_memory.dart';
import 'package:chat_group/features/memory/memory_audit_filter.dart';
import 'package:chat_group/features/memory/memory_management_page.dart';
import 'package:chat_group/providers/providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/lifecycle_hive.dart';

void main() {
  late Directory directory;
  late DatabaseService db;

  setUpAll(() async {
    directory = await openLifecycleHive();
    db = DatabaseService();
  });

  tearDownAll(() => closeLifecycleHive(directory, db));

  setUp(() async {
    await db.aiCharacterBox.clear();
    await db.permanentMemoryBox.clear();
    await db.chatGroupBox.clear();
  });

  Widget app(Widget home) => ProviderScope(
        overrides: [databaseServiceProvider.overrideWithValue(db)],
        child: MaterialApp(home: home),
      );

  Future<void> putCharacter(AICharacter character) =>
      TestWidgetsFlutterBinding.ensureInitialized()
          .runAsync(() => db.aiCharacterBox.put(character.id, character));

  Future<void> putMemory(PermanentMemory memory) =>
      TestWidgetsFlutterBinding.ensureInitialized()
          .runAsync(() => db.permanentMemoryBox.put(memory.id, memory));

  Future<void> pumpPage(
    WidgetTester tester,
    MemoryConversationScope scope, {
    Size viewport = const Size(1200, 900),
  }) async {
    tester.view.physicalSize = viewport;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(app(MemoryManagementPage(scope: scope)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets('group scope selects only in-group observers and objects',
      (tester) async {
    final observer = testCharacter(
      'observer',
      apiConfigId: 'cfg',
      gender: CharacterGender.male,
    )
      ..name = '活跃观察 AI'
      ..role = '医生';
    final member = testCharacter(
      'member',
      apiConfigId: 'cfg',
      gender: CharacterGender.female,
    )
      ..name = '群内另一位 AI'
      ..role = '工程师';
    final outside = testCharacter('outside', apiConfigId: 'cfg')
      ..name = '群外 AI'
      ..role = '律师';
    await putCharacter(observer);
    await putCharacter(member);
    await putCharacter(outside);

    await putMemory(PermanentMemory(
      id: 'group-user-memory',
      observerCharacterId: observer.id,
      kind: MemoryKind.fact,
      content: '群内观察 AI 记得用户',
      subjectIds: const ['user'],
      status: MemoryStatus.active,
      originType: MemoryOriginType.direct,
      originConversationId: 'dm:outside',
      originNameSnapshot: '另一处私聊',
    ));
    await putMemory(PermanentMemory(
      id: 'group-member-memory',
      observerCharacterId: observer.id,
      kind: MemoryKind.fact,
      content: '群内观察 AI 记得群内成员',
      subjectIds: [member.id],
      status: MemoryStatus.active,
      originType: MemoryOriginType.group,
      originNameSnapshot: '其他群聊',
    ));
    await putMemory(PermanentMemory(
      id: 'group-growth-memory',
      observerCharacterId: observer.id,
      kind: MemoryKind.personaGrowth,
      content: '群内观察 AI 的自身成长',
      subjectIds: const [],
      status: MemoryStatus.active,
      originType: MemoryOriginType.manual,
      originNameSnapshot: '手动记录',
    ));
    await putMemory(PermanentMemory(
      id: 'group-outsider-memory',
      observerCharacterId: outside.id,
      kind: MemoryKind.fact,
      content: '群外观察 AI 不可见',
      subjectIds: const ['user'],
      status: MemoryStatus.active,
      originType: MemoryOriginType.group,
      originNameSnapshot: '群外群聊',
    ));
    await putMemory(PermanentMemory(
      id: 'group-mixed-memory',
      observerCharacterId: observer.id,
      kind: MemoryKind.fact,
      content: '含群外主体的记忆不可见',
      subjectIds: [member.id, outside.id],
      status: MemoryStatus.active,
      originType: MemoryOriginType.group,
      originNameSnapshot: '其他群聊',
    ));

    await pumpPage(
      tester,
      MemoryConversationScope.group({observer.id, member.id}),
    );

    expect(find.text('活跃观察 AI 的记忆'), findsOneWidget);
    expect(find.byKey(const ValueKey('memory-observer-all')), findsNothing);
    expect(
        find.byKey(const ValueKey('memory-observer-observer')), findsOneWidget);
    expect(
        find.byKey(const ValueKey('memory-observer-member')), findsOneWidget);
    expect(find.text('群外 AI'), findsNothing);
    expect(find.text('群内观察 AI 记得用户'), findsOneWidget);
    expect(find.text('群内观察 AI 记得群内成员'), findsOneWidget);
    expect(find.text('群内观察 AI 的自身成长'), findsOneWidget);
    expect(find.text('群外观察 AI 不可见'), findsNothing);
    expect(find.text('含群外主体的记忆不可见'), findsNothing);

    await tester.tap(
      find.byKey(const ValueKey('memory-subject-quick-other')),
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('memory-subject-search')));
    await tester.pump();
    expect(find.byKey(const ValueKey('memory-subject-option-member')),
        findsOneWidget);
    expect(find.byKey(const ValueKey('memory-subject-option-observer')),
        findsNothing);
    expect(find.text('群外 AI'), findsNothing);
  });

  testWidgets('changing group scope drops a departed selected observer',
      (tester) async {
    final first = testCharacter('first', apiConfigId: 'cfg')..name = '先前观察 AI';
    final remaining = testCharacter('remaining', apiConfigId: 'cfg')
      ..name = '仍在群内 AI';
    await putCharacter(first);
    await putCharacter(remaining);
    await putMemory(PermanentMemory(
      id: 'scope-change-memory',
      observerCharacterId: first.id,
      kind: MemoryKind.fact,
      content: '旧观察者记忆',
      subjectIds: const ['user'],
      status: MemoryStatus.active,
      originType: MemoryOriginType.group,
      originNameSnapshot: '群聊',
    ));

    await pumpPage(
      tester,
      MemoryConversationScope.group({first.id, remaining.id}),
    );
    expect(find.text('先前观察 AI 的记忆'), findsOneWidget);

    await tester.pumpWidget(app(MemoryManagementPage(
      scope: MemoryConversationScope.group({remaining.id}),
    )));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('仍在群内 AI'), findsWidgets);
    expect(find.text('先前观察 AI'), findsNothing);
    expect(find.text('旧观察者记忆'), findsNothing);
  });

  testWidgets('narrow group selector searches only current group AI',
      (tester) async {
    final observer = testCharacter(
      'narrow-observer',
      apiConfigId: 'cfg',
      gender: CharacterGender.male,
    )
      ..name = '窄屏观察 AI'
      ..role = '医生';
    final member = testCharacter(
      'narrow-member',
      apiConfigId: 'cfg',
      gender: CharacterGender.female,
    )
      ..name = '窄屏群内 AI'
      ..role = '工程师';
    final outside = testCharacter('narrow-outside', apiConfigId: 'cfg')
      ..name = '窄屏群外 AI'
      ..role = '律师';
    await putCharacter(observer);
    await putCharacter(member);
    await putCharacter(outside);

    await pumpPage(
      tester,
      MemoryConversationScope.group({observer.id, member.id}),
      viewport: const Size(600, 900),
    );

    expect(
        find.byKey(const ValueKey('memory-observer-selector')), findsOneWidget);
    expect(find.text('全部 AI'), findsNothing);
    final search = find.byKey(const ValueKey('memory-observer-search'));
    await tester.enterText(search, '工程师');
    await tester.pump();
    expect(find.text('窄屏群内 AI'), findsOneWidget);
    expect(find.text('窄屏群外 AI'), findsNothing);
  });

  testWidgets('empty group scope shows an explicit observer empty state',
      (tester) async {
    await pumpPage(tester, MemoryConversationScope.group(const {}));

    expect(find.text('群聊记忆'), findsOneWidget);
    expect(find.text('暂无可用观察 AI'), findsWidgets);
    expect(find.text('去创建 AI'), findsOneWidget);
  });

  testWidgets(
      'inactive group falls back to its first observer without mixing memories',
      (tester) async {
    final first = testCharacter('inactive-first', apiConfigId: 'cfg')
      ..name = '首位停用 AI'
      ..isActive = false;
    final second = testCharacter('inactive-second', apiConfigId: 'cfg')
      ..name = '第二位停用 AI'
      ..isActive = false;
    await putCharacter(first);
    await putCharacter(second);
    await putMemory(PermanentMemory(
      id: 'second-only-memory',
      observerCharacterId: second.id,
      kind: MemoryKind.fact,
      content: '第二位的记忆',
      subjectIds: const ['user'],
      status: MemoryStatus.active,
      originType: MemoryOriginType.group,
      originNameSnapshot: '群聊',
    ));

    await pumpPage(
        tester, MemoryConversationScope.group({first.id, second.id}));

    expect(find.text('首位停用 AI 的记忆'), findsOneWidget);
    expect(find.text('第二位的记忆'), findsNothing);
    expect(find.text('返回全部记录'), findsNothing);
  });
}
