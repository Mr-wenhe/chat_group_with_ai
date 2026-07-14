import 'dart:io';

import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/api_config.dart';
import 'package:chat_group/core/models/api_provider.dart';
import 'package:chat_group/core/models/chat_group.dart';
import 'package:chat_group/core/models/media_attachment.dart';
import 'package:chat_group/core/models/message.dart';
import 'package:chat_group/core/models/tool_permission.dart';
import 'package:chat_group/features/direct_chat/direct_chat_proactive_service.dart';
import 'package:chat_group/services/chat_api_service.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

/// 用内存版 ChatApiService 验证「主动 DM 走统一每小时发言预算」：
/// 达到上限时跳过（不调模型、不伪造发送），未达上限时正常发送并记用。
class FakeChatApiService extends ChatApiService {
  int sendCount = 0;

  @override
  Future<Map<String, dynamic>> sendChatMessage({
    required String apiKey,
    required ApiProvider provider,
    String? customBaseUrl,
    required String model,
    required List<Map<String, dynamic>> messages,
    double? temperature,
    int? maxTokens,
    Duration? receiveTimeout,
    int? maxRetries,
    CancelToken? cancelToken,
  }) async {
    sendCount++;
    // 不返回 token 计数，避免触发 DatabaseService 的延迟 flush timer，
    // 否则测试结束 Hive 关闭后定时器回调会访问已关闭的 box。
    return {'success': true, 'message': '主动私聊内容'};
  }
}

void main() {
  late Directory tempDir;
  late DatabaseService db;
  late FakeChatApiService chatApi;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('proactive_hive_');
    Hive.init(tempDir.path);
    if (!Hive.isAdapterRegistered(0)) Hive.registerAdapter(AICharacterAdapter());
    if (!Hive.isAdapterRegistered(4)) Hive.registerAdapter(ApiConfigAdapter());
    if (!Hive.isAdapterRegistered(1)) Hive.registerAdapter(ChatGroupAdapter());
    if (!Hive.isAdapterRegistered(2)) Hive.registerAdapter(MessageAdapter());
    if (!Hive.isAdapterRegistered(9)) {
      Hive.registerAdapter(MediaAttachmentAdapter());
    }
    // AICharacter 内嵌 List<ToolPermission>（默认含 skillCreate/skillDownload），
    // 写入 aiCharacterBox 需该适配器，与 DatabaseService.init() 保持一致。
    if (!Hive.isAdapterRegistered(10)) {
      Hive.registerAdapter(ToolPermissionAdapter());
    }
    await Hive.openBox<AICharacter>('ai_characters');
    await Hive.openBox<ApiConfig>('api_configs');
    await Hive.openBox<ChatGroup>('chat_groups');
    await Hive.openBox<Message>('messages');
    await Hive.openBox<dynamic>('app_settings');
    db = DatabaseService();
    chatApi = FakeChatApiService();
  });

  tearDown(() async {
    await Hive.close();
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  AICharacter _seedCharacter({required bool atHourlyLimit}) {
    final config = ApiConfig(
      id: 'cfg-1',
      name: 'cfg',
      provider: 'deepseek',
      apiKey: 'sk-test',
    );
    db.apiConfigBox.put(config.id, config);
    final character = AICharacter(
      id: 'char-1',
      name: '小夏',
      avatar: '',
      age: 20,
      role: '朋友',
      personalityTags: const [],
      systemPrompt: '你是小夏',
      apiKey: '',
      apiProvider: 'deepseek',
      apiConfigId: 'cfg-1',
      hourlyReplyLimit: 5,
      hourlyReplyCount: atHourlyLimit ? 5 : 0,
      lastReplyTimestamp: atHourlyLimit ? DateTime.now() : null,
      isActive: true,
    );
    db.aiCharacterBox.put(character.id, character);
    return character;
  }

  test('达到每小时上限时跳过主动 DM（不调用模型、不伪造发送）', () async {
    _seedCharacter(atHourlyLimit: true);
    final service = DirectChatProactiveService(db: db, chatApi: chatApi);

    final result = await service.tryCreateProactiveMessage();

    // 跳过：不生成消息、不调用模型、不记用。
    expect(result, isNull);
    expect(chatApi.sendCount, 0);
    expect(db.aiCharacterBox.get('char-1')!.hourlyReplyCount, 5);
  });

  test('未达上限时正常发送并记用（与聊天共用同一套每小时预算）', () async {
    _seedCharacter(atHourlyLimit: false);
    final service = DirectChatProactiveService(db: db, chatApi: chatApi);

    final result = await service.tryCreateProactiveMessage();

    expect(result, isNotNull);
    expect(result!.message.content, '主动私聊内容');
    expect(chatApi.sendCount, 1);
    // 统一记用：发送后每小时计数 +1，并记录时间戳。
    expect(db.aiCharacterBox.get('char-1')!.hourlyReplyCount, 1);
    expect(db.aiCharacterBox.get('char-1')!.lastReplyTimestamp, isNotNull);
  });
}
