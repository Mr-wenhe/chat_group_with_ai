import 'dart:async';
import 'dart:io';

import 'package:chat_group/core/database/database_service_provider.dart';
import 'package:chat_group/features/work_mode/default_work_task_runner.dart';
import 'package:chat_group/features/work_mode/work_task_coordinator.dart';
import 'package:chat_group/features/work_mode/work_task_event_store.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Stores public task progress beside the app's Hive data, not in a chat page.
final workTaskEventStoreProvider = Provider<WorkTaskEventStore>((ref) {
  final database = ref.watch(databaseServiceProvider);
  final dataDirectoryPath = database.dataDirPath;
  if (dataDirectoryPath == null || dataDirectoryPath.isEmpty) {
    throw StateError('数据库尚未初始化，无法创建工作任务事件存储。');
  }
  final store = WorkTaskEventStore(
    appSupportDirectory: Directory(dataDirectoryPath).parent,
  );
  ref.onDispose(() => unawaited(store.close()));
  return store;
});

/// App-scoped production runner. It resolves each task's character/API config
/// at execution time and drives the existing AgentRuntime tool loop.
final workTaskRunnerProvider = Provider<WorkTaskRunner>((ref) {
  final database = ref.watch(databaseServiceProvider);
  return DefaultWorkTaskRunner(
    database: database,
    eventStore: ref.watch(workTaskEventStoreProvider),
  );
});

/// App-scoped coordinator. This is deliberately a normal [Provider], not an
/// auto-disposed provider, so navigating away from a chat room cannot stop it.
final workTaskCoordinatorProvider = Provider<WorkTaskCoordinator>((ref) {
  final database = ref.watch(databaseServiceProvider);
  final coordinator = WorkTaskCoordinator(
    taskBox: database.agentTaskBox,
    eventStore: ref.watch(workTaskEventStoreProvider),
    runner: ref.watch(workTaskRunnerProvider),
  );
  ref.onDispose(coordinator.dispose);
  return coordinator;
});
