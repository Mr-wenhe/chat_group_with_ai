import 'dart:io';

import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/models/api_config.dart';
import 'package:chat_group/core/models/api_protocol.dart';
import 'package:chat_group/core/models/api_provider.dart';
import 'package:chat_group/core/models/chat_group.dart';
import 'package:chat_group/core/storage/api_credential_resolver.dart';
import 'package:chat_group/core/storage/credential_repository.dart';
import 'package:chat_group/core/streaming/chat_stream_event.dart';
import 'package:chat_group/features/chat_group/chat_room_page.dart';
import 'package:chat_group/features/settings/ai_speaker_picker_settings.dart';
import 'package:chat_group/providers/providers.dart';
import 'package:chat_group/services/chat_api_service.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

import 'helpers/lifecycle_hive.dart';

/// 记录各类请求的假模型，用来回答"什么时候会调用模型"。
class _ScriptedChatApi extends ChatApiService {
  final List<List<Map<String, dynamic>>> pickerCalls = [];
  final List<List<Map<String, dynamic>>> replyCalls = [];

  /// 每次调用的 model 参数：用来确认选人器用的是全局选中的那个配置。
  final List<String> pickerModels = [];

  /// 选人器返回的正文；默认表示"这一轮到此为止"。
  String pickerResponse = '{"speakerId":null}';

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
    yield ChatStreamEvent.done('测试回复');
  }
}

class _StaticCredentialResolver implements ApiCredentialResolver {
  @override
  Future<String?> resolve(ApiConfig config) async =>
      config.hasCredential ? 'test-key' : null;
}

class _RoomHost extends StatefulWidget {
  const _RoomHost({super.key, required this.groupId, required this.chatApi});

  final String groupId;
  final ChatApiService chatApi;

  @override
  State<_RoomHost> createState() => _RoomHostState();
}

class _RoomHostState extends State<_RoomHost> {
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
        credentialResolver: _StaticCredentialResolver(),
      );
}

void main() {
  late Directory directory;
  late DatabaseService db;
  const ttsChannel = MethodChannel('flutter_tts');

  setUpAll(() async {
    // 房间 dispose 时会停掉 TTS；测试替身环境没有平台实现，不打桩会在清理
    // 阶段抛 MissingPluginException 并让整轮跑的收尾失败。
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(ttsChannel, (call) async => 1);
    directory = await openLifecycleHive();
    db = DatabaseService();
    // 网关的用量账本是独立的 append-only box。生产里由 DatabaseService.init
    // 打开；这里按同一个名字预开，免得第一次记账落进真实 Hive.openBox 上。
    await Hive.openBox<dynamic>(DatabaseService.aiGovernanceLedgerBoxName);
  });

  setUp(() async {
    await db.aiCharacterBox.clear();
    await db.chatGroupBox.clear();
    await db.messageBox.clear();
    await db.apiConfigBox.clear();
    await db.messageBox.clear();
    await Hive.box<dynamic>(DatabaseService.aiGovernanceLedgerBoxName).clear();
  });

  tearDownAll(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(ttsChannel, null);
    // 刻意不调用 `Hive.close()`：这条用例让回合真正跑起来了，途中发起的 Hive
    // 写有一部分留在测试的假时钟上，`close()` 会一直等它们而永久挂起
    //（仓库已知的假区 Hive 行为）。临时目录直接删掉即可。
    CredentialRepository.clearCache();
    try {
      if (await directory.exists()) await directory.delete(recursive: true);
    } on Object {
      // 清理失败不影响用例结论。
    }
  });

  ApiConfig config(String id, {String model = 'char-model'}) => ApiConfig(
        id: id,
        name: '配置$id',
        provider: 'deepseek',
        modelName: model,
        credentialId: 'credential.$id',
        hasCredential: true,
      );

  /// 交替推进假时钟并放行真实 I/O。
  ///
  /// 被测代码会在回合里写 Hive（用量记账等），这类写只有真实事件循环才能完成；
  /// 只 `pump` 会让它们永远悬着并最终卡住 `Hive.close()`。
  Future<void> advance(WidgetTester tester, Duration total) async {
    const step = Duration(seconds: 2);
    var elapsed = Duration.zero;
    while (elapsed < total) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(step);
      elapsed += step;
    }
  }

  Future<void> pumpUntilLoaded(WidgetTester tester) async {
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

  /// 两个「只做搜索答复」的角色。
  ///
  /// 这类角色在空闲自动聊天里不会产生真实回复（见 `_generateAiReply` 的早退
  /// 分支），所以这条用例观察的是"选人器有没有被调用"，不必等待消息落库。
  Future<void> seedRoom(
    WidgetTester tester,
    String groupId, {
    int intervalSeconds = 60,
  }) async {
    await tester.runAsync(() async {
      await db.apiConfigBox.putAll({
        'cfg-a': config('cfg-a'),
        'cfg-b': config('cfg-b'),
        // 选人器用**另一个**配置：它和角色各自的发言配置互不影响。
        'cfg-picker': config('cfg-picker', model: 'picker-model'),
      });
      await db.aiCharacterBox.putAll({
        'va': testCharacter('va', apiConfigId: 'cfg-a')
          ..name = '搜索甲'
          ..zhipuSearchAnswerOnly = true,
        'vb': testCharacter('vb', apiConfigId: 'cfg-b')
          ..name = '搜索乙'
          ..zhipuSearchAnswerOnly = true,
      });
      await db.chatGroupBox.put(
        groupId,
        ChatGroup(
          id: groupId,
          name: '可见性测试群',
          theme: '日常聊天',
          aiCharacterIds: const ['va', 'vb'],
          replyIntervalSeconds: intervalSeconds,
        ),
      );
      await AiSpeakerPickerSettings(db).select('cfg-picker');
    });
  }

  Future<void> pumpRoom(
    WidgetTester tester, {
    required GlobalKey<_RoomHostState> hostKey,
    required String groupId,
    required ChatApiService api,
  }) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [databaseServiceProvider.overrideWithValue(db)],
          child: MaterialApp(
            home: _RoomHost(key: hostKey, groupId: groupId, chatApi: api),
          ),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 60));
    });
    await tester.pump(const Duration(milliseconds: 100));
    await pumpUntilLoaded(tester);
  }

  /// 交替推进假时钟并放行真实 I/O。
  ///
  /// 回合里会写 Hive（用量记账等），这类写只有真实事件循环才能完成；只 `pump`
  /// 会让它们永远悬着，最终卡住 `tearDownAll` 的 `Hive.close()`。
  Future<void> drain(WidgetTester tester, {int rounds = 12}) async {
    for (var round = 0; round < rounds; round++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<void> disposeRoom(WidgetTester tester) async {
    await drain(tester);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await drain(tester);
  }

  testWidgets('被另一个页面盖住时不发起选人调用，回到本群后才恢复调度', (tester) async {
    addTearDown(() => disposeRoom(tester));
    await seedRoom(tester, 'g-vis');

    final api = _ScriptedChatApi();
    final hostKey = GlobalKey<_RoomHostState>();
    await pumpRoom(tester, hostKey: hostKey, groupId: 'g-vis', api: api);

    // 盖住本页：必须立刻停下，且遮挡期间不得积累计时器。
    hostKey.currentState!.pushCover();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('另一个页面'), findsOneWidget);
    await advance(tester, const Duration(seconds: 180));
    expect(api.pickerCalls, isEmpty, reason: '旧群被别的页面盖住时不得发起选人调用');
    expect(api.replyCalls, isEmpty);

    // 回到前台但旧群仍被别的页面盖住：不得因为"App 回到前台"就恢复调度。
    final binding = tester.binding;
    binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await advance(tester, const Duration(seconds: 180));
    expect(api.pickerCalls, isEmpty, reason: '旧群仍被路由遮挡时，回到前台也不得恢复调度');

    // 回到当前群：只恢复一个调度器，初始间隔是群配置（60 秒）+ 抖动。
    hostKey.currentState!.popCover();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    await advance(tester, const Duration(seconds: 180));
    expect(api.pickerCalls, isNotEmpty, reason: '回到当前群后应恢复自动聊天调度');
    // 选人器走的是全局设置里选中的那个配置，而不是任何一位角色自己的配置。
    expect(
      api.pickerModels.toSet(),
      {'picker-model'},
      reason: '选人器必须使用全局设置里选中的那个配置',
    );
  });
}
