import 'dart:convert';
import 'dart:collection';
import 'dart:typed_data';

import 'package:chat_group/core/models/media_attachment.dart';

class AttachmentDataUri {
  const AttachmentDataUri({required this.mimeType, required this.bytes});

  final String mimeType;
  final Uint8List bytes;
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
    final decoded = decodeAttachmentDataUri(value);
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
