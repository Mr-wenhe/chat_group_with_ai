import 'dart:async';
import 'dart:io';

import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/models/agent_task.dart';
import 'package:chat_group/core/models/api_config.dart';
import 'package:chat_group/core/models/api_protocol.dart';
import 'package:chat_group/core/models/api_provider.dart';
import 'package:chat_group/core/models/chat_group.dart';
import 'package:chat_group/core/storage/api_credential_resolver.dart';
import 'package:chat_group/core/storage/credential_repository.dart';
import 'package:chat_group/core/streaming/chat_stream_event.dart';
import 'package:chat_group/features/chat_group/chat_room_page.dart';
import 'package:chat_group/features/settings/ai_speaker_picker_settings.dart';
import 'package:chat_group/features/work_mode/work_task_coordinator.dart';
import 'package:chat_group/features/work_mode/work_task_event_store.dart';
import 'package:chat_group/providers/providers.dart';
import 'package:chat_group/services/chat_api_service.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

import 'lifecycle_hive.dart';

/// 「空闲自动聊天真的跑起来」的一组假区夹具。
///
/// 这些用例关心的都不是模型写了什么，而是**什么时候允许发起调用**：选人还在
/// 等待时关掉自动发言、离开本群、预算被硬拒、队列里压着用户输入——所以请求
/// 计数就是断言。
///
/// **一个文件只放一条会真正跑起回合的 widget 用例**。回合里的用量记账会在假
/// 时钟区发起 Hive 写，同一个进程里再跑第二条会让 box 的写队列卡住（仓库已知
/// 的假区 Hive 行为，见 `chat_room_speaker_visibility_test.dart`）。下面的
/// `pumpRoundRoom` 也刻意把宿主与假模型都放在这里，让每条用例只剩自己的断言。
class ScriptedChatApi extends ChatApiService {
  final List<List<Map<String, dynamic>>> pickerCalls = [];
  final List<List<Map<String, dynamic>>> replyCalls = [];
  final List<String> pickerModels = [];

  /// 选人器返回的正文；默认表示"这一轮到此为止"。
  String pickerResponse = '{"speakerId":null}';

  /// 非空时，下一次选人等到这个 Completer 完成才返回（用来制造"正在选人"）。
  Completer<Map<String, dynamic>>? pendingPicker;

  /// 为 true 时，每次流式回复先吐一段增量再挂起，直到 [releaseHeldReply]。
  ///
  /// 用来把回合停在"已经开始流式输出但还没收尾"的位置——那一段既没有可取消的
  /// 选择器令牌，也没有可复检的 await，只有停流与结果判定能拦住它。
  bool holdReplies = false;

  /// 是否已经有一条被扣住的流式回复吐出了第一段（说明流真的开始了）。
  bool replyStreaming = false;

  Completer<void>? _heldReply;

  void releaseHeldReply() {
    final pending = _heldReply;
    _heldReply = null;
    if (pending != null && !pending.isCompleted) pending.complete();
  }

  /// 最近一次选人请求的取消令牌，用来确认打断真的取消了它。
  CancelToken? pickerCancelToken;

  /// 让下一次选人一直悬着，从外部控制它何时完成。
  Completer<Map<String, dynamic>> holdNextPicker() {
    final pending = Completer<Map<String, dynamic>>();
    pendingPicker = pending;
    return pending;
  }

  @override
  Future<Map<String, dynamic>> sendChatMessageWithResponseLimit({
    required String apiKey,
    required ApiProvider provider,
    ApiProtocol apiProtocol = ApiProtocol.defaultValue,
    String? customBaseUrl,
    required String model,
    required List<Map<String, dynamic>> messages,
    double temperature = 0.85,
    int maxTokens = 1024,
    Duration? receiveTimeout,
    int maxRetries = 5,
    CancelToken? cancelToken,
    bool structuredJson = false,
    // 替身只回一个固定的合法正文，没有需要 `reasoning_content` 兜底的空内容场景。
    bool allowReasoningContentFallback = false,
    required int maxResponseBytes,
  }) async {
    pickerCalls.add(messages);
    pickerModels.add(model);
    pickerCancelToken = cancelToken;
    final pending = pendingPicker;
    if (pending != null) {
      pendingPicker = null;
      return pending.future;
    }
    return {'success': true, 'message': pickerResponse};
  }

  @override
  Stream<ChatStreamEvent> streamChatMessage({
    required String apiKey,
    required ApiProvider provider,
    ApiProtocol apiProtocol = ApiProtocol.defaultValue,
    String? customBaseUrl,
    required String model,
    required List<Map<String, dynamic>> messages,
    double temperature = 0.85,
    int maxTokens = 1024,
    Duration receiveTimeout = const Duration(seconds: 120),
    CancelToken? cancelToken,
  }) async* {
    replyCalls.add(messages);
    if (holdReplies) {
      final pending = Completer<void>();
      _heldReply = pending;
      replyStreaming = true;
      yield ChatStreamEvent.token('第一段');
      await pending.future;
    }
    yield ChatStreamEvent.done('测试回复');
  }
}

class NoopTaskRunner implements WorkTaskRunner {
  @override
  Future<void> run(AgentTask task, WorkTaskCancellation cancellation) async {}
}

class StaticCredentialResolver implements ApiCredentialResolver {
  @override
  Future<String?> resolve(ApiConfig config) async =>
      config.hasCredential ? 'test-key' : null;
}

/// 可悬停的凭据解析器：只扣住**角色**用的那份配置，选人器照常放行。
///
/// 用来把回合停在"选人已完成、角色请求还没发出"的准备阶段——那一段既没有 stream
/// 也没有选择器取消令牌，是可见性闸门与回合代际号唯一能拦住的地方。
class HeldCredentialResolver implements ApiCredentialResolver {
  HeldCredentialResolver({required this.heldConfigId});

  final String heldConfigId;
  final Completer<void> _gate = Completer<void>();

  /// 角色的凭据解析是否已经开始等在闸门上。
  bool reached = false;

  void release() {
    if (!_gate.isCompleted) _gate.complete();
  }

  @override
  Future<String?> resolve(ApiConfig config) async {
    if (config.id == heldConfigId && !_gate.isCompleted) {
      reached = true;
      await _gate.future;
    }
    return config.hasCredential ? 'test-key' : null;
  }
}

/// 推进假时钟直到回合真的走到角色凭据解析那一步。
Future<void> waitForHeldCredential(
  WidgetTester tester,
  HeldCredentialResolver resolver,
) async {
  for (var step = 0; step < 80 && !resolver.reached; step++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }
  expect(resolver.reached, isTrue, reason: '回合没有走到角色凭据解析那一步');
}

class RoundRoomHost extends StatefulWidget {
  const RoundRoomHost({
    super.key,
    required this.groupId,
    required this.chatApi,
    this.credentialResolver,
  });

  final String groupId;
  final ChatApiService chatApi;
  final ApiCredentialResolver? credentialResolver;

  @override
  State<RoundRoomHost> createState() => RoundRoomHostState();
}

class RoundRoomHostState extends State<RoundRoomHost> {
  /// 推一个全屏页面盖住群聊：它会关掉群页面的 ticker，等价于用户切走。
  void pushCover() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Center(child: Text('另一个页面'))),
      ),
    );
  }

  void popCover() => Navigator.of(context).pop();

  @override
  Widget build(BuildContext context) => ChatRoomPage(
        groupId: widget.groupId,
        chatApi: widget.chatApi,
        credentialResolver:
            widget.credentialResolver ?? StaticCredentialResolver(),
      );
}

const MethodChannel _ttsChannel = MethodChannel('flutter_tts');

/// dispose 时会停掉 TTS；测试替身环境没有平台实现，不打桩会在收尾阶段抛
/// MissingPluginException 并让整轮跑失败。
void installTtsChannelMock() {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_ttsChannel, (call) async => 1);
}

void removeTtsChannelMock() {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_ttsChannel, null);
}

/// 网关的用量账本是独立的 append-only box，生产里由 `DatabaseService.init`
/// 打开；这里按同一个名字预开，免得第一次记账落到真实的 `Hive.openBox` 上。
Future<void> openGovernanceLedgerBox() =>
    Hive.openBox<dynamic>(DatabaseService.aiGovernanceLedgerBoxName)
        .then((_) {});

/// 收尾：刻意**不**调用 `Hive.close()`。
///
/// 回合里发起的 Hive 写有一部分留在测试的假时钟上，`close()` 会一直等它们而
/// 永久挂起（仓库已知的假区 Hive 行为）。临时目录直接删掉即可。
Future<void> tearDownRoundFixture(Directory directory) async {
  removeTtsChannelMock();
  CredentialRepository.clearCache();
  try {
    if (await directory.exists()) await directory.delete(recursive: true);
  } on Object {
    // 清理失败不影响用例结论。
  }
}

ApiConfig roundTestConfig(String id, {String model = 'deepseek-chat'}) =>
    ApiConfig(
      id: id,
      name: '配置$id',
      provider: 'deepseek',
      modelName: model,
      credentialId: 'credential.$id',
      hasCredential: true,
    );

/// 两个可发言的角色 + 一个专供选人器使用的配置。
Future<void> seedRoundRoom(
  WidgetTester tester,
  DatabaseService db,
  String groupId, {
  int intervalSeconds = 5,
  String characterModel = 'deepseek-chat',
}) async {
  await tester.runAsync(() async {
    await db.apiConfigBox.putAll({
      'cfg-a': roundTestConfig('cfg-a', model: characterModel),
      'cfg-b': roundTestConfig('cfg-b', model: characterModel),
      // 选人器用**另一个**配置：它与各角色自己的发言配置互不影响。
      'cfg-picker': roundTestConfig('cfg-picker', model: 'picker-model'),
    });
    await db.aiCharacterBox.putAll({
      'va': testCharacter('va', apiConfigId: 'cfg-a')..name = '甲',
      'vb': testCharacter('vb', apiConfigId: 'cfg-b')..name = '乙',
    });
    await db.chatGroupBox.put(
      groupId,
      ChatGroup(
        id: groupId,
        name: '选人回合测试群',
        theme: '日常聊天',
        aiCharacterIds: const ['va', 'vb'],
        replyIntervalSeconds: intervalSeconds,
      ),
    );
    await AiSpeakerPickerSettings(db).select('cfg-picker');
  });
}

Future<void> pumpRoundRoom(
  WidgetTester tester, {
  required GlobalKey<RoundRoomHostState> hostKey,
  required String groupId,
  required ChatApiService api,
  required DatabaseService db,
  required Directory directory,
  ApiCredentialResolver? credentialResolver,
}) async {
  await tester.runAsync(() async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseServiceProvider.overrideWithValue(db),
          workTaskCoordinatorProvider.overrideWith((ref) {
            final events = WorkTaskEventStore(appSupportDirectory: directory);
            final coordinator = WorkTaskCoordinator(
              taskBox: db.agentTaskBox,
              eventStore: events,
              runner: NoopTaskRunner(),
            );
            ref.onDispose(() {
              unawaited(coordinator.dispose().then((_) => events.close()));
            });
            return coordinator;
          }),
        ],
        child: MaterialApp(
          home: RoundRoomHost(
            key: hostKey,
            groupId: groupId,
            chatApi: api,
            credentialResolver: credentialResolver,
          ),
        ),
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 60));
  });
  await tester.pump(const Duration(milliseconds: 100));
  await pumpUntilRoomLoaded(tester);
}

Future<void> pumpUntilRoomLoaded(WidgetTester tester) async {
  final textField = find.byType(TextField);
  for (var attempt = 0;
      attempt < 80 && textField.evaluate().isEmpty;
      attempt++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 20));
  }
  expect(textField, findsOneWidget);
}

/// 交替推进假时钟并放行真实 I/O。
///
/// 回合计发起 Hive 写（用量记账、消息落盘等），这类写只有真实事件循环才能
/// 完成；只 `pump` 会让它们永远悬着。
Future<void> drainRound(WidgetTester tester, {int rounds = 12}) async {
  for (var round = 0; round < rounds; round++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> disposeRoundRoom(WidgetTester tester) async {
  await drainRound(tester);
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
  await drainRound(tester);
}

/// 结束用例体之前，把本轮挂着的假区计时器走完。
///
/// flutter_test 在**用例体结束时**就会检查挂起的计时器（早于 tearDown），而这类
/// 用例天生带着两种长计时器：选人请求自己的 15 秒时限，以及每条回复后面那段
/// "打字延迟"。推进超过这两者的假时间两种情形都覆盖——请求已落地则时限计时器
/// 随即取消，始终没落地就让它超时收场，都不会把挂起的计时器留给收尾。
///
/// 并发跑整轮测试时，固定轮数的 `drainRound` 会因为每轮放行的真实 I/O 被拉长而
/// 不够用，所以这里按**假时间**推进，每步只让出一小段真实时间。
Future<void> settleRoundTimers(WidgetTester tester) async {
  for (var round = 0; round < 20; round++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(seconds: 1));
  }
}

/// 让空闲自动聊天在**假时钟区**重新开始调度。
///
/// 房间首次加载时创建的启动计时器可能落在 `pumpRoundRoom` 的真实时钟上，那样
/// `pump(Duration)` 推不动它。把开关关掉再打开会从测试体（假区）调用
/// `_startAutoChat`，计时器因此回到可被 pump 推进的假时钟上。
Future<void> restartAutoChatScheduler(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('auto-chat-toggle')));
  await tester.pump();
  await tester.tap(find.byKey(const Key('auto-chat-toggle')));
  await tester.pump();
}

/// 推进假时钟直到角色流式调用真的发出去。
///
/// 有界轮询而不是固定轮数：`drainRound` 的每一轮都要放行真实 I/O（Hive 落盘），
/// 整轮测试并发跑时这些真实等待会被拉长，固定 30 轮不够会让断言早于请求到达。
Future<void> waitForReply(WidgetTester tester, ScriptedChatApi api) async {
  for (var step = 0; step < 160 && api.replyCalls.isEmpty; step++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> toggleAutoChatOff(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('auto-chat-toggle')));
  await tester.pump();
}

/// 推进假时钟直到空闲自动聊天真的发起了一次选人请求。
///
/// 刻意不走 `handleAppLifecycleStateChanged`：在 flutter_test 的假区里，暂停
/// 之后任何按**时长**推进的 pump 都可能同步卡死整轮（框架侧行为，`--timeout`
/// 也不生效）。"进后台"与"被别的页面盖住"走的是同一个闸门
/// （`_refreshRoomActivity` 把 `_pageActive`、`_routeVisible`、`_appForeground`
/// 合流成 `_roomWorkAllowed`），所以本组用例统一用"盖住"来驱动它。
Future<void> waitForPicker(WidgetTester tester, ScriptedChatApi api) async {
  for (var step = 0; step < 60 && api.pickerCalls.isEmpty; step++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(seconds: 2));
  }
  expect(api.pickerCalls, hasLength(1));
  expect(
    api.pickerModels.toSet(),
    {'picker-model'},
    reason: '选人器必须使用全局设置里选中的那个配置',
  );
}
