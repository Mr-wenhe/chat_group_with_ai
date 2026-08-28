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
import 'features/work_mode/presentation/work_task_overlay_host.dart';
import 'providers/providers.dart';

const startupCharacterGenderMigrationTimeout = Duration(seconds: 6);
const startupCharacterGenderMigrationDrainTimeout = Duration(seconds: 1);
const startupMemoryMigrationTimeout = Duration(seconds: 6);
const startupMemoryMigrationDrainTimeout = Duration(seconds: 1);
const startupSearchCredentialRepairTimeout = Duration(seconds: 2);

/// Starts the retryable memory migration with a bounded startup wait.
///
/// The migration is idempotent and may finish after the first frame when the
/// bound is exceeded. Keep its eventual future observed so a late storage
/// error cannot become unhandled.
Future<void> runMemoryMigration(
  DatabaseService db, {
  MemoryMigrator? migrator,
  Duration timeout = startupMemoryMigrationTimeout,
  Duration drainTimeout = startupMemoryMigrationDrainTimeout,
}) async {
  final activeMigrator = migrator ?? MemoryMigrator(db);
  final migration = activeMigrator.migrate();
  try {
    await migration.timeout(timeout);
  } on TimeoutException {
    activeMigrator.cancel();
    var lateWriteFenceRequired = true;
    try {
      await activeMigrator.waitForCancellationDrain().timeout(drainTimeout);
      lateWriteFenceRequired = false;
    } on TimeoutException {
      // A local Hive write is stuck. Do not allow the migration to resume with
      // its old snapshot after startup returns.
    } on Object {
      // An alternate migrator may not expose a usable drain signal. The
      // boolean/epoch fence below still protects subsequent writes.
    }
    if (lateWriteFenceRequired) activeMigrator.fencePendingWrites();
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
  Duration drainTimeout = startupCharacterGenderMigrationDrainTimeout,
}) async {
  final activeMigrator = migrator ?? CharacterGenderMigrator(db);
  final migration = activeMigrator.migrate();
  try {
    await migration.timeout(timeout);
  } on TimeoutException {
    activeMigrator.cancel();
    var lateWriteFenceRequired = true;
    try {
      // CharacterGenderMigrator completes this signal after its cancellation
      // path has applied the local fallback. A test or alternate migrator
      // without that contract returns an already-completed signal, preserving
      // the startup bound without guessing a scheduler-dependent delay.
      await activeMigrator.waitForCancellationDrain().timeout(drainTimeout);
      lateWriteFenceRequired = false;
    } on TimeoutException {
      // A local Hive write is stuck. The migration must not be allowed to
      // resume with the old snapshot after startup has returned.
    } on Object {
      // The migrator has already applied its local fallback and safe
      // diagnostic before completing or failing this cancellation drain.
    }
    if (lateWriteFenceRequired) activeMigrator.fencePendingWrites();
    // Keep the original future observed even when an alternate migrator does
    // not expose a drain signal and remains stuck after cancellation.
    unawaited(
      migration.then<void>(
        (_) {},
        onError: (Object _, StackTrace __) {},
      ),
    );
  } on Object {
    // The migrator records only safe diagnostic categories; startup remains
    // usable if storage or an unexpected platform error defeats the retry.
  }
}

/// Retries durable search-credential deletion intents without making a
/// damaged secure store an unbounded startup dependency.
Future<void> runSearchCredentialRepair(
  DatabaseService db, {
  SearchProviderConfigStore? store,
  Duration timeout = startupSearchCredentialRepairTimeout,
}) async {
  final repair = (store ?? SearchProviderConfigStore(db: db))
      .retryPendingCredentialRepairs();
  try {
    await repair.timeout(timeout);
  } on TimeoutException {
    unawaited(
      repair.then<void>(
        (_) {},
        onError: (Object _, StackTrace __) {},
      ),
    );
  } on Object {
    // The marker remains durable and is retried from Settings or the next
    // lifecycle pass when secure storage becomes available again.
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
  unawaited(runSearchCredentialRepair(db));
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
          child: WorkTaskOverlayHost(
            navigatorKey: navigatorKey,
            child: child ?? const SizedBox.shrink(),
          ),
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
