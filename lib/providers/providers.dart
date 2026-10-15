import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/database/database_service_provider.dart';
import 'package:chat_group/core/text/entity_labels.dart';
import 'package:chat_group/core/theme/app_theme.dart';

export 'package:chat_group/core/database/database_service_provider.dart';

export 'package:chat_group/features/web_search/providers/duckduckgo_instant_answer_provider.dart';
export 'package:chat_group/features/web_search/providers/tavily_search_provider.dart';
export 'package:chat_group/features/web_search/providers/brave_search_provider.dart';
export 'package:chat_group/features/web_search/providers/search_provider.dart';
export 'package:chat_group/features/web_search/models/search_provider_config.dart';
export 'package:chat_group/features/web_search/data/search_credential_repository.dart';
export 'package:chat_group/features/web_search/data/search_settings_store.dart';
export 'package:chat_group/features/web_search/security/search_endpoint_validator.dart';
export 'package:chat_group/features/realtime/providers/realtime_providers.dart';
export 'package:chat_group/features/work_mode/providers/work_task_providers.dart';

/// 反显期实体 id → 人话标签。
///
/// 只带 core 解析器（角色/会话/配置/任务）；work_mode 的候选版本、问题、验收等
/// 领域 id 由使用方用 `withResolver` 叠加自己的状态解析器。
final entityLabelsProvider = Provider<EntityLabels>(
  (ref) => EntityLabels.from(ref.watch(databaseServiceProvider)),
);

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
