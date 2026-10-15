import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'binary_document_parser.dart';

class DocumentPageRendererException implements Exception {
  final String code;
  final String message;
  const DocumentPageRendererException(this.code, this.message);
  @override
  String toString() => message;
}

class RenderedDocumentPage {
  final Uint8List png;
  final Map<String, dynamic> manifest;
  const RenderedDocumentPage({required this.png, required this.manifest});
}

/// Uses the installed LibreOffice and Poppler tools; it never executes document macros.
class DocumentPageRenderer {
  static const int maxPages = 80;
  static const int maxPngBytes = 5 * 1024 * 1024;
  static const int scaleTo = 1600;
  static const Duration processLimit = Duration(seconds: 45);

  const DocumentPageRenderer();

  Future<RenderedDocumentPage> render({
    required File source,
    required int page,
    required bool Function() isCancelled,
  }) async {
    final sourceBytes = await _readBounded(source, 10 * 1024 * 1024);
    if (sourceBytes.isEmpty || sourceBytes.length > 10 * 1024 * 1024) {
      throw const DocumentPageRendererException(
          'documentTooLarge', '文档超过 10 MB 渲染上限。');
    }
    final extension = p.extension(source.path).toLowerCase();
    if (!const {'.docx', '.pdf'}.contains(extension)) {
      throw const DocumentPageRendererException(
          'unsupportedMedia', '页图渲染仅支持 DOCX 和 PDF。');
    }
    final inputDigest = sha256.convert(sourceBytes).toString();
    final poppler = _findExecutable('pdftoppm');
    final pdfinfo = _findExecutable('pdfinfo');
    if (poppler == null || pdfinfo == null) {
      throw const DocumentPageRendererException(
          'rendererMissing', '缺少 Poppler 的 pdftoppm 或 pdfinfo。');
    }
    final popplerVersion = await _version(poppler, ['-v'], isCancelled);
    final pdfinfoVersion = await _version(pdfinfo, ['-v'], isCancelled);
    final temp = await Directory.systemTemp.createTemp('chat-group-document-');
    try {
      if (isCancelled()) {
        throw const DocumentPageRendererException('cancelled', '文档渲染已停止。');
      }
      final input = File(p.join(temp.path, 'source$extension'));
      await input.writeAsBytes(sourceBytes, flush: true);
      late final File pdf;
      String? officeVersion;
      if (extension == '.pdf') {
        pdf = input;
      } else {
        final office = _findExecutable('soffice');
        if (office == null) {
          throw const DocumentPageRendererException(
              'rendererMissing', '缺少 LibreOffice soffice DOCX 渲染器。');
        }
        officeVersion = await _version(office, ['--version'], isCancelled);
        final profile = Directory(p.join(temp.path, 'profile'));
        await profile.create();
        final result = await _run(
            office,
            [
              '--headless',
              '--nologo',
              '--nodefault',
              '--nofirststartwizard',
              '-env:UserInstallation=${Uri.directory(profile.path)}',
              '--convert-to',
              'pdf:writer_pdf_Export',
              '--outdir',
              temp.path,
              input.path,
            ],
            isCancelled);
        if (result.exitCode != 0) {
          throw DocumentPageRendererException(
              'renderFailed', _safeProcessError(result.stderr));
        }
        pdf = File(p.join(temp.path, 'source.pdf'));
      }
      if (isCancelled()) {
        throw const DocumentPageRendererException('cancelled', '文档渲染已停止。');
      }
      if (!await pdf.exists() || await pdf.length() == 0) {
        throw const DocumentPageRendererException(
            'renderFailed', '渲染器没有生成 PDF。');
      }
      final info = await _run(pdfinfo, [pdf.path], isCancelled);
      if (info.exitCode != 0) {
        throw DocumentPageRendererException(
            'renderFailed', _safeProcessError(info.stderr));
      }
      final count = _pageCount(info.stdout);
      if (count == null ||
          count < 1 ||
          count > maxPages ||
          page < 1 ||
          page > count) {
        throw DocumentPageRendererException(
            'invalidPage', '页码超出文档范围（页数：${count ?? '未知'}）。');
      }
      final afterDigest = sha256
          .convert(await _readBounded(source, 10 * 1024 * 1024))
          .toString();
      if (afterDigest != inputDigest) {
        throw const DocumentPageRendererException(
            'sourceChanged', '渲染期间源文档发生变化。');
      }
      final outputBase = p.join(temp.path, 'page');
      final rendered = await _run(
          poppler,
          [
            '-f',
            '$page',
            '-l',
            '$page',
            '-singlefile',
            '-png',
            '-scale-to',
            '$scaleTo',
            pdf.path,
            outputBase,
          ],
          isCancelled);
      if (rendered.exitCode != 0) {
        throw DocumentPageRendererException(
            'renderFailed', _safeProcessError(rendered.stderr));
      }
      final image = File('$outputBase.png');
      if (!await image.exists()) {
        throw const DocumentPageRendererException(
            'renderFailed', 'Poppler 没有生成目标页图。');
      }
      final png = await image.readAsBytes();
      if (png.isEmpty || png.length > maxPngBytes) {
        throw const DocumentPageRendererException(
            'imageTooLarge', '页图超过当前模型的单图上限。');
      }
      final fonts =
          await _fontCoverage(extension, sourceBytes, pdf, page, isCancelled);
      return RenderedDocumentPage(
        png: Uint8List.fromList(png),
        manifest: {
          'schemaVersion': 1,
          'fileName': p.basename(source.path),
          'documentSha256': inputDigest,
          'format': extension.substring(1),
          'pageNumber': page,
          'pageCount': count,
          'imageWidthLimit': scaleTo,
          'imageSha256': sha256.convert(png).toString(),
          'renderEngine': extension == '.docx' ? 'LibreOffice' : 'Poppler',
          if (officeVersion != null) 'libreOfficeVersion': officeVersion,
          'popplerVersion': popplerVersion,
          'pdfinfoVersion': pdfinfoVersion,
          'fontCoverage': fonts,
        },
      );
    } finally {
      if (await temp.exists()) await temp.delete(recursive: true);
    }
  }

  Future<Map<String, dynamic>> _fontCoverage(
    String extension,
    Uint8List sourceBytes,
    File pdf,
    int page,
    bool Function() isCancelled,
  ) async {
    final requested = extension == '.docx'
        ? BinaryDocumentParser.declaredDocxFonts(sourceBytes)
        : const <String>[];
    final pdffonts = _findExecutable('pdffonts');
    final pdftotext = _findExecutable('pdftotext');
    final matcher = _findExecutable('fc-match');
    if (pdffonts == null || pdftotext == null || matcher == null) {
      return {
        'status': 'unverified',
        'sourceFonts': requested,
        'resolvedFonts': const [],
        'reason': [
          if (pdffonts == null) 'pdffonts missing',
          if (pdftotext == null) 'pdftotext missing',
          if (matcher == null) 'fc-match missing',
        ].join(', '),
      };
    }
    final result = await _run(
        pdffonts, ['-f', '$page', '-l', '$page', pdf.path], isCancelled);
    if (result.exitCode != 0) {
      return {
        'status': 'unverified',
        'sourceFonts': requested,
        'resolvedFonts': const [],
        'reason': 'pdffonts failed',
      };
    }
    final pageText = await _run(
        pdftotext, ['-f', '$page', '-l', '$page', pdf.path, '-'], isCancelled);
    if (pageText.exitCode != 0) {
      return {
        'status': 'unverified',
        'sourceFonts': requested,
        'resolvedFonts': const [],
        'reason': 'pdftotext failed',
      };
    }
    final fontRows = result.stdout
        .split('\n')
        .skip(2)
        .map((line) {
          final columns = line.trim().split(RegExp(r'\s+'));
          if (columns.length < 8 ||
              columns.first == 'name' ||
              int.tryParse(columns.last) == null ||
              !const {'yes', 'no'}.contains(columns[columns.length - 5]) ||
              !const {'yes', 'no'}.contains(columns[columns.length - 3])) {
            return null;
          }
          return {
            'name': columns[0],
            'embedded': columns[columns.length - 5],
            'unicodeMap': columns[columns.length - 3],
          };
        })
        .whereType<Map<String, String>>()
        .toList(growable: false);
    final names = fontRows.map((row) => row['name']!).toSet().toList();
    final fontDetails = <Map<String, String>>[];
    for (final row in fontRows) {
      final name = row['name']!;
      final family = name.replaceFirst(RegExp(r'^[A-Z]{6}\+'), '');
      final match = await _run(
          matcher, ['-f', '%{family[0]}|%{lang}', family], isCancelled);
      final parts = match.stdout.trim().split('|');
      final normalizedName = _fontKey(family);
      final normalizedFamily = parts.isEmpty ? '' : _fontKey(parts.first);
      final languages = parts.skip(1).join(' ').toLowerCase();
      final supportsCjk = match.exitCode == 0 &&
          parts.length > 1 &&
          normalizedName.startsWith(normalizedFamily) &&
          RegExp(r'(^|\s)(zh-cn|zh-sg|zh-tw|zh-hk|ja|ko)(\s|$)')
              .hasMatch(languages);
      fontDetails.add({
        ...row,
        'family': parts.isEmpty ? '' : parts.first,
        'cjkCoverage': supportsCjk ? 'yes' : 'no',
      });
    }
    final completeFontRows = fontRows.isNotEmpty &&
        fontRows.every((row) =>
            row['unicodeMap'] == 'yes' &&
            (row['embedded'] == 'yes' ||
                const {
                  'Courier',
                  'Courier-Bold',
                  'Courier-Oblique',
                  'Courier-BoldOblique',
                  'Helvetica',
                  'Helvetica-Bold',
                  'Helvetica-Oblique',
                  'Helvetica-BoldOblique',
                  'Times-Roman',
                  'Times-Bold',
                  'Times-Italic',
                  'Times-BoldItalic',
                  'Symbol',
                  'ZapfDingbats'
                }.contains(row['name'])));
    final hasCjkText =
        RegExp(r'[\u3400-\u9fff\uf900-\ufaff]').hasMatch(pageText.stdout);
    final hasCjkFont = fontDetails.any((row) =>
        row['cjkCoverage'] == 'yes' &&
        row['unicodeMap'] == 'yes' &&
        row['embedded'] == 'yes');
    final sourceFontReplacements = <Map<String, String>>[];
    final unverifiedSourceFonts = <String>[];
    for (final sourceFont in requested) {
      final sourceKey = _fontKey(sourceFont);
      if (fontDetails.any((row) =>
          _fontKey(row['name']!) == sourceKey ||
          _fontKey(row['family']!) == sourceKey)) {
        continue;
      }
      final match =
          await _run(matcher, ['-f', '%{family[0]}', sourceFont], isCancelled);
      final resolved = match.exitCode == 0 ? match.stdout.trim() : '';
      if (resolved.isEmpty) {
        unverifiedSourceFonts.add(sourceFont);
        continue;
      }
      final resolvedKey = _fontKey(resolved);
      if (fontDetails.any((row) =>
          _fontKey(row['name']!) == resolvedKey ||
          _fontKey(row['family']!) == resolvedKey)) {
        sourceFontReplacements.add({
          'requested': sourceFont,
          'resolved': resolved,
        });
      } else {
        unverifiedSourceFonts.add(sourceFont);
      }
    }
    final status = !completeFontRows
        ? fontRows.isEmpty
            ? 'unverified'
            : 'partial'
        : unverifiedSourceFonts.isNotEmpty
            ? 'unverified'
            : sourceFontReplacements.isNotEmpty || hasCjkText && !hasCjkFont
                ? 'substituted'
                : 'resolved';
    final reasons = [
      if (fontRows.isEmpty) 'no fonts listed',
      if (!completeFontRows) 'font embedding or Unicode map incomplete',
      if (sourceFontReplacements.isNotEmpty)
        'one or more declared source fonts were substituted',
      if (unverifiedSourceFonts.isNotEmpty)
        'one or more declared source fonts could not be resolved',
      if (hasCjkText && !hasCjkFont)
        'rendered page has CJK text but no verified CJK font',
    ];
    return {
      'status': status,
      'sourceFonts': requested.isEmpty ? names : requested,
      'resolvedFonts': fontDetails,
      if (sourceFontReplacements.isNotEmpty)
        'sourceFontReplacements': sourceFontReplacements,
      if (unverifiedSourceFonts.isNotEmpty)
        'unverifiedSourceFonts': unverifiedSourceFonts,
      'pageContainsCjkText': hasCjkText,
      if (reasons.isNotEmpty) 'reason': reasons.join('; '),
    };
  }

  Future<String> _version(
      String executable, List<String> args, bool Function() isCancelled) async {
    final result = await _run(executable, args, isCancelled);
    if (result.exitCode != 0 ||
        result.stdout.trim().isEmpty && result.stderr.trim().isEmpty) {
      throw DocumentPageRendererException(
          'rendererVersionUnavailable', '无法核验 ${p.basename(executable)} 版本。');
    }
    return (result.stdout.trim().isEmpty ? result.stderr : result.stdout)
        .trim()
        .split('\n')
        .first
        .trim();
  }

  Future<_ProcessOutput> _run(
    String executable,
    List<String> arguments,
    bool Function() isCancelled,
  ) async {
    if (isCancelled()) {
      throw const DocumentPageRendererException('cancelled', '文档渲染已停止。');
    }
    Process process;
    try {
      process = await Process.start(
        executable,
        arguments,
        runInShell: false,
        environment: _fontConfigEnvironment(),
      );
    } on Object {
      throw DocumentPageRendererException(
          'rendererMissing', '无法启动 ${p.basename(executable)}。');
    }
    final stdout = StringBuffer();
    final stderr = StringBuffer();
    var stdoutBytes = 0;
    var stderrBytes = 0;
    final stdoutDone = process.stdout.listen((chunk) {
      if (stdoutBytes < 64 * 1024) {
        stdout.write(utf8.decode(chunk, allowMalformed: true));
      }
      stdoutBytes += chunk.length;
    }).asFuture<void>();
    final stderrDone = process.stderr.listen((chunk) {
      if (stderrBytes < 64 * 1024) {
        stderr.write(utf8.decode(chunk, allowMalformed: true));
      }
      stderrBytes += chunk.length;
    }).asFuture<void>();
    final cancellation = Completer<void>();
    final cancelTimer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (!isCancelled() || cancellation.isCompleted) return;
      process.kill();
      cancellation.complete();
    });
    try {
      final exitCode = await Future.any<int>([
        process.exitCode.timeout(processLimit, onTimeout: () {
          process.kill();
          throw const DocumentPageRendererException(
              'rendererTimeout', '文档渲染超过 45 秒，已停止。');
        }),
        cancellation.future.then((_) => -1),
      ]);
      if (exitCode < 0 || isCancelled()) {
        throw const DocumentPageRendererException('cancelled', '文档渲染已停止。');
      }
      await Future.wait([stdoutDone, stderrDone]);
      return _ProcessOutput(exitCode, stdout.toString(), stderr.toString());
    } finally {
      cancelTimer.cancel();
      if (isCancelled()) process.kill();
    }
  }

  static int? _pageCount(String output) {
    final match =
        RegExp(r'^Pages:\s+(\d+)\s*$', multiLine: true).firstMatch(output);
    return match == null ? null : int.tryParse(match.group(1)!);
  }

  static String _fontKey(String value) =>
      value.toLowerCase().replaceAll(RegExp(r'[^a-z0-9\u3400-\u9fff]'), '');

  static String _safeProcessError(String output) {
    final first = output.trim().split('\n').firstOrNull?.trim() ?? '';
    return first.isEmpty
        ? '渲染器返回错误。'
        : first.substring(0, first.length.clamp(0, 160).toInt());
  }

  static Future<Uint8List> _readBounded(File file, int limit) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in file.openRead(0, limit + 1)) {
      builder.add(chunk);
      if (builder.length > limit) {
        throw const DocumentPageRendererException(
            'documentTooLarge', '文档超过 10 MB 渲染上限。');
      }
    }
    return builder.takeBytes();
  }

  static String? _findExecutable(String name) {
    final separator = Platform.isWindows ? ';' : ':';
    final paths = <String>{
      ...(Platform.environment['PATH'] ?? '').split(separator),
      if (Platform.isMacOS) ...[
        '/opt/homebrew/bin',
        '/usr/local/bin',
        '/opt/local/bin'
      ],
      if (Platform.isLinux) ...['/usr/local/bin', '/usr/bin', '/bin'],
    };
    for (final directory in paths) {
      if (directory.trim().isEmpty) continue;
      final candidate = File(p.join(directory.trim(), name));
      if (FileSystemEntity.typeSync(candidate.path) ==
          FileSystemEntityType.file) {
        return candidate.path;
      }
      // shortcut: assumes bundled Poppler's current path, update if the runtime layout changes.
      if (name.startsWith('pdf') &&
          p.basename(directory.trim()) == 'override') {
        final bundled = File(p.join(p.dirname(p.dirname(directory.trim())),
            'native', 'poppler', 'poppler', 'bin', name));
        if (FileSystemEntity.typeSync(bundled.path) ==
            FileSystemEntityType.file) {
          return bundled.path;
        }
      }
    }
    return null;
  }

  static Map<String, String>? _fontConfigEnvironment() {
    if (!Platform.isMacOS) return null;
    final inherited = Platform.environment['FONTCONFIG_FILE']?.trim();
    // shortcut: matches flutter_test's current config path, update if Flutter changes it.
    // flutter_test injects a font-only config that hides installed CJK fonts.
    if (inherited != null &&
        inherited.isNotEmpty &&
        !inherited.contains('/flutter_test_fonts.')) {
      return null;
    }
    for (final path in const [
      '/opt/homebrew/etc/fonts/fonts.conf',
      '/usr/local/etc/fonts/fonts.conf',
      '/etc/fonts/fonts.conf',
    ]) {
      if (FileSystemEntity.typeSync(path) == FileSystemEntityType.file) {
        return {'FONTCONFIG_FILE': path};
      }
    }
    return null;
  }
}

class _ProcessOutput {
  final int exitCode;
  final String stdout;
  final String stderr;
  const _ProcessOutput(this.exitCode, this.stdout, this.stderr);
}
