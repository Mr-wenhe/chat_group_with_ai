import 'dart:async';
import 'dart:io';

import 'package:chat_group/core/models/agent_task.dart';
import 'package:chat_group/features/work_mode/work_task_coordinator.dart';
import 'package:chat_group/features/work_mode/work_task_event_store.dart';
import 'package:chat_group/providers/providers.dart';
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

/// Stage 04 can exist before the continuous Agent loop is installed in Task 14.
/// The coordinator stays usable for recovery and UI subscription, while an
/// accidental production submit fails visibly instead of pretending to run.
final workTaskRunnerProvider = Provider<WorkTaskRunner>((ref) {
  return const _UnavailableWorkTaskRunner();
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

class _UnavailableWorkTaskRunner implements WorkTaskRunner {
  const _UnavailableWorkTaskRunner();

  @override
  Future<void> run(
    AgentTask task,
    WorkTaskCancellation cancellation,
  ) {
    return Future<void>.error(
      StateError('连续工作 Agent 尚未接入。'),
    );
  }
}
