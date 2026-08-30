import 'dart:async';
import 'dart:io';

import 'package:chat_group/core/database/database_service_provider.dart';
import 'package:chat_group/features/work_mode/default_work_task_runner.dart';
import 'package:chat_group/features/work_mode/work_folder_grant_service.dart';
import 'package:chat_group/features/work_mode/work_snapshot_service.dart';
import 'package:chat_group/features/work_mode/work_task_coordinator.dart';
import 'package:chat_group/features/work_mode/work_task_event_store.dart';
import 'package:chat_group/features/work_mode/work_resource_lock_manager.dart';
import 'package:chat_group/features/work_mode/workspace_mutation_service.dart';
import 'package:chat_group/features/work_mode/workspace_file_service.dart';
import 'package:chat_group/features/work_mode/workspace_path_policy.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive/hive.dart';

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
  unawaited(
    store.cleanup(
      isTaskActive: (taskId) {
        final task = database.agentTaskBox.get(taskId);
        return task != null && !task.isTerminal;
      },
    ),
  );
  ref.onDispose(() => unawaited(store.close()));
  return store;
});

/// App-scoped production runner. It resolves each task's character/API config
/// at execution time and drives the existing AgentRuntime tool loop.
final workTaskRunnerProvider = Provider<WorkTaskRunner>((ref) {
  final database = ref.watch(databaseServiceProvider);
  WorkFolderGrantService? grants;
  try {
    grants = ref.watch(workFolderGrantServiceProvider);
  } on HiveError {
    // Lightweight callers (and the first frame during app startup) may have
    // a DatabaseService but no opened app_settings box yet. Let the runner
    // fail closed until the durable Stage 02 grant store is ready; never
    // restore the old bridge path with its weaker authorization boundary.
    grants = null;
  }
  WorkspaceFileService? files;
  WorkspaceMutationService? mutations;
  if (grants != null) {
    try {
      files = ref.watch(workspaceFileServiceProvider);
      mutations = ref.watch(workspaceMutationServiceProvider);
    } on HiveError {
      files = null;
      mutations = null;
    }
  }
  return DefaultWorkTaskRunner(
    database: database,
    eventStore: ref.watch(workTaskEventStoreProvider),
    folderGrantService: grants,
    workspaceFileService: files,
    mutationService: mutations,
    resourceLockManager: ref.watch(workResourceLockManagerProvider),
  );
});

final workFolderGrantServiceProvider = Provider<WorkFolderGrantService>((ref) {
  final database = ref.watch(databaseServiceProvider);
  final service = WorkFolderGrantService(box: database.appSettingsBox);
  // Preloading is only a latency optimisation. A transient Hive/filesystem
  // failure must remain retryable through the coordinator and settings UI,
  // not become an unhandled async error during provider construction.
  unawaited(
    service.load().then<void>(
          (_) {},
          onError: (Object _, StackTrace __) {},
        ),
  );
  return service;
});

final workResourceLockManagerProvider =
    Provider<WorkResourceLockManager>((ref) {
  return WorkResourceLockManager();
});

/// Stage 02's single read boundary. The service is shared by all tasks, while
/// task-specific paths are still revalidated by its grant-backed policy.
final workspaceFileServiceProvider = Provider<WorkspaceFileService>((ref) {
  final grants = ref.watch(workFolderGrantServiceProvider);
  return WorkspaceFileService(
    pathPolicy: WorkspacePathPolicy(grantService: grants),
  );
});

/// App-scoped task snapshot store. The parent of DatabaseService's `data`
/// directory is the platform Application Support directory.
final workSnapshotServiceProvider = Provider<WorkSnapshotService>((ref) {
  final database = ref.watch(databaseServiceProvider);
  final dataDirectoryPath = database.dataDirPath;
  if (dataDirectoryPath == null || dataDirectoryPath.isEmpty) {
    throw StateError('数据库尚未初始化，无法创建工作任务快照存储。');
  }
  final grants = ref.watch(workFolderGrantServiceProvider);
  final settings = grants.settings;
  final service = WorkSnapshotService(
    appSupportDirectory: Directory(dataDirectoryPath).parent,
    pathPolicy: WorkspacePathPolicy(grantService: grants),
    eventStore: ref.watch(workTaskEventStoreProvider),
    retentionDays: settings.retentionDays,
    snapshotLimitBytes: settings.snapshotLimitBytes,
    resourceLockManager: ref.watch(workResourceLockManagerProvider),
    taskActivityResolver: (taskId) {
      final task = database.agentTaskBox.get(taskId);
      return task != null && !task.isTerminal;
    },
  );
  unawaited(
    service.cleanup().then<void>(
          (_) {},
          onError: (Object _, StackTrace __) {},
        ),
  );
  return service;
});

/// The production mutation entry point uses the same path policy and snapshot
/// store as the task runner; callers must still provide an approved plan.
final workspaceMutationServiceProvider =
    Provider<WorkspaceMutationService>((ref) {
  final grants = ref.watch(workFolderGrantServiceProvider);
  return WorkspaceMutationService(
    pathPolicy: WorkspacePathPolicy(grantService: grants),
    snapshotPort: ref.watch(workSnapshotServiceProvider),
    eventStore: ref.watch(workTaskEventStoreProvider),
    resourceLockManager: ref.watch(workResourceLockManagerProvider),
  );
});

/// Compatibility name for integrations that call the boundary "work
/// mutation" rather than "workspace mutation".
final workMutationServiceProvider = workspaceMutationServiceProvider;

/// App-scoped coordinator. This is deliberately a normal [Provider], not an
/// auto-disposed provider, so navigating away from a chat room cannot stop it.
final workTaskCoordinatorProvider = Provider<WorkTaskCoordinator>((ref) {
  final database = ref.watch(databaseServiceProvider);
  final resourceLockManager = ref.watch(workResourceLockManagerProvider);
  WorkFolderGrantService? folderGrantService;
  try {
    // Some lightweight callers construct only the task box. Production
    // startup opens app_settings before this provider is read.
    folderGrantService = ref.watch(workFolderGrantServiceProvider);
  } on HiveError {
    folderGrantService = null;
  }
  final coordinator = WorkTaskCoordinator(
    taskBox: database.agentTaskBox,
    eventStore: ref.watch(workTaskEventStoreProvider),
    runner: ref.watch(workTaskRunnerProvider),
    folderGrantService: folderGrantService,
    requireFolderGrant: true,
    resourceLockManager: resourceLockManager,
    resourceLockPlan: (task) {
      final grants = folderGrantService?.grants
          .where((grant) =>
              grant.available && grant.cloudDisclosureConfirmedAt != null)
          .map((grant) => _canonicalLockRoot(
                grant.path,
                isWindows: resourceLockManager.isWindows,
              ))
          .toSet();
      if (grants == null || grants.isEmpty) {
        return const <WorkResourceLockRequest>[];
      }
      // Clearly read-only tasks hold shared root read leases, so independent
      // readers can run together while still waiting behind a writer.
      // Ambiguous requests keep the conservative tree-write lease; the Stage 02
      // tool also acquires exact operation locks for later model decisions.
      final mode = _isClearlyReadOnlyWorkRequest(task.userRequest)
          ? WorkResourceLockMode.read
          : WorkResourceLockMode.treeWrite;
      return grants
          .map((path) => WorkResourceLockRequest(path: path, mode: mode))
          .toList(growable: false);
    },
    folderPicker: () => FilePicker.platform.getDirectoryPath(
      dialogTitle: '选择工作模式目录',
    ),
    snapshotStatusUpdater: (taskId, status) =>
        ref.read(workSnapshotServiceProvider).markTaskStatus(taskId, status),
  );
  unawaited(coordinator.restore());
  ref.onDispose(coordinator.dispose);
  return coordinator;
});

bool _isClearlyReadOnlyWorkRequest(String request) {
  final lower = request.toLowerCase();
  if (lower.trim().isEmpty) return false;
  final mutation = RegExp(
    r'(写|写入|修改|改写|创建|生成|删除|移除|重命名|替换|保存|覆盖|安装|提交|推送|'
    r'测试|构建|编译|运行|执行|'
    r'\b(?:write|create|generate|modify|edit|delete|remove|rename|replace|save|overwrite|'
    r'install|commit|push|build|test|compile)\b)',
    caseSensitive: false,
  ).hasMatch(lower);
  if (mutation) return false;
  return RegExp(
    r'(读取|读一下|查看|打开|分析|审查|检查|搜索|查找|列出|列举|统计|概览|'
    r'\b(?:read|view|open|analy[sz]e|review|inspect|search|find|list|status|show|'
    r'cat|grep|rg|head|tail)\b)',
    caseSensitive: false,
  ).hasMatch(lower);
}

String _canonicalLockRoot(String path, {required bool isWindows}) {
  try {
    return WorkFolderGrantService.normalizePath(
      Directory(path).resolveSymbolicLinksSync(),
      isWindows: isWindows,
    );
  } on Object {
    // The grant service already validated the lexical path. If a synchronous
    // canonicalization is unavailable, retain that safe value and let the
    // operation-level Stage 02 lock use its resolved path.
    return WorkFolderGrantService.normalizePath(path, isWindows: isWindows);
  }
}
