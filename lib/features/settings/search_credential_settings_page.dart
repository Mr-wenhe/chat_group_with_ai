import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:chat_group/features/web_search/data/zhipu_native_search_credential_store.dart';
import 'package:chat_group/features/web_search/presentation/zhipu_native_search_settings_card.dart';
import 'package:chat_group/providers/providers.dart';

/// 智谱专用搜索凭据；桌面自动联网复用聊天配置，无需搜索 Key。
class SearchCredentialSettingsPage extends ConsumerStatefulWidget {
  const SearchCredentialSettingsPage({super.key});

  @override
  ConsumerState<SearchCredentialSettingsPage> createState() =>
      _SearchCredentialSettingsPageState();
}

class _SearchCredentialSettingsPageState
    extends ConsumerState<SearchCredentialSettingsPage> {
  late final ZhipuNativeSearchCredentialStore _zhipuSearchCredentials;

  @override
  void initState() {
    super.initState();
    final db = ref.read(databaseServiceProvider);
    _zhipuSearchCredentials = ZhipuNativeSearchCredentialStore(db: db);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: cs.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        title: const Text('搜索服务凭据'),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 48),
        children: [
          if (kIsWeb)
            const Card(
              child: ListTile(
                leading: Icon(Icons.info_outline),
                title: Text('Web 端不支持联网搜索'),
                subtitle: Text('请使用 Android、iOS、macOS 或 Windows 版本。'),
              ),
            )
          else
            Text(
              '这里仅配置智谱专用搜索，供新闻角色、圆桌会议等原有流程使用。'
              'macOS 与 Windows 的自动联网由模型按需调用，无需搜索 Key 或开关；'
              '它复用聊天配置，会增加聊天 Token 消耗。其他平台的自动联网未实现。'
              'Key 只保存在本机，不进入备份。',
              style: TextStyle(
                  fontSize: 13, height: 1.5, color: cs.onSurfaceVariant),
            ),
          const SizedBox(height: 12),
          ZhipuNativeSearchSettingsCard(store: _zhipuSearchCredentials),
        ],
      ),
    );
  }
}
