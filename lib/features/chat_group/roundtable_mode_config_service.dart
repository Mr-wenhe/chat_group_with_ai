import 'package:chat_group/core/database/database_service.dart';

/// Persists the roundtable discussion choice per conversation.
class RoundtableModeConfigService {
  static const _prefix = 'roundtable_mode_enabled:';

  final DatabaseService db;

  const RoundtableModeConfigService({required this.db});

  bool isEnabled(String conversationId) =>
      db.appSettingsBox.get('$_prefix$conversationId', defaultValue: false) ==
      true;

  Future<void> setEnabled(String conversationId, bool enabled) =>
      db.appSettingsBox.put('$_prefix$conversationId', enabled);
}
