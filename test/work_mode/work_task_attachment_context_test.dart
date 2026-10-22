import 'package:chat_group/features/agentic/context_window_manager.dart';
import 'package:chat_group/features/ai_governance/ai_request_guard.dart';
import 'dart:convert';
import 'dart:io';

import 'package:chat_group/core/models/agent_task.dart';
import 'package:chat_group/core/models/media_attachment.dart';
import 'package:chat_group/core/models/message.dart';
import 'package:chat_group/features/work_mode/work_task_attachment_context.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('image Base64 is not counted as millions of text tokens', () {
    final payload = <Map<String, dynamic>>[
      {
        'role': 'user',
        'content': [
          {
            'type': 'image_url',
            'image_url': {'url': 'data:image/png;base64,${'A' * 1000000}'}
          }
        ]
      }
    ];
    expect(
        AiRequestGuard.estimateTokens(payload), inInclusiveRange(4096, 4200));
    expect(ContextWindowManager.estimateRequestTokens(payload),
        inInclusiveRange(4096, 4200));
    final fitted =
        ContextWindowManager.fitToTokenBudget(payload, maxTokens: 8192);
    expect(fitted.single['content'], same(payload.single['content']));
  });

  test(
      'selects current supplements, excludes FIFO, other rooms and hidden input',
      () {
    final task = AgentTask(groupId: 'g', characterId: 'a', userRequest: '分析附件')
      ..executionStateJson = jsonEncode({
        'attachmentMessageId': 'current',
        'discussionAttachmentMessageIds': ['supplement', 'foreign', 'hidden'],
        'queuedAttachmentMessageIds': ['queued'],
      });
    Message source(String id,
            {String room = 'g', List<String> visible = const ['a']}) =>
        Message(
          id: id,
          groupId: room,
          senderId: 'user',
          senderType: 'user',
          content: '分析附件',
          visibleToCharacterIds: visible,
          media: [MediaAttachment(type: 'image', localPath: '/$id.png')],
        );
    expect(
        WorkTaskAttachmentContext.attachments(
                task,
                [
                  source('current'),
                  source('supplement'),
                  source('queued'),
                  source('foreign', room: 'elsewhere'),
                  source('hidden', visible: ['b']),
                ],
                characterId: 'a')
            .map((a) => a.localPath),
        ['/current.png', '/supplement.png']);
  });

  test('legacy text lookup excludes matching queued attachments', () {
    final task = AgentTask(groupId: 'g', characterId: 'a', userRequest: '分析附件')
      ..executionStateJson = '{"queuedAttachmentMessageIds":["future"]}';
    final messages = [
      for (final id in ['current', 'future'])
        Message(
          id: id,
          groupId: 'g',
          senderId: 'user',
          senderType: 'user',
          content: '分析附件',
          visibleToCharacterIds: ['a'],
          timestamp: DateTime(2026, 10, id == 'current' ? 21 : 22),
          media: [MediaAttachment(type: 'file', localPath: '/$id.txt')],
        )
    ];
    expect(
        WorkTaskAttachmentContext.attachments(task, messages, characterId: 'a')
            .single
            .localPath,
        '/current.txt');
  });

  test('legacy DM attachments stay isolated to the original counterpart', () {
    final task = AgentTask(groupId: 'dm:a', characterId: 'a', userRequest: '看图')
      ..executionStateJson = '{"attachmentMessageId":"old"}';
    final source = Message(
        id: 'old',
        groupId: 'dm:a',
        senderId: 'user',
        senderType: 'user',
        content: '看图',
        media: [MediaAttachment(type: 'image', localPath: '/old.png')]);
    expect(
        WorkTaskAttachmentContext.attachments(task, [source], characterId: 'a'),
        hasLength(1));
    expect(
        WorkTaskAttachmentContext.attachments(task, [source], characterId: 'b'),
        isEmpty);
  });

  test(
      'prepares image bytes and document text together without a model tool call',
      () async {
    final root = await Directory.systemTemp.createTemp('work-attachments-');
    addTearDown(() => root.delete(recursive: true));
    final image = await File('${root.path}/image.png').writeAsBytes([1, 2, 3]);
    final html = await File('${root.path}/profile.html')
        .writeAsString('<html><body><p>姓名：陆博文，研究量子物理。</p></body></html>');
    final task =
        AgentTask(groupId: 'g', characterId: 'a', userRequest: '分析姓名和研究方向');
    final content = await WorkTaskAttachmentContext.prepare(
      task: task,
      attachments: [
        MediaAttachment(
            type: 'image', localPath: image.path, mimeType: 'image/png'),
        MediaAttachment(
            type: 'file', localPath: html.path, fileName: 'profile.html'),
      ],
      supportsVision: true,
    ) as List;
    expect(
        content
            .whereType<Map>()
            .where((p) => p['type'] == 'image_url')
            .single['image_url'],
        {'url': 'data:image/png;base64,AQID'});
    expect(jsonEncode(content), contains('量子物理'));
    expect(jsonEncode(content), contains('profile.html'));
    expect(jsonEncode(content), contains('不可信资料'));
  });

  test('missing images and unsupported video stay explicit, never fabricated',
      () async {
    final content = await WorkTaskAttachmentContext.prepare(
      task: AgentTask(groupId: 'g', characterId: 'a', userRequest: '看附件'),
      attachments: [
        MediaAttachment(type: 'image', localPath: '/missing/image.png'),
        MediaAttachment(type: 'video', localPath: '/missing/video.mov'),
      ],
      supportsVision: true,
    );
    expect(jsonEncode(content), contains('不可读取'));
    expect(jsonEncode(content), contains('不支持视频内容理解'));
    expect(jsonEncode(content), isNot(contains('image_url')));
  });
}
