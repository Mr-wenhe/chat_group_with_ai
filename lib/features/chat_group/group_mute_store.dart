import 'package:chat_group/core/database/database_service.dart';

/// 群内成员「禁言」状态的持久化与判定。
///
/// 存在 `app_settings` 而不是 `ChatGroup` 模型里：它与 DM inbox 状态、工作模式
/// 授权同属「轻量、按会话维度」的状态，走既有模式可避免改动 Hive 模型、生成物
/// 与迁移路径。代价是恢复备份时的实体 ID 重映射必须单独登记（见
/// `restore_plan_rewrite.dart`），否则 `copyWithNewIds` 策略下禁言会静默指向
/// 已不存在的旧 id。
///
/// **语义**：禁言只拦「自动挑选」。被 @ 点名的角色照常回复，且回复语气仍由心情
/// 与关系决定——敷衍、带刺都属正常表现。因此它**不**接入
/// `ReplyEligibilityPolicy`，否则会把 @ 点名一并挡住。
class GroupMuteStore {
  /// app_settings 键：`{groupId: [characterId, ...]}`。
  static const String storageKey = 'group_muted_characters_v1';

  final DatabaseService db;

  GroupMuteStore(this.db);

  /// 该群被禁言的角色 id 集合。
  ///
  /// 已删除的角色或已退群的 id 会留在存储里，但不影响判定：调用方只会拿当前
  /// 真实成员来问（见 [isMuted]）。读到损坏数据时按「无禁言」处理。
  Set<String> mutedFor(String groupId) {
    final raw = db.appSettingsBox.get(storageKey);
    if (raw is! Map) return const {};
    final entry = raw[groupId];
    if (entry is! List) return const {};
    return entry.whereType<String>().toSet();
  }

  bool isMuted(String groupId, String characterId) =>
      mutedFor(groupId).contains(characterId);

  /// 该角色本轮是否可能被**自动**选中。
  ///
  /// 禁言只拦自动挑选：被 @ 点名的角色照常参与。
  bool mayAutoPick({
    required String groupId,
    required String characterId,
    required Set<String> mentionedIds,
  }) =>
      !isMuted(groupId, characterId) || mentionedIds.contains(characterId);

  Future<void> setMuted({
    required String groupId,
    required String characterId,
    required bool muted,
  }) async {
    final next = normalize(db.appSettingsBox.get(storageKey));
    final ids = next.putIfAbsent(groupId, () => <String>[]);
    if (muted) {
      if (!ids.contains(characterId)) ids.add(characterId);
    } else {
      ids.remove(characterId);
    }
    // 空列表不留条目，避免取消禁言后留下无意义的群条目。
    if (ids.isEmpty) next.remove(groupId);
    await db.appSettingsBox.put(storageKey, next);
  }

  /// 存储与导出共用的规整边界：忽略损坏项，去重并移除空 id。
  static Map<String, List<String>> normalize(Object? raw) {
    if (raw is! Map) return <String, List<String>>{};
    final result = <String, List<String>>{};
    for (final entry in raw.entries) {
      final key = entry.key;
      if (key is! String || key.isEmpty) continue;
      final ids = entry.value is List
          ? (entry.value as List)
              .whereType<String>()
              .where((id) => id.isNotEmpty)
              .toSet()
              .toList()
          : <String>[];
      if (ids.isNotEmpty) result[key] = ids;
    }
    return result;
  }
}
