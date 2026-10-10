import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/models/api_config.dart';

/// 全局「AI 接话选人器」使用的 API 配置引用。
///
/// 选人是幕后步骤：它按最新对话决定下一位该由谁说，不产生聊天气泡，也不是
/// 群成员。这条设置只在本机保存**一个已有 [ApiConfig] 的 id**，不保存明文
/// Key、凭据对象或整份配置副本——密钥仍然只走 `SecureStorageService`。
///
/// **不进备份**：设备本地的配置引用跨设备没有意义，恢复后必须重新选择。
/// 因此本键刻意不登记进 `backup_setting_keys.dart`，也就不需要恢复期的 ID
/// 改写规则；导出内容里不会多出任何字段。
///
/// 引用失效（配置被删除、替换、恢复后指向不存在的 id、存储值损坏）一律解析
/// 成 null，由调用方回落到本地编排器——不报错，也不反复调用模型。
class AiSpeakerPickerSettings {
  /// app_settings 键。名字里刻意不含 `apikey` 等敏感词元，避免导出侧的
  /// 密钥扫描把整份备份判成违规；键名由本类独占。
  static const String storageKey = 'ai_speaker_picker_api_config_id_v1';

  final DatabaseService db;

  AiSpeakerPickerSettings(this.db);

  /// 已保存的配置引用 id；未设置或值损坏时返回 null。
  String? selectedConfigId() {
    final raw = db.appSettingsBox.get(storageKey);
    if (raw is! String) return null;
    final id = raw.trim();
    return id.isEmpty ? null : id;
  }

  /// 保存（或清除）配置引用。
  ///
  /// 传 null / 空串表示"改用本地规则"，直接删除该键，不留下空值条目。
  Future<void> select(String? configId) async {
    final id = configId?.trim() ?? '';
    if (id.isEmpty) {
      await db.appSettingsBox.delete(storageKey);
      return;
    }
    await db.appSettingsBox.put(storageKey, id);
  }

  /// 解析出真正可用于选人的配置。
  ///
  /// 引用未设置、指向已删除的配置、或该配置没有凭据时都返回 null。
  ApiConfig? resolveConfig() {
    final id = selectedConfigId();
    if (id == null) return null;
    final config = db.apiConfigBox.get(id);
    if (config == null || !config.hasCredential) return null;
    return config;
  }

  /// 配置被删除时清掉悬空引用，避免设置页长期显示一个不存在的选择。
  ///
  /// 只删除引用本身，不触碰任何别的设置。
  Future<void> clearIfReferencing(String apiConfigId) async {
    if (selectedConfigId() != apiConfigId) return;
    await db.appSettingsBox.delete(storageKey);
  }

  /// 清掉指向**已不存在配置**的悬空引用；返回是否真的清理了残留值。
  ///
  /// 删除入口已经会清理它自己造成的悬空引用；这条针对**本机残留**：备份刻意
  /// 不含这个键（设备本地的引用跨设备没有意义），恢复之后旧值会原样留在本机，
  /// 指向这台设备上并不存在的配置。设置页加载时调用一次，让存储状态与界面
  /// 显示的"已回落本地规则"一致，而不是把一次失效引用一直留着。
  ///
  /// 配置存在但暂时没有凭据**不算**悬空：那是可修的临时状态，绑定留着。
  Future<bool> pruneDangling() async {
    final id = selectedConfigId();
    if (id == null || db.apiConfigBox.containsKey(id)) return false;
    await db.appSettingsBox.delete(storageKey);
    return true;
  }
}
