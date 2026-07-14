import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'core/database/database_service.dart';
import 'core/database/database_recovery_page.dart';
import 'core/theme/app_theme.dart';
import 'features/agentic/tools/local_agent_bridge_launcher.dart';
import 'features/ai_character/ai_character_list_page.dart';
import 'features/chat_group/chat_group_list_page.dart';
import 'features/chat_group/chat_room_page.dart';
import 'features/direct_chat/direct_chat_foreground_watcher.dart';
import 'features/direct_chat/direct_chat_list_page.dart';
import 'features/direct_chat/direct_chat_session.dart';
import 'features/settings/settings_page.dart';
import 'providers/providers.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final db = DatabaseService();
  try {
    await db.init();
  } catch (error, stackTrace) {
    debugPrint('[DB] 初始化失败，进入数据库保护模式：$error');
    debugPrint('$stackTrace');
    runApp(DatabaseRecoveryApp(
      error: error,
      dataDirPath: db.dataDirPath,
    ));
    return;
  }

  // 自动拉起本地 agent 桥接服务（仅桌面端真正生效，Web/移动端为 no-op）。
  // start() 在桌面端进程内直接 bind 54263 启动 HttpServer（立即返回），
  // 因此 await 不会明显阻塞首屏；App 退出时由生命周期观察者关闭。
  final bridgeLauncher = LocalAgentBridgeLauncher();
  if (!kIsWeb) {
    await bridgeLauncher.start(
        workspace: await db.effectiveAiProcessingDirPath());
    WidgetsBinding.instance
        .addObserver(_BridgeLifecycleObserver(bridgeLauncher));
  }

  runApp(
    ProviderScope(
      overrides: [databaseServiceProvider.overrideWithValue(db)],
      child: const MyApp(),
    ),
  );
}

final scaffoldMessengerKey = GlobalKey<ScaffoldMessengerState>();
final navigatorKey = GlobalKey<NavigatorState>();

/// 监听 App 生命周期，在 App 被销毁（detached）时关闭进程内桥接服务。
class _BridgeLifecycleObserver extends WidgetsBindingObserver {
  final LocalAgentBridgeLauncher launcher;

  _BridgeLifecycleObserver(this.launcher);

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // detached 表示引擎即将与平台断开（App 退出），此时同步关闭进程内桥接服务。
    if (state == AppLifecycleState.detached) {
      launcher.stop();
    }
  }
}

class MyApp extends ConsumerWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final db = ref.read(databaseServiceProvider);
    final skin = ref.watch(appSkinModeProvider);
    final isGolden = skin == AppSkinMode.golden;
    return MaterialApp(
      title: 'AI 群聊模拟器',
      theme: isGolden ? AppTheme.goldenTheme : AppTheme.lightTheme,
      darkTheme: isGolden ? AppTheme.goldenTheme : AppTheme.darkTheme,
      themeMode: AppTheme.materialThemeModeFor(skin),
      navigatorKey: navigatorKey,
      scaffoldMessengerKey: scaffoldMessengerKey,
      builder: (context, child) {
        return DirectChatForegroundWatcher(
          db: db,
          scaffoldMessengerKey: scaffoldMessengerKey,
          navigatorKey: navigatorKey,
          child: child ?? const SizedBox.shrink(),
        );
      },
      routes: {
        '/': (_) => const AICharacterListPage(),
        '/groups': (_) => const ChatGroupListPage(),
        '/direct-chats': (_) => const DirectChatListPage(),
        '/settings': (_) => const SettingsPage(),
      },
      onGenerateRoute: (settings) {
        if (settings.name?.startsWith('/chat/') ?? false) {
          final groupId = settings.name!.replaceFirst('/chat/', '');
          return MaterialPageRoute(
              builder: (_) => ChatRoomPage(groupId: groupId));
        }
        if (settings.name?.startsWith('/dm/') ?? false) {
          final characterId = settings.name!.replaceFirst('/dm/', '');
          final conversationId =
              DirectChatSession.conversationIdFor(characterId);
          return MaterialPageRoute(
              builder: (_) => ChatRoomPage(groupId: conversationId));
        }
        return null;
      },
    );
  }
}
