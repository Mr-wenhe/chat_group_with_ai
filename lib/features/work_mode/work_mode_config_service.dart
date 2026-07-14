import 'package:chat_group/core/database/database_service.dart';

/// Persists the explicit mode independently from the retired autonomy flag.
/// This prevents an old installation from silently enabling tool execution.
class WorkModeConfigService {
  static const _prefix = 'work_mode_enabled:';

  final DatabaseService db;

  const WorkModeConfigService({required this.db});

  bool isWorkMode(String conversationKey) =>
      db.appSettingsBox.get('$_prefix$conversationKey', defaultValue: false) ==
      true;

  Future<void> setWorkMode(String conversationKey, bool enabled) =>
      db.appSettingsBox.put('$_prefix$conversationKey', enabled);
}
