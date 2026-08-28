import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/theme/app_theme.dart';

export 'package:chat_group/features/web_search/providers/duckduckgo_instant_answer_provider.dart';
export 'package:chat_group/features/web_search/providers/tavily_search_provider.dart';
export 'package:chat_group/features/web_search/providers/brave_search_provider.dart';
export 'package:chat_group/features/web_search/providers/search_provider.dart';
export 'package:chat_group/features/web_search/models/search_provider_config.dart';
export 'package:chat_group/features/web_search/data/search_credential_repository.dart';
export 'package:chat_group/features/web_search/data/search_settings_store.dart';
export 'package:chat_group/features/web_search/security/search_endpoint_validator.dart';
export 'package:chat_group/features/work_mode/providers/work_task_providers.dart';

final databaseServiceProvider = Provider<DatabaseService>((ref) {
  return DatabaseService();
});

final appSkinModeProvider =
    StateNotifierProvider<AppSkinModeNotifier, AppSkinMode>((ref) {
  return AppSkinModeNotifier(ref.read(databaseServiceProvider));
});

class AppSkinModeNotifier extends StateNotifier<AppSkinMode> {
  final DatabaseService _db;

  AppSkinModeNotifier(this._db) : super(_db.savedAppSkinMode);

  Future<void> setSkin(AppSkinMode mode) async {
    state = mode;
    await _db.saveAppSkinMode(mode);
  }
}
