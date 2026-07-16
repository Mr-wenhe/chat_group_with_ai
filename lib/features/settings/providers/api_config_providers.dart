import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/database/data_lifecycle_models.dart';
import 'package:chat_group/core/database/data_lifecycle_service.dart';
import 'package:chat_group/core/models/api_config.dart';
import '../../../providers/providers.dart';

final apiConfigsProvider =
    StateNotifierProvider<ApiConfigsNotifier, List<ApiConfig>>((ref) {
  return ApiConfigsNotifier(ref.read(databaseServiceProvider));
});

class ApiConfigsNotifier extends StateNotifier<List<ApiConfig>> {
  final DatabaseService _db;

  ApiConfigsNotifier(this._db) : super([]) {
    _loadConfigs();
  }

  void _loadConfigs() {
    state = _db.apiConfigBox.values.toList();
  }

  Future<void> addConfig(ApiConfig config) async {
    await _db.saveApiConfig(config);
    _loadConfigs();
  }

  Future<void> updateConfig(ApiConfig config) async {
    await _db.saveApiConfig(config);
    _loadConfigs();
  }

  Future<DataLifecycleResult> deleteConfig(
    String id, {
    String? replacementConfigId,
  }) async {
    final result = await DataLifecycleService(db: _db).deleteApiConfig(
      id,
      replacementConfigId: replacementConfigId,
    );
    _loadConfigs();
    return result;
  }

  ApiConfig? getById(String id) {
    try {
      return _db.apiConfigBox.get(id);
    } catch (_) {
      return null;
    }
  }
}
