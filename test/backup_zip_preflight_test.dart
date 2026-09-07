import 'dart:io';

import 'package:chat_group/features/backup/backup_models.dart';
import 'package:chat_group/features/backup/backup_zip_preflight.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('backup_zip_preflight_');
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  test('预检在 archive 解码前拒绝超量中央目录记录', () async {
    final fixture = File('${root.path}/too-many-entries.zip');
    await fixture.writeAsBytes(_zipBytes([
      const _Entry('a.txt'),
      const _Entry('b.txt'),
      const _Entry('c.txt'),
    ]));

    await expectLater(
      ZipPreflight.validate(fixture, maxEntries: 2),
      throwsA(isA<BackupException>()),
    );
  });

  test('预检拒绝重复中央目录记录，避免 Archive 去重后低估数量', () async {
    final fixture = File('${root.path}/duplicate-entries.zip');
    await fixture.writeAsBytes(_zipBytes([
      const _Entry('same.txt'),
      const _Entry('same.txt'),
    ]));

    await expectLater(
      ZipPreflight.validate(fixture, maxEntries: 10),
      throwsA(isA<BackupException>()),
    );
  });

  test('预检在 archive 解码前拒绝 Unix 符号链接', () async {
    final fixture = File('${root.path}/symlink.zip');
    await fixture.writeAsBytes(_zipBytes([
      const _Entry('link', symbolicLink: true, data: 'target'),
    ]));

    await expectLater(
      ZipPreflight.validate(fixture, maxEntries: 10),
      throwsA(isA<BackupException>()),
    );
  });

  test('预检拒绝作为备份源文件的文件系统符号链接', () async {
    final target = File('${root.path}/target.zip');
    await target.writeAsBytes(
      _zipBytes([const _Entry('data/settings.json', data: '{}')]),
    );
    final link = Link('${root.path}/source.zip');
    await link.create(target.path);

    await expectLater(
      ZipPreflight.validate(File(link.path), maxEntries: 10),
      throwsA(isA<BackupException>()),
    );
  }, skip: Platform.isWindows ? 'symlink privileges vary on Windows' : null);

  test('普通中央目录通过预检', () async {
    final fixture = File('${root.path}/valid.zip');
    await fixture.writeAsBytes(
      _zipBytes([const _Entry('data/settings.json', data: '{}')]),
    );

    await ZipPreflight.validate(fixture, maxEntries: 10);
  });
}

class _Entry {
  final String name;
  final String data;
  final bool symbolicLink;

  const _Entry(
    this.name, {
    this.data = '',
    this.symbolicLink = false,
  });
}

List<int> _zipBytes(List<_Entry> entries) {
  final local = <int>[];
  final central = <int>[];
  for (final entry in entries) {
    final name = entry.name.codeUnits;
    final data = entry.data.codeUnits;
    final localOffset = local.length;
    _u32(local, 0x04034b50);
    _u16(local, 20);
    _u16(local, 0);
    _u16(local, 0);
    _u16(local, 0);
    _u16(local, 0);
    _u32(local, 0);
    _u32(local, data.length);
    _u32(local, data.length);
    _u16(local, name.length);
    _u16(local, 0);
    local.addAll(name);
    local.addAll(data);

    _u32(central, 0x02014b50);
    _u16(central, entry.symbolicLink ? (3 << 8) | 20 : 20);
    _u16(central, 20);
    _u16(central, 0);
    _u16(central, 0);
    _u16(central, 0);
    _u16(central, 0);
    _u32(central, 0);
    _u32(central, data.length);
    _u32(central, data.length);
    _u16(central, name.length);
    _u16(central, 0);
    _u16(central, 0);
    _u16(central, 0);
    _u16(central, 0);
    _u32(central, entry.symbolicLink ? 0xa0000000 : 0);
    _u32(central, localOffset);
    central.addAll(name);
  }

  final result = <int>[...local];
  final centralOffset = result.length;
  result.addAll(central);
  _u32(result, 0x06054b50);
  _u16(result, 0);
  _u16(result, 0);
  _u16(result, entries.length);
  _u16(result, entries.length);
  _u32(result, central.length);
  _u32(result, centralOffset);
  _u16(result, 0);
  return result;
}

void _u16(List<int> output, int value) {
  output
    ..add(value & 0xff)
    ..add((value >> 8) & 0xff);
}

void _u32(List<int> output, int value) {
  output
    ..add(value & 0xff)
    ..add((value >> 8) & 0xff)
    ..add((value >> 16) & 0xff)
    ..add((value >> 24) & 0xff);
}
