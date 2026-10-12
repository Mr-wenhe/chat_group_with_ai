import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:chat_group/features/web_search/data/zhipu_native_search_credential_store.dart';
import 'package:chat_group/features/web_search/presentation/web_search_settings_section.dart';
import 'package:chat_group/features/web_search/presentation/zhipu_native_search_settings_card.dart';
import 'package:chat_group/providers/providers.dart';

/// 联网搜索的凭据页：自建 Provider 与智谱原生 Web Search。
///
/// 两块卡片原先嵌在「模型、成本与联网治理」页里，与预算、账本、诊断混在一屏，
/// 找 Key 要翻过整页治理内容。这里只承载凭据本身；搜索**策略**（关闭 / 询问 /
/// 自动）与运行时设置仍留在治理页，因为它们是行为开关，不是密钥。
class SearchCredentialSettingsPage extends ConsumerStatefulWidget {
  const SearchCredentialSettingsPage({super.key});

  @override
  ConsumerState<SearchCredentialSettingsPage> createState() =>
      _SearchCredentialSettingsPageState();
}

class _SearchCredentialSettingsPageState
    extends ConsumerState<SearchCredentialSettingsPage> {
  late final SearchProviderConfigStore _searchSettings;
  late final ZhipuNativeSearchCredentialStore _zhipuSearchCredentials;

  @override
  void initState() {
    super.initState();
    final db = ref.read(databaseServiceProvider);
    _searchSettings = SearchProviderConfigStore(db: db);
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
              '联网搜索默认关闭。启用后查询会发送给你在这里配置的服务商；'
              'Key 只保存在本机，不会进入备份或导出文件。'
              '恢复备份后 Provider 记录还在，但 Key 需要重新绑定。',
              style: TextStyle(
                  fontSize: 13, height: 1.5, color: cs.onSurfaceVariant),
            ),
          const SizedBox(height: 12),
          WebSearchSettingsSection(store: _searchSettings),
          const SizedBox(height: 8),
          ZhipuNativeSearchSettingsCard(store: _zhipuSearchCredentials),
        ],
      ),
    );
  }
}
