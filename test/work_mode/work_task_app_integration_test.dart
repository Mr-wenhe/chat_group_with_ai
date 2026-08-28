import 'dart:io';

import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/models/agent_task.dart';
import 'package:chat_group/features/work_mode/presentation/work_task_overlay_host.dart';
import 'package:chat_group/features/work_mode/work_task_coordinator.dart';
import 'package:chat_group/features/work_mode/work_task_event_store.dart';
import 'package:chat_group/main.dart' as app;
import 'package:chat_group/providers/providers.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../helpers/lifecycle_hive.dart';

class _NoopRunner implements WorkTaskRunner {
  @override
  Future<void> run(AgentTask task, WorkTaskCancellation cancellation) async {}
}

void main() {
  late Directory directory;
  late DatabaseService database;
  late WorkTaskEventStore eventStore;
  late WorkTaskCoordinator coordinator;

  setUp(() async {
    directory = await openLifecycleHive();
    database = DatabaseService();
    eventStore = WorkTaskEventStore(
      appSupportDirectory: Directory('${directory.path}/app-support'),
    );
    coordinator = WorkTaskCoordinator(
      taskBox: database.agentTaskBox,
      eventStore: eventStore,
      runner: _NoopRunner(),
    );
  });

  tearDown(() async {
    await coordinator.dispose();
    await eventStore.close();
    await closeLifecycleHive(directory, database);
  });

  testWidgets('MyApp installs the app-wide non-modal work-task host',
      (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          databaseServiceProvider.overrideWithValue(database),
          workTaskEventStoreProvider.overrideWithValue(eventStore),
          workTaskRunnerProvider.overrideWithValue(_NoopRunner()),
          workTaskCoordinatorProvider.overrideWithValue(coordinator),
        ],
        child: const app.MyApp(),
      ),
    );
    await tester.pump();

    expect(find.byType(WorkTaskOverlayHost), findsOneWidget);
  });
}
