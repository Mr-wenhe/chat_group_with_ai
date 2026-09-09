import 'dart:io';

import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/features/work_mode/work_mode_workspace_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

class _TestPathProvider extends PathProviderPlatform {
  final String supportPath;

  _TestPathProvider(this.supportPath);

  @override
  Future<String?> getApplicationSupportPath() async => supportPath;

  @override
  Future<String?> getApplicationDocumentsPath() async => supportPath;
}

void main() {
  late Directory supportDirectory;
  late Directory homeDirectory;

  setUp(() async {
    supportDirectory =
        await Directory.systemTemp.createTemp('database_processing_test_');
    homeDirectory =
        await Directory.systemTemp.createTemp('database_home_test_');
    PathProviderPlatform.instance = _TestPathProvider(supportDirectory.path);
  });

  tearDown(() async {
    await Hive.close();
    for (final directory in [supportDirectory, homeDirectory]) {
      if (await directory.exists()) await directory.delete(recursive: true);
    }
  });

  test('creates the default AI workspace under the user home directory',
      () async {
    final database = DatabaseService(userHomePath: homeDirectory.path);
    await database.init();

    final expected = Directory('${homeDirectory.path}/.chat_group');
    expect(database.aiProcessingDirPath, isNull);
    expect((await database.aiProcessingDir).path, expected.absolute.path);
    expect(await expected.exists(), isTrue);

    final workspace = await WorkModeWorkspaceService(db: database).loadOrCreate(
      conversationId: 'default-root-group',
      isDirectChat: false,
    );
    expect(
      workspace.workDirPath,
      '${expected.absolute.path}/conversations/group_default-root-group',
    );

    database.dispose();
  });
}
