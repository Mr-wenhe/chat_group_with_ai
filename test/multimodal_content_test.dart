import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:chat_group/core/models/media_attachment.dart';
import 'package:chat_group/core/models/message.dart';
import 'package:chat_group/features/chat_group/multimodal_content.dart';

void main() {
  group('buildUserMessageContent', () {
    test('async preparation reads image bytes without synchronous IO',
        () async {
      var readCompleted = false;
      final message = Message(
        groupId: 'g1',
        senderId: 'user',
        senderType: 'user',
        content: '异步图片',
        media: [
          MediaAttachment(
            type: 'image',
            localPath: '/tmp/async.png',
            mimeType: 'image/png',
          ),
        ],
      );

      final future = prepareUserMessageContent(
        message,
        supportsVision: true,
        fileReader: (_) async {
          await Future<void>.delayed(Duration.zero);
          readCompleted = true;
          return Uint8List.fromList([1, 2, 3]);
        },
      );
      expect(readCompleted, isFalse);

      final result = await future as List<Map<String, dynamic>>;
      expect(readCompleted, isTrue);
      expect(result[1]['image_url']['url'],
          'data:image/png;base64,${base64Encode([1, 2, 3])}');
    });

    test('无媒体 → 返回 String 文案', () {
      final message = Message(
        groupId: 'g1',
        senderId: 'user',
        senderType: 'user',
        content: '你好，群友',
      );

      final result = buildUserMessageContent(message, supportsVision: true);

      expect(result, isA<String>());
      expect(result, '你好，群友');
    });

    test('图片 + supportsVision=true → List 含 image_url，base64 前缀正确', () {
      final image = MediaAttachment(
        id: 'img1',
        type: 'image',
        localPath: '/tmp/a.jpg',
        mimeType: 'image/jpeg',
      );
      final message = Message(
        groupId: 'g1',
        senderId: 'user',
        senderType: 'user',
        content: '看这张图',
        media: [image],
      );

      // 注入假字节，避免真实文件 IO。
      const fakeBytes = [1, 2, 3, 4];
      final result = buildUserMessageContent(
        message,
        supportsVision: true,
        fileReader: (_) => Uint8List.fromList(fakeBytes),
      );

      expect(result, isA<List>());
      final parts = result as List;
      expect(parts.length, 2);
      expect(parts[0], {'type': 'text', 'text': '看这张图'});

      final imagePart = parts[1] as Map<String, dynamic>;
      expect(imagePart['type'], 'image_url');
      final url = (imagePart['image_url'] as Map)['url'] as String;
      expect(url, startsWith('data:image/jpeg;base64,'));
      expect(url, 'data:image/jpeg;base64,${base64Encode(fakeBytes)}');
    });

    test('图片 + supportsVision=false → 含 [用户发送了 N 张图片]', () {
      final image = MediaAttachment(
        id: 'img1',
        type: 'image',
        localPath: '/tmp/a.png',
        mimeType: 'image/png',
      );
      final message = Message(
        groupId: 'g1',
        senderId: 'user',
        senderType: 'user',
        content: '看',
        media: [image],
      );

      final result = buildUserMessageContent(
        message,
        supportsVision: false,
        fileReader: (_) => Uint8List.fromList([9]),
      );

      expect(result, isA<String>());
      expect(result, contains('[用户发送了 1 张图片]'));
    });

    test('多张图片 + supportsVision=false → 数量正确', () {
      final images = [
        MediaAttachment(id: '1', type: 'image', localPath: '/a.jpg'),
        MediaAttachment(id: '2', type: 'image', localPath: '/b.jpg'),
      ];
      final message = Message(
        groupId: 'g1',
        senderId: 'user',
        senderType: 'user',
        content: '',
        media: images,
      );

      final result = buildUserMessageContent(
        message,
        supportsVision: false,
        fileReader: (_) => Uint8List.fromList([0]),
      );

      expect(result, contains('[用户发送了 2 张图片]'));
    });

    test('视频 → 含 [用户发送了一段视频]', () {
      final video = MediaAttachment(
        id: 'v1',
        type: 'video',
        localPath: '/tmp/a.mp4',
        mimeType: 'video/mp4',
      );
      final message = Message(
        groupId: 'g1',
        senderId: 'user',
        senderType: 'user',
        content: '这是视频',
        media: [video],
      );

      final result = buildUserMessageContent(
        message,
        supportsVision: false,
        fileReader: (_) => Uint8List.fromList([1]),
      );

      expect(result, contains('[用户发送了一段视频]'));
    });

    test('普通文件 → 含文件名和大小提示', () {
      final file = MediaAttachment(
        id: 'f1',
        type: 'file',
        localPath: '/tmp/report.pdf',
        fileName: 'report.pdf',
        fileSize: 2048,
        mimeType: 'application/pdf',
      );
      final message = Message(
        groupId: 'g1',
        senderId: 'user',
        senderType: 'user',
        content: '请看附件',
        media: [file],
      );

      final result = buildUserMessageContent(
        message,
        supportsVision: true,
      );

      expect(result, isA<String>());
      expect(result, contains('请看附件'));
      expect(result, contains('[用户发送了文件：report.pdf，2.0 KB]'));
    });

    test('图片 + 视频混合 → 图片按视觉处理、视频追加文字提示', () {
      final image = MediaAttachment(
        id: 'img1',
        type: 'image',
        localPath: '/tmp/a.jpg',
        mimeType: 'image/jpeg',
      );
      final video = MediaAttachment(
        id: 'v1',
        type: 'video',
        localPath: '/tmp/b.mp4',
        mimeType: 'video/mp4',
      );
      final message = Message(
        groupId: 'g1',
        senderId: 'user',
        senderType: 'user',
        content: '混合内容',
        media: [image, video],
      );

      const fake = [7, 7, 7];
      final result = buildUserMessageContent(
        message,
        supportsVision: true,
        fileReader: (_) => Uint8List.fromList(fake),
      );

      expect(result, isA<List>());
      final parts = result as List;
      // 文案 + 图片 + 视频提示
      expect(parts.length, 3);
      expect((parts[0] as Map)['type'], 'text');
      expect((parts[1] as Map)['type'], 'image_url');
      final videoHint = parts[2] as Map<String, dynamic>;
      expect(videoHint['type'], 'text');
      expect(videoHint['text'], contains('[用户发送了一段视频]'));
    });
  });
}
