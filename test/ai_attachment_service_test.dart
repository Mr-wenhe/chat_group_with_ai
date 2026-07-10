import 'dart:typed_data';

import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/media_attachment.dart';
import 'package:chat_group/services/ai_attachment_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AiAttachmentService', () {
    test('detects image and file attachment requests', () {
      final service = AiAttachmentService(db: _TestDatabaseService());

      expect(service.detectIntent('给我贴图看看').wantsImage, isTrue);
      expect(service.detectIntent('整理成附件发我').wantsFile, isTrue);
      expect(service.detectIntent('聊聊你的看法').hasAny, isFalse);
      expect(service.detectIntent('从网上找一张猫图片').wantsNetworkImage, isTrue);
      expect(service.detectIntent('生成一张星空图片').wantsNetworkImage, isFalse);
    });

    test('generates a valid png sticker bitmap', () {
      final bytes = PngStickerGenerator.generate(seedText: 'hello');
      expect(bytes.take(8).toList(), [137, 80, 78, 71, 13, 10, 26, 10]);

      final data = ByteData.sublistView(Uint8List.fromList(bytes));
      expect(data.getUint32(8), 13);
      expect(String.fromCharCodes(bytes.sublist(12, 16)), 'IHDR');
      expect(data.getUint32(16), PngStickerGenerator.width);
      expect(data.getUint32(20), PngStickerGenerator.height);
    });

    test('downloads a requested web image and includes its source note',
        () async {
      final db = _TestDatabaseService();
      final service = AiAttachmentService(
        db: db,
        remoteImageFetcher: const _FakeRemoteImageFetcher(
          RemoteImagePayload(
            bytes: [0xff, 0xd8, 0xff, 0xd9],
            extension: 'jpg',
            title: 'Cat portrait',
            sourceUrl: 'https://commons.wikimedia.org/wiki/File:Cat.jpg',
            attribution: 'CC BY-SA / Example Author',
          ),
        ),
      );

      final attachments = await service.createRequestedAttachments(
        character: _character,
        userMessage: '从网上找一张猫图片',
        replyContent: '找到了',
      );

      expect(attachments, hasLength(2));
      expect(attachments.first.type, 'image');
      expect(db.writes.first.fileName, endsWith('.jpg'));
      expect(String.fromCharCodes(db.writes.last.bytes), contains('CC BY-SA'));
      expect(String.fromCharCodes(db.writes.last.bytes), contains('https://'));
    });

    test('falls back to generated png when remote image lookup fails',
        () async {
      final db = _TestDatabaseService();
      final service = AiAttachmentService(
        db: db,
        remoteImageFetcher: const _FakeRemoteImageFetcher(null),
      );

      final attachments = await service.createRequestedAttachments(
        character: _character,
        userMessage: '网上找一张海边图片',
        replyContent: '给你',
      );

      expect(attachments, hasLength(1));
      expect(db.writes.single.bytes.take(8), [137, 80, 78, 71, 13, 10, 26, 10]);
    });
  });
}

final _character = AICharacter(
  id: 'c1',
  name: '林溪',
  avatar: '',
  age: 20,
  role: '摄影师',
  personalityTags: const [],
  systemPrompt: '',
  apiKey: '',
  apiProvider: 'deepseek',
);

class _WriteRecord {
  final List<int> bytes;
  final String fileName;

  const _WriteRecord(this.bytes, this.fileName);
}

class _TestDatabaseService extends DatabaseService {
  final writes = <_WriteRecord>[];

  @override
  Future<MediaAttachment> writeBytesToAiCharacterDir({
    required List<int> bytes,
    required String fileName,
    required String characterId,
    required String characterName,
    String type = 'file',
  }) async {
    writes.add(_WriteRecord(bytes, fileName));
    return MediaAttachment(
      type: type,
      localPath: '/virtual/$fileName',
      fileName: fileName,
      fileSize: bytes.length,
    );
  }
}

class _FakeRemoteImageFetcher implements RemoteImageFetcher {
  final RemoteImagePayload? payload;

  const _FakeRemoteImageFetcher(this.payload);

  @override
  Future<RemoteImagePayload?> fetch(String query) async => payload;
}
