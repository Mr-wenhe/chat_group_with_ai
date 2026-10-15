import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:chat_group/features/work_mode/macos_app_bundle_archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('macOS app bundle archive', skip: !Platform.isMacOS, () {
    late Directory root;
    late Directory app;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('native_bundle_test_');
      app = Directory('${root.path}/build/Fixture.app');
      await Directory('${app.path}/Contents/MacOS').create(recursive: true);
      await Directory('${app.path}/Contents/Resources').create(recursive: true);
      await File('${app.path}/Contents/Info.plist').writeAsString('''
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.example.chatgroup.fixture</string>
<key>CFBundleExecutable</key><string>Fixture</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>ChatGroupTestDataEnvironment</key><string>CHAT_GROUP_TEST_DATA_DIR</string>
</dict></plist>
''');
      final executable = File('${app.path}/Contents/MacOS/Fixture');
      await executable.writeAsString('#!/bin/sh\nexit 0\n');
      await Process.run('/bin/chmod', ['755', executable.path]);
      await File('${app.path}/Contents/Resources/data.txt')
          .writeAsString('fixture');
      await Link('${app.path}/Contents/Resources/current').create('data.txt');
      final signed = await Process.run(
          '/usr/bin/codesign', ['--force', '--deep', '--sign', '-', app.path]);
      if (signed.exitCode != 0) {
        throw StateError('Unable to sign test fixture: ${signed.stderr}');
      }
    });

    tearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });

    test('packages, verifies and extracts a signed app with internal link/mode',
        () async {
      final archive = File('${root.path}/Fixture.zip');
      final expected = await MacAppBundleArchive.package(
        app: app,
        workspaceRoot: root,
        destination: archive,
        appPath: 'build/Fixture.app',
        archivePath: 'artifacts/Fixture.zip',
      );
      expect(expected.bundleId, 'com.example.chatgroup.fixture');
      expect(
          expected.executablePath, 'build/Fixture.app/Contents/MacOS/Fixture');
      expect(
          (await MacAppBundleArchive.inspect(archive,
                  appPath: expected.appPath, archivePath: expected.archivePath))
              .treeSha256,
          expected.treeSha256);

      final extracted = await MacAppBundleArchive.extractVerified(
        archive: archive,
        expected: expected,
        destination: Directory('${root.path}/copy'),
      );
      expect(
          await File('${extracted.path}/Contents/Resources/current').exists(),
          isTrue);
      expect(
          await Link('${extracted.path}/Contents/Resources/current').target(),
          'data.txt');
      final executable = File('${extracted.path}/Contents/MacOS/Fixture');
      expect((await executable.stat()).mode & 0x49, isNot(0));
    });

    test('rejects credentials inside a signed app bundle', () async {
      for (final name in ['.env', 'dev_credentials.hive']) {
        final credential = File('${app.path}/Contents/Resources/$name');
        await credential.writeAsString('synthetic fixture');
        final signed = await Process.run('/usr/bin/codesign',
            ['--force', '--deep', '--sign', '-', app.path]);
        expect(signed.exitCode, 0, reason: '${signed.stderr}');

        final archive = File('${root.path}/$name.zip');
        await expectLater(
          MacAppBundleArchive.package(
            app: app,
            workspaceRoot: root,
            destination: archive,
            appPath: 'build/Fixture.app',
            archivePath: 'artifacts/$name.zip',
          ),
          throwsA(isA<StateError>()),
        );
        expect(await archive.exists(), isFalse);
        await credential.delete();
      }
    });

    test('rejects a bundle containing an external symlink', () async {
      await Link('${app.path}/Contents/Resources/outside')
          .create(root.path, recursive: true);
      await expectLater(
        MacAppBundleArchive.package(
          app: app,
          workspaceRoot: root,
          destination: File('${root.path}/external.zip'),
          appPath: 'Fixture.app',
          archivePath: 'Fixture.zip',
        ),
        throwsStateError,
      );
    });

    test('rejects a high-ratio ZIP before reading its app contents', () async {
      final archive = Archive();
      archive.addFile(ArchiveFile.string(
        'Fixture.app/Contents/Resources/zeros',
        List<String>.filled(3 * 1024 * 1024, '0').join(),
      ));
      final zip = File('${root.path}/bomb.zip');
      await zip.writeAsBytes(ZipEncoder().encode(archive));
      await expectLater(
        MacAppBundleArchive.inspect(
          zip,
          appPath: 'Fixture.app',
          archivePath: 'Fixture.zip',
        ),
        throwsStateError,
      );
    });
  });

  test(
    'packages and extracts the real built Flutter app when requested',
    () async {
      final appPath = Platform.environment['CHAT_GROUP_P2_APP_PATH']!;
      final relativeAppPath = p
          .relative(p.normalize(appPath), from: Directory.current.path)
          .replaceAll('\\', '/');
      final root = await Directory.systemTemp.createTemp('real_flutter_app_');
      try {
        final archive = File('${root.path}/flutter-app.zip');
        final description = await MacAppBundleArchive.package(
          app: Directory(appPath),
          workspaceRoot: Directory.current,
          destination: archive,
          appPath: relativeAppPath,
          archivePath: 'artifacts/flutter-app.zip',
        );
        final extracted = await MacAppBundleArchive.extractVerified(
          archive: archive,
          expected: description,
          destination: Directory('${root.path}/copy'),
        );
        expect(description.bundleId, 'com.example.chatGroup');
        expect(await File(p.join(extracted.path, 'Contents/MacOS/伴伴')).exists(),
            isTrue);
      } finally {
        if (await root.exists()) await root.delete(recursive: true);
      }
    },
    skip: !Platform.isMacOS ||
        Platform.environment['CHAT_GROUP_P2_APP_PATH'] == null,
  );
}
