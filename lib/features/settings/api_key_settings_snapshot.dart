import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/database/database_service_image.dart';
import 'package:chat_group/core/models/api_config.dart';
import 'package:chat_group/features/settings/ai_speaker_picker_settings.dart';
import 'package:chat_group/features/settings/api_key_settings_status.dart';
import 'package:chat_group/features/web_search/data/zhipu_native_search_credential_store.dart';
import 'package:chat_group/features/web_search/data/search_settings_store.dart';

/// 从本机只读快照汇总五类凭据的状态。
///
/// 收集与判据分开：判据是 `api_key_settings_status.dart` 里的纯函数，这里只
/// 负责把各存储里的值取出来喂给它。设置页的入口行与「API KEY 设置」页共用这
/// 一个收集点 —— 两处各维护一套"配没配"的口径，迟早会给出互相矛盾的引导。
ApiKeyOverview collectApiKeyOverview({
  required DatabaseService db,
  required List<ApiConfig> apiConfigs,
}) {
  final speakerPickerId = AiSpeakerPickerSettings(db).selectedConfigId();
  return ApiKeyOverview(<ApiKeyStatusEntry>[
    chatStatus(apiConfigs),
    speakerPickerStatus(
      selectedConfigId: speakerPickerId,
      selectedConfig:
          speakerPickerId == null ? null : db.apiConfigBox.get(speakerPickerId),
    ),
    voiceStatus(db.voiceServiceConfig),
    imageStatus(db.imageServiceConfig),
    searchStatus(
      SearchProviderConfigStore(db: db).configs,
      zhipuNativeConfigured:
          ZhipuNativeSearchCredentialStore(db: db).hasConfiguredCredential,
    ),
  ]);
}
