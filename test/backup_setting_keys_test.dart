import 'package:chat_group/features/backup/backup_setting_keys.dart';
import 'package:flutter_test/flutter_test.dart';

/// 备份携带键的清单与谓词。
///
/// 这些键都是手写字符串集合，任一键名打错都会静默失效（主列表打错 → 该项永不
/// 导出；子集打错 → 该键永不随「仅配置」导出）。可机器判定的部分在这里钉住。
void main() {
  test('「仅配置」清单是主清单的子集', () {
    expect(
      backupConfigurationOnlySettingKeys.difference(backupCarriedSettingKeys),
      isEmpty,
      reason: '子集里出现了主清单没有的键，通常是键名拼写错误',
    );
  });

  test('前缀键由谓词识别，且必须完整匹配前缀', () {
    expect(isBackupCarriedSettingKey('theme_mode'), isTrue);
    expect(isBackupCarriedSettingKey('work_mode_enabled:g1'), isTrue);
    expect(
      isBackupCarriedSettingKey('context_compressed_through:g1:a1'),
      isTrue,
    );
    expect(
      isBackupCarriedSettingKey('work_mode_enabled'),
      isFalse,
      reason: '缺少冒号的前缀不应被误判携带',
    );
    expect(isBackupCarriedSettingKey('some_unrelated_key'), isFalse);
  });
}
