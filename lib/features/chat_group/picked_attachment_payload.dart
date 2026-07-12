import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

const int maxWebAttachmentBytes = 10 * 1024 * 1024;
const int maxWebAttachmentTotalBytes = 10 * 1024 * 1024;

bool isWithinWebAttachmentLimit(int byteLength) =>
    byteLength <= maxWebAttachmentBytes;

bool canAddWebAttachment({
  required int existingBytes,
  required int newBytes,
}) =>
    isWithinWebAttachmentLimit(newBytes) &&
    existingBytes + newBytes <= maxWebAttachmentTotalBytes;

sealed class PickedAttachmentPayload {
  const PickedAttachmentPayload(this.fileName);

  final String fileName;
}

class PickedAttachmentBytes extends PickedAttachmentPayload {
  const PickedAttachmentBytes({
    required String fileName,
    required this.bytes,
  }) : super(fileName);

  final Uint8List bytes;
}

class PickedAttachmentPath extends PickedAttachmentPayload {
  const PickedAttachmentPath({
    required String fileName,
    required this.path,
  }) : super(fileName);

  final String path;
}

PickedAttachmentPayload? resolvePickedAttachmentPayload(
  PlatformFile file, {
  required bool isWeb,
}) {
  if (isWeb) {
    final bytes = file.bytes;
    if (bytes == null || bytes.isEmpty) return null;
    return PickedAttachmentBytes(fileName: file.name, bytes: bytes);
  }
  final path = file.path?.trim() ?? '';
  if (path.isEmpty) return null;
  return PickedAttachmentPath(fileName: file.name, path: path);
}
