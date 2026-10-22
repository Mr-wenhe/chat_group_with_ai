import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:chat_group/core/models/media_attachment.dart';
import 'package:chat_group/features/document/attachment_preview_dialog.dart';
import 'package:chat_group/features/document/libreoffice_download.dart';
import 'package:chat_group/features/document/libreoffice_install_dialog.dart';
import 'package:chat_group/features/document/libreoffice_installer.dart';
import 'package:chat_group/features/document/libreoffice_system_install.dart';
import 'package:chat_group/features/document/office_preview_session.dart';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _Download extends LibreOfficeDownload {
  bool corrupt = false;
  Completer<void>? gate;
  final started = Completer<void>();
  File? saved;
  static const bytes = [1, 2, 3, 4];
  @override
  Future<String> checksum(
          LibreOfficePackage package, CancelToken cancel) async =>
      sha256.convert(corrupt ? [0] : bytes).toString();
  @override
  Future<void> download(LibreOfficePackage package, File target,
      CancelToken cancel, void Function(int, int) progress) async {
    saved = target;
    await target.writeAsBytes(bytes);
    progress(bytes.length, bytes.length);
    started.complete();
    if (gate != null) await gate!.future;
  }
}

class _System extends LibreOfficeSystemInstall {
  bool installed = false;
  bool reject = false;
  @override
  Future<void> install(File package) async {
    expect(await package.readAsBytes(), _Download.bytes);
    if (reject) throw const LibreOfficeInstallException('系统签名校验失败');
    installed = true;
  }
}

class _UiInstaller extends LibreOfficeInstaller {
  _UiInstaller(this.stage);
  final LibreOfficeInstallStage stage;
  CancelToken? token;
  @override
  Future<void> install(
      {required CancelToken cancel,
      required void Function(LibreOfficeInstallProgress) onProgress}) async {
    token = cancel;
    onProgress(LibreOfficeInstallProgress(stage, received: 50, total: 100));
    await cancel.whenCancel;
  }
}

class _MissingOffice extends OfficePreviewSession {
  @override
  Future<File> convert(File source, {required bool spreadsheet}) async =>
      throw const AttachmentPreviewException('缺少 LibreOffice',
          code: 'officeMissing');
}

void main() {
  LibreOfficeInstaller installer(_Download download, _System system) =>
      LibreOfficeInstaller(
          download: download,
          system: system,
          findOffice: () => system.installed ? '/installed/soffice' : null,
          package: LibreOfficePackage.forAbi(Abi.macosArm64));

  test('packages are fixed official HTTPS paths for each desktop architecture',
      () {
    final cases = {
      Abi.macosArm64: 'MacOS_aarch64.dmg',
      Abi.macosX64: 'MacOS_x86-64.dmg',
      Abi.windowsX64: 'Win_x86-64.msi',
      Abi.windowsArm64: 'Win_aarch64.msi'
    };
    for (final entry in cases.entries) {
      final package = LibreOfficePackage.forAbi(entry.key);
      expect(package.uri.scheme, 'https');
      expect(package.uri.host, LibreOfficePackage.host);
      expect(package.fileName, endsWith(entry.value));
      expect(package.uri.userInfo, isEmpty);
    }
    expect(() => LibreOfficePackage.forAbi(Abi.linuxX64),
        throwsA(isA<LibreOfficeInstallException>()));
  });

  test(
      'checksum metadata must name the exact installer and contain one SHA-256',
      () {
    final package = LibreOfficePackage.forAbi(Abi.macosArm64);
    final digest = sha256.convert([1]).toString();
    expect(package.parseChecksum('$digest  ${package.fileName}\n'), digest);
    for (final source in [
      '$digest malicious.dmg',
      '$digest ${package.fileName}\n$digest ${package.fileName}',
      '<html>error</html>',
      'a ${package.fileName}'
    ]) {
      expect(() => package.parseChecksum(source),
          throwsA(isA<LibreOfficeInstallException>()));
    }
  });

  test(
      'download then verify then install; remove temporary installer on success',
      () async {
    final download = _Download();
    final system = _System();
    final stages = <LibreOfficeInstallStage>[];
    await installer(download, system)
        .install(cancel: CancelToken(), onProgress: (p) => stages.add(p.stage));
    expect(system.installed, isTrue);
    expect(
        stages,
        containsAllInOrder([
          LibreOfficeInstallStage.downloading,
          LibreOfficeInstallStage.verifying,
          LibreOfficeInstallStage.installing
        ]));
    expect(await download.saved!.exists(), isFalse);
  });

  test('bad checksum never reaches installation and removes the download',
      () async {
    final download = _Download()..corrupt = true;
    final system = _System();
    await expectLater(
        installer(download, system)
            .install(cancel: CancelToken(), onProgress: (_) {}),
        throwsA(isA<LibreOfficeInstallException>()));
    expect(system.installed, isFalse);
    expect(await download.saved!.exists(), isFalse);
  });

  test('cancelling download never starts automatic installation', () async {
    final download = _Download();
    final system = _System();
    final token = CancelToken();
    await expectLater(
        installer(download, system).install(
            cancel: token,
            onProgress: (p) {
              if (p.received > 0) token.cancel();
            }),
        throwsA(isA<LibreOfficeInstallException>()));
    expect(system.installed, isFalse);
    expect(await download.saved!.exists(), isFalse);
  });

  test(
      'only one installation runs at a time and a failed system check can be retried',
      () async {
    final download = _Download()..gate = Completer<void>();
    final system = _System()..reject = true;
    final first = installer(download, system)
        .install(cancel: CancelToken(), onProgress: (_) {});
    final firstCheck =
        expectLater(first, throwsA(isA<LibreOfficeInstallException>()));
    await download.started.future;
    await expectLater(
        installer(_Download(), _System())
            .install(cancel: CancelToken(), onProgress: (_) {}),
        throwsA(isA<LibreOfficeInstallException>()));
    download.gate!.complete();
    await firstCheck;
    expect(system.installed, isFalse);
    system.reject = false;
    await installer(_Download(), system)
        .install(cancel: CancelToken(), onProgress: (_) {});
    expect(system.installed, isTrue);
  });

  testWidgets('missing Office preview offers download and installation',
      (tester) async {
    final directory =
        Directory.systemTemp.createTempSync('missing-office-widget-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final file = File('${directory.path}/sample.docx')
      ..writeAsStringSync('fixture');
    await tester.runAsync(() async {
      await tester.pumpWidget(MaterialApp(
          home: AttachmentPreviewDialog(
              attachment: MediaAttachment(type: 'file', localPath: file.path),
              office: _MissingOffice())));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pump();
    expect(find.text('下载并安装 LibreOffice'), findsOneWidget);
    expect(find.text('用系统应用打开'), findsOneWidget);
  });

  for (final stage in [
    LibreOfficeInstallStage.downloading,
    LibreOfficeInstallStage.installing
  ]) {
    testWidgets('installer UI shows $stage and protects active installation',
        (tester) async {
      final fake = _UiInstaller(stage);
      await tester.pumpWidget(
          MaterialApp(home: LibreOfficeInstallDialog(installer: fake)));
      await tester.pump();
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      final cancel =
          tester.widget<TextButton>(find.widgetWithText(TextButton, '取消下载'));
      expect(cancel.onPressed == null,
          stage == LibreOfficeInstallStage.installing);
      expect(tester.widget<PopScope>(find.byType(PopScope).last).canPop,
          stage != LibreOfficeInstallStage.installing);
      fake.token!.cancel();
    });
  }
}
