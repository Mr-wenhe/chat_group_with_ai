import 'package:chat_group/core/models/media_attachment.dart';
import 'package:chat_group/core/models/message.dart';
import 'package:chat_group/features/agentic/agent_attachment_context.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('current agent request includes attachment identity path and text',
      () async {
    final attachment = MediaAttachment(
      id: 'f1',
      type: 'file',
      localPath: r'C:\Users\me\AppData\Local\chat_group\spec.md',
      fileName: 'spec.md',
      fileSize: 128,
      mimeType: 'text/markdown',
    );

    final result = await AgentAttachmentContext.enhanceCurrentRequest(
      userRequest: '按这个文件继续做',
      media: [attachment],
      readText: (_) async => '# 需求\n必须兼容 Windows 路径。',
    );

    expect(result, contains('spec.md'));
    expect(result, contains(r'C:\Users\me'));
    expect(result, contains('必须兼容 Windows 路径'));
  });

  test('history keeps earlier attachment context for later agent turns',
      () async {
    final messages = [
      Message(
        groupId: 'g',
        senderId: 'user',
        senderType: 'user',
        content: '这是项目说明',
        media: [
          MediaAttachment(
            id: 'f1',
            type: 'file',
            localPath: '/tmp/project.md',
            fileName: 'project.md',
            fileSize: 42,
          ),
        ],
      ),
      Message(
        groupId: 'g',
        senderId: 'assistant',
        senderType: 'ai',
        content: '我看到了。',
      ),
      Message(
        groupId: 'g',
        senderId: 'user',
        senderType: 'user',
        content: '继续',
      ),
    ];

    final history = await AgentAttachmentContext.buildHistory(
      messages: messages,
      currentUserRequest: '继续',
      readText: (_) async => '长期任务要求：保留附件上下文。',
    );

    expect(history, hasLength(2));
    expect(history.first['content'], contains('project.md'));
    expect(history.first['content'], contains('/tmp/project.md'));
    expect(history.first['content'], contains('保留附件上下文'));
  });

  test('fresh artifact request does not inline an older AI artifact body',
      () async {
    final messages = [
      Message(
        groupId: 'g',
        senderId: 'assistant',
        senderType: 'ai',
        content: '已生成宇宙遨游页面。',
        media: [
          MediaAttachment(
            id: 'old-page',
            type: 'file',
            localPath: '/tmp/page.html',
            fileName: 'page.html',
            fileSize: 12000,
            mimeType: 'text/html',
          ),
        ],
      ),
      Message(
        groupId: 'g',
        senderId: 'user',
        senderType: 'user',
        content: '小薇，我现在要你再生成一份html文件，内容是从宇宙中看到地球。',
      ),
    ];

    final history = await AgentAttachmentContext.buildHistory(
      messages: messages,
      currentUserRequest: '小薇，我现在要你再生成一份html文件，'
          '内容是从宇宙中看到地球，并能拖动地球旋转。',
      readText: (_) async =>
          '<html><title>DEEP SPACE VOYAGER</title><body>old stars</body></html>',
    );

    expect(history, hasLength(1));
    expect(history.single['content'], contains('page.html'));
    expect(history.single['content'], isNot(contains('DEEP SPACE VOYAGER')));
    expect(history.single['content'], isNot(contains('old stars')));
  });

  test('explicit revision request can still inline the previous AI artifact',
      () async {
    final messages = [
      Message(
        groupId: 'g',
        senderId: 'assistant',
        senderType: 'ai',
        content: '已生成页面。',
        media: [
          MediaAttachment(
            id: 'previous-page',
            type: 'file',
            localPath: '/tmp/page.html',
            fileName: 'page.html',
            fileSize: 128,
            mimeType: 'text/html',
          ),
        ],
      ),
      Message(
        groupId: 'g',
        senderId: 'user',
        senderType: 'user',
        content: '继续修改刚才的附件，把地球改大一点。',
      ),
    ];

    final history = await AgentAttachmentContext.buildHistory(
      messages: messages,
      currentUserRequest: '继续修改刚才的附件，把地球改大一点。',
      readText: (_) async => '<html><body>previous earth</body></html>',
    );

    expect(history.single['content'], contains('previous earth'));
  });

  test('binary files remain remembered by metadata without unsafe decoding',
      () async {
    var readCount = 0;
    final result = await AgentAttachmentContext.enhanceCurrentRequest(
      userRequest: '记住这个 PDF',
      media: [
        MediaAttachment(
          id: 'pdf',
          type: 'file',
          localPath: '/tmp/report.pdf',
          fileName: 'report.pdf',
          fileSize: 2000,
          mimeType: 'application/pdf',
        ),
      ],
      readText: (_) async {
        readCount++;
        return 'should not read';
      },
    );

    expect(result, contains('report.pdf'));
    expect(result, contains('/tmp/report.pdf'));
    expect(readCount, 0);
  });
}
