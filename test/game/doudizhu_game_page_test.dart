import 'dart:async';
import 'dart:io';

import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/database/database_service_provider.dart';
import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/api_config.dart';
import 'package:chat_group/features/ai_character/providers/ai_character_providers.dart';
import 'package:chat_group/features/game/doudizhu/doudizhu_ai_player.dart';
import 'package:chat_group/features/game/doudizhu/doudizhu_game_director.dart';
import 'package:chat_group/features/game/doudizhu/doudizhu_game_page.dart';
import 'package:chat_group/features/game/doudizhu/doudizhu_game_providers.dart';
import 'package:chat_group/features/game/doudizhu/doudizhu_game_state.dart';
import 'package:chat_group/features/game/doudizhu/doudizhu_hard_engine.dart';
import 'package:chat_group/features/game/doudizhu/doudizhu_rules.dart';
import 'package:chat_group/features/game/doudizhu/doudizhu_table_view.dart';
import 'package:chat_group/features/game/doudizhu/doudizhu_table_widgets.dart';
import 'package:chat_group/features/game/game_lobby_page.dart';
import 'package:chat_group/providers/providers.dart';
import 'package:dio/dio.dart' show CancelToken;
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/lifecycle_hive.dart';

AICharacter _character(String name) => AICharacter(
      name: name,
      avatar: name.substring(0, 1),
      age: 24,
      role: '牌手',
      personalityTags: const [],
      systemPrompt: '角色人设',
      apiKey: '',
      apiProvider: 'custom',
    );

class _FirstLegalSelector implements DoudizhuHardMoveSelector {
  int calls = 0;

  @override
  Future<DoudizhuHardDecision?> decide(
    DoudizhuAiTurnInput input, {
    CancelToken? cancelToken,
  }) async {
    calls++;
    if (cancelToken?.isCancelled == true) return null;
    final option = input.options.firstWhere(
      (item) => item.action is DoudizhuPlayAction,
    );
    return DoudizhuHardDecision(
      action: option.action,
      elapsedMilliseconds: 1,
      candidateCount: input.options.length,
      handsBefore: input.ownHand.length,
      handsAfter: input.ownHand.length - option.cardIds.length,
      score: 0,
    );
  }
}

class _DeferredSelector implements DoudizhuHardMoveSelector {
  final requests = <_DeferredRequest>[];

  @override
  Future<DoudizhuHardDecision?> decide(
    DoudizhuAiTurnInput input, {
    CancelToken? cancelToken,
  }) {
    final request = _DeferredRequest(input: input, cancelToken: cancelToken);
    requests.add(request);
    return request.result.future;
  }

  void complete(int index) {
    final request = requests[index];
    final option = request.input.options.firstWhere(
      (item) => item.action is DoudizhuPlayAction,
    );
    request.result.complete(
      DoudizhuHardDecision(
        action: option.action,
        elapsedMilliseconds: 1,
        candidateCount: request.input.options.length,
        handsBefore: request.input.ownHand.length,
        handsAfter: request.input.ownHand.length - option.cardIds.length,
        score: 0,
      ),
    );
  }
}

class _DeferredRequest {
  _DeferredRequest({required this.input, required this.cancelToken});

  final DoudizhuAiTurnInput input;
  final CancelToken? cancelToken;
  final result = Completer<DoudizhuHardDecision?>();
}

Future<void> _openLobby(
  WidgetTester tester,
  DatabaseService database,
  DoudizhuHardMoveSelector selector, {
  List<AICharacter>? characters,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        databaseServiceProvider.overrideWithValue(database),
        userManagedAICharactersProvider.overrideWith(
          (ref) =>
              characters ??
              [_character('白果'), _character('黑豆'), _character('青梅')],
        ),
        doudizhuApiConfigsProvider.overrideWith((ref) => const <ApiConfig>[]),
        doudizhuHardMoveEngineProvider.overrideWith((ref) => selector),
        doudizhuMoveSpacingProvider.overrideWith((ref) => Duration.zero),
        doudizhuTransitionSpacingProvider.overrideWith((ref) => Duration.zero),
        doudizhuSeedProvider.overrideWith((ref) => 12345),
      ],
      child: const MaterialApp(home: GameLobbyPage()),
    ),
  );
  await tester.pumpAndSettle();
  expect(find.text('3 款'), findsOneWidget);
  await tester.ensureVisible(find.text('斗地主'));
  await tester.tap(find.text('斗地主'));
  await tester.pumpAndSettle();
  expect(find.byType(DoudizhuGamePage), findsOneWidget);
  expect(
    find.byKey(const ValueKey<String>('doudizhu-role-model-status-0')),
    findsOneWidget,
  );
  expect(find.textContaining('未绑定可用模型或凭据'), findsWidgets);
}

Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() condition, {
  int maxFrames = 60,
}) async {
  for (var frame = 0; frame < maxFrames; frame++) {
    if (condition()) return;
    await tester.pump(const Duration(milliseconds: 20));
  }
  expect(condition(), isTrue, reason: '条件应在有限帧内满足');
}

Future<void> _completeLobbyMatch(
  WidgetTester tester, {
  required DatabaseService database,
  required bool includeHuman,
  DoudizhuHardMoveSelector? selector,
  bool waitForRealAsync = false,
  bool verifyFullHistory = false,
}) async {
  await _openLobby(tester, database, selector ?? _FirstLegalSelector());
  if (includeHuman) {
    await tester.tap(find.text('真人参与'));
    await tester.pumpAndSettle();
  }
  await tester.tap(find.text('开始发牌'));
  await tester.pumpAndSettle();

  var finished = false;
  DoudizhuTableSnapshot? finalSnapshot;
  DoudizhuTableSnapshot? observedSnapshot;
  for (var frame = 0; frame < 2500; frame++) {
    if (waitForRealAsync) {
      await tester.runAsync<void>(
        () => Future<void>.delayed(const Duration(milliseconds: 2)),
      );
    }
    await tester.pump(const Duration(milliseconds: 20));
    final table = tester.widget<DoudizhuTableView>(
      find.byType(DoudizhuTableView),
    );
    final snapshot = table.snapshot;
    observedSnapshot = snapshot;
    if (snapshot.status == DoudizhuMatchStatus.finished) {
      finished = true;
      finalSnapshot = snapshot;
      break;
    }
    if (snapshot.status == DoudizhuMatchStatus.error) break;
    if (!includeHuman || !snapshot.isHumanTurn) continue;

    if (snapshot.phase == DoudizhuPhase.bidding) {
      await tester.ensureVisible(find.text('3 分'));
      await tester.tap(find.text('3 分'));
      await tester.pump();
      continue;
    }

    final human = snapshot.seats.singleWhere((seat) => seat.isHuman);
    final hand = human.visibleHand!;
    int? playable;
    for (final cardId in hand) {
      final validation = DoudizhuRules.validatePlay(
        hand: hand,
        cardIds: [cardId],
        lastPlay: snapshot.trick?.move,
      );
      if (validation.isValid) {
        playable = cardId;
        break;
      }
    }
    if (playable == null) {
      expect(snapshot.trick, isNotNull);
      final passButton = find.byKey(
        const ValueKey<String>('doudizhu-pass'),
      );
      await tester.ensureVisible(passButton);
      await tester.tap(passButton);
    } else {
      final card = find.byKey(ValueKey<int>(playable));
      await tester.ensureVisible(card);
      await tester.pump();
      await tester.tap(card);
      await tester.pump();
      final playButton = find.byKey(
        const ValueKey<String>('doudizhu-play'),
      );
      await tester.ensureVisible(playButton);
      await tester.pump();
      await tester.tap(playButton);
    }
    await tester.pump();
  }

  expect(
    finished,
    isTrue,
    reason:
        '大厅对局应在有界帧数内结束；状态：${observedSnapshot?.status}，阶段：${observedSnapshot?.phase}，副数：${observedSnapshot?.dealNumber}，提示：${observedSnapshot?.statusMessage}',
  );
  expect(
    finalSnapshot!.seats.fold<int>(
          0,
          (sum, seat) => sum + seat.handSize,
        ) +
        finalSnapshot.playedCounts.fold<int>(0, (sum, count) => sum + count),
    54,
  );
  if (verifyFullHistory) {
    expect(finalSnapshot.events.length, greaterThan(8));
    expect(find.textContaining('兜底原因：'), findsWidgets);
    final firstEvent = finalSnapshot.events.first;
    final fullLogButton = find.byKey(
      const ValueKey<String>('doudizhu-show-full-log'),
    );
    await tester.ensureVisible(fullLogButton);
    await tester.tap(fullLogButton);
    await tester.pumpAndSettle();
    expect(
      find.text('完整牌桌记录 · ${finalSnapshot.events.length} 条'),
      findsOneWidget,
    );
    expect(find.text(firstEvent.message), findsOneWidget);
    expect(find.text('叫分策略'), findsWidgets);
    expect(find.text('宗师直连'), findsWidgets);
    expect(find.textContaining('候选'), findsWidgets);
  }
}

void main() {
  late Directory directory;
  late DatabaseService database;

  setUpAll(() async {
    directory = await openLifecycleHive();
    database = DatabaseService();
  });

  tearDownAll(() => closeLifecycleHive(directory, database));

  testWidgets('大厅斗地主入口打开原生牌桌并显示开局模式', (tester) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.view.physicalSize = const Size(430, 900);
    tester.view.devicePixelRatio = 1;
    final engine = _FirstLegalSelector();
    await _openLobby(tester, database, engine);
    expect(find.text('斗地主'), findsOneWidget);
    expect(find.text('上帝视角'), findsOneWidget);
    expect(find.text('真人参与'), findsOneWidget);
    expect(find.text('开始发牌'), findsOneWidget);
  });

  testWidgets('桌面宽屏显示绿毡牌桌和独立信息侧栏', (tester) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.view.physicalSize = const Size(1440, 1000);
    tester.view.devicePixelRatio = 1;
    await _openLobby(tester, database, _FirstLegalSelector());
    await tester.tap(find.text('真人参与'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('开始发牌'));
    await tester.pump();

    expect(find.byType(DoudizhuTableView), findsOneWidget);
    expect(find.text('公开牌桌动态'), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('doudizhu-card-counter')),
        findsOneWidget);
    expect(find.text('宗师兜底引擎'), findsNothing);
    expect(find.textContaining('当前桌面'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('860 逻辑宽窗口把第一视角手牌 / 按钮 / 记牌器嵌进绿桌', (tester) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    // 本机桌面窗口约 860 逻辑像素宽（截图 1726px @2x）。旧的内嵌门槛是
    // 1050，在此永远不命中，手牌被挤到绿桌外面、真人座位卡还在桌上——
    // 这是"还是不对"的根因，此用例锁住该回归。
    tester.view.physicalSize = const Size(860, 820);
    tester.view.devicePixelRatio = 1;
    await _openLobby(tester, database, _FirstLegalSelector());
    await tester.tap(find.text('真人参与'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('开始发牌'));
    await tester.pump();

    expect(find.byKey(const ValueKey<String>('doudizhu-card-counter')),
        findsOneWidget);
    // 真人座位卡移除，桌上只剩两个 AI 对手。
    expect(find.byType(DoudizhuSeatCard), findsNWidgets(2));

    final tableBottom = tester.getBottomLeft(find.byType(DoudizhuFeltTable)).dy;
    final handCenter = tester.getCenter(find.textContaining('你的手牌'));
    final counterCenter = tester.getCenter(
      find.byKey(const ValueKey<String>('doudizhu-card-counter')),
    );
    // 手牌在绿桌内部（不是桌外下方），记牌器在手牌上方。
    expect(handCenter.dy, lessThan(tableBottom));
    expect(counterCenter.dy, lessThan(handCenter.dy));
    expect(tester.takeException(), isNull);
  });

  testWidgets('上帝视角不显示冗余记牌器', (tester) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.view.physicalSize = const Size(430, 900);
    tester.view.devicePixelRatio = 1;
    await _openLobby(tester, database, _FirstLegalSelector());
    await tester.tap(find.text('开始发牌'));
    await tester.pumpAndSettle();

    expect(find.byType(DoudizhuTableView), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('doudizhu-card-counter')),
        findsNothing);
  });

  testWidgets('真人记牌器按自己手牌与已出牌计算外面各点数', (tester) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.view.physicalSize = const Size(430, 900);
    tester.view.devicePixelRatio = 1;
    await _openLobby(tester, database, _FirstLegalSelector());
    await tester.tap(find.text('真人参与'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('开始发牌'));
    await tester.pumpAndSettle();

    final table = tester.widget<DoudizhuTableView>(
      find.byType(DoudizhuTableView),
    );
    final ownHand =
        table.snapshot.seats.singleWhere((seat) => seat.isHuman).visibleHand!;
    final threeCount = ownHand.where((card) => card ~/ 4 == 0).length;
    final expectedOutsideThrees =
        doudizhuTotalOfRank[0] - table.snapshot.playedCounts[0] - threeCount;
    // 记牌器是常驻的一行横条，无需点标题展开；直接滚动到横条容器即可。
    final counterScroll = find.byKey(
      const PageStorageKey<String>('doudizhu-counter-grid-scroll'),
    );
    await tester.ensureVisible(counterScroll);
    await tester.pumpAndSettle();

    expect(counterScroll, findsOneWidget);
    final threeCell =
        find.byKey(const ValueKey<String>('doudizhu-counter-rank-0'));
    expect(threeCell, findsOneWidget);
    // 格子里上排是点数名、下排是剩余张数，两行分开渲染，所以按"该格内的
    // 数字文本"断言，避免和其他格子里的同名数字混淆。
    expect(
      find.descendant(
        of: threeCell,
        matching: find.text('$expectedOutsideThrees'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('AI 角色席位不重复，选择已占用角色时交换席位', (tester) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.view.physicalSize = const Size(430, 900);
    tester.view.devicePixelRatio = 1;
    await _openLobby(tester, database, _FirstLegalSelector());

    await tester.tap(
      find.byKey(const ValueKey<String>('doudizhu-role-picker-1')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('白果').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('doudizhu-start')));
    await tester.pump();

    final seats = tester
        .widget<DoudizhuTableView>(find.byType(DoudizhuTableView))
        .snapshot
        .seats;
    expect(seats.map((seat) => seat.name).toList(), ['黑豆', '白果', '青梅']);
  });

  testWidgets('不同角色数量不足时禁止开始对局', (tester) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.view.physicalSize = const Size(430, 900);
    tester.view.devicePixelRatio = 1;
    await _openLobby(
      tester,
      database,
      _FirstLegalSelector(),
      characters: [_character('白果')],
    );

    expect(find.textContaining('此模式需要 3 个'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const ValueKey<String>('doudizhu-start')),
          )
          .onPressed,
      isNull,
    );
  });

  testWidgets('三个角色从大厅通过真实宗师引擎完成整局并可查看完整记录', (tester) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.view.physicalSize = const Size(430, 900);
    tester.view.devicePixelRatio = 1;
    await _completeLobbyMatch(
      tester,
      database: database,
      includeHuman: false,
      selector: const DoudizhuHardEngine(),
      waitForRealAsync: true,
      verifyFullHistory: true,
    );
  });

  testWidgets('从大厅完成真人与两个 AI 的整局', (tester) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.view.physicalSize = const Size(430, 900);
    tester.view.devicePixelRatio = 1;
    await _completeLobbyMatch(
      tester,
      database: database,
      includeHuman: true,
    );
  });

  testWidgets('真人席位可选牌、取消、拒绝非法组合、出牌和过牌', (tester) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.view.physicalSize = const Size(430, 900);
    tester.view.devicePixelRatio = 1;
    final engine = _FirstLegalSelector();
    await _openLobby(tester, database, engine);
    await tester.tap(find.text('真人参与'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('开始发牌'));
    await tester.pumpAndSettle();

    var table =
        tester.widget<DoudizhuTableView>(find.byType(DoudizhuTableView));
    expect(table.snapshot.isHumanTurn, isTrue);
    expect(table.snapshot.bottomCards, isNull);
    await tester.ensureVisible(find.text('3 分'));
    await tester.tap(find.text('3 分'));
    await tester.pumpAndSettle();

    table = tester.widget<DoudizhuTableView>(find.byType(DoudizhuTableView));
    expect(table.snapshot.phase, DoudizhuPhase.playing);
    expect(table.snapshot.bottomCards, isNotNull);
    expect(table.snapshot.seats[1].visibleHand, isNull);
    expect(table.snapshot.seats[2].visibleHand, isNull);
    final ownHand = table.snapshot.seats[0].visibleHand!;
    final playButton = find.byKey(const ValueKey<String>('doudizhu-play'));

    final hintButton = find.byKey(const ValueKey<String>('doudizhu-hint'));
    await tester.ensureVisible(hintButton);
    await tester.tap(hintButton);
    await tester.pump();
    table = tester.widget<DoudizhuTableView>(find.byType(DoudizhuTableView));
    expect(table.selectedCardIds, isNotEmpty);
    expect(
      DoudizhuRules.validatePlay(
        hand: ownHand,
        cardIds: table.selectedCardIds.toList(),
        lastPlay: null,
      ).isValid,
      isTrue,
    );
    await tester.tap(find.byKey(const ValueKey<String>('doudizhu-clear')));
    await tester.pump();

    final dragCards = ownHand.take(3).toList();
    for (final card in dragCards) {
      await tester.ensureVisible(find.byKey(ValueKey<int>(card)));
    }
    await tester.pumpAndSettle();
    final touchDrag = await tester.startGesture(
      tester.getCenter(find.byKey(ValueKey<int>(dragCards.first))),
    );
    await touchDrag.moveTo(
      tester.getCenter(find.byKey(ValueKey<int>(dragCards[1]))),
    );
    await tester.pump();
    await touchDrag.up();
    await tester.pumpAndSettle();
    table = tester.widget<DoudizhuTableView>(find.byType(DoudizhuTableView));
    expect(table.selectedCardIds, isEmpty);

    final drag = await tester.startGesture(
      tester.getCenter(find.byKey(ValueKey<int>(dragCards.first))),
      kind: PointerDeviceKind.mouse,
    );
    for (final card in dragCards.skip(1)) {
      await drag.moveTo(tester.getCenter(find.byKey(ValueKey<int>(card))));
      await tester.pump();
    }
    await drag.up();
    await tester.pumpAndSettle();
    table = tester.widget<DoudizhuTableView>(find.byType(DoudizhuTableView));
    expect(table.selectedCardIds, containsAll(dragCards));

    final deselectDrag = await tester.startGesture(
      tester.getCenter(find.byKey(ValueKey<int>(dragCards.first))),
      kind: PointerDeviceKind.mouse,
    );
    for (final card in dragCards.skip(1)) {
      await deselectDrag.moveTo(
        tester.getCenter(find.byKey(ValueKey<int>(card))),
      );
      await tester.pump();
    }
    await deselectDrag.up();
    await tester.pumpAndSettle();
    table = tester.widget<DoudizhuTableView>(find.byType(DoudizhuTableView));
    expect(table.selectedCardIds, isEmpty);
    await tester.tap(find.byKey(const ValueKey<String>('doudizhu-clear')));
    await tester.pump();

    await tester.ensureVisible(find.byKey(ValueKey<int>(ownHand.last)));
    await tester.tap(find.byKey(ValueKey<int>(ownHand.last)));
    await tester.pump();
    expect(tester.widget<FilledButton>(playButton).onPressed, isNotNull);
    await tester.ensureVisible(find.byKey(ValueKey<int>(ownHand.last)));
    await tester.tap(find.byKey(ValueKey<int>(ownHand.last)));
    await tester.pump();
    expect(tester.widget<FilledButton>(playButton).onPressed, isNull);

    final firstRank = ownHand.first ~/ 4;
    final illegalPair = [
      ownHand.first,
      ownHand.firstWhere((card) => card ~/ 4 != firstRank),
    ];
    for (final card in illegalPair) {
      await tester.ensureVisible(find.byKey(ValueKey<int>(card)));
      await tester.tap(find.byKey(ValueKey<int>(card)));
      await tester.pump();
    }
    expect(tester.widget<FilledButton>(playButton).onPressed, isNotNull);
    await tester.tap(playButton);
    await tester.pump();
    expect(find.text('不构成合法牌型'), findsOneWidget);
    table = tester.widget<DoudizhuTableView>(find.byType(DoudizhuTableView));
    expect(table.snapshot.seats[0].handSize, 20);

    for (final card in illegalPair) {
      await tester.ensureVisible(find.byKey(ValueKey<int>(card)));
      await tester.tap(find.byKey(ValueKey<int>(card)));
      await tester.pump();
    }
    await tester.ensureVisible(find.byKey(ValueKey<int>(ownHand.last)));
    await tester.tap(find.byKey(ValueKey<int>(ownHand.last)));
    await tester.pump();
    await tester.tap(playButton);
    await tester.pumpAndSettle();
    await _pumpUntil(tester, () {
      final current = tester.widget<DoudizhuTableView>(
        find.byType(DoudizhuTableView),
      );
      return current.snapshot.isHumanTurn && current.snapshot.trick != null;
    });
    table = tester.widget<DoudizhuTableView>(find.byType(DoudizhuTableView));
    expect(table.snapshot.seats[0].handSize, 19);
    expect(table.snapshot.trick, isNotNull);
    expect(
      find.byKey(ValueKey<String>(
        'doudizhu-played-action-${table.snapshot.trick!.seat}',
      )),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey<String>('doudizhu-table-center')),
        matching: find.byWidgetPredicate((widget) => widget is Wrap),
      ),
      findsNothing,
    );
    expect(
        tester
            .widget<OutlinedButton>(
              find.byKey(const ValueKey<String>('doudizhu-pass')),
            )
            .onPressed,
        isNotNull);

    final passButton = find.byKey(
      const ValueKey<String>('doudizhu-pass'),
    );
    await tester.ensureVisible(passButton);
    await tester.tap(passButton);
    await tester.pumpAndSettle();
    table = tester.widget<DoudizhuTableView>(find.byType(DoudizhuTableView));
    expect(
        table.snapshot.events.any((event) => event.message == '你 不出'), isTrue);
    await tester.tap(find.byTooltip('停止对局'));
    await tester.pump();
    expect(find.textContaining('对局已停止'), findsOneWidget);
    await tester.tap(find.byTooltip('重新发牌'));
    await tester.pumpAndSettle();
    table = tester.widget<DoudizhuTableView>(find.byType(DoudizhuTableView));
    expect(table.snapshot.phase, isNot(DoudizhuPhase.over));
    expect(table.snapshot.dealNumber, 1);
    await tester.tap(find.byTooltip('停止对局'));
    await tester.pump();
  });

  testWidgets('切入后台不暂停牌局，用户停止仍取消旧模型回合', (tester) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.view.physicalSize = const Size(430, 900);
    tester.view.devicePixelRatio = 1;
    final engine = _DeferredSelector();
    await _openLobby(tester, database, engine);
    await tester.tap(find.text('开始发牌'));
    await tester.pumpAndSettle();
    await _pumpUntil(tester, () => engine.requests.isNotEmpty);
    final firstToken = engine.requests[0].cancelToken!;

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    expect(firstToken.isCancelled, isFalse);
    var table =
        tester.widget<DoudizhuTableView>(find.byType(DoudizhuTableView));
    expect(table.snapshot.status, DoudizhuMatchStatus.playing);
    expect(find.textContaining('应用已暂停'), findsNothing);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await tester.tap(find.byTooltip('停止对局'));
    await tester.pump();
    expect(firstToken.isCancelled, isTrue);
    engine.complete(0);
    await tester.pump();
    table = tester.widget<DoudizhuTableView>(find.byType(DoudizhuTableView));
    expect(table.snapshot.playedCounts.reduce((a, b) => a + b), 0);
    expect(table.snapshot.status, DoudizhuMatchStatus.stopped);

    await tester.tap(find.byTooltip('重新发牌'));
    await tester.pumpAndSettle();
    table = tester.widget<DoudizhuTableView>(find.byType(DoudizhuTableView));
    expect(table.snapshot.status, DoudizhuMatchStatus.playing);
    expect(table.snapshot.dealNumber, 1);
    expect(table.snapshot.playedCounts.reduce((a, b) => a + b), 0);
    await tester.tap(find.byTooltip('停止对局'));
    await tester.pump();
  });

  testWidgets('离开牌桌会取消宗师请求并忽略迟到结果', (tester) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.view.physicalSize = const Size(430, 900);
    tester.view.devicePixelRatio = 1;
    final engine = _DeferredSelector();
    await _openLobby(tester, database, engine);
    await tester.tap(find.text('开始发牌'));
    await tester.pumpAndSettle();
    await _pumpUntil(tester, () => engine.requests.isNotEmpty);
    final token = engine.requests.first.cancelToken!;

    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(token.isCancelled, isTrue);
    engine.complete(0);
    await tester.pump();
    expect(find.byType(DoudizhuGamePage), findsNothing);
    expect(find.byType(GameLobbyPage), findsOneWidget);
  });
}
