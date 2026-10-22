import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:html/parser.dart' as html;
import 'package:html/dom.dart';
import 'package:path/path.dart' as p;

import 'document_font_environment.dart';

class AttachmentPreviewException implements Exception {
  const AttachmentPreviewException(this.message, {this.code});
  final String message;
  final String? code;
}

class PreviewSheet {
  const PreviewSheet(this.name, this.html);
  final String name;
  final String html;
}

/// Only images produced inside this conversion directory may enter the viewer.
Future<List<PreviewSheet>> loadPreviewSheets(File converted) async {
  final document = html.parse(await readPreviewText(converted));
  final root = await converted.parent.resolveSymbolicLinks();
  var remaining = OfficePreviewSession.maxHtmlBytes;
  for (final image in document.querySelectorAll('img')) {
    final src = image.attributes['src'] ?? '';
    final uri = Uri.tryParse(src);
    if (uri == null || uri.hasScheme || uri.hasAuthority) continue;
    final file = File(p.join(root, Uri.decodeComponent(uri.path)));
    if (!await file.exists()) continue;
    final path = await file.resolveSymbolicLinks();
    if (!p.isWithin(root, path)) continue;
    final mime = const {
      '.png': 'image/png',
      '.jpg': 'image/jpeg',
      '.jpeg': 'image/jpeg',
      '.gif': 'image/gif'
    }[p.extension(path).toLowerCase()];
    if (mime == null || await file.length() > remaining) continue;
    final bytes = await file.readAsBytes();
    remaining -= bytes.length;
    image.attributes['src'] = 'data:$mime;base64,${base64Encode(bytes)}';
  }
  return parsePreviewSheets(document.outerHtml);
}

/// A private conversion directory per preview; originals are never written.
class OfficePreviewSession {
  static const maxInputBytes = 100 * 1024 * 1024;
  static const maxHtmlBytes = 8 * 1024 * 1024;
  static const conversionTimeout = Duration(seconds: 60);
  Directory? _directory;
  Process? _process;
  bool _closed = false;

  Future<File> convert(File source, {required bool spreadsheet}) async {
    final office = findOfficeExecutable();
    if (office == null) {
      throw const AttachmentPreviewException(
          'Office 预览需要本地 LibreOffice，可点击下方按钮下载并自动安装，无需安装 Microsoft Office。',
          code: 'officeMissing');
    }
    if (await source.length() > maxInputBytes) {
      throw const AttachmentPreviewException('文件超过 100 MB 预览上限，请用系统应用打开。');
    }
    final directory =
        await Directory.systemTemp.createTemp('chat-group-preview-');
    _directory = directory;
    try {
      _ensureOpen();
      final input = await source
          .copy(p.join(directory.path, 'source${p.extension(source.path)}'));
      final profile = Directory(p.join(directory.path, 'profile', 'user'));
      await profile.create(recursive: true);
      // A fresh profile never inherits trusted macro locations or link-update preferences.
      await File(p.join(profile.path, 'registrymodifications.xcu')).writeAsString(
          '''<?xml version="1.0"?><oor:items xmlns:oor="http://openoffice.org/2001/registry"><item oor:path="/org.openoffice.Office.Common/Security/Scripting"><prop oor:name="MacroSecurityLevel" oor:op="fuse"><value>3</value></prop></item><item oor:path="/org.openoffice.Office.Calc/Content/Update"><prop oor:name="Link" oor:op="fuse"><value>1</value></prop></item><item oor:path="/org.openoffice.Office.Writer/Content/Update"><prop oor:name="Link" oor:op="fuse"><value>2</value></prop></item></oor:items>''');
      _ensureOpen();
      final exit = await _runConversion(office, directory, input, spreadsheet);
      _ensureOpen();
      final result = File(
          p.join(directory.path, spreadsheet ? 'source.html' : 'source.pdf'));
      if (exit != 0 || !await result.exists() || await result.length() == 0) {
        throw const AttachmentPreviewException('文档转换失败，文件可能已损坏、加密或不受本地转换器支持。');
      }
      return result;
    } on AttachmentPreviewException {
      rethrow;
    } on Object {
      throw const AttachmentPreviewException(
          '无法转换此文件，请检查文件权限及 LibreOffice 安装。');
    }
  }

  Future<int> _runConversion(
      String office, Directory directory, File input, bool spreadsheet) async {
    final process = await Process.start(
        office,
        [
          '-env:UserInstallation=${Uri.directory(p.join(directory.path, 'profile'))}',
          '--headless',
          '--nologo',
          '--nodefault',
          '--nofirststartwizard',
          '--convert-to',
          spreadsheet ? 'html:HTML (StarCalc)' : 'pdf',
          '--outdir',
          directory.path,
          input.path,
        ],
        runInShell: false,
        environment: documentFontEnvironment(fallbackDirectory: directory));
    _process = process;
    if (_closed) process.kill();
    // Drain both pipes without retaining provider/tool output or local paths.
    final drained = Future.wait(
        [process.stdout.drain<void>(), process.stderr.drain<void>()]);
    final exit =
        await process.exitCode.timeout(conversionTimeout, onTimeout: () {
      process.kill();
      throw const AttachmentPreviewException('文档转换超过 60 秒，已停止。请用系统应用打开。');
    });
    await drained;
    _process = null;
    return exit;
  }

  void _ensureOpen() {
    if (_closed) throw const AttachmentPreviewException('预览已关闭。');
  }

  Future<void> close() async {
    _closed = true;
    final process = _process;
    if (process != null) {
      process.kill();
      await process.exitCode;
    }
    final directory = _directory;
    if (directory != null && await directory.exists()) {
      try {
        await directory.delete(recursive: true);
      } on FileSystemException {
        /* Conversion may still be releasing a file on Windows. */
      }
    }
  }

  static String? findOfficeExecutable() {
    final roots = (Platform.environment['PATH'] ?? '')
        .split(Platform.isWindows ? ';' : ':');
    final candidates = <String>[
      if (Platform.isMacOS)
        '/Applications/LibreOffice.app/Contents/MacOS/soffice',
      if (Platform.isMacOS && Platform.environment['HOME'] != null)
        p.join(Platform.environment['HOME']!, 'Applications', 'LibreOffice.app',
            'Contents', 'MacOS', 'soffice'),
      if (Platform.isWindows) ...[
        for (final key in ['ProgramFiles', 'ProgramFiles(x86)', 'LOCALAPPDATA'])
          if (Platform.environment[key] != null)
            p.join(Platform.environment[key]!, 'LibreOffice', 'program',
                'soffice.exe'),
      ],
      for (final root in roots.where((r) => r.isNotEmpty))
        p.join(root, Platform.isWindows ? 'soffice.exe' : 'soffice'),
    ];
    return candidates.where((path) => File(path).existsSync()).firstOrNull;
  }
}

/// LibreOffice's Calc HTML export contains one top-level table per worksheet.
List<PreviewSheet> parsePreviewSheets(String source) {
  final document = html.parse(source);
  final styles =
      document.querySelectorAll('style').map((e) => e.outerHtml).join();
  final tables = document.querySelectorAll('table').where((table) {
    Element? parent = table.parent;
    while (parent != null) {
      if (parent.localName == 'table') return false;
      parent = parent.parent;
    }
    return true;
  });
  final sheets = <PreviewSheet>[];
  for (final table in tables) {
    final anchor =
        table.querySelector('caption a') ?? table.querySelector('a[name]');
    final name =
        table.previousElementSibling?.querySelector('em')?.text.trim() ??
            anchor?.attributes['name'] ??
            table.querySelector('caption')?.text.trim();
    sheets.add(PreviewSheet(
        name?.isNotEmpty == true ? name! : '工作表 ${sheets.length + 1}',
        '$styles${table.outerHtml}'));
  }
  if (sheets.isEmpty) {
    throw const AttachmentPreviewException('表格转换结果没有可显示的工作表。');
  }
  return sheets;
}

Future<Uint8List> readPreviewBytes(File file, {required int limit}) async {
  final bytes = BytesBuilder(copy: false);
  await for (final chunk in file.openRead(0, limit + 1)) {
    bytes.add(chunk);
    if (bytes.length > limit) {
      throw const AttachmentPreviewException('文件超过预览大小上限，请用系统应用打开。');
    }
  }
  return bytes.takeBytes();
}

Future<String> readPreviewText(File file,
    {int limit = OfficePreviewSession.maxHtmlBytes}) async {
  final bytes = await readPreviewBytes(file, limit: limit);
  if (bytes.length >= 2 &&
      (bytes[0] == 0xff && bytes[1] == 0xfe ||
          bytes[0] == 0xfe && bytes[1] == 0xff)) {
    final little = bytes[0] == 0xff;
    if (bytes.length.isOdd) {
      throw const AttachmentPreviewException('UTF-16 文本不完整，请检查文件内容。');
    }
    return String.fromCharCodes([
      for (var i = 2; i + 1 < bytes.length; i += 2)
        little ? bytes[i] | bytes[i + 1] << 8 : bytes[i] << 8 | bytes[i + 1]
    ]);
  }
  try {
    return utf8.decode(bytes).replaceFirst('\uFEFF', '');
  } on FormatException {
    throw const AttachmentPreviewException('文本编码无法识别，请转换为 UTF-8 或 UTF-16 后预览。');
  }
}
