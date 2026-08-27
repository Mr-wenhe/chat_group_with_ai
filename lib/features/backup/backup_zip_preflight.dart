import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'backup_models.dart';

/// Performs bounded ZIP central-directory validation before `archive` creates
/// an in-memory [Archive]. The third-party decoder has no entry-count limit and
/// reads Unix symlink payloads while decoding, so policy checks must happen at
/// the file boundary first.
class ZipPreflight {
  static const int maxCentralDirectoryBytes = 64 * 1024 * 1024;
  static const int maxEntryNameBytes = 4096;
  static const int maxEntryExtraBytes = 64 * 1024;
  static const int maxEntryCommentBytes = 64 * 1024;

  static const int _eocdSignature = 0x06054b50;
  static const int _zip64LocatorSignature = 0x07064b50;
  static const int _zip64EocdSignature = 0x06064b50;
  static const int _centralHeaderSignature = 0x02014b50;
  static const int _centralHeaderBytes = 46;

  const ZipPreflight._();

  static Future<void> validate(
    File package, {
    required int maxEntries,
  }) async {
    if (maxEntries <= 0) {
      throw const BackupException('压缩包条目限制无效');
    }
    final length = await package.length();
    if (length < 22) {
      throw const BackupException('压缩包中央目录无效');
    }

    final input = await package.open();
    try {
      final eocdOffset = await _findEndOfCentralDirectory(input, length);
      final directory = await _readDirectoryBounds(input, length, eocdOffset);
      if (directory.entryCount > maxEntries) {
        throw const BackupException('压缩包条目数量超出限制');
      }
      if (directory.size > maxCentralDirectoryBytes) {
        throw const BackupException('压缩包中央目录过大');
      }
      if (directory.offset < 0 ||
          directory.offset > length ||
          directory.size > length - directory.offset) {
        throw const BackupException('压缩包中央目录范围无效');
      }
      await _scanDirectory(input, directory, maxEntries);
    } on BackupException {
      rethrow;
    } catch (_) {
      throw const BackupException('压缩包中央目录读取失败');
    } finally {
      await input.close();
    }
  }

  static Future<int> _findEndOfCentralDirectory(
    RandomAccessFile input,
    int fileLength,
  ) async {
    final tailLength = math.min(fileLength, 22 + 0xffff);
    await input.setPosition(fileLength - tailLength);
    final tail = await _readExactly(input, tailLength);
    for (var index = tail.length - 22; index >= 0; index--) {
      if (_u32(tail, index) != _eocdSignature) continue;
      final commentLength = _u16(tail, index + 20);
      // The EOCD must be the final record. Requiring an exact end position
      // avoids mistaking a matching byte sequence inside a ZIP comment for
      // the real directory terminator.
      if (index + 22 + commentLength == tail.length) {
        return fileLength - tailLength + index;
      }
    }
    throw const BackupException('压缩包缺少中央目录结束记录');
  }

  static Future<_DirectoryBounds> _readDirectoryBounds(
    RandomAccessFile input,
    int fileLength,
    int eocdOffset,
  ) async {
    await input.setPosition(eocdOffset);
    final eocd = await _readExactly(input, 22);
    if (_u32(eocd, 0) != _eocdSignature ||
        _u16(eocd, 4) != 0 ||
        _u16(eocd, 6) != 0) {
      throw const BackupException('压缩包不支持多磁盘格式');
    }

    var entryCount = _u16(eocd, 10);
    var size = _u32(eocd, 12);
    var offset = _u32(eocd, 16);
    if (entryCount != 0xffff && size != 0xffffffff && offset != 0xffffffff) {
      return _DirectoryBounds(entryCount, size, offset);
    }

    final locatorOffset = eocdOffset - 20;
    if (locatorOffset < 0 || locatorOffset + 20 > fileLength) {
      throw const BackupException('ZIP64 中央目录定位记录无效');
    }
    await input.setPosition(locatorOffset);
    final locator = await _readExactly(input, 20);
    if (_u32(locator, 0) != _zip64LocatorSignature) {
      throw const BackupException('ZIP64 中央目录定位记录缺失');
    }
    final zip64Offset = _u64(locator, 8);
    if (zip64Offset < 0 || zip64Offset > fileLength - 56) {
      throw const BackupException('ZIP64 中央目录偏移无效');
    }
    await input.setPosition(zip64Offset);
    final zip64 = await _readExactly(input, 56);
    final zip64RecordSize = _u64(zip64, 4);
    if (_u32(zip64, 0) != _zip64EocdSignature ||
        zip64RecordSize < 44 ||
        zip64RecordSize > fileLength - zip64Offset - 12) {
      throw const BackupException('ZIP64 中央目录结束记录无效');
    }
    entryCount = _u64(zip64, 32);
    size = _u64(zip64, 40);
    offset = _u64(zip64, 48);
    return _DirectoryBounds(entryCount, size, offset);
  }

  static Future<void> _scanDirectory(
    RandomAccessFile input,
    _DirectoryBounds directory,
    int maxEntries,
  ) async {
    final end = directory.offset + directory.size;
    var position = directory.offset;
    var count = 0;
    final names = <String>{};
    await input.setPosition(position);
    while (position < end) {
      if (++count > maxEntries) {
        throw const BackupException('压缩包条目数量超出限制');
      }
      if (end - position < _centralHeaderBytes) {
        throw const BackupException('压缩包中央目录记录不完整');
      }
      final header = await _readExactly(input, _centralHeaderBytes);
      position += _centralHeaderBytes;
      if (_u32(header, 0) != _centralHeaderSignature) {
        throw const BackupException('压缩包中央目录记录无效');
      }

      final nameLength = _u16(header, 28);
      final extraLength = _u16(header, 30);
      final commentLength = _u16(header, 32);
      if (nameLength > maxEntryNameBytes ||
          extraLength > maxEntryExtraBytes ||
          commentLength > maxEntryCommentBytes) {
        throw const BackupException('压缩包条目元数据过大');
      }
      final variableLength = nameLength + extraLength + commentLength;
      if (variableLength > end - position) {
        throw const BackupException('压缩包中央目录记录越界');
      }
      final variable = await _readExactly(input, variableLength);
      position += variableLength;
      final nameBytes = variable.sublist(0, nameLength);
      final name = utf8.decode(nameBytes, allowMalformed: true);
      if (!names.add(name)) {
        throw BackupException('压缩包包含重复条目：$name');
      }

      final versionMadeBy = _u16(header, 4);
      final externalAttributes = _u32(header, 38);
      final unixMode = externalAttributes >> 16;
      if (versionMadeBy >> 8 == 3 && (unixMode & 0xf000) == 0xa000) {
        throw BackupException('压缩包包含不支持的符号链接：$name');
      }
    }
    if (position != end || count != directory.entryCount) {
      throw const BackupException('压缩包中央目录条目数量不一致');
    }
  }

  static Future<Uint8List> _readExactly(
    RandomAccessFile input,
    int length,
  ) async {
    if (length == 0) return Uint8List(0);
    final output = BytesBuilder(copy: false);
    var remaining = length;
    while (remaining > 0) {
      final chunk = await input.read(remaining);
      if (chunk.isEmpty) {
        throw const BackupException('压缩包数据不完整');
      }
      output.add(chunk);
      remaining -= chunk.length;
    }
    return output.takeBytes();
  }

  static int _u16(Uint8List bytes, int offset) =>
      bytes[offset] | (bytes[offset + 1] << 8);

  static int _u32(Uint8List bytes, int offset) =>
      bytes[offset] |
      (bytes[offset + 1] << 8) |
      (bytes[offset + 2] << 16) |
      (bytes[offset + 3] << 24);

  static int _u64(Uint8List bytes, int offset) {
    var value = 0;
    for (var index = 7; index >= 0; index--) {
      value = value * 256 + bytes[offset + index];
    }
    return value;
  }
}

class _DirectoryBounds {
  final int entryCount;
  final int size;
  final int offset;

  const _DirectoryBounds(this.entryCount, this.size, this.offset);
}
