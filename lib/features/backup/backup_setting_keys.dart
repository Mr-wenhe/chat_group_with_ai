import 'package:chat_group/features/ai_governance/ai_governance_store.dart';
import 'package:chat_group/features/chat_group/group_mute_store.dart';
import 'package:chat_group/features/web_search/data/search_settings_store.dart';

/// `.cgbak` 会携带的 `app_settings` 键。
///
/// **刻意只保留一份**：导出侧用它决定写进备份的内容，导入侧用它决定接受哪些键。
/// 两处各写一份时出现过"导出加了、校验没加"——结果是自己导出的备份被自己的
/// 导入拒绝（报"备份包含不允许的设置"）。两处必须永远是同一个集合，所以这里
/// 是唯一的定义处。
const Set<String> backupCarriedSettingKeys = {
  'theme_mode',
  'app_skin_mode',
  'tts_enabled',
  'direct_chat_read_at',
  'direct_chat_source',
  'direct_chat_last_proactive_at',
  'group_chat_read_at',
  'group_chat_last_proactive_at',
  GroupMuteStore.storageKey,
  'pinned_character_ids',
  'pinned_group_ids',
  'memory_pinned_keys_v1',
  'token_usage',
  SearchProviderConfigStore.configsKey,
  SearchProviderConfigStore.defaultProviderKey,
  SearchProviderConfigStore.runtimeSettingsKey,
  AiGovernanceStore.globalSearchPolicyKey,
  AiGovernanceStore.conversationSearchPoliciesKey,
};

/// 按房间维度、每间一个键的设置前缀；这些键随「会话范围」备份。
const List<String> backupCarriedSettingKeyPrefixes = [
  'work_mode_enabled:',
  'context_compressed_through:',
];

/// 该 `app_settings` 键是否由备份携带。
bool isBackupCarriedSettingKey(String key) =>
    backupCarriedSettingKeys.contains(key) ||
    backupCarriedSettingKeyPrefixes.any(key.startsWith);
