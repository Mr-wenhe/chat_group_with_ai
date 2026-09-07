import 'dart:convert';
import 'dart:collection';
import 'dart:typed_data';

import 'package:chat_group/core/models/media_attachment.dart';

class AttachmentDataUri {
  const AttachmentDataUri({required this.mimeType, required this.bytes});

  final String mimeType;
  final Uint8List bytes;
}

/// Raised when a data URI would exceed a caller's decoded byte budget.
///
/// Checking the encoded payload before calling [base64Decode] is important:
/// decoding an attacker-controlled multi-megabyte string just to reject it
/// would already have defeated the memory boundary.
class AttachmentDataUriTooLargeException implements Exception {
  final String message;

  const AttachmentDataUriTooLargeException(this.message);

  @override
  String toString() => message;
}

String encodeAttachmentDataUri(Uint8List bytes, String mimeType) {
  return 'data:$mimeType;base64,${base64Encode(bytes)}';
}

MediaAttachment createDataUriAttachment({
  required List<int> bytes,
  required String fileName,
  required String mimeType,
  String type = 'file',
}) {
  final payload = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
  return MediaAttachment(
    type: type,
    localPath: encodeAttachmentDataUri(payload, mimeType),
    fileName: fileName,
    fileSize: payload.lengthInBytes,
    mimeType: mimeType,
  );
}

bool isAttachmentDataUri(String value) {
  if (!value.startsWith('data:')) return false;
  final separator = value.indexOf(',');
  if (separator <= 5) return false;
  // Keep the metadata probe bounded as well. Callers use this predicate in
  // UI/opening paths before they can reach a decoded-byte guard.
  const maxMetadataCharacters = 128;
  if (separator - 5 > maxMetadataCharacters) return false;
  final metadata = value.substring(5, separator);
  return metadata.endsWith(';base64') && metadata.length > ';base64'.length;
}

AttachmentDataUri? decodeAttachmentDataUri(String value) {
  if (!isAttachmentDataUri(value)) return null;
  final separator = value.indexOf(',');
  final metadata = value.substring(5, separator);
  final mimeType = metadata.substring(0, metadata.length - ';base64'.length);
  try {
    return AttachmentDataUri(
      mimeType: mimeType,
      bytes: base64Decode(value.substring(separator + 1)),
    );
  } on FormatException {
    return null;
  }
}

/// Decodes an inline attachment only when its encoded and decoded sizes are
/// within [maxBytes]. Invalid values still return `null`, matching
/// [decodeAttachmentDataUri].
AttachmentDataUri? decodeAttachmentDataUriBounded(
  String value, {
  required int maxBytes,
  String message = '附件超过大小上限',
}) {
  if (maxBytes < 0) {
    throw ArgumentError.value(maxBytes, 'maxBytes', 'must not be negative');
  }
  // Do not call [isAttachmentDataUri] here: it extracts the metadata
  // substring before the size check, which would let an attacker allocate a
  // huge `data:` prefix before this bounded decoder can reject it.
  if (!value.startsWith('data:')) return null;
  final separator = value.indexOf(',');
  if (separator <= 5) return null;
  // A MIME type is metadata, not content. Keep it bounded as well so a huge
  // `data:` prefix cannot force an unbounded substring before base64 decode.
  const maxMetadataCharacters = 128;
  final metadataLength = separator - 5;
  final payloadLength = value.length - separator - 1;
  final maxEncodedPayloadLength = ((maxBytes + 2) ~/ 3) * 4;
  if (metadataLength > maxMetadataCharacters ||
      payloadLength > maxEncodedPayloadLength) {
    throw AttachmentDataUriTooLargeException(message);
  }
  final metadata = value.substring(5, separator);
  const base64Suffix = ';base64';
  if (!metadata.endsWith(base64Suffix) ||
      metadata.length <= base64Suffix.length) {
    return null;
  }
  final mimeType = metadata.substring(0, metadata.length - base64Suffix.length);
  try {
    final decoded = AttachmentDataUri(
      mimeType: mimeType,
      bytes: base64Decode(value.substring(separator + 1)),
    );
    if (decoded.bytes.lengthInBytes > maxBytes) {
      throw AttachmentDataUriTooLargeException(message);
    }
    return decoded;
  } on FormatException {
    return null;
  }
}

/// Bounded LRU cache used by UI image widgets to avoid decoding the same
/// base64 payload on every rebuild. Agent/tool reads deliberately bypass it.
class AttachmentDataUriCache {
  AttachmentDataUriCache({required this.maxEntries, required this.maxBytes})
      : assert(maxEntries > 0),
        assert(maxBytes > 0);

  final int maxEntries;
  final int maxBytes;
  final LinkedHashMap<String, AttachmentDataUri> _entries = LinkedHashMap();
  int _bytes = 0;

  AttachmentDataUri? decode(String value) {
    final existing = _entries.remove(value);
    if (existing != null) {
      _entries[value] = existing;
      return existing;
    }
    final AttachmentDataUri? decoded;
    try {
      decoded = decodeAttachmentDataUriBounded(
        value,
        maxBytes: maxBytes,
        message: '图片超过大小上限',
      );
    } on AttachmentDataUriTooLargeException {
      // UI previews should degrade to the ordinary file placeholder instead
      // of throwing during build. Agent/document paths use the throwing
      // bounded decoder directly so their failure reason remains explicit.
      return null;
    }
    if (decoded == null || decoded.bytes.lengthInBytes > maxBytes) {
      return decoded;
    }
    while (_entries.isNotEmpty &&
        (_entries.length >= maxEntries ||
            _bytes + decoded.bytes.lengthInBytes > maxBytes)) {
      final oldestKey = _entries.keys.first;
      _bytes -= _entries.remove(oldestKey)!.bytes.lengthInBytes;
    }
    _entries[value] = decoded;
    _bytes += decoded.bytes.lengthInBytes;
    return decoded;
  }
}

final uiAttachmentDataUriCache = AttachmentDataUriCache(
  maxEntries: 24,
  maxBytes: 20 * 1024 * 1024,
);
