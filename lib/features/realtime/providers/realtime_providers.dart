import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:chat_group/core/database/database_service_provider.dart';
import 'package:chat_group/features/realtime/realtime_group_service.dart';
import 'package:chat_group/features/realtime/realtime_settings.dart';

/// 实时群聊配置（服务地址 + 共享令牌）的读写入口。
final realtimeSettingsStoreProvider = Provider<RealtimeSettingsStore>((ref) {
  final db = ref.watch(databaseServiceProvider);
  return RealtimeSettingsStore(appSettingsBox: db.appSettingsBox);
});

/// 当前生效的实时群聊配置。启动时异步读一次（令牌在安全存储里）。
///
/// 设置页保存后调用 `ref.invalidate(realtimeSettingsProvider)` 让它重新读取。
final realtimeSettingsProvider = FutureProvider<RealtimeSettings>((ref) {
  return ref.watch(realtimeSettingsStoreProvider).load();
});

/// 群注册 / 邀请码解析的 HTTP 客户端。
///
/// 与长连接分开：这里的失败要立刻反馈给用户，长连接的失败要自己重连。
final realtimeGroupServiceProvider = Provider<RealtimeGroupService>(
  (ref) => RealtimeGroupService(),
);
