import 'dart:typed_data';

import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/services/ai_attachment_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AiAttachmentService', () {
    test('detects image and file attachment requests', () {
      final service = AiAttachmentService(db: _TestDatabaseService());

      expect(service.detectIntent('给我贴图看看').wantsImage, isTrue);
      expect(service.detectIntent('整理成附件发我').wantsFile, isTrue);
      expect(service.detectIntent('聊聊你的看法').hasAny, isFalse);
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
  });
}

class _TestDatabaseService extends DatabaseService {}
