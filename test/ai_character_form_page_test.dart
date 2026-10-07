import 'dart:async';
import 'dart:io';

import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/api_config.dart';
import 'package:chat_group/core/models/character_presets.dart';
import 'package:chat_group/core/models/tool_permission.dart';
import 'package:chat_group/features/ai_character/ai_character_form_page.dart';
import 'package:chat_group/features/ai_character/providers/ai_character_providers.dart';
import 'package:chat_group/features/ai_character/widgets/ip_portrait_panel.dart';
import 'package:chat_group/core/widgets/top_toast.dart';
import 'package:chat_group/providers/providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/async_pump.dart';
import 'helpers/lifecycle_hive.dart';

/// 把指定角色的保存永久挂起，用来在测试里固定住「保存进行中」这一瞬：
/// 真实 Hive 写盘在假时钟下既跑不完也收不了尾（见 CLAUDE.md 的 `runAsync` 规则），
/// 换成永不完成的 Future 就既不需要真实区、也不会给 tearDown 留下待写记录。
class _StallingSaveCharactersNotifier extends AICharactersNotifier {
  _StallingSaveCharactersNotifier(super.db, this.stallingIds);

  final Set<String> stallingIds;

  @override
  Future<void> updateCharacter(AICharacter character) {
    if (stallingIds.contains(character.id)) return Completer<void>().future;
    return super.updateCharacter(character);
  }
}

void main() {
  late Directory hiveDirectory;
  late DatabaseService db;
  late ProviderContainer providerContainer;
  final stallingSaveIds = <String>{};

  setUp(() async {
    hiveDirectory = await openLifecycleHive();
    db = DatabaseService();
    stallingSaveIds.clear();
    providerContainer = ProviderContainer(
      overrides: [
        databaseServiceProvider.overrideWithValue(db),
        aiCharactersProvider.overrideWith(
          (ref) => _StallingSaveCharactersNotifier(
            ref.read(databaseServiceProvider),
            stallingSaveIds,
          ),
        ),
      ],
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

  /// 从宿主页 push 表单页，使「返回」真的是一次出栈 —— 直接用
  /// `MaterialApp(home: page)` 时表单是根路由，pop 掉之后没有任何页面可留，
  /// 「有没有退出」无从断言。
  Future<void> pumpFormPage(
      WidgetTester tester, AICharacterFormPage page) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: providerContainer,
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => page),
                  ),
                  child: const Text('打开'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
  }

  /// 等「聚焦输入框触发的自动回滚」跑完，再点同一 ListView 里的其它控件。
  ///
  /// 表单 body 是 ListView，`ensureVisible` 把列表滚到底部后名字字段会被顶出
  /// 视口；此时 `enterText` 聚焦它会启动一次回滚动画（DrivenScrollActivity，
  /// `shouldIgnorePointer == true`），动画期间 Scrollable 外层的 IgnorePointer
  /// 吞掉列表内全部命中 —— 紧接着的 `tap` 看似点在控件上，实则被吞掉，
  /// 后续「找不到弹出菜单项」的报错会误导人以为是 finder 写错。
  /// 两帧足够：第一帧让 postFrame 回调把动画启动，第二帧把它推到底。
  Future<void> settleFocusScroll(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
  }

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

  testWidgets('role can opt into keyless web search', (tester) async {
    tester.view.physicalSize = const Size(800, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(app(const AICharacterFormPage()));
    await tester.ensureVisible(find.text('允许联网搜索'));
    await tester.tap(find.text('允许联网搜索'));
    await tester.pump();

    await tester.enterText(find.byType(TextFormField).at(0), '搜索角色');
    await tester.enterText(find.byType(TextFormField).at(2), '研究员');
    await settleFocusScroll(tester);
    await tester.tap(find.byType(DropdownButtonFormField<CharacterGender>));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('女'));
    await tester.pump();
    await tester.runAsync(() async {
      await tester.tap(find.text('创建').first);
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pump(const Duration(milliseconds: 300));

    expect(db.aiCharacterBox.values.single.webSearchEnabled, isTrue);
  });

  testWidgets('role can disable proactive private messages', (tester) async {
    tester.view.physicalSize = const Size(800, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(app(const AICharacterFormPage()));
    await tester.ensureVisible(find.text('允许主动聊天'));
    expect(
      tester
          .widget<SwitchListTile>(
            find.widgetWithText(SwitchListTile, '允许主动聊天'),
          )
          .value,
      isTrue,
    );
    await tester.tap(find.text('允许主动聊天'));
    await tester.pump();

    await tester.enterText(find.byType(TextFormField).at(0), '安静角色');
    await tester.enterText(find.byType(TextFormField).at(2), '研究员');
    await settleFocusScroll(tester);
    await tester.tap(find.byType(DropdownButtonFormField<CharacterGender>));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('女'));
    await tester.pump();
    await tester.runAsync(() async {
      await tester.tap(find.text('创建').first);
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pump(const Duration(milliseconds: 300));

    expect(db.aiCharacterBox.values.single.proactiveChatEnabled, isFalse);
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

  testWidgets('必填项没填齐时禁用生成，并点名缺什么', (tester) async {
    // 空草稿曾能直接生成，拼出 `an AI companion.` 这种没有姓名/职业的空壳
    // prompt，还照样扣一次生图费。按钮置灰的同时必须说清缺哪几项。
    await tester.pumpWidget(app(const AICharacterFormPage()));
    await tester.pump();

    final generate = tester.widget<FilledButton>(
      find.byKey(const ValueKey('ip-portrait-generate')),
    );
    expect(generate.onPressed, isNull);
    expect(find.text('请先填写：名字、性别、角色'), findsOneWidget);
  });

  testWidgets('必填项填齐后生成按钮启用，提示换回参考说明', (tester) async {
    await tester.pumpWidget(app(const AICharacterFormPage()));
    await tester.pump();

    await tester.enterText(find.byType(TextFormField).at(0), '阿杰');
    await tester.pump();
    await tester.enterText(find.byType(TextFormField).at(2), '工程师');
    await tester.pump();
    await tester.tap(find.byType(DropdownButtonFormField<CharacterGender>));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('男'));
    await tester.pump();

    final generate = tester.widget<FilledButton>(
      find.byKey(const ValueKey('ip-portrait-generate')),
    );
    expect(generate.onPressed, isNotNull);
    expect(find.text('请先填写：名字、性别、角色'), findsNothing);
    expect(find.textContaining('提炼长相'), findsOneWidget);
  });

  testWidgets('面板滚出视口后不被卸载，生成状态得以存活', (tester) async {
    // 表单 body 是 ListView，面板随滚动被 collectGarbage 卸载时，后台的生成
    // 其实已跑完并写盘，只是 mounted 变假导致 _tracker.adopt() 被跳过 —— 用户
    // 看到的正是「滚回来生成就停了」。保活是这条链的解药，本例锁住它：去掉
    // mixin 后 State 会被重建，实例标识一变测试立刻红。
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(app(const AICharacterFormPage()));
    await tester.pump();

    final before = tester.state<IpPortraitPanelState>(
      find.byType(IpPortraitPanel),
    );

    await tester.drag(find.byType(ListView), const Offset(0, -4000));
    await tester.pumpAndSettle();
    await tester.drag(find.byType(ListView), const Offset(0, 4000));
    await tester.pumpAndSettle();

    final after = tester.state<IpPortraitPanelState>(
      find.byType(IpPortraitPanel),
    );
    expect(identical(before, after), isTrue);
  });

  testWidgets('草稿带全 apiConfigId / voiceId，LLM 外观改写不再静默失效', (tester) async {
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

  group('未保存返回确认', () {
    testWidgets('编辑角色没改动时直接退出，不弹确认框', (tester) async {
      final saved = character();
      await tester.runAsync(() => db.aiCharacterBox.put(saved.id, saved));

      await pumpFormPage(tester, AICharacterFormPage(character: saved));
      expect(find.text('编辑角色'), findsOneWidget);

      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();

      expect(find.text('资料尚未保存'), findsNothing);
      expect(find.text('编辑角色'), findsNothing);
    });

    testWidgets('新建角色没改动时直接退出，不弹确认框', (tester) async {
      // 新建态在 initState 里会预选 ApiConfig、填默认工具权限，这些都不是
      // 「用户改了什么」——基线取错位置会让这里立刻弹框。
      await pumpFormPage(tester, const AICharacterFormPage());

      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();

      expect(find.text('资料尚未保存'), findsNothing);
      expect(find.text('创建 AI 角色'), findsNothing);
    });

    testWidgets('预设快速创建没改动时直接退出，不弹确认框', (tester) async {
      await pumpFormPage(
        tester,
        AICharacterFormPage(preset: CharacterPreset.presets.first),
      );

      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();

      expect(find.text('资料尚未保存'), findsNothing);
      expect(find.text('创建 AI 角色'), findsNothing);
    });

    testWidgets('保存进行中按返回不弹确认框', (tester) async {
      // 保存的续体会自己出栈；此时再弹确认框，保存成功后的
      // `Navigator.pop(context, character)` 会先命中栈顶的确认框，拿角色对象去
      // complete `_UnsavedExitAction?` 的 completer 直接抛类型错误。
      final saved = character();
      await tester.runAsync(() => db.aiCharacterBox.put(saved.id, saved));

      await pumpFormPage(tester, AICharacterFormPage(character: saved));
      await tester.enterText(find.byType(TextFormField).at(0), '小萌');
      await tester.pump();

      // 让这次保存卡在 `await updateCharacter` 上：`_isSaving` 保持 true。
      stallingSaveIds.add(saved.id);
      await tester.tap(find.text('更新').first);
      await tester.pump();
      expect(find.text('编辑角色'), findsOneWidget);

      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();

      expect(find.text('资料尚未保存'), findsNothing);
      expect(find.text('编辑角色'), findsOneWidget);
      expect(db.aiCharacterBox.get(saved.id)!.name, 'Amy');
    });

    testWidgets('确认框点遮罩取消后留在本页，且返回键仍然可用', (tester) async {
      final saved = character();
      await tester.runAsync(() => db.aiCharacterBox.put(saved.id, saved));

      await pumpFormPage(tester, AICharacterFormPage(character: saved));
      await tester.enterText(find.byType(TextFormField).at(0), '小萌');
      await tester.pump();

      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.text('资料尚未保存'), findsOneWidget);

      // 点对话框之外（遮罩）取消这次返回。
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();

      expect(find.text('资料尚未保存'), findsNothing);
      expect(find.text('编辑角色'), findsOneWidget);

      // 重入防护必须已放行，否则返回键会永久失效。
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.text('资料尚未保存'), findsOneWidget);
      expect(db.aiCharacterBox.get(saved.id)!.name, 'Amy');
    });

    testWidgets('改过资料后返回弹确认框，选放弃保存则不落库', (tester) async {
      final saved = character();
      await tester.runAsync(() => db.aiCharacterBox.put(saved.id, saved));

      await pumpFormPage(tester, AICharacterFormPage(character: saved));
      await tester.enterText(find.byType(TextFormField).at(0), '小萌');
      await tester.pump();

      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();

      expect(find.text('资料尚未保存'), findsOneWidget);
      expect(find.text('放弃保存'), findsOneWidget);
      expect(find.text('保存并返回'), findsOneWidget);

      await tester.tap(find.text('放弃保存'));
      await tester.pumpAndSettle();

      expect(find.text('编辑角色'), findsNothing);
      expect(db.aiCharacterBox.get(saved.id)!.name, 'Amy');
    });

    testWidgets('确认框选保存并返回会落库并退出', (tester) async {
      final saved = character();
      await tester.runAsync(() => db.aiCharacterBox.put(saved.id, saved));

      await pumpFormPage(tester, AICharacterFormPage(character: saved));
      await tester.enterText(find.byType(TextFormField).at(0), '小萌');
      await tester.pump();

      // 「返回」的点击必须放进 runAsync：确认框是 [_handleBack] 弹的，谁弹的
      // 决定 `showDialog` 的 future 属于哪个 zone，也就决定了随后 [_save] 跑在
      // 哪个 zone。若落在 fake 区，`box.put` 也在 fake 区发起，Hive 内部落盘
      // 回调依赖假时钟 —— 测试体全部通过，tearDown 的 `Hive.close()` 却会一直
      // 等它而挂死。放进真实区后，保存链路与既有用例里点「更新」完全同路。
      await tester.runAsync(
        () => tester.tap(find.byType(BackButton)),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存并返回'));

      // 点下按钮后要同时满足两件事，缺一不可，所以轮询条件而不是猜时长：
      //   1. [_save] 的续体是真实区的微任务，只在 runAsync 窗口里推进；
      //   2. 确认框退场与出栈动画只吃 fake 时钟，得靠带时长的 pump 推进。
      for (var i = 0; i < 40; i++) {
        if (find.text('编辑角色').evaluate().isEmpty) break;
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 25)),
        );
        await tester.pump(const Duration(milliseconds: 100));
      }

      expect(db.aiCharacterBox.get(saved.id)!.name, '小萌');
      expect(find.text('编辑角色'), findsNothing);
    });

    testWidgets('只切换「设为头像」也算未保存修改', (tester) async {
      // 头像是 IP 形象面板单向上报的草稿态，不经过任何 TextField。
      final saved = character(ipImageRelPath: 'character-1/missing.png');
      await tester.runAsync(() => db.aiCharacterBox.put(saved.id, saved));

      await pumpFormPage(tester, AICharacterFormPage(character: saved));
      await tester.tap(find.byKey(const ValueKey('ip-portrait-toggle-avatar')));
      await tester.pump();

      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();

      expect(find.text('资料尚未保存'), findsOneWidget);
    });

    testWidgets('只改画风也算未保存修改', (tester) async {
      final saved = character(ipImageStyle: 'watercolor');
      await tester.runAsync(() => db.aiCharacterBox.put(saved.id, saved));

      await pumpFormPage(tester, AICharacterFormPage(character: saved));
      await tester.tap(find.byKey(const ValueKey('ip-portrait-style')));
      await tester.pump();
      await tester.tap(find.text('水墨').last);
      await tester.pump();

      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();

      expect(find.text('资料尚未保存'), findsOneWidget);
    });

    testWidgets('改了又改回原值后返回不再弹确认框', (tester) async {
      final saved = character();
      await tester.runAsync(() => db.aiCharacterBox.put(saved.id, saved));

      await pumpFormPage(tester, AICharacterFormPage(character: saved));
      await tester.enterText(find.byType(TextFormField).at(0), '小萌');
      await tester.pump();
      await tester.enterText(find.byType(TextFormField).at(0), 'Amy');
      await tester.pump();

      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();

      expect(find.text('资料尚未保存'), findsNothing);
      expect(find.text('编辑角色'), findsNothing);
    });
  });
}
