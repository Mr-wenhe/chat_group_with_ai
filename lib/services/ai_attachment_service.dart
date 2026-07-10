import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/media_attachment.dart';
import 'package:dio/dio.dart';

class AiAttachmentIntent {
  final bool wantsImage;
  final bool wantsFile;
  final bool wantsNetworkImage;

  const AiAttachmentIntent({
    required this.wantsImage,
    required this.wantsFile,
    this.wantsNetworkImage = false,
  });

  bool get hasAny => wantsImage || wantsFile;
}

class RemoteImagePayload {
  final List<int> bytes;
  final String extension;
  final String title;
  final String sourceUrl;
  final String attribution;

  const RemoteImagePayload({
    required this.bytes,
    required this.extension,
    required this.title,
    required this.sourceUrl,
    required this.attribution,
  });
}

abstract interface class RemoteImageFetcher {
  Future<RemoteImagePayload?> fetch(String query);
}

/// Downloads a reasonably sized preview from Wikimedia Commons.
///
/// Commons exposes a public MediaWiki API and does not require an API key.
/// A source note is saved alongside every downloaded image so licensing and
/// attribution information are not lost.
class WikimediaCommonsImageFetcher implements RemoteImageFetcher {
  WikimediaCommonsImageFetcher({Dio? dio}) : _dio = dio ?? Dio();

  static const _endpoint = 'https://commons.wikimedia.org/w/api.php';
  static const _maxImageBytes = 8 * 1024 * 1024;
  final Dio _dio;

  @override
  Future<RemoteImagePayload?> fetch(String query) async {
    final normalized = query.trim();
    if (normalized.isEmpty) return null;
    try {
      final response = await _dio.get<Map<String, dynamic>>(
        _endpoint,
        queryParameters: {
          'action': 'query',
          'format': 'json',
          'generator': 'search',
          'gsrsearch': normalized,
          'gsrnamespace': 6,
          'gsrlimit': 8,
          'prop': 'imageinfo',
          'iiprop': 'url|mime|size|extmetadata',
          'iiurlwidth': 1280,
          'iiextmetadatafilter': 'Artist|Credit|LicenseShortName|UsageTerms',
        },
        options: Options(
          sendTimeout: const Duration(seconds: 12),
          receiveTimeout: const Duration(seconds: 20),
          headers: const {
            'User-Agent': 'AIGroupChat/1.0 (desktop image attachment)'
          },
        ),
      );
      final page = _firstUsablePage(response.data);
      if (page == null) return null;
      final info = (page['imageinfo'] as List).first as Map;
      final imageUrl = (info['thumburl'] ?? info['url'])?.toString() ?? '';
      final descriptionUrl = info['descriptionurl']?.toString() ?? '';
      final mime = (info['thumbmime'] ?? info['mime'])?.toString() ?? '';
      if (!imageUrl.startsWith('https://') || !mime.startsWith('image/')) {
        return null;
      }

      final download = await _dio.get<List<int>>(
        imageUrl,
        options: Options(
          responseType: ResponseType.bytes,
          sendTimeout: const Duration(seconds: 12),
          receiveTimeout: const Duration(seconds: 30),
          headers: const {
            'User-Agent': 'AIGroupChat/1.0 (desktop image attachment)'
          },
        ),
      );
      final bytes = download.data;
      if (bytes == null || bytes.isEmpty || bytes.length > _maxImageBytes) {
        return null;
      }
      return RemoteImagePayload(
        bytes: bytes,
        extension: _extensionForMime(mime),
        title: page['title']?.toString().replaceFirst('File:', '') ??
            'Wikimedia image',
        sourceUrl: descriptionUrl.isNotEmpty ? descriptionUrl : imageUrl,
        attribution: _attribution(info['extmetadata']),
      );
    } on DioException {
      return null;
    } on FormatException {
      return null;
    } catch (_) {
      // A malformed third-party API response must never fail the AI message.
      return null;
    }
  }

  static Map<String, dynamic>? _firstUsablePage(Map<String, dynamic>? data) {
    final query = data?['query'];
    if (query is! Map) return null;
    final pages = query['pages'];
    if (pages is! Map) return null;
    for (final value in pages.values) {
      if (value is! Map) continue;
      final rawInfo = value['imageinfo'];
      if (rawInfo is! List || rawInfo.isEmpty || rawInfo.first is! Map) {
        continue;
      }
      final info = rawInfo.first as Map;
      final mime = (info['thumbmime'] ?? info['mime'])?.toString() ?? '';
      final url = (info['thumburl'] ?? info['url'])?.toString() ?? '';
      if (mime.startsWith('image/') && url.startsWith('https://')) {
        return Map<String, dynamic>.from(value);
      }
    }
    return null;
  }

  static String _extensionForMime(String mime) {
    if (mime.contains('png')) return 'png';
    if (mime.contains('webp')) return 'webp';
    if (mime.contains('gif')) return 'gif';
    return 'jpg';
  }

  static String _attribution(dynamic metadata) {
    if (metadata is! Map) return 'See the Wikimedia Commons source page';
    String value(String key) {
      final entry = metadata[key];
      if (entry is Map) return entry['value']?.toString().trim() ?? '';
      return '';
    }

    final parts = [
      value('Artist'),
      value('Credit'),
      value('LicenseShortName'),
      value('UsageTerms'),
    ].where((item) => item.isNotEmpty).toSet().toList();
    return parts.isEmpty
        ? 'See the Wikimedia Commons source page'
        : parts.join(' / ');
  }
}

class AiAttachmentService {
  AiAttachmentService({
    required this.db,
    RemoteImageFetcher? remoteImageFetcher,
  }) : remoteImageFetcher =
            remoteImageFetcher ?? WikimediaCommonsImageFetcher();

  final DatabaseService db;
  final RemoteImageFetcher remoteImageFetcher;

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
    final wantsNetworkImage = wantsImage &&
        _containsAny(text, const [
          '联网',
          '网上',
          '网络',
          '搜索图片',
          '找图',
          '找一张',
          '拉取',
          'search image',
          'find image',
          'from web',
          'download image',
        ]);
    return AiAttachmentIntent(
      wantsImage: wantsImage,
      wantsFile: wantsFile,
      wantsNetworkImage: wantsNetworkImage,
    );
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
      final remote = intent.wantsNetworkImage
          ? await remoteImageFetcher
              .fetch(_networkImageQuery(userMessage ?? ''))
          : null;
      if (remote != null) {
        final stamp = DateTime.now().millisecondsSinceEpoch;
        attachments.add(await db.writeBytesToAiCharacterDir(
          bytes: remote.bytes,
          fileName:
              'commons_${_safeFileStem(remote.title)}_$stamp.${remote.extension}',
          characterId: character.id,
          characterName: character.name,
          type: 'image',
        ));
        final sourceNote = '# 图片来源\n\n'
            '- 标题：${remote.title}\n'
            '- 来源：${remote.sourceUrl}\n'
            '- 作者/授权：${remote.attribution}\n';
        attachments.add(await db.writeBytesToAiCharacterDir(
          bytes: utf8.encode(sourceNote),
          fileName: 'commons_source_$stamp.md',
          characterId: character.id,
          characterName: character.name,
        ));
      } else {
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

  String _networkImageQuery(String text) {
    var query = text.trim();
    for (final token in const [
      '请',
      '帮我',
      '给我',
      '联网',
      '从网上',
      '网上',
      '搜索',
      '找一张',
      '找',
      '拉取',
      '发一张',
      '发',
      '图片',
      '配图',
      '图',
    ]) {
      query = query.replaceAll(token, ' ');
    }
    query = query.replaceAll(RegExp(r'\s+'), ' ').trim();
    return query.isEmpty ? text.trim() : query;
  }

  String _safeFileStem(String value) {
    final safe = value
        .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F]'), '_')
        .replaceAll(RegExp(r'\s+'), '_')
        .replaceAll(RegExp(r'_+'), '_')
        .replaceAll(RegExp(r'^[._ ]+|[._ ]+$'), '');
    if (safe.isEmpty) return 'image';
    return safe.length > 64 ? safe.substring(0, 64) : safe;
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
