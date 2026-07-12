import 'dart:convert';
import 'dart:typed_data';

import 'package:chat_group/core/models/attachment_data_uri.dart';
import 'package:chat_group/core/models/media_attachment.dart';
import 'package:chat_group/core/models/message.dart';
import 'package:chat_group/features/agentic/agent_attachment_context.dart';
import 'package:chat_group/features/chat_group/multimodal_content.dart';
import 'package:chat_group/features/chat_group/picked_attachment_payload.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('web attachments are capped before base64 storage', () {
    expect(isWithinWebAttachmentLimit(maxWebAttachmentBytes), isTrue);
    expect(isWithinWebAttachmentLimit(maxWebAttachmentBytes + 1), isFalse);
  });

  test('web attachments are also capped by pending message total', () {
    expect(
      canAddWebAttachment(
        existingBytes: 6 * 1024 * 1024,
        newBytes: 4 * 1024 * 1024,
      ),
      isTrue,
    );
    expect(
      canAddWebAttachment(
        existingBytes: 6 * 1024 * 1024,
        newBytes: 4 * 1024 * 1024 + 1,
      ),
      isFalse,
    );
  });

  test('web picker payload uses bytes without reading a filesystem path', () {
    final bytes = Uint8List.fromList(utf8.encode('# Web attachment'));
    final picked = PlatformFile(
      name: 'note.md',
      size: bytes.length,
      bytes: bytes,
    );

    final payload = resolvePickedAttachmentPayload(picked, isWeb: true);

    expect(payload, isA<PickedAttachmentBytes>());
    expect((payload as PickedAttachmentBytes).bytes, bytes);
    expect(payload.fileName, 'note.md');
  });

  test('attachment data URI round-trips binary bytes and mime type', () {
    final bytes = Uint8List.fromList([0, 1, 2, 253, 254, 255]);

    final uri = encodeAttachmentDataUri(bytes, 'application/octet-stream');
    final decoded = decodeAttachmentDataUri(uri);

    expect(decoded, isNotNull);
    expect(decoded!.mimeType, 'application/octet-stream');
    expect(decoded.bytes, bytes);
  });

  test('generated web file becomes a clickable in-memory attachment', () {
    final bytes = Uint8List.fromList(
      utf8.encode('<!doctype html><title>鬼魂街大佬</title>'),
    );

    final attachment = createDataUriAttachment(
      bytes: bytes,
      fileName: 'page.html',
      mimeType: 'text/html',
    );

    expect(attachment.type, 'file');
    expect(attachment.fileName, 'page.html');
    expect(attachment.fileSize, bytes.length);
    expect(attachment.mimeType, 'text/html');
    expect(isAttachmentDataUri(attachment.localPath), isTrue);
    expect(decodeAttachmentDataUri(attachment.localPath)!.bytes, bytes);
  });

  test('UI data URI cache reuses decoded bytes for repeated builds', () {
    final uri = encodeAttachmentDataUri(
      Uint8List.fromList([5, 4, 3, 2, 1]),
      'image/png',
    );
    final cache = AttachmentDataUriCache(maxEntries: 2, maxBytes: 32);

    final first = cache.decode(uri);
    final second = cache.decode(uri);

    expect(first, isNotNull);
    expect(identical(first!.bytes, second!.bytes), isTrue);
  });

  test('data URI image is sent to a vision model without filesystem IO', () {
    final uri = encodeAttachmentDataUri(
      Uint8List.fromList([1, 2, 3]),
      'image/png',
    );
    final content = buildUserMessageContent(
      Message(
        groupId: 'g1',
        senderId: 'user',
        senderType: 'user',
        content: '看图',
        media: [
          MediaAttachment(
            type: 'image',
            localPath: uri,
            mimeType: 'image/png',
            fileSize: 3,
          ),
        ],
      ),
      supportsVision: true,
    ) as List<Map<String, dynamic>>;

    expect(content[1]['image_url']['url'], uri);
  });

  test('data URI text attachment is available to agent context', () async {
    final uri = encodeAttachmentDataUri(
      Uint8List.fromList(utf8.encode('# Acceptance report')),
      'text/markdown',
    );
    final enhanced = await AgentAttachmentContext.enhanceCurrentRequest(
      userRequest: '总结附件',
      media: [
        MediaAttachment(
          type: 'file',
          localPath: uri,
          fileName: 'report.md',
          mimeType: 'text/markdown',
          fileSize: 19,
        ),
      ],
    );

    expect(enhanced, contains('# Acceptance report'));
    expect(enhanced, isNot(contains('base64,')));
    expect(enhanced, contains('浏览器内存附件'));
  });
}
