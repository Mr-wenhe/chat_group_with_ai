import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/media_attachment.dart';

class AiAttachmentIntent {
  final bool wantsImage;
  final bool wantsFile;

  const AiAttachmentIntent({
    required this.wantsImage,
    required this.wantsFile,
  });

  bool get hasAny => wantsImage || wantsFile;
}

class AiAttachmentService {
  const AiAttachmentService({required this.db});

  final DatabaseService db;

  AiAttachmentIntent detectIntent(String? userMessage) {
    final text = userMessage?.trim().toLowerCase() ?? '';
    if (text.isEmpty) {
      return const AiAttachmentIntent(wantsImage: false, wantsFile: false);
    }
    final wantsImage = _containsAny(text, const [
      '贴图',
      '发图',
      '发张图',
      '图片',
      '配图',
      '表情包',
      'image',
      'picture',
      'sticker',
    ]);
    final wantsFile = _containsAny(text, const [
      '附件',
      '发文件',
      '给我文件',
      '文档附件',
      'markdown附件',
      'md附件',
      '整理成文件',
      'file',
      'attachment',
    ]);
    return AiAttachmentIntent(wantsImage: wantsImage, wantsFile: wantsFile);
  }

  Future<List<MediaAttachment>> createRequestedAttachments({
    required AICharacter character,
    required String? userMessage,
    required String replyContent,
  }) async {
    final intent = detectIntent(userMessage);
    if (!intent.hasAny) return const [];

    final attachments = <MediaAttachment>[];
    if (intent.wantsImage) {
      final bytes = PngStickerGenerator.generate(
        seedText: '${character.id}|$userMessage|$replyContent',
      );
      attachments.add(await db.writeBytesToAiCharacterDir(
        bytes: bytes,
        fileName: 'ai_sticker_${DateTime.now().millisecondsSinceEpoch}.png',
        characterId: character.id,
        characterName: character.name,
        type: 'image',
      ));
    }
    if (intent.wantsFile) {
      final markdown = _markdownAttachment(
        character: character,
        userMessage: userMessage ?? '',
        replyContent: replyContent,
      );
      attachments.add(await db.writeBytesToAiCharacterDir(
        bytes: utf8.encode(markdown),
        fileName: 'ai_reply_${DateTime.now().millisecondsSinceEpoch}.md',
        characterId: character.id,
        characterName: character.name,
        type: 'file',
      ));
    }
    return attachments;
  }

  bool _containsAny(String text, List<String> tokens) {
    return tokens.any(text.contains);
  }

  String _markdownAttachment({
    required AICharacter character,
    required String userMessage,
    required String replyContent,
  }) {
    final now = DateTime.now().toLocal().toIso8601String();
    return [
      '# ${character.name} 的回复附件',
      '',
      '- 生成时间：$now',
      '- 角色：${character.name} / ${character.role}',
      '',
      '## 用户请求',
      '',
      userMessage.trim().isEmpty ? '（无文本请求）' : userMessage.trim(),
      '',
      '## AI 回复',
      '',
      replyContent.trim().isEmpty ? '（无回复文本）' : replyContent.trim(),
      '',
    ].join('\n');
  }
}

class PngStickerGenerator {
  static const int width = 480;
  static const int height = 320;

  static List<int> generate({required String seedText}) {
    final seed = _hash(seedText);
    final a = _rgb(seed);
    final b = _rgb(seed * 1103515245 + 12345);
    final c = _rgb(seed * 1664525 + 1013904223);
    final rows = BytesBuilder(copy: false);
    for (var y = 0; y < height; y++) {
      rows.addByte(0);
      for (var x = 0; x < width; x++) {
        final wave =
            ((sin((x + seed % 37) / 22) + cos((y + seed % 53) / 18) + 2) / 4)
                .clamp(0.0, 1.0);
        final t =
            (x / max(1, width - 1) * 0.55) + (y / max(1, height - 1) * 0.45);
        final r = _mix(_mix(a[0], b[0], t), c[0], wave * 0.32);
        final g = _mix(_mix(a[1], b[1], t), c[1], wave * 0.32);
        final bl = _mix(_mix(a[2], b[2], t), c[2], wave * 0.32);
        final vignette = _vignette(x, y);
        rows
          ..addByte((r * vignette).round().clamp(0, 255))
          ..addByte((g * vignette).round().clamp(0, 255))
          ..addByte((bl * vignette).round().clamp(0, 255));
      }
    }
    final compressed = zlib.encode(rows.takeBytes());
    final out = BytesBuilder(copy: false)
      ..add(const [137, 80, 78, 71, 13, 10, 26, 10])
      ..add(_chunk('IHDR', _ihdr()))
      ..add(_chunk('IDAT', compressed))
      ..add(_chunk('IEND', const []));
    return out.takeBytes();
  }

  static List<int> _ihdr() {
    final data = ByteData(13)
      ..setUint32(0, width)
      ..setUint32(4, height)
      ..setUint8(8, 8)
      ..setUint8(9, 2)
      ..setUint8(10, 0)
      ..setUint8(11, 0)
      ..setUint8(12, 0);
    return data.buffer.asUint8List();
  }

  static List<int> _chunk(String type, List<int> data) {
    final typeBytes = ascii.encode(type);
    final bytes = BytesBuilder(copy: false)
      ..add(typeBytes)
      ..add(data);
    final payload = bytes.takeBytes();
    final chunk = BytesBuilder(copy: false)
      ..add(_uint32(data.length))
      ..add(payload)
      ..add(_uint32(_crc32(payload)));
    return chunk.takeBytes();
  }

  static List<int> _uint32(int value) {
    final data = ByteData(4)..setUint32(0, value);
    return data.buffer.asUint8List();
  }

  static int _hash(String text) {
    var hash = 2166136261;
    for (final unit in text.codeUnits) {
      hash ^= unit;
      hash = (hash * 16777619) & 0xffffffff;
    }
    return hash == 0 ? 1 : hash;
  }

  static List<int> _rgb(int seed) {
    final random = Random(seed);
    return [
      72 + random.nextInt(144),
      72 + random.nextInt(144),
      72 + random.nextInt(144),
    ];
  }

  static double _vignette(int x, int y) {
    final dx = (x - width / 2) / width;
    final dy = (y - height / 2) / height;
    return (1.12 - sqrt(dx * dx + dy * dy) * 0.72).clamp(0.72, 1.0);
  }

  static int _mix(int a, int b, double t) {
    return (a + (b - a) * t).round();
  }

  static int _crc32(List<int> bytes) {
    var crc = 0xffffffff;
    for (final byte in bytes) {
      crc ^= byte;
      for (var i = 0; i < 8; i++) {
        final mask = -(crc & 1);
        crc = (crc >> 1) ^ (0xedb88320 & mask);
      }
    }
    return (crc ^ 0xffffffff) & 0xffffffff;
  }
}
