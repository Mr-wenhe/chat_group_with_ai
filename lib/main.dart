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

const startupCharacterGenderMigrationTimeout = Duration(seconds: 6);
// Give cancelled remote inference enough time to finish its local Hive writes
// under a busy device scheduler, while keeping startup strictly bounded.
const startupCharacterGenderMigrationDrainTimeout = Duration(milliseconds: 500);
const startupMemoryMigrationTimeout = Duration(seconds: 6);

/// Starts the retryable memory migration with a bounded startup wait.
///
/// The migration is idempotent and may finish after the first frame when the
/// bound is exceeded. Keep its eventual future observed so a late storage
/// error cannot become unhandled.
Future<void> runMemoryMigration(
  DatabaseService db, {
  MemoryMigrator? migrator,
  Duration timeout = startupMemoryMigrationTimeout,
}) async {
  final migration = (migrator ?? MemoryMigrator(db)).migrate();
  try {
    await migration.timeout(timeout);
  } on TimeoutException {
    // MemoryMigrator has no cancellation contract; its idempotent write pass
    // may finish in the background while the app opens.
    unawaited(
      migration.then<void>(
        (_) {},
        onError: (Object _, StackTrace __) {},
      ),
    );
  } on Object {
    // A later startup retries the migration; opening the UI is still safe.
  }
}

/// Runs before [runApp] when possible, while keeping the startup wait bounded
/// on bad networks and storage failures. Active legacy characters use the
/// deterministic compatibility gender in prompts if the local drain expires.
Future<void> runCharacterGenderMigration(
  DatabaseService db, {
  CharacterGenderMigrator? migrator,
  Duration timeout = startupCharacterGenderMigrationTimeout,
}) async {
  final activeMigrator = migrator ?? CharacterGenderMigrator(db);
  final migration = activeMigrator.migrate();
  try {
    await migration.timeout(timeout);
  } on TimeoutException {
    activeMigrator.cancel();
    try {
      await migration.timeout(startupCharacterGenderMigrationDrainTimeout);
    } on TimeoutException {
      // Cancellation is best effort. Startup must not wait for a stuck local
      // write; the migration future still owns its eventual completion.
      unawaited(
        migration.then<void>(
          (_) {},
          onError: (Object _, StackTrace __) {},
        ),
      );
    } on Object {
      // The migrator has already applied its local fallback and safe
      // diagnostic before completing or failing this cancellation drain.
    }
  } on Object {
    // The migrator records only safe diagnostic categories; startup remains
    // usable if storage or an unexpected platform error defeats the retry.
  }
}

void main() async {
  DedupKeyEventBinding.ensureInitialized();

  final db = DatabaseService();
  try {
    await db.init();
  } catch (error) {
    runApp(DatabaseRecoveryApp(
      error: error,
      dataDirPath: db.dataDirPath,
    ));
    return;
  }
  // These migrations are independent: a legacy-memory warning must not skip
  // the gender pass required before the first real character prompt.
  await runMemoryMigration(db);
  await runCharacterGenderMigration(db);

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
