part of 'backup_restore_service_test.dart';

Future<File> _writeV1Fixture(Directory root) async {
  const character = {
    'id': 'char-1',
    'name': '旧角色',
    'avatar': '旧',
    'age': 20,
    'role': '测试',
    'personalityTags': <String>[],
    'systemPrompt': 'legacy',
    'memorySummary': '【事实】旧版摘要事实',
    'apiProvider': '',
    'modelName': '',
    'customBaseUrl': '',
    'hourlyReplyLimit': 60,
    'hourlyReplyCount': 0,
    'lastReplyTimestamp': null,
    'isActive': true,
    'createdAt': '2026-08-01T00:00:00.000Z',
    'apiConfigId': '',
    'agenticEnabled': true,
    'skillIds': <String>[],
    'toolPermissions': <String>[],
  };
  const group = {
    'id': 'group-1',
    'name': '旧群',
    'theme': '旧版',
    'description': '',
    'aiCharacterIds': ['char-1'],
    'createdAt': '2026-08-01T00:00:00.000Z',
  };
  const message = {
    'key': 'message-1',
    'value': {
      'id': 'message-1',
      'groupId': 'group-1',
      'senderId': 'user',
      'senderType': 'user',
      'content': '旧版消息',
      'timestamp': '2026-08-01T00:00:00.000Z',
      'replyToMessageId': null,
      'isMention': false,
      'mentionedAiIds': <String>[],
      'media': <dynamic>[],
    },
  };
  const relationship = {
    'key': 'relationship-1',
    'value': {
      'id': 'relationship-1',
      'groupId': 'group-1',
      'sourceCharacterId': 'char-1',
      'targetId': 'user',
      'targetType': 'user',
      'affinity': 1,
      'trust': 1,
      'friction': 0,
      'familiarity': 1,
      'recentMood': 'neutral',
      'notes': '',
      'lastInteractionAt': '2026-08-01T00:00:00.000Z',
      'createdAt': '2026-08-01T00:00:00.000Z',
    },
  };
  const characterMemory = {
    'key': 'legacy-memory',
    'value': {
      'id': 'legacy-memory',
      'groupId': 'group-1',
      'characterId': 'char-1',
      'facts': ['旧版事实'],
      'relationshipNotes': <String>[],
      'personaGrowth': <String>[],
      'lastUpdatedAt': '2026-08-01T00:00:00.000Z',
      'createdAt': '2026-08-01T00:00:00.000Z',
    },
  };
  final contents = <String, String>{
    'data/api_configs.json': '[]',
    'data/characters.json': jsonEncode([
      {'key': 'char-1', 'value': character}
    ]),
    'data/groups.json': jsonEncode([
      {'key': 'group-1', 'value': group}
    ]),
    'data/messages.jsonl': '${jsonEncode(message)}\n',
    'data/group_memories.json': '[]',
    'data/character_memories.json': jsonEncode([characterMemory]),
    'data/relationships.json': jsonEncode([relationship]),
    'data/skills.json': '[]',
    'data/agent_tasks.json': '[]',
    'data/work_mode.json': '[]',
    'data/settings.json': '{}',
  };
  final archive = Archive();
  final files = <String, dynamic>{};
  for (final entry in contents.entries) {
    final bytes = utf8.encode(entry.value);
    files[entry.key] = {
      'bytes': bytes.length,
      'sha256': sha256.convert(bytes).toString(),
    };
    archive.addFile(ArchiveFile.string(entry.key, entry.value));
  }
  archive.addFile(ArchiveFile.string(
    'manifest.json',
    jsonEncode({
      'format': BackupManifest.formatName,
      'formatVersion': 1,
      'schemaVersion': 1,
      'appVersion': '1.0.0',
      'createdAt': '2026-08-01T00:00:00.000Z',
      'scope': 'all',
      'counts': {
        'apiConfigs': 0,
        'characters': 1,
        'groups': 1,
        'messages': 1,
        'characterMemories': 1,
        'groupMemories': 0,
        'relationships': 1,
        'skills': 0,
        'agentTasks': 0,
        'workMode': 0,
        'settings': 0,
        'attachments': 0,
      },
      'files': files,
      'missingAttachments': <String>[],
      'credentialsIncluded': false,
    }),
  ));
  final fixture = File('${root.path}/legacy-v1.cgbak');
  await fixture.writeAsBytes(ZipEncoder().encodeBytes(archive));
  return fixture;
}

Future<File> _rewriteBackupJson(
  File source,
  File destination,
  String path,
  void Function(dynamic value) mutate,
) async {
  final archive = ZipDecoder().decodeBytes(await source.readAsBytes());
  final manifestFile = archive.findFile('manifest.json')!;
  final manifest = Map<String, dynamic>.from(
    jsonDecode(utf8.decode(manifestFile.content)) as Map,
  );
  final dataFile = archive.findFile(path)!;
  final decoded = jsonDecode(utf8.decode(dataFile.content));
  mutate(decoded);
  final content = jsonEncode(decoded);
  final bytes = utf8.encode(content);
  final files = Map<String, dynamic>.from(manifest['files'] as Map);
  files[path] = {
    'bytes': bytes.length,
    'sha256': sha256.convert(bytes).toString(),
  };
  manifest['files'] = files;

  final rewritten = Archive();
  for (final file in archive.files) {
    if (file.name == path) {
      rewritten.addFile(ArchiveFile.string(path, content));
    } else if (file.name == 'manifest.json') {
      rewritten
          .addFile(ArchiveFile.string('manifest.json', jsonEncode(manifest)));
    } else {
      rewritten.addFile(ArchiveFile(file.name, file.size, file.content));
    }
  }
  await destination.writeAsBytes(ZipEncoder().encodeBytes(rewritten));
  return destination;
}

Future<File> _rewriteManifestArchive(
  File source,
  File destination,
  void Function(Map<String, dynamic> manifest) mutate,
) async {
  final archive = ZipDecoder().decodeBytes(await source.readAsBytes());
  final manifestFile = archive.findFile('manifest.json')!;
  final manifest = Map<String, dynamic>.from(
    jsonDecode(utf8.decode(manifestFile.content)) as Map,
  );
  mutate(manifest);

  final rewritten = Archive();
  for (final file in archive.files) {
    if (file.name == 'manifest.json') {
      rewritten.addFile(
        ArchiveFile.string('manifest.json', jsonEncode(manifest)),
      );
    } else {
      rewritten.addFile(ArchiveFile(file.name, file.size, file.content));
    }
  }
  await destination.writeAsBytes(ZipEncoder().encodeBytes(rewritten));
  return destination;
}

Future<File> _writeInvalidConfigurationGlobalFixture(Directory root) async {
  const globalPaths = [
    'data/user_profile.json',
    'data/permanent_memories.json',
    'data/relationship_events.json',
    'data/relationships.json',
  ];
  final archive = Archive();
  final files = <String, dynamic>{};
  for (final path in globalPaths) {
    const content = '[]';
    final bytes = utf8.encode(content);
    files[path] = {
      'bytes': bytes.length,
      'sha256': sha256.convert(bytes).toString(),
    };
    archive.addFile(ArchiveFile.string(path, content));
  }
  archive.addFile(ArchiveFile.string(
    'manifest.json',
    jsonEncode({
      'format': BackupManifest.formatName,
      'formatVersion': 1,
      'schemaVersion': 2,
      'backupKind': 'full',
      'includesGlobalData': false,
      'appVersion': '2.0.0',
      'createdAt': '2026-08-01T00:00:00.000Z',
      'scope': 'configurationOnly',
      'counts': <String, int>{},
      'files': files,
      'missingAttachments': <String>[],
    }),
  ));
  final fixture = File('${root.path}/invalid-configuration-global.cgbak');
  await fixture.writeAsBytes(ZipEncoder().encodeBytes(archive));
  return fixture;
}

List<Map<String, dynamic>> _recordsFromArchive(
  Archive archive,
  String path,
) {
  final file = archive.findFile(path);
  if (file == null) return const [];
  final decoded = jsonDecode(utf8.decode(file.content));
  return (decoded as List)
      .map((item) => Map<String, dynamic>.from(item as Map))
      .toList(growable: false);
}
