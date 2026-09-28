import 'dart:io';

import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/api_config.dart';
import 'package:chat_group/core/models/character_presets.dart';
import 'package:chat_group/core/models/tool_permission.dart';
import 'package:chat_group/features/ai_character/ai_character_form_page.dart';
import 'package:chat_group/core/widgets/top_toast.dart';
import 'package:chat_group/providers/providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/async_pump.dart';
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

  AICharacter character({
    CharacterGender gender = CharacterGender.female,
    bool hasKnownGender = true,
    String ipImageRelPath = '',
    bool avatarFromIpImage = false,
    String ipImageStyle = '',
    String apiConfigId = 'config-1',
    String voiceId = '',
  }) =>
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
        apiConfigId: apiConfigId,
        voiceId: voiceId,
        gender: gender,
        hasKnownGender: hasKnownGender,
        ipImageRelPath: ipImageRelPath,
        avatarFromIpImage: avatarFromIpImage,
        ipImageStyle: ipImageStyle,
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

  testWidgets('edit form returns the persisted permissions to its caller',
      (tester) async {
    tester.view.physicalSize = const Size(800, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final saved = character();
    await tester.runAsync(() => db.aiCharacterBox.put(saved.id, saved));

    AICharacter? returned;
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: providerContainer,
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: ElevatedButton(
                onPressed: () async {
                  returned = await Navigator.of(context).push<AICharacter>(
                    MaterialPageRoute(
                      builder: (_) => AICharacterFormPage(character: saved),
                    ),
                  );
                },
                child: const Text('打开设置'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开设置'));
    await tester.pumpAndSettle();

    final readWorkspace = find.text('读工作区');
    final patchWorkspace = find.text('改文件');
    await tester.pump();
    await tester.tap(readWorkspace);
    await tester.tap(patchWorkspace);
    await tester.pump();

    await tester.runAsync(() async {
      await tester.tap(find.text('更新').first);
    });
    // Saving writes to Hive before the route pops, so wait for the caller to
    // receive the result rather than for a guessed duration.
    await pumpUntilReady(tester, () => returned != null);
    await tester.pump(const Duration(milliseconds: 300));

    expect(returned?.id, saved.id);
    expect(returned?.toolPermissions, contains(ToolPermission.workspaceRead));
    expect(returned?.toolPermissions, contains(ToolPermission.workspacePatch));
    expect(
        db.aiCharacterBox.get(saved.id)!.toolPermissions,
        containsAll(<ToolPermission>[
          ToolPermission.workspaceRead,
          ToolPermission.workspacePatch,
        ]));
  });

  testWidgets(
      'edit form reloads persisted permissions when given a stale character',
      (tester) async {
    tester.view.physicalSize = const Size(800, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final saved = character();
    await tester.runAsync(() => db.aiCharacterBox.put(saved.id, saved));

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: providerContainer,
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: ElevatedButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => AICharacterFormPage(character: saved),
                  ),
                ),
                child: const Text('打开设置'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开设置'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('读工作区'));
    await tester.tap(find.text('改文件'));
    await tester.pump();

    await tester.runAsync(() async {
      await tester.tap(find.text('更新').first);
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pump(const Duration(milliseconds: 300));

    expect(
        db.aiCharacterBox.get(saved.id)!.toolPermissions,
        containsAll(<ToolPermission>[
          ToolPermission.workspaceRead,
          ToolPermission.workspacePatch,
        ]));

    // The caller may still hold the object it used to open the first form.
    await tester.pumpAndSettle();
    await tester.tap(find.text('打开设置'));
    await tester.pumpAndSettle();

    final permissionChips = find.byType(FilterChip);
    expect(permissionChips, findsNWidgets(ToolPermission.values.length));
    // ToolPermission.values starts with workspaceRead/workspacePatch.
    expect(tester.widget<FilterChip>(permissionChips.at(0)).selected, isTrue);
    expect(tester.widget<FilterChip>(permissionChips.at(1)).selected, isTrue);
  });

  testWidgets('edit form keeps a legacy unknown gender visibly unresolved',
      (tester) async {
    final saved = character(
      gender: CharacterGender.female,
      hasKnownGender: false,
    );

    await tester.pumpWidget(app(AICharacterFormPage(character: saved)));
    await tester.pump();

    expect(find.text('未知（迁移中）'), findsOneWidget);
    expect(find.text('女'), findsNothing);
    expect(find.text('创建后不可修改'), findsOneWidget);
  });

  testWidgets('IP 形象面板出现在姓名行下方', (tester) async {
    await tester.pumpWidget(app(const AICharacterFormPage()));
    await tester.pump();

    expect(find.text('IP 形象'), findsOneWidget);
    expect(find.byKey(const ValueKey('ip-portrait-generate')), findsOneWidget);
    // 未生成时不出「设为头像 / 清除形象」。
    expect(
      find.byKey(const ValueKey('ip-portrait-toggle-avatar')),
      findsNothing,
    );
    expect(find.byKey(const ValueKey('ip-portrait-clear')), findsNothing);
  });

  testWidgets('查看 Prompt 摊出拼装原文，并标注尚未生成过', (tester) async {
    final saved = character();
    await tester.runAsync(() => db.aiCharacterBox.put(saved.id, saved));

    await tester.pumpWidget(app(AICharacterFormPage(character: saved)));
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('ip-portrait-show-prompt')));
    await tester.pump();

    expect(find.text('生图 Prompt'), findsOneWidget);
    expect(
      find.textContaining('a 28-year-old female 瑜伽教练'),
      findsOneWidget,
    );
    // 没点过生成时要讲清这不是真实发出的请求。
    expect(find.textContaining('本地模板拼装的预览'), findsOneWidget);

    await tester.tap(find.widgetWithText(TextButton, '关闭'));
    await tester.pump();
  });

  testWidgets('未知性别的角色拼 Prompt 不得谎报成女性', (tester) async {
    // `_draftCharacter()` 曾只带 gender 不带 hasKnownGender，落到构造默认
    // `true`；而 initState 对 hasKnownGender=false 的角色特意把 _selectedGender
    // 置 null，于是 `?? CharacterGender.female` 把未知性别硬编码成女性。保存
    // 路径由 provider 从库里回填，测试看不出来 —— 只有草稿这条线能锁住。
    final saved = character(
      gender: CharacterGender.female,
      hasKnownGender: false,
    );
    await tester.runAsync(() => db.aiCharacterBox.put(saved.id, saved));

    await tester.pumpWidget(app(AICharacterFormPage(character: saved)));
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('ip-portrait-show-prompt')));
    await tester.pump();

    // 年龄保留、性别词整个省略（_subjectClause 对 hasKnownGender=false 的降级）。
    expect(find.textContaining('a 28-year-old 瑜伽教练'), findsOneWidget);
    expect(find.textContaining('female'), findsNothing);
    expect(find.textContaining('male'), findsNothing);

    await tester.tap(find.widgetWithText(TextButton, '关闭'));
    await tester.pump();
  });

  testWidgets('草稿带全 apiConfigId / voiceId，LLM 外观改写不再静默失效',
      (tester) async {
    // 这两项曾被 _draftCharacter() 漏带：拼 prompt 用的是草稿，于是
    // _describeVisual 看到空 apiConfigId 直接返回 null，外观改写 100% 静默
    // 走本地模板，音色线索也不出现 —— 出图全是头发却无从排查。
    final saved = character(voiceId: 'zh_female_gaolengyujie_moon_bigtts');
    await tester.runAsync(() => db.aiCharacterBox.put(saved.id, saved));

    await tester.pumpWidget(app(AICharacterFormPage(character: saved)));
    await tester.pump();

    expect(
      find.byKey(const ValueKey('ip-portrait-rewrite-source')),
      findsOneWidget,
    );
    expect(find.textContaining('由聊天模型「测试配置」改写'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('ip-portrait-show-prompt')));
    await tester.pump();

    expect(
      find.textContaining('Voice temperament hint: "高冷御姐"'),
      findsOneWidget,
    );
    await tester.tap(find.widgetWithText(TextButton, '关闭'));
    await tester.pump();
  });

  testWidgets('未绑定聊天模型时，面板明确标注走本地模板', (tester) async {
    // 回落本身不是错，静默才是。要让用户看得见自己没吃到 LLM 改写。
    final saved = character(apiConfigId: '');
    await tester.runAsync(() => db.aiCharacterBox.put(saved.id, saved));

    await tester.pumpWidget(app(AICharacterFormPage(character: saved)));
    await tester.pump();

    expect(find.textContaining('本地模板（未绑定聊天模型）'), findsOneWidget);
  });

  testWidgets('画风下拉改选后随保存落库，重进表单能还原', (tester) async {
    final saved = character(ipImageStyle: 'watercolor');
    await tester.runAsync(() => db.aiCharacterBox.put(saved.id, saved));

    await tester.pumpWidget(app(AICharacterFormPage(character: saved)));
    await tester.pump();
    // 收起状态下下拉显示的就是选中项（DropdownButtonFormField 不暴露 value）。
    expect(find.text('水彩'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('ip-portrait-style')));
    await tester.pump();
    await tester.tap(find.text('水墨').last);
    await tester.pump();

    await tester.runAsync(() async {
      await tester.tap(find.text('更新').first);
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pump(const Duration(milliseconds: 300));

    expect(db.aiCharacterBox.get(saved.id)!.ipImageStyle, 'ink');
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump(const Duration(seconds: 4));
  });

  testWidgets('保存会带上 IP 形象字段（withGender 重建不清空）', (tester) async {
    // 用不存在的相对路径：解析层返回 null 回落文本头像，避开 testWidgets
    // FakeAsync 里 FileImage 真实解码卡死；字段往返本身不受影响。
    final saved = character(
      ipImageRelPath: 'character-1/missing.png',
      avatarFromIpImage: true,
      ipImageStyle: 'watercolor',
    );
    await tester.runAsync(() => db.aiCharacterBox.put(saved.id, saved));

    await tester.pumpWidget(app(AICharacterFormPage(character: saved)));
    await tester.pump();

    expect(find.text('取消头像'), findsOneWidget);

    await tester.runAsync(() async {
      await tester.tap(find.text('更新').first);
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pump(const Duration(milliseconds: 300));

    final reloaded = db.aiCharacterBox.get(saved.id)!;
    expect(reloaded.ipImageRelPath, 'character-1/missing.png');
    expect(reloaded.avatarFromIpImage, isTrue);
    expect(reloaded.ipImageStyle, 'watercolor');
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump(const Duration(seconds: 4));
  });

  testWidgets('取消头像后保存只关开关、不动形象路径', (tester) async {
    final saved = character(
      ipImageRelPath: 'character-1/missing.png',
      avatarFromIpImage: true,
    );
    await tester.runAsync(() => db.aiCharacterBox.put(saved.id, saved));

    await tester.pumpWidget(app(AICharacterFormPage(character: saved)));
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('ip-portrait-toggle-avatar')));
    await tester.pump();
    expect(find.text('设为头像'), findsOneWidget);

    await tester.runAsync(() async {
      await tester.tap(find.text('更新').first);
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pump(const Duration(milliseconds: 300));

    final reloaded = db.aiCharacterBox.get(saved.id)!;
    expect(reloaded.ipImageRelPath, 'character-1/missing.png');
    expect(reloaded.avatarFromIpImage, isFalse);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump(const Duration(seconds: 4));
  });

  test('withGender 重建对象时保留 IP 形象字段', () {
    final source = character(
      ipImageRelPath: 'character-1/ip.png',
      avatarFromIpImage: true,
      ipImageStyle: 'ink',
    );

    final rebuilt = source.withGender(CharacterGender.male);

    expect(rebuilt.ipImageRelPath, 'character-1/ip.png');
    expect(rebuilt.avatarFromIpImage, isTrue);
    expect(rebuilt.ipImageStyle, 'ink');
    // 顺带守住 voiceId 同类事故的回归。
    expect(rebuilt.voiceId, source.voiceId);
  });
}
