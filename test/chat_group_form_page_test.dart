import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/widgets/required_fields_banner.dart';
import 'package:chat_group/features/ai_character/providers/ai_character_providers.dart';
import 'package:chat_group/features/chat_group/chat_group_form_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  /// 直接覆写页面实际读取的成员列表 provider，绕开 Hive 与
  /// `AICharactersNotifier` 的异步装载：本组用例只验「点创建之后报什么」，
  /// 让列表在首帧就位才能把注意力留在提示条上。
  Widget app({List<AICharacter> characters = const []}) => ProviderScope(
        overrides: [
          userManagedAICharactersProvider.overrideWithValue(characters),
        ],
        child: const MaterialApp(home: ChatGroupFormPage()),
      );

  AICharacter character({required String id, required String name}) =>
      AICharacter(
        id: id,
        name: name,
        avatar: name.characters.first,
        age: 25,
        role: '测试角色',
        personalityTags: const [],
        systemPrompt: '',
        apiKey: '',
        apiProvider: 'custom',
      );

  /// 表单很长，成员勾选框在首屏之外；放大视口避免"点了但没点到"。
  void useTallViewport(WidgetTester tester) {
    tester.view.physicalSize = const Size(800, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  testWidgets('打开表单时不预先报错，点创建后才点名缺什么', (tester) async {
    await tester.pumpWidget(app());
    await tester.pump();

    expect(tester.getSize(find.byType(RequiredFieldsBanner)).height, 0);

    await tester.tap(find.text('创建').first);
    await tester.pump();

    expect(find.text('请先填写：群聊名称、主题、选择角色'), findsOneWidget);
  });

  testWidgets('缺项清单随填写实时收敛，补齐后提示自动消失', (tester) async {
    useTallViewport(tester);
    await tester.pumpWidget(
      app(characters: [character(id: 'c1', name: '小林')]),
    );
    await tester.pump();

    await tester.tap(find.text('创建').first);
    await tester.pump();
    expect(find.text('请先填写：群聊名称、主题、选择角色'), findsOneWidget);

    await tester.enterText(find.byType(TextFormField).at(0), '外卖小分队');
    await tester.pump();
    expect(find.text('请先填写：主题、选择角色'), findsOneWidget);

    await tester.enterText(find.byType(TextFormField).at(1), '今天吃什么');
    await tester.pump();
    expect(find.text('请先填写：选择角色'), findsOneWidget);

    await tester.tap(find.byType(CheckboxListTile).first);
    await tester.pump();
    expect(tester.getSize(find.byType(RequiredFieldsBanner)).height, 0);

    // 「提示消失不等于表单被顶掉」必须用页面自身断言：`find.text('创建群聊')`
    // 同时命中顶栏标题和底部按钮，写成 findsWidgets 永远为真，等于没断言。
    expect(find.byType(ChatGroupFormPage), findsOneWidget);
  });

  testWidgets('纯空格的名称与主题不算填过，顶栏与字段级红字同时报', (tester) async {
    // 顶栏清单与 validator 曾经各写一份判据（一个 trim、一个不 trim），空格名称
    // 就会变成"顶栏报缺、字段没红字"，而保存时又会 trim 成空串落库。
    await tester.pumpWidget(app());
    await tester.pump();

    await tester.enterText(find.byType(TextFormField).at(0), '   ');
    await tester.enterText(find.byType(TextFormField).at(1), '  ');
    await tester.tap(find.text('创建').first);
    await tester.pump();

    expect(find.text('请先填写：群聊名称、主题、选择角色'), findsOneWidget);
    expect(find.text('请输入群聊名称'), findsOneWidget);
    expect(find.text('请输入群聊主题'), findsOneWidget);
  });

  testWidgets('提示条钉在顶栏下方，表单滚动它不动', (tester) async {
    // 这一条锁的才是用户要的效果（固定在顶栏下方、不随表单滚动）。只断言
    // `find.text` 存在是不够的——把提示条挪进 ListView 末尾，在长视口下用例
    // 照样绿。
    await tester.pumpWidget(app());
    await tester.pump();
    await tester.tap(find.text('创建').first);
    await tester.pump();

    final banner = find.byType(RequiredFieldsBanner);
    final bannerTop = tester.getRect(banner).top;
    final nameTop = tester.getRect(find.byType(TextFormField).first).top;

    expect(banner.hitTestable(), findsOneWidget);
    expect(bannerTop, lessThan(nameTop));

    await tester.drag(find.byType(ListView), const Offset(0, -200));
    await tester.pump();

    expect(tester.getRect(banner).top, bannerTop);
    expect(tester.getRect(find.byType(TextFormField).first).top,
        lessThan(nameTop));
  });
}
