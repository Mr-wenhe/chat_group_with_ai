import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'core/binding/dedup_key_event_binding.dart';
import 'core/database/database_service.dart';
import 'core/database/database_recovery_page.dart';
import 'core/theme/app_theme.dart';
import 'features/ai_character/ai_character_list_page.dart';
import 'features/ai_character/character_gender_migrator.dart';
import 'features/chat_group/chat_group_list_page.dart';
import 'features/chat_group/chat_room_page.dart';
import 'features/direct_chat/direct_chat_foreground_watcher.dart';
import 'features/direct_chat/direct_chat_list_page.dart';
import 'features/direct_chat/direct_chat_session.dart';
import 'features/memory/memory_migrator.dart';
import 'features/memory/observation_entry.dart';
import 'features/settings/settings_page.dart';
import 'providers/providers.dart';

void main() async {
  DedupKeyEventBinding.ensureInitialized();

  final db = DatabaseService();
  try {
    await db.init();
    // 幂等迁移；失败不影响启动。
    try {
      final migrator = MemoryMigrator(db);
      await migrator.migrate();
      await CharacterGenderMigrator(db).migrate();
    } on Object catch (_) {
      // 静默失败，下次启动重试。
    }
  } catch (error) {
    runApp(DatabaseRecoveryApp(
      error: error,
      dataDirPath: db.dataDirPath,
    ));
    return;
  }

  final messageIndexReady = db.ensureMessageIndex();
  unawaited(
    ObservationEntry(db: db).processRetryQueue().catchError((_) => 0),
  );
  runApp(ProviderScope(
    overrides: [databaseServiceProvider.overrideWithValue(db)],
    child: FutureBuilder<void>(
      future: messageIndexReady,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return DatabaseRecoveryApp(
            error: snapshot.error!,
            dataDirPath: db.dataDirPath,
          );
        }
        if (snapshot.connectionState != ConnectionState.done) {
          return const MaterialApp(
            home: Scaffold(
              body: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircularProgressIndicator(),
                    SizedBox(height: 16),
                    Text('正在整理聊天记录…'),
                  ],
                ),
              ),
            ),
          );
        }
        return const MyApp();
      },
    ),
  ));
}

final scaffoldMessengerKey = GlobalKey<ScaffoldMessengerState>();
final navigatorKey = GlobalKey<NavigatorState>();

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
