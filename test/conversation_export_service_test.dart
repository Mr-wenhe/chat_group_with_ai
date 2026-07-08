import 'dart:convert';
import 'dart:io';

import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/chat_group.dart';
import 'package:chat_group/core/models/message.dart';
import 'package:chat_group/services/conversation_export_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// 故意写入密钥，用于验证导出内容「绝不泄露」。
AICharacter _mkChar(String id, String name, String role) => AICharacter(
      id: id,
      name: name,
      avatar: name[0],
      age: 30,
      role: role,
      personalityTags: ['a', 'b'],
      systemPrompt: 'sys',
      apiKey: 'sk-TOPSECRET-$id',
      apiProvider: 'deepseek',
      apiConfigId: 'cfg-$id',
    );

Message _mkMsg(String id, String senderId, String senderType, String content,
        DateTime ts) =>
    Message(
      groupId: 'g1',
      id: id,
      senderId: senderId,
      senderType: senderType,
      content: content,
      timestamp: ts,
    );

void main() {
  final chatGroup =
      ChatGroup(name: '测试群', theme: '主题A', aiCharacterIds: ['c1']);
  final c1 = _mkChar('c1', '小亮', '分析师');
  final charById = {'c1': c1};
  final t = DateTime(2026, 7, 7, 15, 30);
  final messages = [
    _mkMsg('m1', 'user', 'user', '你好', t),
    _mkMsg('m2', 'c1', 'ai', '我是小亮', t.add(const Duration(minutes: 1))),
  ];

  group('ConversationExportService', () {
    test('toMarkdown 含群组名、主题与按时间排序的内容', () {
      final md =
          ConversationExportService().toMarkdown(chatGroup, messages, charById);
      expect(md, contains('# 测试群'));
      expect(md, contains('主题：主题A'));
      expect(md, contains('你好'));
      expect(md, contains('我是小亮'));
      expect(md, contains('小亮'));
      // 时间顺序：用户消息应出现在 AI 回复之前
      expect(md.indexOf('你好'), lessThan(md.indexOf('我是小亮')));
    });

    test('toJson 结构正确且绝不包含密钥字段', () {
      final json =
          ConversationExportService().toJson(chatGroup, messages, charById);
      expect(json['group']['name'], '测试群');
      expect(json['group']['theme'], '主题A');
      // group 只含展示字段，不含任何密钥
      expect(json['group'].containsKey('apiKey'), isFalse);
      expect(json['group'].containsKey('apiConfigId'), isFalse);

      final msgs = json['messages'] as List;
      expect(msgs.length, 2);
      final aiMsg = msgs.firstWhere((m) => m['senderType'] == 'ai');
      expect(aiMsg['name'], '小亮');
      expect(aiMsg['role'], '分析师');
      expect(aiMsg['content'], '我是小亮');
      // 把整个 JSON 序列化后再检查，确保任何层级都不含密钥
      final encoded = jsonEncode(json);
      expect(encoded.contains('sk-TOPSECRET'), isFalse);
      expect(encoded.contains('apiKey'), isFalse);
      expect(encoded.contains('apiConfigId'), isFalse);
    });

    test('toMarkdown 与 toJson 均绝不泄露 apiKey/apiProvider/apiConfigId/apiConfig',
        () {
      // 构造一个持有明文密钥的角色，验证导出内容任何层级都不含敏感字段。
      final service = ConversationExportService();
      final md = service.toMarkdown(chatGroup, messages, charById);
      final json = service.toJson(chatGroup, messages, charById);
      final jsonStr = jsonEncode(json);

      // 明文密钥值绝不出现
      expect(jsonStr.contains('sk-TOPSECRET'), isFalse,
          reason: 'JSON 泄露明文 apiKey');
      expect(md.contains('sk-TOPSECRET'), isFalse,
          reason: 'Markdown 泄露明文 apiKey');

      // 安全红线四项字段名绝不出现（设计文档硬性约定）
      for (final bad in [
        'apiKey',
        'apiProvider',
        'apiConfigId',
        'apiConfig',
      ]) {
        expect(jsonStr.contains(bad), isFalse, reason: 'JSON 泄露字段: $bad');
        expect(md.contains(bad), isFalse, reason: 'Markdown 泄露字段: $bad');
      }
    });

    test('exports do not include humanized intent debug fields', () {
      final group = ChatGroup(
        id: 'g1',
        name: '灵感群',
        description: '',
        theme: '日常创作',
        aiCharacterIds: const ['c1'],
      );
      final character = AICharacter(
        id: 'c1',
        name: '阿月',
        avatar: 'A',
        age: 24,
        role: '插画师',
        personalityTags: const ['敏感'],
        systemPrompt: 'secret system prompt',
        apiKey: 'secret-key',
        apiProvider: 'deepseek',
      );
      final localMessages = [
        Message(
          groupId: 'g1',
          senderId: 'c1',
          senderType: 'ai',
          content: '这配色有点太满了。',
        ),
      ];

      final json = ConversationExportService().toJson(
        group,
        localMessages,
        {'c1': character},
      );
      final markdown = ConversationExportService().toMarkdown(
        group,
        localMessages,
        {'c1': character},
      );
      final jsonText = jsonEncode(json);

      expect(jsonText, isNot(contains('ReplyIntent')));
      expect(jsonText, isNot(contains('reason')));
      expect(jsonText, isNot(contains('secret-key')));
      expect(jsonText, isNot(contains('secret system prompt')));
      expect(markdown, isNot(contains('ReplyIntent')));
      expect(markdown, isNot(contains('secret-key')));
      expect(markdown, isNot(contains('secret system prompt')));
    });

    test('saveToFile 写入文件并可回读，随后清理', () async {
      // 注：本例仅涉及 dart:io 文件操作，故用普通 test 而非 testWidgets，
      // 避免引入 Flutter Widget 绑定；同时注入系统临时目录来验证「落盘 + 回读」，
      // 因为 flutter test 环境下 path_provider 的 MethodChannel 无实现。
      final tmp =
          await Directory.systemTemp.createTemp('chat_group_export_test');
      try {
        final service = ConversationExportService();
        final content = service.toMarkdown(chatGroup, messages, charById);
        final file = await service.saveToFile(
          content,
          'unit_test_export.md',
          baseDirectory: tmp,
        );
        expect(await file.exists(), isTrue);
        final read = await file.readAsString();
        expect(read, contains('你好'));
      } finally {
        // 清理，避免污染临时目录
        await tmp.delete(recursive: true);
      }
    });
  });
}
