import 'package:chat_group/features/ai_governance/ai_governance_store.dart';
import 'package:chat_group/features/chat_group/group_mute_store.dart';
import 'package:chat_group/features/web_search/data/search_settings_store.dart';
import 'package:chat_group/features/work_mode/presentation/work_task_pill_position.dart';
import 'package:chat_group/features/work_mode/work_context_boundary.dart';

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
  // 能力声明决定工作模式能否启动（工具/流式）以及一次能写多长，且内置快照
  // 覆盖不到的模型只能靠它；丢了就要用户逐条重填。
  AiGovernanceStore.customCapabilitiesKey,
  // 用户把任务胶囊拖到哪儿是明确的偏好设置，不带走在恢复后要重摆一次。
  WorkTaskPillPosition.storageKey,
};

/// 按房间维度、每间一个键的设置前缀；这些键随「会话范围」备份。
const List<String> backupCarriedSettingKeyPrefixes = [
  'work_mode_enabled:',
  'context_compressed_through:',
  // 删除任务划下的工作上下文分界线：必须随备份走。它是会话状态（不是用户配置），
  // 不带走的话，恢复后那段已被删掉的上下文会重新进入模型提示。
  WorkContextBoundary.storageKeyPrefix,
];

/// 其中属于「用户配置」的子集，随 `configurationOnly` 范围一起备份。
///
/// 必须是 [backupCarriedSettingKeys] 的子集；两者都是手写字符串，键名打错会静默
/// 失效，因此由 `backup_setting_keys_test.dart` 钉住这层包含关系。
const Set<String> backupConfigurationOnlySettingKeys = {
  'theme_mode',
  'app_skin_mode',
  'tts_enabled',
  'pinned_character_ids',
  'pinned_group_ids',
  // 禁言是用户显式设定的偏好（而非阅后即焚的运行态），随配置一起走。
  GroupMuteStore.storageKey,
  SearchProviderConfigStore.configsKey,
  SearchProviderConfigStore.defaultProviderKey,
  SearchProviderConfigStore.runtimeSettingsKey,
  AiGovernanceStore.globalSearchPolicyKey,
  AiGovernanceStore.conversationSearchPoliciesKey,
  // 能力声明按 provider/model 存、由用户逐条填写，属于配置而非某个房间的状态，
  // 因此不随「会话范围」备份，只随「全部」与「仅配置」。
  AiGovernanceStore.customCapabilitiesKey,
  // 同上的理由：胶囊位置是全局偏好，不属于任何一间房。
  WorkTaskPillPosition.storageKey,
};

/// 该 `app_settings` 键是否由备份携带。
bool isBackupCarriedSettingKey(String key) =>
    backupCarriedSettingKeys.contains(key) ||
    backupCarriedSettingKeyPrefixes.any(key.startsWith);
