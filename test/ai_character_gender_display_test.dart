import 'dart:io';

import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/features/ai_character/ai_character_list_page.dart';
import 'package:chat_group/features/chat_group/chat_room_page.dart';
import 'package:chat_group/features/chat_group/widgets/member_sheet.dart';
import 'package:chat_group/providers/providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'helpers/lifecycle_hive.dart';

AICharacter _character({
  required String id,
  required String name,
  required CharacterGender gender,
  required String role,
  int age = 28,
  int hourlyReplyCount = 0,
}) {
  return AICharacter(
    id: id,
    name: name,
    avatar: name.substring(0, 1),
    age: age,
    role: role,
    personalityTags: const [],
    systemPrompt: '',
    apiKey: '',
    apiProvider: 'custom',
    hourlyReplyCount: hourlyReplyCount,
    gender: gender,
  );
}

void main() {
  late Directory hiveDirectory;
  late DatabaseService db;

  setUp(() async {
    hiveDirectory = await openLifecycleHive();
    db = DatabaseService();
  });

  tearDown(() => closeLifecycleHive(hiveDirectory));

  testWidgets('character list shows gender and searches by gender',
      (tester) async {
    final female = _character(
      id: 'female',
      name: 'Amy',
      gender: CharacterGender.female,
      role: '瑜伽教练',
    );
    final male = _character(
      id: 'male',
      name: '阿杰',
      gender: CharacterGender.male,
      role: '工程师',
      age: 30,
    );
    await tester.runAsync(
      () => db.aiCharacterBox.putAll({female.id: female, male.id: male}),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [databaseServiceProvider.overrideWithValue(db)],
        child: const MaterialApp(home: AICharacterListPage()),
      ),
    );
    await tester.pump();

    expect(find.text('女 · 瑜伽教练 · 28岁'), findsOneWidget);
    expect(find.text('男 · 工程师 · 30岁'), findsOneWidget);

    final search = find.byType(TextField).first;
    await tester.enterText(search, '男');
    await tester.pump();
    expect(find.text('阿杰'), findsOneWidget);
    expect(find.text('Amy'), findsNothing);
  });

  testWidgets('member sheet shows gender status and has no narrow overflow',
      (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final character = _character(
      id: 'male',
      name: '阿杰',
      gender: CharacterGender.male,
      role: '工程师',
      hourlyReplyCount: 2,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MemberSheet(
            characters: [character],
            ownerName: '群主',
            senderColor: (_) => Colors.blue,
            statusText: (member) => formatMemberStatus(member, null),
            onOpenSettings: (_) {},
            onDirectChat: (_) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('男 · 工程师 · 28岁 · 可回复 · 2/60 次/小时'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
