import 'dart:io';

import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/api_config.dart';
import 'package:chat_group/core/models/character_presets.dart';
import 'package:chat_group/features/ai_character/ai_character_form_page.dart';
import 'package:chat_group/core/widgets/top_toast.dart';
import 'package:chat_group/providers/providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/lifecycle_hive.dart';

void main() {
  late Directory hiveDirectory;
  late DatabaseService db;
  late ProviderContainer providerContainer;

  setUp(() async {
    hiveDirectory = await openLifecycleHive();
    db = DatabaseService();
    providerContainer = ProviderContainer(
      overrides: [databaseServiceProvider.overrideWithValue(db)],
    );
    await db.apiConfigBox.put(
      'config-1',
      ApiConfig(
        id: 'config-1',
        name: '测试配置',
        provider: 'custom',
        customBaseUrl: 'https://example.invalid',
      ),
    );
  });

  tearDown(() async {
    providerContainer.dispose();
    AppToast.dismiss();
    await closeLifecycleHive(hiveDirectory);
  });

  Widget app(AICharacterFormPage page) => UncontrolledProviderScope(
        container: providerContainer,
        child: MaterialApp(home: page),
      );

  AICharacter character({CharacterGender gender = CharacterGender.female}) =>
      AICharacter(
        id: 'character-1',
        name: 'Amy',
        avatar: 'A',
        age: 28,
        role: '瑜伽教练',
        personalityTags: const [],
        systemPrompt: '温柔地陪伴用户。',
        apiKey: '',
        apiProvider: 'custom',
        apiConfigId: 'config-1',
        gender: gender,
      );

  testWidgets('new character requires an explicit gender', (tester) async {
    await tester.pumpWidget(app(const AICharacterFormPage()));
    await tester.tap(find.text('创建').first);
    await tester.pump();

    expect(find.text('请选择性别'), findsOneWidget);
  });

  testWidgets('gender field has only male and female choices', (tester) async {
    await tester.pumpWidget(app(const AICharacterFormPage()));
    await tester.tap(find.byType(DropdownButtonFormField<CharacterGender>));
    await tester.pumpAndSettle();

    expect(find.text('男'), findsOneWidget);
    expect(find.text('女'), findsOneWidget);
    expect(find.byType(DropdownMenuItem<CharacterGender>), findsNWidgets(2));
  });

  testWidgets('preset keeps gender unselected and shows the creation hint',
      (tester) async {
    await tester.pumpWidget(
      app(AICharacterFormPage(preset: CharacterPreset.presets.first)),
    );
    await tester.pump();

    expect(find.text('请选择'), findsOneWidget);
    expect(
      find.text('保存后不可修改，并会影响角色称谓与表达。'),
      findsOneWidget,
    );
  });

  testWidgets('age and gender fields align at 320 logical pixels',
      (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(app(const AICharacterFormPage()));
    await tester.pump();

    final ageField = find.byType(TextFormField).at(1);
    final genderField = find.byType(DropdownButtonFormField<CharacterGender>);
    final ageTop = tester.getTopLeft(ageField).dy;
    final genderTop = tester.getTopLeft(genderField).dy;

    expect((ageTop - genderTop).abs(), lessThan(0.5));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('selected gender is saved on creation', (tester) async {
    await tester.pumpWidget(app(const AICharacterFormPage()));
    await tester.enterText(find.byType(TextFormField).at(0), '阿杰');
    await tester.enterText(find.byType(TextFormField).at(2), '工程师');
    await tester.tap(find.byType(DropdownButtonFormField<CharacterGender>));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('男'));
    await tester.pump();
    await tester.runAsync(() async {
      await tester.tap(find.text('创建').first);
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pump(const Duration(milliseconds: 300));

    expect(db.aiCharacterBox.values.single.gender, CharacterGender.male);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump(const Duration(seconds: 4));
  });

  testWidgets('edit form locks the stored gender and explains the boundary',
      (tester) async {
    final saved = character(gender: CharacterGender.male);
    await tester.runAsync(() => db.aiCharacterBox.put(saved.id, saved));

    await tester.pumpWidget(app(AICharacterFormPage(character: saved)));
    await tester.pump();

    expect(find.text('男'), findsOneWidget);
    expect(find.byIcon(Icons.lock_outline_rounded), findsOneWidget);
    expect(find.text('创建后不可修改'), findsOneWidget);

    await tester.tap(find.byType(DropdownButtonFormField<CharacterGender>));
    await tester.pump();
    expect(find.text('女'), findsNothing);

    await tester.runAsync(() async {
      await tester.tap(find.text('更新').first);
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pump(const Duration(milliseconds: 300));
    expect(db.aiCharacterBox.get(saved.id)!.gender, CharacterGender.male);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump(const Duration(seconds: 4));
  });
}
