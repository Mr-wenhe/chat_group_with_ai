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
    final archive = ZipDecoder().decodeBytes(bytes, verify: true);
    if (archive.length > maxArchiveEntries) {
      throw const FormatException('压缩包条目过多');
    }
    final expandedBytes = archive.files.fold<int>(
      0,
      (total, file) => total + (file.isFile ? file.size : 0),
    );
    if (expandedBytes > maxExpandedBytes) {
      throw const FormatException('压缩包展开后超过 32 MB 上限');
    }
    return archive;
  }

  static XmlDocument _xml(ArchiveFile file) {
    final bytes = file.readBytes();
    if (bytes == null) throw const FormatException('XML 内容无法读取');
    return XmlDocument.parse(utf8.decode(bytes, allowMalformed: false));
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
