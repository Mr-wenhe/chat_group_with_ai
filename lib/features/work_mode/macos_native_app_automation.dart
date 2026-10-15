import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:xml/xml.dart';

import 'package:chat_group/core/models/agent_task.dart';
import 'package:chat_group/features/work_mode/agent_decision.dart';
import 'package:chat_group/features/work_mode/work_approval_fingerprint.dart';
import 'package:chat_group/features/work_mode/work_candidate_publication.dart';
import 'package:chat_group/features/work_mode/work_collaboration_state.dart';
import 'package:chat_group/features/work_mode/work_resource_lock_manager.dart';
import 'package:chat_group/features/work_mode/work_task_event.dart';
import 'package:chat_group/features/work_mode/work_task_event_store.dart';
import 'package:chat_group/features/work_mode/work_task_error_sanitizer.dart';
import 'package:chat_group/features/work_mode/work_tool_registry.dart';
import 'package:chat_group/features/work_mode/work_usage_receipt.dart';
import 'macos_app_bundle_archive.dart';

const int _maxNativeImageDataUriChars = 7 * 1024 * 1024;

Set<String> nativeExpectedOutcomeTexts(String expectedResult, String method) {
  final source = '$expectedResult\n$method';
  return RegExp(
    r'(?:显示|出现|提示|变为|变成|结果(?:为|是)|状态(?:为|是)|内容(?:为|是))\s*[^“「"]{0,20}[“「"]([^”」"]{1,512})[”」"]',
  ).allMatches(source).map((match) => match.group(1)!).toSet();
}

/// Checks an expected UI result against the last successful action baseline.
bool nativeExpectedOutcomeChanged({
  required String? actionBeforeText,
  required String currentBeforeText,
  required String observedText,
  required String expectedText,
}) =>
    observedText.contains(expectedText) &&
    !(actionBeforeText ?? currentBeforeText).contains(expectedText);

/// 动作成功之后是否把断言基线前移到动作前的状态。
///
/// 只有可能**写出**验收结果的动作用新基线：`click` / `input` 会改写控件内容，
/// 而 `scroll` / `resize` 只改变可见范围与窗口几何，元素文本不是它们写的；
/// `reopen` 更是只把同一份状态重新载入。让这些动作也顶掉基线，"保存成功 →
/// 调整窗口 → 重开 → 断言"里的基线本身就含有预期文本，而断言要求预期文本不在
/// 基线中，正常结果因此永远拿不到通过收据——重开那一处正是按这条规则修掉的。
bool nativeActionMovesOutcomeBaseline(String action) =>
    action == 'click' || action == 'input';

typedef NativeAppIdentityProbe = Future<NativeAppIdentitySnapshot> Function(
  String bundleId,
  String appPath,
);

class NativeAppProcess {
  final String appPath;
  final String executablePath;
  final int pid;
  const NativeAppProcess(this.appPath, this.executablePath, this.pid);
}

class NativeAppIdentitySnapshot {
  final List<NativeAppProcess> processes;
  final bool frontmostMatches;
  const NativeAppIdentitySnapshot(this.processes, this.frontmostMatches);
}

class NativeAppIdentity {
  static const MethodChannel _channel =
      MethodChannel('com.chatgroup/native_app');

  static Future<NativeAppIdentitySnapshot> probe(
      String bundleId, String appPath) async {
    final value = await _channel.invokeMapMethod<String, dynamic>(
        'processes', {'bundleId': bundleId, 'appPath': appPath});
    if (value == null || value['processes'] is! List) {
      throw StateError('macOS 原生进程身份桥接返回无效数据。');
    }
    final processes = <NativeAppProcess>[];
    for (final raw in value['processes'] as List) {
      if (raw is! Map ||
          raw['bundleId'] != bundleId ||
          raw['appPath'] is! String ||
          raw['executablePath'] is! String ||
          raw['pid'] is! int) {
        throw StateError('macOS 原生进程身份桥接返回无效进程。');
      }
      processes.add(NativeAppProcess(raw['appPath'] as String,
          raw['executablePath'] as String, raw['pid'] as int));
    }
    if (value['frontmostMatches'] is! bool) {
      throw StateError('macOS 原生焦点检查返回无效数据。');
    }
    return NativeAppIdentitySnapshot(
        List.unmodifiable(processes), value['frontmostMatches'] as bool);
  }
}

class MacAppiumServiceConflict implements Exception {
  final String message;
  const MacAppiumServiceConflict(this.message);
}

class MacAppiumServiceOwner {
  static const port = 4725;
  static const appiumVersion = '3.8.0';
  static const mac2DriverVersion = '4.4.0';
  Process? _process;
  String? _nodePath;
  String? _entrypointPath;
  bool _processExited = false;

  bool get isStarted => _process != null;
  bool get isAlive => _process != null && !_processExited;

  static bool? automationModeEnabledFromStatus(String output) {
    final status = output.toLowerCase();
    if (status.contains('automation mode is disabled')) return false;
    if (status.contains('automation mode is enabled')) return true;
    return null;
  }

  static bool shouldPauseForAutomationAuthorization({
    required bool sessionCreationAttempted,
    required int? httpStatus,
    required bool? automationModeEnabled,
  }) =>
      sessionCreationAttempted &&
      httpStatus == 500 &&
      automationModeEnabled == false;

  Future<void> start() async {
    if (_process != null) {
      await _assertOwned();
      return;
    }
    if ((await _listenerPids()).isNotEmpty) {
      throw const MacAppiumServiceConflict(
          '127.0.0.1:4725 已由外部进程占用；未连接或终止该服务。');
    }

    final runtime = await _resolveRuntime();
    final nodePath = await _resolveNode();
    final process = await Process.start(
      nodePath,
      [
        runtime.entrypoint,
        '--address',
        '127.0.0.1',
        '--port',
        '$port',
        '--base-path',
        '/',
        '--allow-insecure=*:session_discovery',
        '--log-level',
        'error',
      ],
      environment: {
        ...Platform.environment,
        'APPIUM_HOME': runtime.appiumHome,
      },
      runInShell: false,
    );
    _process = process;
    _nodePath = nodePath;
    _entrypointPath = runtime.entrypoint;
    _processExited = false;
    unawaited(process.exitCode.then<void>((_) => _processExited = true));
    process.stdout.listen((_) {}, onError: (Object _) {});
    process.stderr.listen((_) {}, onError: (Object _) {});

    try {
      final deadline = DateTime.now().add(const Duration(seconds: 30));
      while (DateTime.now().isBefore(deadline)) {
        if (_processExited) {
          throw StateError('本应用启动的 Appium 进程提前退出。');
        }
        final listeners = await _listenerPids();
        if (listeners.isNotEmpty) {
          if (listeners.length != 1 || listeners.single != process.pid) {
            throw const MacAppiumServiceConflict(
                'Appium 启动期间固定端口被外部进程占用；未接管该服务。');
          }
          await _assertOwned();
          return;
        }
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
      throw TimeoutException('本应用启动的 Appium 未在 30 秒内监听固定端口。');
    } on Object {
      try {
        await stop();
      } on Object catch (cleanupError) {
        throw StateError('Appium 启动失败且进程清理未核实：$cleanupError');
      }
      rethrow;
    }
  }

  Future<void> assertOwned() => _assertOwned();

  Future<void> stop() async {
    final process = _process;
    final nodePath = _nodePath;
    final entrypoint = _entrypointPath;
    if (process == null || nodePath == null || entrypoint == null) return;
    if (!_processExited) {
      await _assertChildIdentity(process.pid, nodePath, entrypoint);
      process.kill(ProcessSignal.sigterm);
      try {
        await process.exitCode.timeout(const Duration(seconds: 5));
      } on TimeoutException {
        await _assertChildIdentity(process.pid, nodePath, entrypoint);
        process.kill(ProcessSignal.sigkill);
        await process.exitCode.timeout(const Duration(seconds: 3));
      }
    }
    if ((await _listenerPids()).contains(process.pid)) {
      throw StateError('Appium 进程退出后仍持有固定监听端口。');
    }
    _process = null;
    _nodePath = null;
    _entrypointPath = null;
    _processExited = false;
  }

  Future<void> _assertOwned() async {
    final process = _process;
    final nodePath = _nodePath;
    final entrypoint = _entrypointPath;
    if (process == null ||
        nodePath == null ||
        entrypoint == null ||
        _processExited) {
      throw StateError('Appium 服务不是由当前运行器持有的活动进程。');
    }
    await _assertChildIdentity(process.pid, nodePath, entrypoint);
    final listeners = await _listenerPids();
    if (listeners.length != 1 || listeners.single != process.pid) {
      throw StateError('固定端口监听 PID 与本应用启动的 Appium 不一致。');
    }
  }

  Future<void> _assertChildIdentity(
      int pid, String nodePath, String entrypoint) async {
    final result = await Process.run(
      '/bin/ps',
      ['-p', '$pid', '-o', 'command='],
      runInShell: false,
    );
    final expected =
        '$nodePath $entrypoint --address 127.0.0.1 --port $port --base-path / --allow-insecure=*:session_discovery --log-level error';
    if (result.exitCode != 0 || result.stdout.toString().trim() != expected) {
      throw StateError('Appium 进程 PID、可执行文件或启动参数身份已变化。');
    }
  }

  Future<List<int>> _listenerPids() async {
    final result = await Process.run(
      '/usr/sbin/lsof',
      ['-nP', '-t', '-iTCP:$port', '-sTCP:LISTEN'],
      runInShell: false,
    );
    if (result.exitCode > 1 ||
        (result.exitCode != 0 && result.stderr.toString().trim().isNotEmpty)) {
      throw const MacAppiumServiceConflict(
          '无法核对 127.0.0.1:4725 的监听进程；已保留 Mac 桌面锁。');
    }
    final pids = <int>[];
    for (final line in result.stdout.toString().split('\n')) {
      final value = int.tryParse(line.trim());
      if (value != null) pids.add(value);
    }
    return pids;
  }

  Future<String> _resolveNode() async {
    for (final directory in (Platform.environment['PATH'] ?? '').split(':')) {
      if (directory.isEmpty) continue;
      final file = File(p.join(directory, 'node'));
      if (await FileSystemEntity.type(file.path, followLinks: false) ==
          FileSystemEntityType.notFound) {
        continue;
      }
      final path = await file.resolveSymbolicLinks();
      final version = await Process.run(path, ['--version'], runInShell: false);
      final match = RegExp(r'^v?(\d+)\.(\d+)')
          .firstMatch(version.stdout.toString().trim());
      if (version.exitCode != 0 || match == null) {
        throw StateError('PATH 中的 Node.js 版本无法验证。');
      }
      final major = int.parse(match.group(1)!);
      final minor = int.parse(match.group(2)!);
      if (!(major >= 24 ||
          (major == 22 && minor >= 12) ||
          (major == 20 && minor >= 19))) {
        throw StateError('Appium/Mac2 需要 Node.js 20.19+、22.12+ 或 24+。');
      }
      return path;
    }
    throw StateError('未在当前应用运行环境 PATH 中找到兼容的 Node.js。');
  }

  Future<_MacAppiumRuntime> _resolveRuntime() async {
    final roots = <String>{};
    void addAncestors(String path) {
      var current = Directory(path).absolute.path;
      for (var depth = 0; depth < 24; depth++) {
        roots.add(p.normalize(current));
        final parent = p.dirname(current);
        if (parent == current) break;
        current = parent;
      }
    }

    addAncestors(Directory.current.path);
    addAncestors(p.dirname(Platform.resolvedExecutable));
    for (final rootPath in roots) {
      final root = Directory(rootPath);
      final pubspec = File(p.join(rootPath, 'pubspec.yaml'));
      if (await FileSystemEntity.type(pubspec.path, followLinks: false) !=
          FileSystemEntityType.file) {
        continue;
      }
      if (!RegExp(r'^name:\s*chat_group\s*$', multiLine: true)
          .hasMatch(await pubspec.readAsString())) {
        continue;
      }
      final runtimePath = p.join(rootPath, 'build', 'p0_macos', 'runtime');
      final entrypoint =
          File(p.join(runtimePath, 'node_modules', 'appium', 'index.js'));
      final appiumDriver = File(p.join(
          runtimePath, 'node_modules', 'appium-mac2-driver', 'package.json'));
      final homeDriver = File(p.join(
          runtimePath, 'appium-home', 'node_modules', 'appium-mac2-driver'));
      if (await FileSystemEntity.type(entrypoint.path, followLinks: false) !=
              FileSystemEntityType.file ||
          await FileSystemEntity.type(appiumDriver.path, followLinks: false) !=
              FileSystemEntityType.file ||
          await FileSystemEntity.type(homeDriver.path, followLinks: false) ==
              FileSystemEntityType.notFound) {
        continue;
      }
      final realRoot = await root.resolveSymbolicLinks();
      final realEntrypoint = await entrypoint.resolveSymbolicLinks();
      final realDriver = await appiumDriver.resolveSymbolicLinks();
      final realHomeDriverPackage =
          await File(p.join(homeDriver.path, 'package.json'))
              .resolveSymbolicLinks();
      if (![realEntrypoint, realDriver, realHomeDriverPackage]
          .every((path) => p.isWithin(realRoot, path))) {
        throw StateError('本地 Appium 运行时包含指向仓库外部的符号链接。');
      }
      if (await _packageVersion(
                  File(p.join(
                      runtimePath, 'node_modules', 'appium', 'package.json')),
                  'appium') !=
              appiumVersion ||
          await _packageVersion(appiumDriver, 'appium-mac2-driver') !=
              mac2DriverVersion ||
          realDriver != realHomeDriverPackage) {
        throw StateError('本地 Appium/Mac2 版本或已安装驱动身份不匹配。');
      }
      return _MacAppiumRuntime(
        entrypoint: realEntrypoint,
        appiumHome: p.join(runtimePath, 'appium-home'),
      );
    }
    throw StateError('未找到仓库内 P0 固定版本的 Appium/Mac2 本地运行时。');
  }

  Future<String?> _packageVersion(File file, String packageName) async {
    final json = jsonDecode(await file.readAsString());
    if (json is! Map ||
        json['name'] != packageName ||
        json['version'] is! String) {
      return null;
    }
    return json['version'] as String;
  }
}

class _MacAppiumRuntime {
  final String entrypoint;
  final String appiumHome;
  const _MacAppiumRuntime({required this.entrypoint, required this.appiumHome});
}

class MacNativeAppAutomation {
  static const _desktopPath = '/__chat_group_macos__/desktop';
  static const _wdaPort = 10123;
  final WorkResourceLockManager locks;
  final WorkTaskEventStore events;
  final Dio _dio;
  final MacAppiumServiceOwner _appiumService;
  final NativeAppIdentityProbe identityProbe;
  final Directory tempRoot;
  final Map<String, _NativeAppSession> _sessions = {};
  WorkResourceLockLease? _blockedLease;
  String? _blockedReason;
  String? _blockedBundleId;
  String? _blockedAppPath;

  MacNativeAppAutomation({
    required this.locks,
    required this.events,
    Dio? dio,
    MacAppiumServiceOwner? appiumService,
    NativeAppIdentityProbe? identityProbe,
    Directory? tempRoot,
    int appiumPort = 4725,
  })  : _dio = dio ??
            Dio(BaseOptions(
              baseUrl: 'http://127.0.0.1:$appiumPort',
              connectTimeout: const Duration(seconds: 5),
              sendTimeout: const Duration(seconds: 30),
              receiveTimeout: const Duration(seconds: 30),
              followRedirects: false,
            )),
        _appiumService = appiumService ?? MacAppiumServiceOwner(),
        identityProbe = identityProbe ?? NativeAppIdentity.probe,
        tempRoot = tempRoot ?? Directory.systemTemp;

  bool get hasUnverifiedCleanup => _blockedReason != null;
  bool hasOpenSession(String taskId) => _sessions.containsKey(taskId);

  Future<WorkToolResult> invoke({
    required AgentTask task,
    required WorkCollaborationState state,
    required WorkCandidate candidate,
    required Map<String, dynamic> assignment,
    required AgentToolCall call,
    required Future<void>? cancellationSignal,
    required bool Function() isCancelled,
  }) async {
    if (!Platform.isMacOS) {
      return const WorkToolResult.permissionDenied(
          message: 'native.app 仅支持已验证的 macOS 桌面。', failureCode: 'toolMissing');
    }
    if (_blockedReason != null && call.arguments['operation'] != 'close') {
      return WorkToolResult.paused(message: _blockedReason!);
    }
    if (isCancelled()) {
      return const WorkToolResult.paused(message: '任务已停止，未继续操作。');
    }
    final operation = call.arguments['operation'];
    if (operation == 'open') {
      return _open(
          task, state, candidate, assignment, cancellationSignal, isCancelled);
    }
    final session = _sessions[task.id];
    if (operation == 'close' && session == null) {
      return _clearResolvedBlockage();
    }
    if (session == null ||
        session.actorId != task.characterId ||
        call.arguments['sessionRef'] != session.sessionRef ||
        session.iterationId != candidate.iterationId ||
        session.artifactDigest != candidate.digest ||
        session.planDigest != state.usagePlanDigest ||
        session.scenarioId != assignment['scenarioId']) {
      return const WorkToolResult.permissionDenied(
          message: '当前 native.app 会话不属于此成员、场景或冻结候选。',
          failureCode: 'discussionPhaseDenied');
    }
    if (operation == 'close') return _close(task.id, session);
    if (operation == 'observe') {
      return _withSessionRef(await _observe(session), session.sessionRef);
    }
    if (operation != 'act') {
      return const WorkToolResult.failed(
          message: 'native.app 操作无效。', failureCode: 'modelProtocol');
    }
    if (session.uncertain) {
      return _withSessionRef(
        const WorkToolResult.paused(
            message: '上一次桌面动作结果不确定；先重新 observe 核对，不自动重放。'),
        session.sessionRef,
      );
    }
    if (isCancelled()) {
      return const WorkToolResult.paused(message: '任务已停止，未继续操作。');
    }
    try {
      return _withSessionRef(
        await _act(
            session, state, assignment, call, cancellationSignal, isCancelled),
        session.sessionRef,
      );
    } on _NativeFocusChanged {
      session.elements.clear();
      session.latest = null;
      session.uncertain = true;
      return _withSessionRef(
        const WorkToolResult.paused(
            message: '操作期间目标 App 失去前台焦点；后续输入已阻断，请重新 observe。'),
        session.sessionRef,
      );
    } on DioException catch (error) {
      if (error.type == DioExceptionType.cancel || isCancelled()) {
        final closed = await _close(task.id, session);
        if (!closed.succeeded) {
          return const WorkToolResult.paused(
              message: '停止已阻断后续动作，但 Appium/App 清理未核实；桌面资源仍被占用。');
        }
        return const WorkToolResult.paused(message: '任务已停止，App 会话已清理。');
      }
      session.uncertain = true;
      return _withSessionRef(
        const WorkToolResult.failed(
            message: 'Appium 动作响应中断，结果不确定；已禁止自动重放，请重新 observe 或 close。',
            failureCode: 'nativeActionUncertain'),
        session.sessionRef,
      );
    } on Object catch (error) {
      return _withSessionRef(
        WorkToolResult.failed(
            message: _safeError(error),
            failureCode: 'nativeAppOperationFailed'),
        session.sessionRef,
      );
    }
  }

  WorkToolResult _withSessionRef(WorkToolResult result, String sessionRef) {
    if (result.data['sessionRef'] == sessionRef) return result;
    return WorkToolResult(
      status: result.status,
      message: result.message,
      data: {...result.data, 'sessionRef': sessionRef},
      failureCode: result.failureCode,
      committed: result.committed,
      usageObservation: result.usageObservation,
    );
  }

  Future<WorkToolResult> _open(
    AgentTask task,
    WorkCollaborationState state,
    WorkCandidate candidate,
    Map<String, dynamic> assignment,
    Future<void>? cancellationSignal,
    bool Function() isCancelled,
  ) async {
    final existing = _sessions[task.id];
    if (existing != null) {
      if (existing.actorId == task.characterId &&
          existing.iterationId == candidate.iterationId &&
          existing.artifactDigest == candidate.digest &&
          existing.planDigest == state.usagePlanDigest &&
          existing.scenarioId == assignment['scenarioId']) {
        return WorkToolResult.alreadyCommitted(
          message: existing.uncertain
              ? '本成员会话仍打开；上次动作结果可能不确定，未重放。先用返回的 sessionRef 重新 observe 核对。'
              : '本成员当前候选会话已打开；未创建第二个会话。',
          data: {'sessionRef': existing.sessionRef},
        );
      }
      return const WorkToolResult.permissionDenied(
          message: '当前成员会话尚未核实关闭，不能切换角色或候选。');
    }
    final manifest = candidate.manifest['nativeBundle'];
    final descriptor = MacAppBundleDescription.tryParse(manifest);
    if (descriptor == null ||
        state.artifactContract['nativeBundle'] is! Map ||
        (state.artifactContract['nativeBundle'] as Map)['appPath'] !=
            descriptor.appPath ||
        (state.artifactContract['nativeBundle'] as Map)['archivePath'] !=
            descriptor.archivePath ||
        !const {
          'macos.native.click',
          'macos.native.input',
          'macos.native.scroll',
          'macos.native.resize',
          'macos.native.reopen',
        }.containsAll(
            (assignment['requiredCapabilities'] as List).cast<String>())) {
      return const WorkToolResult.permissionDenied(
          message: '候选或场景超出 native.app 已验证的权限和能力。',
          failureCode: 'discussionPhaseDenied');
    }
    final lock = await locks.acquire(
      'macos-native:${task.id}',
      const [WorkResourceLockRequest.treeWrite(_desktopPath)],
      cancellation: cancellationSignal,
      isCancelled: isCancelled,
    );
    if (isCancelled()) {
      await lock.release();
      return const WorkToolResult.paused(message: '任务已停止，未打开测试 App。');
    }
    Directory? runRoot;
    String? clonedAppPath;
    String? bundleId;
    var sessionCreationAttempted = false;
    final sessionToken = CancelToken();
    if (cancellationSignal != null) {
      unawaited(cancellationSignal
          .then<void>((_) => sessionToken.cancel('native.app task stopped')));
    }
    try {
      if (await _portIsOpen(_wdaPort)) {
        _blockedReason = 'Mac2 WDA 端口 10123 已被未知进程占用；已保留 Mac 桌面锁，未终止该进程。';
        _blockedLease = lock;
        _blockedBundleId = descriptor.bundleId;
        _blockedAppPath = descriptor.appPath;
        await _recordBlockage(task.id, _blockedReason!);
        return WorkToolResult.paused(message: _blockedReason!);
      }
      try {
        await _appiumService.start();
      } on MacAppiumServiceConflict catch (error) {
        _blockedReason = error.message;
        _blockedLease = lock;
        _blockedBundleId = descriptor.bundleId;
        _blockedAppPath = descriptor.appPath;
        await _recordBlockage(task.id, _blockedReason!);
        return WorkToolResult.paused(message: _blockedReason!);
      }
      final status = await _request('GET', '/status');
      final value = _value(status);
      if (value is! Map || value['ready'] != true || value['build'] is! Map) {
        throw StateError('本应用启动的 Appium 服务返回了无效状态。');
      }
      if (value['build']['version'] != MacAppiumServiceOwner.appiumVersion) {
        throw StateError('Appium 版本与本地固定运行时不一致。');
      }
      final sessions = await _sessionsFromServer();
      if (sessions.isNotEmpty) {
        _blockedReason = '本应用管理的 Appium 出现无法归属的会话；已保留 Mac 桌面锁，未触碰该会话。';
        _blockedLease = lock;
        await _recordBlockage(task.id, _blockedReason!);
        return WorkToolResult.paused(message: _blockedReason!);
      }
      final archive = File(p.joinAll([
        candidate.directory.path,
        'artifacts',
        ...p.posix.split(descriptor.archivePath),
      ]));
      if (await MacAppBundleArchive.inspect(archive,
              appPath: descriptor.appPath, archivePath: descriptor.archivePath)
          .then((actual) =>
              jsonEncode(actual.toJson()) != jsonEncode(descriptor.toJson()))) {
        throw StateError('冻结候选 ZIP 与包内元数据不一致。');
      }
      runRoot = await tempRoot.createTemp('chat-group-native-${task.id}-');
      await Process.run('/bin/chmod', ['700', runRoot.path]);
      final app = await MacAppBundleArchive.extractVerified(
        archive: archive,
        expected: descriptor,
        destination: Directory(p.join(runRoot.path, 'candidate')),
      );
      final appPath = await app.resolveSymbolicLinks();
      clonedAppPath = appPath;
      bundleId = descriptor.bundleId;
      final archiveApp = p.joinAll([
        candidate.directory.path,
        'artifacts',
        ...p.posix.split(descriptor.appPath),
      ]);
      if (await FileSystemEntity.type(archiveApp, followLinks: false) !=
          FileSystemEntityType.notFound) {
        throw StateError('冻结候选中不应存在独立解压目录。');
      }
      final prior = await identityProbe(descriptor.bundleId, appPath);
      if (prior.processes.isNotEmpty) {
        _blockedReason = '检测到同 bundleId 的现存 App 进程；已保留 Mac 桌面锁，未接管、激活或终止它。';
        _blockedLease = lock;
        _blockedBundleId = descriptor.bundleId;
        _blockedAppPath = appPath;
        await _recordBlockage(task.id, _blockedReason!);
        throw StateError('检测到同 bundleId 的旧 App 进程；未接管、激活或终止它。');
      }
      final dataRoot = Directory(p.join(runRoot.path, 'test-data'));
      await dataRoot.create();
      await Process.run('/bin/chmod', ['700', dataRoot.path]);
      if (isCancelled()) {
        throw DioException.requestCancelled(
            requestOptions: RequestOptions(path: '/session'),
            reason: 'native.app task stopped');
      }
      sessionCreationAttempted = true;
      final sessionReply = await _request('POST', '/session',
          body: {
            'capabilities': {
              'alwaysMatch': {
                'platformName': 'Mac',
                'appium:automationName': 'Mac2',
                'appium:appPath': appPath,
                'appium:bundleId': descriptor.bundleId,
                'appium:systemHost': '127.0.0.1',
                'appium:systemPort': _wdaPort,
                'appium:noReset': true,
                'appium:newCommandTimeout': 300,
                'appium:environment': {
                  'CHAT_GROUP_TEST_DATA_DIR': dataRoot.path,
                },
              },
            },
          },
          cancelToken: sessionToken);
      final sessionValue = _value(sessionReply);
      final sessionId =
          sessionValue is Map ? sessionValue['sessionId']?.toString() : null;
      if (sessionId == null || sessionId.isEmpty) {
        throw StateError('Appium 未返回受控 sessionId。');
      }
      final session = _NativeAppSession(
        taskId: task.id,
        conversationId: state.conversationId,
        actorId: task.characterId,
        scenarioId: assignment['scenarioId'] as String,
        iterationId: candidate.iterationId,
        artifactDigest: candidate.digest,
        planDigest: state.usagePlanDigest,
        verificationRevision: state.verificationRevision,
        bundleId: descriptor.bundleId,
        appPath: appPath,
        executablePath: p.joinAll([
          appPath,
          ...p.posix
              .split(descriptor.executablePath)
              .skip(p.posix.split(descriptor.appPath).length),
        ]),
        archive: archive,
        descriptor: descriptor,
        dataRoot: dataRoot,
        runRoot: runRoot,
        appiumSessionId: sessionId,
        lock: lock,
        requiredCapabilities:
            (assignment['requiredCapabilities'] as List).cast<String>().toSet(),
        acceptanceIds:
            (assignment['acceptanceIds'] as List).cast<String>().toList(),
        events: events,
      );
      _sessions[task.id] = session;
      if (isCancelled()) {
        throw DioException.requestCancelled(
            requestOptions: RequestOptions(path: '/session'),
            reason: 'native.app task stopped');
      }
      final serverSessions = await _sessionsFromServer();
      if (!serverSessions.contains(sessionId)) {
        throw StateError('Appium 会话没有进入受控会话表。');
      }
      if (isCancelled()) {
        throw DioException.requestCancelled(
            requestOptions: RequestOptions(path: '/session'),
            reason: 'native.app task stopped');
      }
      await _assertExactProcess(session);
      await _verifyFrozenApp(session);
      session.latest = await _capture(session);
      await _verifyFrozenApp(session);
      if (isCancelled()) {
        throw DioException.requestCancelled(
            requestOptions: RequestOptions(path: '/session'),
            reason: 'native.app task stopped');
      }
      await _appendTrace(session, 'open', 'committed', '');
      return WorkToolResult.success(
          message: '已从冻结候选打开独立测试副本，窗口、进程路径和候选摘要已核对。',
          data: {
            'bundleId': session.bundleId,
            'sessionRef': session.sessionRef,
            'iterationId': session.iterationId,
            'artifactDigest': session.artifactDigest,
            'scenarioId': session.scenarioId,
            'evidenceRefs': session.latest!.refs,
            'content': _snapshotContent(session.latest!),
          });
    } on Object catch (error) {
      final active = _sessions[task.id];
      if (active != null) {
        final cleanup = await _close(task.id, active);
        if (isCancelled()) {
          return WorkToolResult.paused(
              message: cleanup.succeeded
                  ? '任务已停止，App 会话已清理。'
                  : '停止已阻断后续动作，但 App 清理未核实；桌面资源仍被占用。',
              data: {'cleanupVerified': cleanup.succeeded});
        }
        return WorkToolResult.failed(
            message: cleanup.succeeded
                ? _safeError(error)
                : '打开期间出错，且目标 App 清理未核实；桌面锁仍被保留。',
            data: {'cleanupVerified': cleanup.succeeded},
            failureCode: cleanup.succeeded
                ? 'nativeAppOpenFailed'
                : 'nativeAppCleanupBlocked');
      }
      if (sessionCreationAttempted) {
        try {
          final serverSessions = await _sessionsFromServer();
          final processes = bundleId == null || clonedAppPath == null
              ? const <NativeAppProcess>[]
              : (await identityProbe(bundleId, clonedAppPath)).processes;
          if (serverSessions.isNotEmpty ||
              processes.any((p) => p.appPath == clonedAppPath) ||
              await _portIsOpen(_wdaPort)) {
            _blockedReason = 'Appium 创建响应不确定，运行中会话或进程无法归属；已保留 Mac 桌面锁。';
            _blockedLease = lock;
            _blockedBundleId = bundleId;
            _blockedAppPath = clonedAppPath;
          }
        } on Object {
          _blockedReason = 'Appium 创建响应不确定，无法核实会话清理；已保留 Mac 桌面锁。';
          _blockedLease = lock;
          _blockedBundleId = bundleId;
          _blockedAppPath = clonedAppPath;
        }
        if (identical(_blockedLease, lock) && _blockedReason != null) {
          await _recordBlockage(task.id, _blockedReason!);
        }
      }
      final statusCode =
          error is DioException ? error.response?.statusCode : null;
      final automationModeEnabled =
          sessionCreationAttempted && statusCode == 500
              ? await _automationModeStatus()
              : null;
      final needsAutomationAuthorization =
          MacAppiumServiceOwner.shouldPauseForAutomationAuthorization(
        sessionCreationAttempted: sessionCreationAttempted,
        httpStatus: statusCode,
        automationModeEnabled: automationModeEnabled,
      );
      if (!identical(_blockedLease, lock)) {
        try {
          await _appiumService.stop();
        } on Object catch (cleanupError) {
          _blockedReason =
              'Appium 服务启动后清理未核实，桌面资源仍被占用：${_safeError(cleanupError)}';
          _blockedLease = lock;
          await _recordBlockage(task.id, _blockedReason!);
        }
      }
      if (runRoot != null) {
        try {
          if (!identical(_blockedLease, lock)) {
            await runRoot.delete(recursive: true);
          }
        } on Object {
          // The test copy contains no user data; report the original setup failure.
        }
      }
      if (!identical(_blockedLease, lock)) await lock.release();
      if (isCancelled()) {
        return const WorkToolResult.paused(message: '任务已停止，未继续打开测试 App。');
      }
      if (identical(_blockedLease, lock) && _blockedReason != null) {
        return WorkToolResult.paused(message: _blockedReason!);
      }
      if (needsAutomationAuthorization) {
        return const WorkToolResult.paused(
            message:
                'macOS Automation Mode 需要当前用户完成系统认证；未建立 Appium 会话，已停止重试。完成系统授权后可继续。');
      }
      return WorkToolResult.failed(
          message: _safeError(error), failureCode: 'nativeAppOpenFailed');
    }
  }

  Future<bool?> _automationModeStatus() async {
    try {
      final result = await Process.run(
          '/usr/bin/automationmodetool', ['-status'],
          runInShell: false);
      return result.exitCode == 0
          ? MacAppiumServiceOwner.automationModeEnabledFromStatus(
              '${result.stdout}\n${result.stderr}')
          : null;
    } on Object {
      return null;
    }
  }

  Future<WorkToolResult> _observe(_NativeAppSession session) async {
    try {
      await _assertExactProcess(session);
      await _verifyFrozenApp(session);
      final identity = await identityProbe(session.bundleId, session.appPath);
      if (!identity.frontmostMatches) {
        session.elements.clear();
        session.latest = null;
        return const WorkToolResult.paused(
            message: '目标 App 已失去前台焦点；已清除旧控件引用。先让目标重新处于前台，再 observe。');
      }
      session.latest = await _capture(session);
      await _verifyFrozenApp(session);
      session.uncertain = false;
      await _appendTrace(session, 'observe', 'committed', '');
      return WorkToolResult.success(message: '已观察本成员会话的目标窗口。', data: {
        'sessionRef': session.sessionRef,
        'elements': session.latest!.elements,
        'window': session.latest!.window,
        'evidenceRefs': session.latest!.refs,
        'content': _snapshotContent(session.latest!),
        'candidateDigest': session.artifactDigest,
        'scenarioId': session.scenarioId,
      });
    } on Object catch (error) {
      return WorkToolResult.failed(
          message: _safeError(error), failureCode: 'nativeAppObserveFailed');
    }
  }

  Future<WorkToolResult> _act(
    _NativeAppSession session,
    WorkCollaborationState state,
    Map<String, dynamic> assignment,
    AgentToolCall call,
    Future<void>? cancellationSignal,
    bool Function() isCancelled,
  ) async {
    final args = call.arguments;
    final action = args['action'] as String;
    final capability = 'macos.native.$action';
    if (action != 'assert' &&
        !session.requiredCapabilities.contains(capability)) {
      return WorkToolResult.permissionDenied(
          message: '当前试用场景未授权 $action 动作。',
          failureCode: 'discussionPhaseDenied');
    }
    await _assertExactProcess(session);
    await _verifyFrozenApp(session);
    final identity = await identityProbe(session.bundleId, session.appPath);
    if (!identity.frontmostMatches) {
      session.elements.clear();
      session.latest = null;
      return const WorkToolResult.paused(
          message: '目标 App 已失去前台焦点，未发送输入；先重新 observe。');
    }
    final before = session.latest ?? await _capture(session);
    final elementId = args['elementId'] as String?;
    if (elementId != null && !session.elements.containsKey(elementId)) {
      return const WorkToolResult.permissionDenied(
          message: '控件不属于本成员最近一次观察；未向该控件发送动作。',
          failureCode: 'discussionPhaseDenied');
    }
    final fingerprint = WorkApprovalFingerprint.mutation(call: call);
    final replayState = jsonEncode({
      'tree': before.treeDigest,
      'window': before.window,
      'fields': before.fieldValues,
    });
    final replayKey = sha256
        .convert(utf8.encode('${session.sessionRef}|$fingerprint|$replayState'))
        .toString();
    final operationKey = 'native-action:$replayKey';
    if (await events.hasCommittedAction(session.taskId, operationKey)) {
      return const WorkToolResult.alreadyCommitted(
          message: '相同观察状态下的桌面动作已经提交；未重放，请先 observe。',
          data: {'requiresFreshObserve': true});
    }
    // Seal before the first side effect: a lost Appium response can never
    // make the same click/input silently run again after recovery.
    await events.recordCommittedAction(session.taskId, operationKey);
    final token = CancelToken();
    final cancel = cancellationSignal?.then<void>((_) {
      token.cancel('native.app task stopped');
      unawaited(cancelTask(session.taskId));
    });
    try {
      switch (action) {
        case 'click':
          await _assertFrontmost(session);
          final id = await _resolveElement(session, elementId!);
          await _request('POST',
              '/session/${_id(session.appiumSessionId)}/element/${_id(id)}/click',
              body: const {}, cancelToken: token);
          break;
        case 'input':
          await _assertFrontmost(session);
          final id = await _resolveElement(session, elementId!);
          await _request('POST',
              '/session/${_id(session.appiumSessionId)}/element/${_id(id)}/click',
              body: const {}, cancelToken: token);
          await _assertFrontmost(session);
          await _request('POST',
              '/session/${_id(session.appiumSessionId)}/element/${_id(id)}/clear',
              body: const {}, cancelToken: token);
          await _assertFrontmost(session);
          if (!session.elements.containsKey(elementId)) {
            throw _NativeFocusChanged();
          }
          await _request('POST',
              '/session/${_id(session.appiumSessionId)}/element/${_id(id)}/value',
              body: {'text': args['text']}, cancelToken: token);
          break;
        case 'scroll':
          await _assertFrontmost(session);
          final id = await _resolveElement(session, elementId!);
          await _request(
              'POST', '/session/${_id(session.appiumSessionId)}/execute/sync',
              body: {
                'script': 'macos: scroll',
                'args': [
                  {
                    'element': id,
                    'direction': args['direction'],
                    'distance': args['distance'],
                  }
                ],
              },
              cancelToken: token);
          break;
        case 'assert':
          break;
        case 'resize':
          await _assertFrontmost(session);
          final rect = before.window;
          final widthDelta = args['widthDelta'] as int;
          final heightDelta = args['heightDelta'] as int;
          await _request(
              'POST', '/session/${_id(session.appiumSessionId)}/execute/sync',
              body: {
                'script': 'macos: clickAndDrag',
                'args': [
                  {
                    'duration': 0.4,
                    'startX': (rect['x'] as num).toDouble() +
                        (rect['width'] as num).toDouble() -
                        2,
                    'startY': (rect['y'] as num).toDouble() +
                        (rect['height'] as num).toDouble() -
                        2,
                    'endX': (rect['x'] as num).toDouble() +
                        (rect['width'] as num).toDouble() +
                        widthDelta,
                    'endY': (rect['y'] as num).toDouble() +
                        (rect['height'] as num).toDouble() +
                        heightDelta,
                  }
                ],
              },
              cancelToken: token);
          break;
        case 'reopen':
          final beforeFields = before.fieldValues;
          await _assertFrontmost(session);
          await _request(
              'POST', '/session/${_id(session.appiumSessionId)}/execute/sync',
              body: {
                'script': 'macos: terminateApp',
                'args': [
                  {'bundleId': session.bundleId}
                ],
              },
              cancelToken: token);
          await _waitForTargetExit(session);
          if (isCancelled()) {
            throw DioException.requestCancelled(
                requestOptions: RequestOptions(path: '/execute/sync'),
                reason: 'native.app task stopped');
          }
          await _request(
              'POST', '/session/${_id(session.appiumSessionId)}/execute/sync',
              body: {
                'script': 'macos: launchApp',
                'args': [
                  {
                    'bundleId': session.bundleId,
                    'path': session.appPath,
                    'environment': {
                      'CHAT_GROUP_TEST_DATA_DIR': session.dataRoot.path,
                    },
                  }
                ],
              },
              cancelToken: token);
          await _waitForTargetLaunch(session);
          await _verifyFrozenApp(session);
          final reopened = await _capture(session);
          final storage = await _testDataFiles(session.dataRoot);
          final fieldsMatch = beforeFields.isNotEmpty &&
              beforeFields.entries.every(
                  (entry) => reopened.fieldValues[entry.key] == entry.value);
          final resultOk = fieldsMatch && storage.isNotEmpty;
          if (resultOk) {
            // 只登记能力，**不移动断言基线**：重开不改写界面内容，按
            // [nativeActionMovesOutcomeBaseline] 的规则它不是"产生结果"的动作，
            // 基线要留在真正写出这个值的点击/输入之前。它是否保住了状态由这里的
            // fieldsMatch / storage 连同这个能力单独证明。
            session.completedCapabilities.add('macos.native.reopen');
          }
          session.latest = reopened;
          await _verifyFrozenApp(session);
          await _assertExactProcess(session);
          return _observationResult(
            session,
            state,
            before,
            reopened,
            action,
            fingerprint,
            resultOk,
            failureMessage:
                resultOk ? null : '重开后控件数据未与关闭前一致，或测试数据目录没有检测到真实写入。',
            extra: {
              'persistedDataFiles': storage.length,
              'fieldsMatch': fieldsMatch,
            },
          );
      }
      if (isCancelled()) {
        throw DioException.requestCancelled(
            requestOptions: RequestOptions(path: '/session'),
            reason: 'native.app task stopped');
      }
      final after = await _capture(session);
      await _verifyFrozenApp(session);
      session.latest = after;
      if (action == 'assert') {
        final acceptanceId = args['acceptanceId'] as String;
        final expectedText = args['expectedText'] as String;
        final acceptanceIds =
            (assignment['acceptanceIds'] as List).cast<String>();
        final acceptance = state.acceptances
            .where((item) => item['id'] == acceptanceId)
            .firstOrNull;
        final agreedText = '${assignment['expectedResult']} '
            '${acceptance?['method'] ?? ''}';
        final agreedValues = nativeExpectedOutcomeTexts(
          assignment['expectedResult'] as String,
          acceptance?['method'] as String? ?? '',
        );
        final element = after.elements
            .where((item) => item['elementId'] == elementId)
            .firstOrNull;
        final observedText = [element?['label'], element?['value']]
            .whereType<String>()
            .where((value) => value.isNotEmpty)
            .join(' ');
        final assertionBefore = session.lastActionBefore ?? before;
        final actionBeforeElement = assertionBefore.elements
            .where((item) => item['elementId'] == elementId)
            .firstOrNull;
        final actionBeforeText = [
          actionBeforeElement?['label'],
          actionBeforeElement?['value']
        ].whereType<String>().join(' ');
        final currentBeforeText = before.elements
            .where((item) => item['elementId'] == elementId)
            .expand((item) => [item['label'], item['value']])
            .whereType<String>()
            .join(' ');
        final persistenceRequired =
            RegExp(r'持久化|重启|重开|重新打开|再次打开').hasMatch(agreedText);
        final resultOk = acceptanceIds.contains(acceptanceId) &&
            acceptance != null &&
            agreedValues.contains(expectedText) &&
            nativeExpectedOutcomeChanged(
              actionBeforeText:
                  session.lastActionBefore == null ? null : actionBeforeText,
              currentBeforeText: currentBeforeText,
              observedText: observedText,
              expectedText: expectedText,
            ) &&
            session.completedCapabilities
                .containsAll(session.requiredCapabilities) &&
            (!persistenceRequired ||
                session.completedCapabilities.contains('macos.native.reopen'));
        return _observationResult(
          session,
          state,
          assertionBefore,
          after,
          action,
          fingerprint,
          resultOk,
          verifiedAcceptanceIds: resultOk ? [acceptanceId] : const [],
          failureMessage: resultOk ? null : '当前控件内容不符合已批准验收项的预期文本。',
          extra: {
            'acceptanceId': acceptanceId,
            'expectedText': expectedText,
            'observedText': observedText,
          },
        );
      }
      final resultOk = switch (action) {
        'click' => before.treeDigest != after.treeDigest,
        'input' => after.fieldValues[elementId] == args['text'],
        'scroll' => before.treeDigest != after.treeDigest,
        'resize' => (before.window['width'] as num) !=
                (after.window['width'] as num) ||
            (before.window['height'] as num) != (after.window['height'] as num),
        _ => false,
      };
      if (resultOk) {
        session.completedCapabilities.add(capability);
        if (nativeActionMovesOutcomeBaseline(action)) {
          session.lastActionBefore = before;
        }
      }
      return _observationResult(
        session,
        state,
        before,
        after,
        action,
        fingerprint,
        resultOk,
        failureMessage: resultOk ? null : '动作没有产生可观察的目标窗口变化。',
      );
    } on DioException {
      rethrow;
    } on Object {
      session.uncertain = true;
      rethrow;
    } finally {
      if (cancel != null) unawaited(cancel);
    }
  }

  Future<WorkToolResult> _observationResult(
    _NativeAppSession session,
    WorkCollaborationState state,
    _NativeSnapshot before,
    _NativeSnapshot after,
    String action,
    String fingerprint,
    bool actionVerified, {
    String? failureMessage,
    List<String> verifiedAcceptanceIds = const [],
    Map<String, Object?> extra = const {},
  }) async {
    final observation = WorkUsageObservation(
      taskId: session.taskId,
      conversationId: state.conversationId,
      actorId: session.actorId,
      scenarioId: session.scenarioId,
      iterationId: session.iterationId,
      artifactDigest: session.artifactDigest,
      planDigest: session.planDigest,
      verificationRevision: session.verificationRevision,
      runtime: 'macos-native',
      sessionRef: session.sessionRef,
      operation: action,
      beforeRef: before.ref,
      afterRef: after.ref,
      outputRefs: [...before.refs, ...after.refs],
      verifiedAcceptanceIds: actionVerified ? verifiedAcceptanceIds : const [],
      businessResultVerified:
          actionVerified && verifiedAcceptanceIds.isNotEmpty,
    );
    await _appendTrace(
        session, action, actionVerified ? 'observed' : 'failed', fingerprint);
    if (failureMessage != null) {
      return WorkToolResult.failed(
          usageObservation: observation,
          message: failureMessage,
          data: {
            'action': action,
            'businessResultVerified': false,
            'evidenceRefs': [...before.refs, ...after.refs],
            'content': _snapshotContent(after),
            ...extra,
          },
          failureCode: 'nativeAppAcceptanceFailed');
    }
    return WorkToolResult.success(
        usageObservation: observation,
        message: '动作已执行并由新观察核对。',
        data: {
          'action': action,
          'businessResultVerified':
              actionVerified && verifiedAcceptanceIds.isNotEmpty,
          'verifiedAcceptanceIds':
              actionVerified ? verifiedAcceptanceIds : const [],
          'evidenceRefs': [...before.refs, ...after.refs],
          'content': _snapshotContent(after),
          ...extra,
        });
  }

  Future<WorkToolResult> _close(String taskId, _NativeAppSession session) {
    final closing = session.closeFuture;
    if (closing != null) return closing;
    final future = _closeImpl(taskId, session);
    session.closeFuture = future;
    return future;
  }

  Future<WorkToolResult> _closeImpl(
      String taskId, _NativeAppSession session) async {
    session.closing = true;
    var candidateChanged = false;
    try {
      await _verifyFrozenApp(session);
    } on Object {
      candidateChanged = true;
    }
    if (candidateChanged) {
      await session.events.recordCommittedAction(
        taskId,
        'native-session-invalidated:${session.sessionRef}',
      );
    }
    try {
      final serverSessions = await _sessionsFromServer();
      if (serverSessions.contains(session.appiumSessionId)) {
        final processes =
            await identityProbe(session.bundleId, session.appPath);
        if (processes.processes.any((p) =>
            p.appPath == session.appPath &&
            p.executablePath == session.executablePath)) {
          await _request(
              'POST', '/session/${_id(session.appiumSessionId)}/execute/sync',
              body: {
                'script': 'macos: terminateApp',
                'args': [
                  {'bundleId': session.bundleId}
                ],
              });
        }
        await _request('DELETE', '/session/${_id(session.appiumSessionId)}');
      }
      final sessions = await _sessionsFromServer();
      final processes = await identityProbe(session.bundleId, session.appPath);
      if (sessions.contains(session.appiumSessionId) ||
          processes.processes.isNotEmpty ||
          await _portIsOpen(_wdaPort)) {
        throw StateError('Appium/WDA 会话或目标进程仍存在，不能释放桌面锁。');
      }
      await _appiumService.stop();
      if (await _portIsOpen(MacAppiumServiceOwner.port)) {
        throw StateError('Appium 清理后固定端口仍由进程占用，不能释放桌面锁。');
      }
      try {
        await _verifyFrozenApp(session);
      } on Object {
        candidateChanged = true;
      }
      if (candidateChanged) {
        await session.events.recordCommittedAction(
          taskId,
          'native-session-invalidated:${session.sessionRef}',
        );
      }
      _sessions.remove(taskId);
      await session.runRoot.delete(recursive: true);
      await _appendTrace(session, 'close', 'verified', '');
      await session.lock.release();
      _blockedReason = null;
      _blockedLease = null;
      _blockedBundleId = null;
      _blockedAppPath = null;
      final snapshot = session.latest;
      if (candidateChanged && snapshot != null) {
        return WorkToolResult.failed(
          message: '试用副本与冻结候选不一致；会话已清理，本轮使用证据作废。',
          data: {'cleanupVerified': true, 'evidenceRefs': snapshot.refs},
          failureCode: 'nativeAppCandidateChanged',
          usageObservation: WorkUsageObservation(
            taskId: session.taskId,
            conversationId: session.conversationId,
            actorId: session.actorId,
            scenarioId: session.scenarioId,
            iterationId: session.iterationId,
            artifactDigest: session.artifactDigest,
            planDigest: session.planDigest,
            verificationRevision: session.verificationRevision,
            runtime: 'macos-native',
            sessionRef: session.sessionRef,
            operation: 'bundle-integrity-failed',
            beforeRef: snapshot.ref,
            afterRef: '${snapshot.ref}|bundle-integrity-failed',
            outputRefs: snapshot.refs,
          ),
        );
      }
      return const WorkToolResult.success(
          message: '目标进程、Appium 会话与 WDA 端口均已核实清理，桌面锁已释放。',
          data: {'cleanupVerified': true});
    } on Object catch (error) {
      _blockedReason = 'macOS App 清理未核实，桌面资源仍被占用：${_safeError(error)}';
      _blockedLease = session.lock;
      session.closing = false;
      session.closeFuture = null;
      await _recordBlockage(taskId, _blockedReason!);
      return WorkToolResult.failed(
          message: _blockedReason!,
          data: {'cleanupVerified': false},
          failureCode: 'nativeAppCleanupBlocked');
    }
  }

  Future<void> cancelTask(String taskId) async {
    final session = _sessions[taskId];
    if (session == null) return;
    await _close(taskId, session);
  }

  Future<WorkToolResult> _clearResolvedBlockage() async {
    final lease = _blockedLease;
    if (lease == null) {
      return const WorkToolResult.alreadyCommitted(
          message: '当前任务没有待清理的 native.app 会话。');
    }
    try {
      if (await _portIsOpen(_wdaPort)) {
        return WorkToolResult.paused(message: _blockedReason ?? 'Mac 桌面仍被占用。');
      }
      if (_appiumService.isStarted) {
        if (_appiumService.isAlive &&
            (await _sessionsFromServer()).isNotEmpty) {
          return WorkToolResult.paused(
              message: _blockedReason ?? 'Appium 会话仍在运行。');
        }
        await _appiumService.stop();
      } else if (await _portIsOpen(MacAppiumServiceOwner.port)) {
        return WorkToolResult.paused(
            message: _blockedReason ?? '未知 Appium 服务仍占用桌面自动化端口。');
      }
      final bundleId = _blockedBundleId;
      final appPath = _blockedAppPath;
      if (bundleId != null && appPath != null && appPath.isNotEmpty) {
        final identity = await identityProbe(bundleId, appPath);
        if (identity.processes.isNotEmpty) {
          return WorkToolResult.paused(
              message: _blockedReason ?? '同 bundleId 的 App 仍在运行。');
        }
      }
      await lease.release();
      _blockedLease = null;
      _blockedReason = null;
      _blockedBundleId = null;
      _blockedAppPath = null;
      return const WorkToolResult.success(
          message: 'Appium、WDA 和已知目标进程均已核实清理，Mac 桌面锁已释放。',
          data: {'cleanupVerified': true});
    } on Object catch (error) {
      return WorkToolResult.paused(
          message: _blockedReason ?? _safeError(error));
    }
  }

  Future<_NativeSnapshot> _capture(_NativeAppSession session) async {
    await _assertExactProcess(session);
    final identity = await identityProbe(session.bundleId, session.appPath);
    if (!identity.frontmostMatches) {
      throw StateError('目标 App 已失去前台焦点；不从后台继续读取或操作。');
    }
    final source = _value(await _request(
        'GET', '/session/${_id(session.appiumSessionId)}/source'));
    if (source is! String || source.isEmpty || source.length > 1024 * 1024) {
      throw StateError('Appium 控件树为空或超过 1 MiB。');
    }
    final document = XmlDocument.parse(source);
    final window = document.descendants
        .whereType<XmlElement>()
        .firstWhere((element) => element.name.local == 'XCUIElementTypeWindow');
    final windowXml = window.toXmlString(pretty: true);
    final bounds = _attributes(window, const ['x', 'y', 'width', 'height']);
    final rawElements = <Map<String, Object?>>[];
    final elementIds = <String, Map<String, String>>{};
    final fieldValues = <String, String>{};
    for (final element
        in window.descendants.whereType<XmlElement>().take(500)) {
      final identifier = element.getAttribute('identifier')?.trim() ?? '';
      final type = element.name.local;
      if (!RegExp(r'^[A-Za-z0-9_]+$').hasMatch(type)) continue;
      final typeIndex = document.descendants
              .whereType<XmlElement>()
              .takeWhile((candidate) => !identical(candidate, element))
              .where((candidate) => candidate.name.local == type)
              .length +
          1;
      final label = element.getAttribute('label') ?? '';
      final value = element.getAttribute('value');
      if (identifier.isNotEmpty &&
          identifier.length <= 128 &&
          !identifier.startsWith('_XCUI:') &&
          !elementIds.containsKey(identifier)) {
        elementIds[identifier] = {
          'using': 'accessibility id',
          'value': identifier,
        };
        if (type == 'XCUIElementTypeTextField' ||
            type == 'XCUIElementTypeSecureTextField' ||
            type == 'XCUIElementTypeTextView') {
          fieldValues[identifier] = value ?? '';
        }
        rawElements.add({
          'elementId': identifier,
          'type': type,
          if (label.isNotEmpty) 'label': label,
          if (value != null) 'value': value,
          if (element.getAttribute('enabled') != null)
            'enabled': element.getAttribute('enabled') == 'true',
        });
      } else {
        final elementId = 'observed-${rawElements.length}';
        elementIds[elementId] = {
          'using': 'xpath',
          'value': '(//$type)[$typeIndex]',
        };
        if (type == 'XCUIElementTypeTextField' ||
            type == 'XCUIElementTypeSecureTextField' ||
            type == 'XCUIElementTypeTextView') {
          fieldValues[elementId] = value ?? '';
        }
        rawElements.add({
          'elementId': elementId,
          'type': type,
          if (identifier.isNotEmpty) 'accessibilityIdentifier': identifier,
          if (label.isNotEmpty) 'label': label,
          if (value != null) 'value': value,
          if (element.getAttribute('enabled') != null)
            'enabled': element.getAttribute('enabled') == 'true',
        });
      }
    }
    if (rawElements.length > 200) {
      throw StateError('目标窗口控件数超过 200，未向模型展示整桌面。');
    }
    final identifier = window.getAttribute('identifier') ?? '';
    final result = await _request(
        'POST', '/session/${_id(session.appiumSessionId)}/element',
        body: identifier.isEmpty
            ? const {'using': 'class name', 'value': 'XCUIElementTypeWindow'}
            : {'using': 'accessibility id', 'value': identifier});
    final windowElement = _elementId(_value(result));
    final rawPng = _value(await _request('GET',
        '/session/${_id(session.appiumSessionId)}/element/${_id(windowElement)}/screenshot'));
    if (rawPng is! String) throw StateError('Appium 未返回目标窗口截图。');
    final imageDataUri = 'data:image/png;base64,$rawPng';
    if (imageDataUri.length > _maxNativeImageDataUriChars) {
      throw StateError('目标窗口截图超出成员模型可接收的图像上限。');
    }
    final png = base64Decode(rawPng);
    if (png.length < 24 ||
        png.length > WorkTaskEventStore.maxNativeScreenshotBytes) {
      throw StateError('目标窗口截图为空或超过上限。');
    }
    final width = _pngDimension(png, 16);
    final height = _pngDimension(png, 20);
    final process = identity.processes.singleWhere((p) =>
        p.appPath == session.appPath &&
        p.executablePath == session.executablePath);
    final captureSequence = ++session.captureSequence;
    final geometry = jsonEncode({
      'window': bounds,
      'imagePixels': [width, height],
      'scale': [
        width / (bounds['width'] as num).toDouble(),
        height / (bounds['height'] as num).toDouble(),
      ],
      'pid': process.pid,
      'captureSequence': captureSequence,
    });
    final treeRef = await events.writeNativeEvidence(
        session.taskId, 'xml', utf8.encode(windowXml));
    final imageRef =
        await events.writeNativeEvidence(session.taskId, 'png', png);
    final geometryRef = await events.writeNativeEvidence(
        session.taskId, 'json', utf8.encode(geometry));
    final treeDigest = sha256.convert(utf8.encode(windowXml)).toString();
    session.elements
      ..clear()
      ..addAll(elementIds);
    return _NativeSnapshot(
      ref: '$treeRef|$imageRef|$geometryRef|pid:${process.pid}',
      refs: [treeRef, imageRef, geometryRef],
      treeDigest: treeDigest,
      elements: List.unmodifiable(rawElements),
      fieldValues: Map.unmodifiable(fieldValues),
      window: Map.unmodifiable(bounds),
      imageDataUri: imageDataUri,
    );
  }

  Future<String> _resolveElement(
      _NativeAppSession session, String elementId) async {
    final selector = session.elements[elementId];
    if (selector == null) {
      throw StateError('控件引用不属于当前观察。');
    }
    return _elementId(_value(await _request(
        'POST', '/session/${_id(session.appiumSessionId)}/element',
        body: selector)));
  }

  Future<void> _verifyFrozenApp(_NativeAppSession session) =>
      MacAppBundleArchive.verifyExtractedTree(
        app: Directory(session.appPath),
        expected: session.descriptor,
      );

  Future<void> _assertExactProcess(_NativeAppSession session) async {
    final actual = await identityProbe(session.bundleId, session.appPath);
    if (actual.processes.length != 1 ||
        actual.processes.single.appPath != session.appPath ||
        actual.processes.single.executablePath != session.executablePath) {
      throw StateError('同 bundleId 目标进程数量、App 路径或执行文件路径不匹配。');
    }
  }

  Future<void> _assertFrontmost(_NativeAppSession session) async {
    await _assertExactProcess(session);
    if (!(await identityProbe(session.bundleId, session.appPath))
        .frontmostMatches) {
      throw _NativeFocusChanged();
    }
  }

  Future<void> _waitForTargetExit(_NativeAppSession session) async {
    for (var i = 0; i < 40; i++) {
      final actual = await identityProbe(session.bundleId, session.appPath);
      if (!actual.processes.any((p) =>
          p.appPath == session.appPath &&
          p.executablePath == session.executablePath)) {
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    throw StateError('目标 App 在 4 秒内未退出。');
  }

  Future<void> _waitForTargetLaunch(_NativeAppSession session) async {
    for (var i = 0; i < 40; i++) {
      final actual = await identityProbe(session.bundleId, session.appPath);
      if (actual.processes.length == 1 &&
          actual.processes.single.appPath == session.appPath &&
          actual.processes.single.executablePath == session.executablePath &&
          actual.frontmostMatches) {
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    throw StateError('目标 App 未从本轮冻结副本重新启动到前台。');
  }

  Future<List<File>> _testDataFiles(Directory root) async {
    final files = <File>[];
    if (await FileSystemEntity.type(root.path, followLinks: false) !=
        FileSystemEntityType.directory) {
      return files;
    }
    await for (final entity in root.list(recursive: true, followLinks: false)) {
      if (entity is Link) {
        throw StateError('测试数据目录包含符号链接。');
      }
      if (entity is File) {
        if (await entity.length() > 0) files.add(entity);
        if (files.length > 1000) throw StateError('测试数据文件数超过 1000。');
      }
    }
    return files;
  }

  Future<List<String>> _sessionsFromServer() async {
    final response = await _request('GET', '/appium/sessions');
    final value = _value(response);
    if (value is! List ||
        value.any((item) => item is! Map || item['id'] is! String)) {
      throw StateError('Appium 会话列表不是严格 JSON 数组。');
    }
    return value.map((item) => (item as Map)['id'] as String).toList();
  }

  Future<dynamic> _request(String method, String path,
      {Object? body, CancelToken? cancelToken}) async {
    await _appiumService.assertOwned();
    final response = await _dio.request<dynamic>(
      path,
      data: body,
      cancelToken: cancelToken,
      options: Options(
        method: method,
        contentType: Headers.jsonContentType,
        responseType: ResponseType.json,
        validateStatus: (status) =>
            status != null && status >= 200 && status < 300,
      ),
    );
    return response.data;
  }

  dynamic _value(dynamic response) {
    if (response is! Map || !response.containsKey('value')) {
      throw StateError('Appium 响应缺少 value 字段。');
    }
    final value = response['value'];
    if (value is Map && value['error'] != null) {
      throw StateError('Appium 拒绝了受控操作：${value['error']}');
    }
    return value;
  }

  Future<bool> _portIsOpen(int port) async {
    Socket? socket;
    try {
      socket = await Socket.connect('127.0.0.1', port,
          timeout: const Duration(milliseconds: 250));
      return true;
    } on SocketException {
      return false;
    } on TimeoutException {
      return true;
    } finally {
      socket?.destroy();
    }
  }

  Future<void> _appendTrace(_NativeAppSession session, String operation,
      String status, String fingerprint) async {
    final body = jsonEncode({
      'schemaVersion': 1,
      'taskId': session.taskId,
      'actorId': session.actorId,
      'scenarioId': session.scenarioId,
      'iterationId': session.iterationId,
      'artifactDigest': session.artifactDigest,
      'sessionRef': session.sessionRef,
      'operation': operation,
      'status': status,
      if (fingerprint.isNotEmpty) 'approvalFingerprint': fingerprint,
      'timestamp': DateTime.now().toUtc().toIso8601String(),
    });
    final digest = sha256.convert(utf8.encode(body)).toString();
    await events.writeDiscussionDetail(
        session.taskId, digest.substring(0, 24), body);
  }

  Future<void> _recordBlockage(String taskId, String detail) async {
    try {
      await events.append(
        taskId: taskId,
        kind: WorkTaskEventKind.paused,
        title: 'macOS 测试桌面清理被阻塞',
        detail: detail,
        safeMetadata: const {
          'runtime': 'macos-native',
          'resource': 'desktop',
          'cleanupVerified': false,
        },
      );
    } on Object {
      // The lock remains authoritative even if the diagnostic store is unavailable.
    }
  }

  String _elementId(dynamic value) {
    if (value is! Map) throw StateError('Appium 控件引用无效。');
    final id = value['element-6066-11e4-a52e-4f735466cecf'] ?? value['ELEMENT'];
    if (id is! String || id.isEmpty || id.length > 256) {
      throw StateError('Appium 控件引用无效。');
    }
    return id;
  }

  Map<String, num> _attributes(XmlElement element, List<String> names) {
    final result = <String, num>{};
    for (final name in names) {
      final value = double.tryParse(element.getAttribute(name) ?? '');
      if (value == null || !value.isFinite) {
        throw StateError('目标窗口缺少有效几何数据。');
      }
      result[name] = value;
    }
    return result;
  }

  int _pngDimension(List<int> bytes, int offset) =>
      (bytes[offset] << 24) |
      (bytes[offset + 1] << 16) |
      (bytes[offset + 2] << 8) |
      bytes[offset + 3];

  String _id(String value) => Uri.encodeComponent(value);

  String _safeError(Object error) {
    if (error is DioException) {
      return error.type == DioExceptionType.connectionError
          ? '受控 Appium 服务未响应；需要 loopback 127.0.0.1:4725。'
          : '受控 Appium 操作失败，现场已保留。';
    }
    final text = sanitizeWorkTaskError(error);
    if (text == '任务执行失败') return 'native.app 操作失败，现场已保留。';
    return text.length <= 400 ? text : '${text.substring(0, 399)}…';
  }
}

class _NativeFocusChanged implements Exception {}

List<Map<String, Object?>> _snapshotContent(_NativeSnapshot snapshot) => [
      {
        'type': 'text',
        'text': '这是当前成员目标窗口截图，用于本人核对可见结果。',
      },
      {
        'type': 'image_url',
        'image_url': {'url': snapshot.imageDataUri},
      },
    ];

class _NativeAppSession {
  final String taskId;
  final String conversationId;
  final String actorId;
  final String scenarioId;
  final String iterationId;
  final String artifactDigest;
  final String planDigest;
  final int verificationRevision;
  final String bundleId;
  final String appPath;
  final String executablePath;
  final File archive;
  final MacAppBundleDescription descriptor;
  final Directory dataRoot;
  final Directory runRoot;
  final String appiumSessionId;
  final WorkResourceLockLease lock;
  final Set<String> requiredCapabilities;
  final Set<String> completedCapabilities = <String>{};
  final List<String> acceptanceIds;
  final WorkTaskEventStore events;
  final String sessionRef;
  final Map<String, Map<String, String>> elements = {};
  _NativeSnapshot? latest;
  _NativeSnapshot? lastActionBefore;
  bool uncertain = false;
  bool closing = false;
  int captureSequence = 0;
  Future<WorkToolResult>? closeFuture;

  _NativeAppSession({
    required this.taskId,
    required this.conversationId,
    required this.actorId,
    required this.scenarioId,
    required this.iterationId,
    required this.artifactDigest,
    required this.planDigest,
    required this.verificationRevision,
    required this.bundleId,
    required this.appPath,
    required this.executablePath,
    required this.archive,
    required this.descriptor,
    required this.dataRoot,
    required this.runRoot,
    required this.appiumSessionId,
    required this.lock,
    required this.requiredCapabilities,
    required this.acceptanceIds,
    required this.events,
  }) : sessionRef =
            'native:${sha256.convert(utf8.encode('$taskId|$actorId|$iterationId|$appiumSessionId')).toString().substring(0, 24)}';
}

class _NativeSnapshot {
  final String ref;
  final List<String> refs;
  final String treeDigest;
  final List<Map<String, Object?>> elements;
  final Map<String, String> fieldValues;
  final Map<String, num> window;
  final String imageDataUri;

  const _NativeSnapshot({
    required this.ref,
    required this.refs,
    required this.treeDigest,
    required this.elements,
    required this.fieldValues,
    required this.window,
    required this.imageDataUri,
  });
}
