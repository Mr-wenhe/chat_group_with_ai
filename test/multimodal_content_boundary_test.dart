import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:chat_group/core/models/media_attachment.dart';
import 'package:chat_group/core/models/message.dart';
import 'package:chat_group/features/chat_group/multimodal_content.dart';

/// QA 独立补充的边界用例（严过关，second-opinion）。
/// 目标：证明 buildUserMessageContent 在工程师既有用例之外的健壮性。
void main() {
  group('buildUserMessageContent 边界用例 (QA 补充)', () {
    test('多图(2)+视频混合 + supportsVision=true → 文案+2图+视频提示 共4 part', () {
      final images = [
        MediaAttachment(
            id: 'i1',
            type: 'image',
            localPath: '/a.jpg',
            mimeType: 'image/jpeg'),
        MediaAttachment(
            id: 'i2',
            type: 'image',
            localPath: '/b.png',
            mimeType: 'image/png'),
      ];
      final video = MediaAttachment(
          id: 'v1', type: 'video', localPath: '/c.mp4', mimeType: 'video/mp4');
      final message = Message(
        groupId: 'g1',
        senderId: 'user',
        senderType: 'user',
        content: '多图加视频',
        media: [...images, video],
      );

      final result = buildUserMessageContent(
        message,
        supportsVision: true,
        fileReader: (_) => Uint8List.fromList([5]),
      );

      expect(result, isA<List>());
      final parts = result as List;
      // 文案 + 2 张图片 + 视频提示
      expect(parts.length, 4);
      expect((parts[0] as Map)['type'], 'text');
      expect((parts[1] as Map)['type'], 'image_url');
      expect((parts[2] as Map)['type'], 'image_url');
      final videoHint = parts[3] as Map<String, dynamic>;
      expect(videoHint['type'], 'text');
      expect(videoHint['text'], '[用户发送了一段视频]');
      // 两张图片的 mime 前缀必须各不相同且正确
      final url1 = (parts[1] as Map)['image_url']['url'] as String;
      final url2 = (parts[2] as Map)['image_url']['url'] as String;
      expect(url1, startsWith('data:image/jpeg;base64,'));
      expect(url2, startsWith('data:image/png;base64,'));
      expect(url1, 'data:image/jpeg;base64,${base64Encode([5])}');
      expect(url2, 'data:image/png;base64,${base64Encode([5])}');
    });

    test(
        '仅图片 + content 空字符串 + supportsVision=true → 仅 1 个 image_url part（无空文案）',
        () {
      final image = MediaAttachment(
          id: 'i1', type: 'image', localPath: '/a.jpg', mimeType: 'image/jpeg');
      final message = Message(
        groupId: 'g1',
        senderId: 'user',
        senderType: 'user',
        content: '',
        media: [image],
      );

      final result = buildUserMessageContent(
        message,
        supportsVision: true,
        fileReader: (_) => Uint8List.fromList([1, 2]),
      );

      expect(result, isA<List>());
      final parts = result as List;
      // 空文案不应生成多余的 text part
      expect(parts.length, 1);
      expect((parts[0] as Map)['type'], 'image_url');
    });

    test('仅图片 + content 空字符串 + supportsVision=false → 仅 [用户发送了 1 张图片]', () {
      final image =
          MediaAttachment(id: 'i1', type: 'image', localPath: '/a.jpg');
      final message = Message(
        groupId: 'g1',
        senderId: 'user',
        senderType: 'user',
        content: '',
        media: [image],
      );

      final result = buildUserMessageContent(
        message,
        supportsVision: false,
        fileReader: (_) => Uint8List.fromList([0]),
      );

      // 空文案 + 无视频 → 不应出现多余换行
      expect(result, '[用户发送了 1 张图片]');
    });

    test('仅视频 + content 空字符串 + supportsVision=true → 仅 [用户发送了一段视频]', () {
      final video = MediaAttachment(
          id: 'v1', type: 'video', localPath: '/c.mp4', mimeType: 'video/mp4');
      final message = Message(
        groupId: 'g1',
        senderId: 'user',
        senderType: 'user',
        content: '',
        media: [video],
      );

      final result = buildUserMessageContent(
        message,
        supportsVision: true,
        fileReader: (_) => Uint8List.fromList([9]),
      );

      // 无图片时走仅视频分支，空文案不应残留
      expect(result, '[用户发送了一段视频]');
    });

    test('mimeType 缺失 → 回退 image/jpeg 前缀', () {
      final image =
          MediaAttachment(id: 'i1', type: 'image', localPath: '/x.unknown');
      final message = Message(
        groupId: 'g1',
        senderId: 'user',
        senderType: 'user',
        content: '无 mime',
        media: [image],
      );

      final result = buildUserMessageContent(
        message,
        supportsVision: true,
        fileReader: (_) => Uint8List.fromList([3]),
      );

      final parts = result as List;
      final url = (parts[1] as Map)['image_url']['url'] as String;
      expect(url, startsWith('data:image/jpeg;base64,'));
    });

    test('图片文件读取失败 → 降级为文字提示且不抛异常', () {
      final image =
          MediaAttachment(id: 'i1', type: 'image', localPath: '/missing.jpg');
      final message = Message(
        groupId: 'g1',
        senderId: 'user',
        senderType: 'user',
        content: '这张图还在吗',
        media: [image],
      );

      final result = buildUserMessageContent(
        message,
        supportsVision: true,
        fileReader: (_) => throw const FileSystemException('missing'),
      );

      expect(result, isA<String>());
      expect(result, contains('这张图还在吗'));
      expect(result, contains('[用户发送了 1 张图片，但本地文件暂时不可读取]'));
    });

    test('超过视觉图片数量上限 → 只内联前 N 张并追加跳过提示', () {
      final images = List.generate(
        5,
        (index) => MediaAttachment(
          id: 'i$index',
          type: 'image',
          localPath: '/$index.jpg',
          mimeType: 'image/jpeg',
        ),
      );
      final message = Message(
        groupId: 'g1',
        senderId: 'user',
        senderType: 'user',
        content: '',
        media: images,
      );

      final result = buildUserMessageContent(
        message,
        supportsVision: true,
        fileReader: (_) => Uint8List.fromList([1]),
      );

      final parts = result as List;
      expect(
        parts.where((part) => (part as Map)['type'] == 'image_url'),
        hasLength(4),
      );
      expect(parts.last, {
        'type': 'text',
        'text': '[用户还发送了 1 张图片，但因为数量或体积限制没有内联发送]',
      });
    });

    test('图片超过内联体积上限 → 降级为文字提示', () {
      final image = MediaAttachment(
        id: 'i1',
        type: 'image',
        localPath: '/large.jpg',
        fileSize: defaultMaxInlineImageBytes + 1,
      );
      final message = Message(
        groupId: 'g1',
        senderId: 'user',
        senderType: 'user',
        content: '大图',
        media: [image],
      );

      final result = buildUserMessageContent(
        message,
        supportsVision: true,
        fileReader: (_) => Uint8List.fromList([1]),
      );

      expect(result, isA<String>());
      expect(result, contains('大图'));
      expect(result, contains('[用户还发送了 1 张图片，但因为数量或体积限制没有内联发送]'));
    });
  });
}
