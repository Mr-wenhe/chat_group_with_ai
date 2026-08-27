part of 'staged_backup_data.dart';

const List<String> _stagedBackupDataPaths = [
  'data/api_configs.json',
  'data/characters.json',
  'data/groups.json',
  'data/messages.jsonl',
  'data/group_memories.json',
  'data/character_memories.json',
  'data/relationships.json',
  'data/skills.json',
  'data/agent_tasks.json',
  'data/work_mode.json',
  'data/user_profile.json',
  'data/permanent_memories.json',
  'data/relationship_events.json',
  'data/settings.json',
];

Future<void> _checkAggregateJsonSize(
  Directory root,
  int limit,
) async {
  var total = 0;
  for (final path in _stagedBackupDataPaths) {
    final file = File('${root.path}/$path');
    if (!await file.exists()) continue;
    total += await file.length();
    if (total > limit) {
      throw const BackupException('备份数据总大小超过限制');
    }
  }
}

Map<String, dynamic> _stagedBackupRecord(Object? value) {
  if (value is! Map || value['key'] is! String || value['value'] is! Map) {
    throw const BackupException('备份记录格式无效');
  }
  return Map<String, dynamic>.from(value);
}

List<String> _stagedBackupStrings(Object? value) =>
    (value as List? ?? const []).map((item) => item.toString()).toList();
