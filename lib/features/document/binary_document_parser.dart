import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';
import 'package:xml/xml.dart';

class BinaryDocumentSection {
  final String text;
  final int? page;
  final int? paragraph;
  final String? sheet;
  final int? rowStart;
  final int? rowEnd;

  const BinaryDocumentSection({
    required this.text,
    this.page,
    this.paragraph,
    this.sheet,
    this.rowStart,
    this.rowEnd,
  });
}

/// Pure-Dart parsers for the binary formats admitted by phase 06C.
class BinaryDocumentParser {
  static const int maxPdfPages = 80;
  static const int maxArchiveEntries = 2048;
  static const int maxExpandedBytes = 32 * 1024 * 1024;
  static const int maxArchiveEntryReadBytes = 8 * 1024 * 1024;
  static const int maxExtractedChars = 1024 * 1024;
  static const int maxSpreadsheetRows = 10000;
  static const int _maxSectionChars = 1200;

  static List<BinaryDocumentSection> parse(
    String format,
    Uint8List bytes,
  ) =>
      switch (format) {
        'pdf' => _parsePdf(bytes),
        'docx' => _parseDocx(bytes),
        'xlsx' => _parseXlsx(bytes),
        _ => throw const FormatException('不支持的二进制文档格式'),
      };

  static List<BinaryDocumentSection> _parsePdf(Uint8List bytes) {
    if (bytes.length < 5 || ascii.decode(bytes.sublist(0, 5)) != '%PDF-') {
      throw const FormatException('PDF 文件签名无效');
    }
    final document = PdfDocument(inputBytes: bytes);
    try {
      final pageCount = document.pages.count;
      if (pageCount > maxPdfPages) {
        throw const FormatException('PDF 超过 80 页解析上限');
      }
      final extractor = PdfTextExtractor(document);
      final result = <BinaryDocumentSection>[];
      var extractedChars = 0;
      for (var page = 0; page < pageCount; page++) {
        final text = extractor
            .extractText(startPageIndex: page, endPageIndex: page)
            .trim();
        if (text.isEmpty) continue;
        extractedChars += text.length;
        _checkExtractedSize(extractedChars);
        result.add(BinaryDocumentSection(text: text, page: page + 1));
      }
      return result;
    } finally {
      document.dispose();
    }
  }

  static List<BinaryDocumentSection> _parseDocx(Uint8List bytes) {
    final archive = _openOfficeArchive(bytes);
    final documentFile = archive.find('word/document.xml');
    if (documentFile == null) {
      throw const FormatException('DOCX 缺少 word/document.xml');
    }
    final document = _xml(documentFile);
    final result = <BinaryDocumentSection>[];
    var extractedChars = 0;
    var paragraph = 0;
    for (final element in _elements(document, 'p')) {
      paragraph++;
      final text = _textContent(element).trim();
      if (text.isEmpty) continue;
      extractedChars += text.length;
      _checkExtractedSize(extractedChars);
      result.add(BinaryDocumentSection(
        text: text,
        paragraph: paragraph,
      ));
    }
    return result;
  }

  static List<BinaryDocumentSection> _parseXlsx(Uint8List bytes) {
    final archive = _openOfficeArchive(bytes);
    final workbookFile = archive.find('xl/workbook.xml');
    if (workbookFile == null) {
      throw const FormatException('XLSX 缺少 xl/workbook.xml');
    }
    final workbook = _xml(workbookFile);
    final relationships = _workbookRelationships(archive);
    final sharedStrings = _sharedStrings(archive);
    final sheets = _elements(workbook, 'sheet').toList(growable: false);
    final result = <BinaryDocumentSection>[];
    var extractedChars = 0;
    var totalRows = 0;

    for (var sheetIndex = 0; sheetIndex < sheets.length; sheetIndex++) {
      final sheetElement = sheets[sheetIndex];
      final sheetName =
          sheetElement.getAttribute('name') ?? '工作表 ${sheetIndex + 1}';
      final relationshipId = sheetElement.attributes
          .where((item) => item.name.local == 'id')
          .map((item) => item.value)
          .firstOrNull;
      final path = relationshipId == null
          ? 'xl/worksheets/sheet${sheetIndex + 1}.xml'
          : relationships[relationshipId];
      final sheetFile = path == null ? null : archive.find(path);
      if (sheetFile == null) continue;
      final sheet = _xml(sheetFile);
      final rows = _elements(sheet, 'row');
      var batch = <String>[];
      var batchChars = 0;
      var batchStart = 0;
      var batchEnd = 0;

      void flush() {
        if (batch.isEmpty) return;
        result.add(BinaryDocumentSection(
          text: batch.join('\n'),
          sheet: sheetName,
          rowStart: batchStart,
          rowEnd: batchEnd,
        ));
        batch = [];
        batchChars = 0;
      }

      for (final row in rows) {
        totalRows++;
        if (totalRows > maxSpreadsheetRows) {
          throw const FormatException('XLSX 超过 10000 行解析上限');
        }
        final rowNumber =
            int.tryParse(row.getAttribute('r') ?? '') ?? totalRows;
        final cells = <String>[];
        for (final cell in _elements(row, 'c')) {
          final value = _cellValue(cell, sharedStrings);
          if (value.isEmpty) continue;
          cells.add('${cell.getAttribute('r') ?? ''}: $value');
        }
        if (cells.isEmpty) continue;
        final rowText = cells.join(' | ');
        extractedChars += rowText.length;
        _checkExtractedSize(extractedChars);
        if (batch.isNotEmpty &&
            batchChars + rowText.length + 1 > _maxSectionChars) {
          flush();
        }
        batchStart = batch.isEmpty ? rowNumber : batchStart;
        batchEnd = rowNumber;
        batch.add(rowText);
        batchChars += rowText.length + 1;
      }
      flush();
    }
    return result;
  }

  static Archive _openOfficeArchive(Uint8List bytes) {
    if (bytes.length < 4 || bytes[0] != 0x50 || bytes[1] != 0x4b) {
      throw const FormatException('Open XML 文件签名无效');
    }
    // Inspect the central directory before handing bytes to archive. The
    // package eagerly expands Unix symlink entries while decoding metadata;
    // rejecting those entries here prevents that path from bypassing the
    // bounded output stream below. The same preflight also catches obviously
    // invalid declared sizes before any decompressor is started.
    _preflightArchiveDirectory(bytes);
    // archive 4.0.x currently comments out its verify=true CRC branch. Decode
    // metadata first, then verify only the bounded entries we actually read.
    final archive = ZipDecoder().decodeBytes(bytes, verify: false);
    if (archive.length > maxArchiveEntries) {
      throw const FormatException('压缩包条目过多');
    }
    var expandedBytes = 0;
    for (final file in archive.files) {
      if (!file.isFile) continue;
      if (file.size < 0 || file.size > maxExpandedBytes) {
        throw const FormatException('压缩包条目展开后超过 32 MB 上限');
      }
      expandedBytes += file.size;
      if (expandedBytes > maxExpandedBytes) {
        throw const FormatException('压缩包展开后超过 32 MB 上限');
      }
    }
    if (expandedBytes > maxExpandedBytes) {
      throw const FormatException('压缩包展开后超过 32 MB 上限');
    }
    return archive;
  }

  static void _preflightArchiveDirectory(Uint8List bytes) {
    final directory = ZipDirectory();
    directory.read(InputMemoryStream(bytes));
    if (directory.fileHeaders.length > maxArchiveEntries) {
      throw const FormatException('压缩包条目过多');
    }
    var expandedBytes = 0;
    for (final header in directory.fileHeaders) {
      final file = header.file;
      if (file == null) continue;
      if (_isUnixSymlink(header)) {
        // DOCX/XLSX never need archive links. Rejecting them also avoids the
        // archive package's eager, unbounded symlink read during decode.
        throw const FormatException('压缩包不支持符号链接条目');
      }
      final uncompressed = header.uncompressedSize;
      final compressed = header.compressedSize;
      if (uncompressed < 0 ||
          uncompressed > maxExpandedBytes ||
          compressed < 0 ||
          compressed > bytes.length) {
        throw const FormatException('压缩包条目展开后超过 32 MB 上限');
      }
      expandedBytes += uncompressed;
      if (expandedBytes > maxExpandedBytes) {
        throw const FormatException('压缩包展开后超过 32 MB 上限');
      }
    }
  }

  static bool _isUnixSymlink(ZipFileHeader header) {
    final madeByUnix = header.versionMadeBy >> 8 == 3;
    final fileType = (header.externalFileAttributes >> 16) & 0xf000;
    return madeByUnix && fileType == 0xa000;
  }

  static XmlDocument _xml(ArchiveFile file) {
    final bytes = _readArchiveBytes(file, maxArchiveEntryReadBytes);
    return XmlDocument.parse(utf8.decode(bytes, allowMalformed: false));
  }

  /// Decompresses an entry into a bounded sink. Calling ArchiveFile.readBytes
  /// would first materialize the complete expansion, making the ZIP header's
  /// declared size the only practical guard against a decompression bomb.
  static Uint8List _readArchiveBytes(ArchiveFile file, int limit) {
    if (!file.isFile || file.size < 0 || file.size > limit) {
      throw const FormatException('压缩包条目超过读取上限');
    }
    final output = _BoundedArchiveOutputStream(limit);
    file.decompress(output);
    final bytes = output.toBytes();
    if (file.crc32 != null && getCrc32(bytes) != file.crc32) {
      throw const FormatException('压缩包条目校验失败');
    }
    return bytes;
  }

  static Iterable<XmlElement> _elements(XmlNode node, String localName) =>
      node.descendants
          .whereType<XmlElement>()
          .where((item) => item.name.local == localName);

  static String _textContent(XmlElement element) {
    final buffer = StringBuffer();
    for (final node in element.descendants.whereType<XmlElement>()) {
      switch (node.name.local) {
        case 't':
          buffer.write(node.innerText);
          break;
        case 'tab':
          buffer.write('\t');
          break;
        case 'br':
          buffer.write('\n');
          break;
      }
    }
    return buffer.toString();
  }

  static Map<String, String> _workbookRelationships(Archive archive) {
    final file = archive.find('xl/_rels/workbook.xml.rels');
    if (file == null) return const {};
    final result = <String, String>{};
    for (final relationship in _elements(_xml(file), 'Relationship')) {
      final id = relationship.getAttribute('Id');
      final target = relationship.getAttribute('Target');
      if (id == null || target == null) continue;
      result[id] = _normalizeArchivePath(
        target.startsWith('/') ? target.substring(1) : 'xl/$target',
      );
    }
    return result;
  }

  static List<String> _sharedStrings(Archive archive) {
    final file = archive.find('xl/sharedStrings.xml');
    if (file == null) return const [];
    return _elements(_xml(file), 'si')
        .map(_textContent)
        .toList(growable: false);
  }

  static String _cellValue(XmlElement cell, List<String> sharedStrings) {
    final type = cell.getAttribute('t');
    if (type == 'inlineStr') return _textContent(cell).trim();
    final value =
        _elements(cell, 'v').map((item) => item.innerText).firstOrNull;
    if (value == null) return '';
    if (type == 's') {
      final index = int.tryParse(value);
      if (index == null || index < 0 || index >= sharedStrings.length) {
        throw const FormatException('XLSX 共享字符串索引无效');
      }
      return sharedStrings[index];
    }
    if (type == 'b') return value == '1' ? 'TRUE' : 'FALSE';
    return value;
  }

  static String _normalizeArchivePath(String path) {
    final parts = <String>[];
    for (final part in path.replaceAll('\\', '/').split('/')) {
      if (part.isEmpty || part == '.') continue;
      if (part == '..') {
        if (parts.isEmpty) throw const FormatException('XLSX 关系路径越界');
        parts.removeLast();
      } else {
        parts.add(part);
      }
    }
    return parts.join('/');
  }

  static void _checkExtractedSize(int chars) {
    if (chars > maxExtractedChars) {
      throw const FormatException('提取文本超过 1 MB 上限');
    }
  }
}

/// Minimal streaming sink used by [BinaryDocumentParser] to enforce an
/// actual post-decompression byte limit without allocating an untrusted size.
class _BoundedArchiveOutputStream extends OutputStream {
  final int _limit;
  final BytesBuilder _chunks = BytesBuilder(copy: false);
  var _length = 0;

  _BoundedArchiveOutputStream(this._limit)
      : super(byteOrder: ByteOrder.littleEndian);

  @override
  int get length => _length;

  @override
  void clear() {
    _chunks.clear();
    _length = 0;
  }

  @override
  void flush() {}

  @override
  void writeByte(int value) => writeBytes(<int>[value]);

  @override
  void writeBytes(List<int> bytes, {int? length}) {
    final count = length ?? bytes.length;
    if (count < 0 || count > bytes.length || _length + count > _limit) {
      throw const FormatException('压缩包实际展开内容超过读取上限');
    }
    if (count == 0) return;
    _chunks.add(bytes is Uint8List
        ? bytes.sublist(0, count)
        : bytes.take(count).toList());
    _length += count;
  }

  @override
  void writeStream(InputStream stream) {
    while (!stream.isEOS) {
      final count = stream.length.clamp(0, 8192).toInt();
      if (count == 0) break;
      writeBytes(stream.readBytes(count).toUint8List());
    }
  }

  @override
  Uint8List subset(int start, [int? end]) => toBytes().sublist(start, end);

  Uint8List toBytes() => _chunks.takeBytes();
}
