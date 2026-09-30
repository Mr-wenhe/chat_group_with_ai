# 工作模式：分块写入与截断抢救 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让工作模式的长产物写入天然分成多次小动作（`workspace.patch` 支持追加与合并），并把被输出上限截断的响应里已生成的部分落盘续写。

**Architecture:** 不给模型加新工具，而是在既有写入工具 `workspace.patch` 上增加两种形态（追加、合并），复用既有的路径授权、审批范围、快照与原子替换链路；抢救则把被切断的动作 JSON 前缀提取出来，作为一次**真实的工具请求**跑同一条管线落到暂存分段文件，再以一条独立 message 把续写指令交给下一次决策。

**Tech Stack:** Flutter 3.27.1 / Dart 3.6.0，手写 Provider，`flutter_test`，无新依赖。

**Spec:** `docs/work_mode_chunked_writes_design.md`（本计划与其配套；两者在同一分支上一起演进）

## Global Constraints

- 面向用户的文案、注释、提交信息用中文；代码标识符与既有文件保持一致。
- 追加只吃 UTF-8 文本（与 `workspace.read` 同界）；二进制/敏感路径沿用既有拒绝与审批口径。
- **不改** `_operationKey` 去重语义；**不引入** `expectedSha256` 前置校验；**不改** Hive 模型、box、备份/导出字段；**不影响** `WorkApprovalScope` 的动作语义。
- 审批范围语义三条不可动：同任务同路径已批准动作不重复弹窗、新增路径必须补充审批、删除/命令/不可快照/敏感**始终**逐次审批（见 `work_change_policy.dart`）。
- 单函数 ≤50 行；魔法数字与文案抽具名常量；注释说明 *why*。
- 验证命令固定为 `flutter analyze`（CI 只对 error 失败）与 `flutter test <文件>`；本计划不涉及 Hive 模型改动，**不需要** `build_runner`。
- 测试中若涉及 Hive 写操作须用 `tester.runAsync()`；单个用例超过 30 秒视为疑似死循环，停止并报告文件路径。

## Review Focus

按最容易伤到用户的顺序，逐条钉测试到下面的任务里：

1. **目标文件超过读取上限时追加**：必须在读完之前拒绝（`append_requires_full_read`），不得在残缺内容上拼接——否则文件中间部分会被永久丢掉。→ Task 2。
2. **分段文件在合并前缺失或被改名**：合并必须点名缺失的分段并保持目标文件不变。→ Task 3。
3. **截断点落在转义序列中间**（末尾半个 `\`、半截 `\uXX`）：抢救结果不得吐出半个转义或非法字符。→ Task 6。
4. **抢救文本里含 JSON 转义**（`\n`、`\"`）：落盘后必须是模型原本要写的字符，不是带反斜杠的字面量。→ Task 7。
5. **续写提示穿过上下文压缩**：输入上下文被压缩时，续写指令仍必须到达模型（它不能只存在于被压缩的检查点里）。→ Task 7。

---

### Task 1: 解析器支持 `append` 与 `parts` 参数

**Files:**
- Modify: `lib/features/work_mode/agent_decision_parser.dart:615`（`_validateWorkspacePatchArguments`）
- Test: `test/work_mode/agent_decision_parser_test.dart`（文件末尾新增 group）

**Interfaces:**
- Consumes: 既有 `_validateFields` / `_ArgumentType`（`agent_decision_parser.dart:694`、`:768`）——`stringList` 已存在，会自动校验「元素全是字符串」。
- Produces: `workspace.patch` 的合法参数形态：`{path, content, append}` 与 `{path, parts}`；错误文案供模型自我修正。**本任务不做执行**，执行在 Task 2/3/4。

- [ ] **Step 1: 写失败测试**

在 `test/work_mode/agent_decision_parser_test.dart` 末尾（`void main()` 内）新增：

```dart
  group('workspace.patch append and merge arguments', () {
    String patchJson(Map<String, dynamic> args) => _json({
          'action': 'tool',
          'public_update': '正在写文件。',
          'tool': {'name': 'workspace.patch', 'arguments': args},
          'completion': null,
        });

    test('accepts append with content', () async {
      final result = await parser.parse(
        patchJson({'path': 'report.md', 'content': '第二段', 'append': true}),
      );

      expect(result.isSuccess, isTrue, reason: result.detail);
      final decision = result.decision! as AgentToolDecision;
      expect(decision.tool.arguments['append'], isTrue);
    });

    test('accepts a merge plan with parts only', () async {
      final result = await parser.parse(
        patchJson({
          'path': 'report.md',
          'parts': ['report.part1.md', 'report.part2.md'],
        }),
      );

      expect(result.isSuccess, isTrue, reason: result.detail);
    });

    final invalidCases = <({String name, Map<String, dynamic> args, String detail})>[
      (
        name: 'append without content',
        args: {'path': 'report.md', 'append': true},
        detail: '必须与 content 一起使用',
      ),
      (
        name: 'append together with parts',
        args: {
          'path': 'report.md',
          'content': 'x',
          'append': true,
          'parts': ['a.md'],
        },
        detail: '不能与 content 或 append 同时使用',
      ),
      (
        name: 'parts together with content',
        args: {'path': 'report.md', 'content': 'x', 'parts': ['a.md']},
        detail: '不能与 content 或 append 同时使用',
      ),
      (
        name: 'parts together with an exact patch',
        args: {
          'path': 'report.md',
          'parts': ['a.md'],
          'expectedSha256': 'abc',
          'expectedFragment': 'x',
          'replacement': 'y',
        },
        detail: '不能与 append 或 parts 同时使用',
      ),
      (
        name: 'empty parts',
        args: {'path': 'report.md', 'parts': <String>[]},
        detail: '必须是非空字符串数组',
      ),
      (
        name: 'parts with a blank entry',
        args: {'path': 'report.md', 'parts': ['a.md', ' ']},
        detail: '只能包含非空字符串',
      ),
      (
        name: 'append with a non-boolean flag',
        args: {'path': 'report.md', 'content': 'x', 'append': 'true'},
        detail: '类型不正确',
      ),
    ];

    for (final testCase in invalidCases) {
      test('rejects ${testCase.name}', () async {
        final result = await parser.parse(patchJson(testCase.args));

        expect(result.isFailure, isTrue);
        expect(result.detail, contains(testCase.detail));
      });
    }
  });
```

- [ ] **Step 2: 跑测试确认失败**

Run: `flutter test test/work_mode/agent_decision_parser_test.dart --plain-name "workspace.patch append and merge arguments"`
Expected: FAIL —— `append`/`parts` 目前是未知字段，报 `tool.arguments 不支持字段 append`。

- [ ] **Step 3: 改写校验函数**

把 `agent_decision_parser.dart` 的 `_validateWorkspacePatchArguments` 整体替换为：

```dart
  String? _validateWorkspacePatchArguments(Map<String, dynamic> args) {
    final error = _validateFields(args, const {
      'path': _ArgumentType.string,
      'content': _ArgumentType.string,
      'overwrite': _ArgumentType.boolean,
      'append': _ArgumentType.boolean,
      'parts': _ArgumentType.stringList,
      'expectedSha256': _ArgumentType.string,
      'expectedFragment': _ArgumentType.string,
      'replacement': _ArgumentType.string,
    });
    if (error != null) return error;
    final path = args['path'];
    if (path is! String || path.trim().isEmpty) {
      return 'tool.arguments.path 必须是非空字符串。';
    }
    const patchKeys = {
      'expectedSha256',
      'expectedFragment',
      'replacement',
    };
    final hasExactPatch = args.keys.any(patchKeys.contains);
    final append = args['append'];
    final parts = args['parts'];
    // 四种形态互斥：整文件写 / 精确补丁 / 追加 / 合并。混用会被执行层按不同
    // 语义解析，只有在这里拒绝才能保证模型看到确切原因。
    if (hasExactPatch && (append == true || parts != null)) {
      return 'workspace.patch 的精确补丁不能与 append 或 parts 同时使用。';
    }
    if (parts != null) {
      if (args['content'] != null || append != null) {
        return 'workspace.patch 的 parts 不能与 content 或 append 同时使用。';
      }
      if (parts.isEmpty) {
        return 'workspace.patch.parts 必须是非空字符串数组。';
      }
      if (parts.any((part) => part.trim().isEmpty)) {
        return 'workspace.patch.parts 只能包含非空字符串。';
      }
      return null;
    }
    if (append == true) {
      if (args['content'] is! String) {
        return 'workspace.patch 的 append 必须与 content 一起使用。';
      }
      return null;
    }
    if (!hasExactPatch && args['content'] is! String) {
      return 'workspace.patch 必须提供 content 或完整精确补丁字段。';
    }
    if (hasExactPatch) {
      if (args['content'] != null ||
          args['expectedSha256'] is! String ||
          args['expectedFragment'] is! String ||
          args['replacement'] is! String) {
        return 'workspace.patch 的精确补丁必须包含 expectedSha256、expectedFragment、replacement。';
      }
      if ((args['expectedSha256'] as String).trim().isEmpty) {
        return 'workspace.patch.expectedSha256 必须是非空字符串。';
      }
    }
    return null;
  }
```

- [ ] **Step 4: 跑测试确认通过**

Run: `flutter test test/work_mode/agent_decision_parser_test.dart`
Expected: PASS（含既有全部用例）。

- [ ] **Step 5: 提交**

```bash
git add lib/features/work_mode/agent_decision_parser.dart test/work_mode/agent_decision_parser_test.dart
git commit -m "feat(work-mode): accept append and parts arguments for workspace.patch"
```

---

### Task 2: stage02 追加写

**Files:**
- Modify: `lib/features/work_mode/stage02_workspace_file_tool.dart`（在 `write`（`:321`）之后新增 `append`）
- Test: `test/work_mode/stage02_workspace_file_tool_test.dart`

**Interfaces:**
- Consumes: `pathPolicy.resolve(allowMissing: true)`、`files.readTextRange`（`workspace_file_service.dart:123`）、`_hashFile`（`stage02_workspace_file_tool.dart:772`）、`_filePlan`（`:503`）、`_execute`（`:528`）、`WorkspaceMutationRequest`（默认构造，`contents` + `expectedSha256`）。
- Produces: `Future<Map<String, dynamic>> Stage02WorkspaceFileTool.append(String path, String chunk)`——返回与 `write` 同形的结果 Map（`ok` / `path` / `bytes` / `changed` / `beforeSha256` / `afterSha256`），并可能返回 `not_a_file`、`sensitive_mutation_requires_approval`、`append_requires_full_read`。

- [ ] **Step 1: 写失败测试**

在 `test/work_mode/stage02_workspace_file_tool_test.dart` 末尾新增：

```dart
  test('append creates the file and then extends it without losing text',
      () async {
    final current = task('stage02-append');
    final tool = toolFor(current);
    final path = '${root.path}/notes.md';

    final created = await tool.append(path, '第一段');
    expect(created['ok'], isTrue, reason: '${created['message']}');
    expect(await File(path).readAsString(), '第一段');

    final extended = await tool.append(path, '第二段');
    expect(extended['ok'], isTrue, reason: '${extended['message']}');
    expect(await File(path).readAsString(), '第一段第二段');
    expect(extended['changed'], isTrue);
  });

  test('append to an existing empty file stays a modification', () async {
    final current = task('stage02-append-empty');
    final tool = toolFor(current);
    final path = '${root.path}/empty.md';
    await File(path).writeAsString('');

    final result = await tool.append(path, '内容');

    expect(result['ok'], isTrue, reason: '${result['message']}');
    expect(await File(path).readAsString(), '内容');
  });

  test('append refuses a directory target', () async {
    final current = task('stage02-append-dir');
    final tool = toolFor(current);
    final path = '${root.path}/folder';
    await Directory(path).create();

    final result = await tool.append(path, '内容');

    expect(result['ok'], isFalse);
    expect(result['error'], 'not_a_file');
  });

  test('append refuses a target larger than the read limit', () async {
    // 读回来的只是文件前一段；在残缺内容上拼接会把中间部分永久丢掉，
    // 所以必须在读取阶段就拒绝，而不是写出一份被截短的文件。
    final current = task('stage02-append-huge');
    final smallReads = WorkspaceFileService(
      pathPolicy: pathPolicy,
      limits: const WorkspaceReadLimits(maxReadBytes: 8),
    );
    final tool = toolFor(current, files: smallReads);
    final path = '${root.path}/big.md';
    await File(path).writeAsString('0123456789abcdef');

    final result = await tool.append(path, '尾部');

    expect(result['ok'], isFalse);
    expect(result['error'], 'append_requires_full_read');
    expect(await File(path).readAsString(), '0123456789abcdef');
  });
```

同一步里给测试夹具的 `toolFor` 增加一个可选的服务参数（默认沿用 `setUp` 里的 `files`；参数名不能叫 `files`，否则遮蔽外层同名局部变量）：

```dart
  Stage02WorkspaceFileTool toolFor(
    AgentTask task, {
    WorkspaceFileService? fileService,
    void Function(String path, String operation)? onSensitiveRead,
    bool allowWithoutUndo = false,
    WorkChangeApprovalDecision? approvalDecision,
    String? approvedSensitiveOperation,
  }) {
    final service = fileService ?? files;
    return Stage02WorkspaceFileTool(
      files: service,
      mutations: mutations,
      pathPolicy: pathPolicy,
      task: task,
      workspaceRoot: root.path,
      allowImplicitScope: true,
      approvalDecision: approvalDecision,
      approvedSensitiveOperation: approvedSensitiveOperation,
      approvalCapability: approvedSensitiveOperation == null
          ? null
          : WorkApprovalCapability.sensitiveRead,
      onSensitiveRead: onSensitiveRead,
      allowWithoutUndo: allowWithoutUndo,
      resourceLockManager: resourceLocks,
    );
  }
```

并把上面那个用例里的 `toolFor(current, files: smallReads)` 改为 `toolFor(current, fileService: smallReads)`。

- [ ] **Step 2: 跑测试确认失败**

Run: `flutter test test/work_mode/stage02_workspace_file_tool_test.dart`
Expected: FAIL —— `The method 'append' isn't defined`。

- [ ] **Step 3: 实现 `append`**

在 `stage02_workspace_file_tool.dart` 的 `write` 之后新增：

```dart
  /// 追加写：读出当前内容，把 [chunk] 接到末尾，再走与 [write] 相同的原子
  /// 替换路径落盘。
  ///
  /// 这是长产物唯一可行的分块方式：一次决策的输出有上限，整份正文塞进一次
  /// `content` 会被上游截断、整条动作作废。
  Future<Map<String, dynamic>> append(String path, String chunk) async {
    try {
      final absolute = _absolutePath(path);
      final resolved = await pathPolicy.resolve(absolute, allowMissing: true);
      if (resolved.exists && !resolved.isFile) {
        return {
          'ok': false,
          'error': 'not_a_file',
          'message': '目标不是普通文件，未执行追加。',
          'path': resolved.path,
        };
      }
      final sensitive = files.isSensitivePath(absolute) ||
          files.isSensitivePath(resolved.path);
      // 敏感路径的批准必须在**读取旧内容之前**拿到：读出旧文就等于把文件内容
      // 带进本进程，边界和 write 里哈希前置检查是同一条。
      final plan = _filePlan(
        action: resolved.exists
            ? WorkChangeActionType.modify
            : WorkChangeActionType.create,
        path: resolved.path,
        directory: resolved.authorizedRoot,
        bytes: utf8.encode(chunk).length,
      );
      final sensitiveApproved = approvalDecision?.permitsExecution == true &&
          approvalScope?.allows(plan) == true;
      if (sensitive && !sensitiveApproved) {
        return {
          'ok': false,
          'error': 'sensitive_mutation_requires_approval',
          'requiresApproval': true,
          'sensitive': true,
          'redacted': true,
          'message': '修改、重命名或删除敏感文件必须再次确认。',
          'path': resolved.path,
        };
      }
      var existing = '';
      String? expectedSha;
      if (resolved.exists) {
        final read = await _withReadLock(
          resolved.path,
          () => files.readTextRange(resolved.path),
        );
        if (read.truncated) {
          return {
            'ok': false,
            'error': 'append_requires_full_read',
            'message': '目标文件超过读取上限，无法安全读回后追加；请改用分段文件。',
            'path': resolved.path,
          };
        }
        existing = read.text;
        expectedSha = await _hashFile(File(resolved.path));
      }
      final combined = '$existing$chunk';
      final writePlan = _filePlan(
        action: plan.actionType,
        path: resolved.path,
        directory: resolved.authorizedRoot,
        bytes: utf8.encode(combined).length,
      );
      return _execute(
        writePlan,
        WorkspaceMutationRequest(
          path: resolved.path,
          contents: combined,
          expectedSha256: expectedSha,
          approvalDecision: approvalDecision,
        ),
        sensitivePath: sensitive,
      );
    } on WorkspacePathException catch (error) {
      return _pathError(error, path);
    } on WorkspaceFileException catch (error) {
      return _fileError(error);
    } on FileSystemException {
      return {'ok': false, 'error': 'io', 'message': '无法读取目标文件。'};
    }
  }
```

- [ ] **Step 4: 跑测试确认通过**

Run: `flutter test test/work_mode/stage02_workspace_file_tool_test.dart`
Expected: PASS（含既有用例；夹具改名后原有断言不变）。

- [ ] **Step 5: 提交**

```bash
git add lib/features/work_mode/stage02_workspace_file_tool.dart test/work_mode/stage02_workspace_file_tool_test.dart
git commit -m "feat(work-mode): add append mode to the stage 02 file tool"
```

---

### Task 3: stage02 合并

**Files:**
- Modify: `lib/features/work_mode/stage02_workspace_file_tool.dart`（`append` 之后新增 `merge`）
- Test: `test/work_mode/stage02_workspace_file_tool_test.dart`

**Interfaces:**
- Consumes: Task 2 的读锁与 `_filePlan` / `_execute` / `_hashFile` 用法。
- Produces: `Future<Map<String, dynamic>> Stage02WorkspaceFileTool.merge({required String path, required List<String> parts})`；失败码 `invalid_merge`（含 `missingParts` 列表，供模型与事件点名缺失分段）、`append_requires_full_read`（分段超读取上限）、`not_a_file`。

- [ ] **Step 1: 写失败测试**

```dart
  test('merge promotes a single part into the deliverable', () async {
    final current = task('stage02-merge-single');
    final tool = toolFor(current);
    await File('${root.path}/report.part1.md').writeAsString('全文');

    final result = await tool.merge(
      path: '${root.path}/report.md',
      parts: ['${root.path}/report.part1.md'],
    );

    expect(result['ok'], isTrue, reason: '${result['message']}');
    expect(await File('${root.path}/report.md').readAsString(), '全文');
  });

  test('merge concatenates parts in the given order', () async {
    final current = task('stage02-merge-order');
    final tool = toolFor(current);
    await File('${root.path}/p1.md').writeAsString('一');
    await File('${root.path}/p2.md').writeAsString('二');

    final result = await tool.merge(
      path: '${root.path}/out.md',
      parts: ['${root.path}/p2.md', '${root.path}/p1.md'],
    );

    expect(result['ok'], isTrue, reason: '${result['message']}');
    // 顺序是模型的契约：这里刻意不排序、不去重。
    expect(await File('${root.path}/out.md').readAsString(), '二一');
  });

  test('merge replaces an existing deliverable', () async {
    final current = task('stage02-merge-replace');
    final tool = toolFor(current);
    final target = '${root.path}/report.md';
    await File(target).writeAsString('旧版本');
    await File('${root.path}/report.part1.md').writeAsString('新版本');

    final result = await tool.merge(
      path: target,
      parts: ['${root.path}/report.part1.md'],
    );

    expect(result['ok'], isTrue, reason: '${result['message']}');
    expect(await File(target).readAsString(), '新版本');
  });

  test('merge names the missing parts and keeps the target untouched',
      () async {
    final current = task('stage02-merge-missing');
    final tool = toolFor(current);
    final target = '${root.path}/report.md';
    await File(target).writeAsString('旧版本');
    await File('${root.path}/report.part1.md').writeAsString('一');

    final result = await tool.merge(
      path: target,
      parts: ['${root.path}/report.part1.md', '${root.path}/report.part9.md'],
    );

    expect(result['ok'], isFalse);
    expect(result['error'], 'invalid_merge');
    expect(result['missingParts'], ['${root.path}/report.part9.md']);
    expect(await File(target).readAsString(), '旧版本');
  });

  test('merge refuses more parts than the cap allows', () async {
    final current = task('stage02-merge-cap');
    final tool = toolFor(current);
    await File('${root.path}/p1.md').writeAsString('一');

    final result = await tool.merge(
      path: '${root.path}/out.md',
      parts: List<String>.filled(
        maxWorkspaceMergeParts + 1,
        '${root.path}/p1.md',
      ),
    );

    expect(result['ok'], isFalse);
    expect(result['error'], 'invalid_merge');
  });
```

- [ ] **Step 2: 跑测试确认失败**

Run: `flutter test test/work_mode/stage02_workspace_file_tool_test.dart --plain-name "merge"`
Expected: FAIL —— `The method 'merge' isn't defined`（以及 `maxWorkspaceMergeParts` 未定义）。

- [ ] **Step 3: 实现 `merge`**

在 `stage02_workspace_file_tool.dart` 的 `append` 之后新增：

```dart
/// 一次合并允许的分段数量上限。合并要按顺序把分段全部读进内存再原子写回，
/// 没有上限的话一个被写坏的动作就能要求读进任意多个文件。
const int maxWorkspaceMergeParts = 64;

extension ...
```

（常量放在文件顶层；`merge` 方法体放在 `_WorkspaceFileToolApi`/类体内）

```dart
  /// 合并：按给定顺序把各分段拼成一个文件，原子替换写入 [path]。
  ///
  /// 不排序、不去重——顺序是模型的契约。目标文件在整个过程中要么是旧版本、
  /// 要么是新版本，不会出现"写到一半"的产物。
  Future<Map<String, dynamic>> merge({
    required String path,
    required List<String> parts,
  }) async {
    if (parts.isEmpty || parts.length > maxWorkspaceMergeParts) {
      return {
        'ok': false,
        'error': 'invalid_merge',
        'message': parts.isEmpty
            ? '合并至少需要一个分段文件。'
            : '合并的分段数量超过上限 $maxWorkspaceMergeParts。',
      };
    }
    final missing = <String>[];
    final resolvedParts = <String>[];
    for (final part in parts) {
      try {
        final resolved = await pathPolicy.resolveExisting(_absolutePath(part));
        if (!resolved.isFile) {
          missing.add(part);
          continue;
        }
        resolvedParts.add(resolved.path);
      } on WorkspacePathException {
        missing.add(part);
      }
    }
    if (missing.isNotEmpty) {
      return {
        'ok': false,
        'error': 'invalid_merge',
        'message': '以下分段文件不存在或不可读，合并未执行：${missing.join('、')}',
        'missingParts': missing,
      };
    }
    return _mergeResolvedParts(path, resolvedParts);
  }

  Future<Map<String, dynamic>> _mergeResolvedParts(
    String path,
    List<String> resolvedParts,
  ) async {
    try {
      final resolved = await pathPolicy.resolve(_absolutePath(path), allowMissing: true);
      if (resolved.exists && !resolved.isFile) {
        return {
          'ok': false,
          'error': 'not_a_file',
          'message': '合并目标不是普通文件，未执行合并。',
          'path': resolved.path,
        };
      }
      final buffer = StringBuffer();
      for (final part in resolvedParts) {
        final read = await _withReadLock(
          part,
          () => files.readTextRange(part),
        );
        if (read.truncated) {
          return {
            'ok': false,
            'error': 'append_requires_full_read',
            'message': '分段文件超过读取上限，无法安全合并：$part',
            'path': part,
          };
        }
        buffer.write(read.text);
      }
      final combined = buffer.toString();
      final sensitive = files.isSensitivePath(resolved.path) ||
          resolvedParts.any(files.isSensitivePath);
      final expectedSha =
          resolved.exists ? await _hashFile(File(resolved.path)) : null;
      final plan = _filePlan(
        action: resolved.exists
            ? WorkChangeActionType.modify
            : WorkChangeActionType.create,
        path: resolved.path,
        directory: resolved.authorizedRoot,
        bytes: utf8.encode(combined).length,
      );
      return _execute(
        plan,
        WorkspaceMutationRequest(
          path: resolved.path,
          contents: combined,
          expectedSha256: expectedSha,
          approvalDecision: approvalDecision,
        ),
        sensitivePath: sensitive,
      );
    } on WorkspacePathException catch (error) {
      return _pathError(error, path);
    } on WorkspaceFileException catch (error) {
      return _fileError(error);
    } on FileSystemException {
      return {'ok': false, 'error': 'io', 'message': '无法读取分段文件。'};
    }
  }
```

- [ ] **Step 4: 跑测试确认通过**

Run: `flutter test test/work_mode/stage02_workspace_file_tool_test.dart`
Expected: PASS。

- [ ] **Step 5: 提交**

```bash
git add lib/features/work_mode/stage02_workspace_file_tool.dart test/work_mode/stage02_workspace_file_tool_test.dart
git commit -m "feat(work-mode): merge staged parts into a deliverable atomically"
```

---

### Task 4: 工具接线（schema + handler + 计划器）

**Files:**
- Modify: `lib/features/work_mode/default_work_task_runner_tools.dart:337-392`（schema 与 handler）
- Modify: `lib/features/work_mode/default_work_task_runner_context.dart:172`（新增 `_isMergePatch` 谓词附近）
- Modify: `lib/features/work_mode/default_work_task_runner_file_policy.dart:17`（自动改名开关）
- Modify: `test/work_mode/default_work_task_runner_stage02_test.dart`（`_SequencedGateway` 增加 `patchArguments`，新增端到端用例）
- Modify: `docs/work_mode_chunked_writes_design.md`（补 §3.2 的审批次数事实）

**Interfaces:**
- Consumes: Task 2 的 `append(path, chunk)`、Task 3 的 `merge(path:, parts:)`、Task 1 的校验。
- Produces: 模型可用 `{"name":"workspace.patch","arguments":{"path":..,"content":..,"append":true}}` 与 `{"path":..,"parts":[..]}`；两种形态都不允许自动改名（避免给交付物造出近似重复）。

**事实核对（写进 spec）**：审批范围条目记录的是「路径 + 动作集合」，而追加序列里第一次是 `create`、之后都是 `modify`。因此**新建文件的长产物会弹 2 次审批**（create 一次、首次 modify 一次），之后同路径免费；修订既有文件只弹 1 次。这不是本任务引入的行为，是既有范围语义；必须写清楚，避免"会弹一次"的错误预期。

- [ ] **Step 1: 修正 spec 的审批次数说明**

在 `docs/work_mode_chunked_writes_design.md` §3.2 的「修订钉定不变」条目后插入：

```markdown
- **审批次数**：审批范围条目记录的是「路径 + 动作集合」，而追加序列第一次是 `create`、其余是 `modify`。所以新建文件的长产物弹 **2** 次审批（create 一次 + 首次 modify 一次），此后同一路径免费；修订既有文件（始终 modify）只弹 **1** 次。这是既有范围语义的结果，不是本设计新增的摩擦。
```

- [ ] **Step 2: 写失败测试**

在 `test/work_mode/default_work_task_runner_stage02_test.dart` 里给 `_SequencedGateway` 增加可选参数：

```dart
class _SequencedGateway extends AiRequestGateway {
  final String patchPath;
  final String patchContent;
  final Map<String, dynamic>? patchArguments;
  final bool repeatToolOnSecondModelCall;
  final String? finishSummary;

  _SequencedGateway({
    this.patchPath = 'notes.txt',
    this.patchContent = 'production-stage02',
    this.patchArguments,
    this.repeatToolOnSecondModelCall = false,
    this.finishSummary,
  }) : super(
          store: MemoryGovernanceStore(),
          client: _UnusedClient(),
        );
```

并把 `returnsTool` 分支里的 `arguments` 换成：

```dart
                'arguments':
                    patchArguments ?? {'path': patchPath, 'content': patchContent},
```

随后新增端到端用例（放在 `production runner routes approved workspace.patch through Stage02` 之后）：

```dart
  test('production runner appends through Stage02 without re-prompting',
      () async {
    // 追加序列的第一次是 create（文件不存在），第二次起是 modify；第二次因为
    // 动作不在已批准集合里必须补一次审批，此后同路径不再弹窗。
    final grants = WorkFolderGrantService(
      box: database.appSettingsBox,
      directoryValidator: (_) async => true,
      writeDirectoryValidator: (_) async => true,
      isWindows: false,
    );
    expect(
      await grants.authorizeDirectory(
        authorizedDirectory.path,
        consent: (_) async => true,
      ),
      isNotNull,
    );
    final pathPolicy = WorkspacePathPolicy(grantService: grants);
    final files = WorkspaceFileService(pathPolicy: pathPolicy);
    final snapshots = WorkSnapshotService(
      appSupportDirectory: Directory('${hiveDirectory.path}/app-support-append'),
      pathPolicy: pathPolicy,
    );
    final mutations = WorkspaceMutationService(
      pathPolicy: pathPolicy,
      snapshotPort: snapshots,
    );
    final gateway = _AppendGateway();
    final config = ApiConfig(
      id: 'stage02-append-config',
      name: 'Stage02 append config',
      provider: ApiProvider.deepseek.name,
      modelName: 'deepseek-chat',
    );
    final character = AICharacter(
      id: 'stage02-append-character',
      name: 'Stage02 append character',
      avatar: 'A',
      age: 30,
      role: '测试追加角色',
      personalityTags: const [],
      systemPrompt: '只按工具协议工作。',
      apiKey: '',
      apiProvider: ApiProvider.deepseek.name,
      modelName: 'deepseek-chat',
      apiConfigId: config.id,
      toolPermissions: const [
        ToolPermission.workspaceRead,
        ToolPermission.workspacePatch,
      ],
    );
    await database.apiConfigBox.put(config.id, config);
    await database.aiCharacterBox.put(character.id, character);

    final runner = DefaultWorkTaskRunner(
      database: database,
      eventStore: eventStore,
      credentials: _TestCredentials(),
      gateway: gateway,
      workspaceService: WorkModeWorkspaceService(
        db: database,
        grantService: grants,
      ),
      folderGrantService: grants,
      workspaceFileService: files,
      mutationService: mutations,
    );
    final task = AgentTask(
      id: 'stage02-append-runner-task',
      groupId: 'stage02-append-group',
      characterId: character.id,
      userRequest: '把报告分块写入',
      workModeTask: true,
    );

    Future<void> approveAndRun() async {
      final checkpoint = jsonDecode(task.executionStateJson) as Map;
      task.executionStateJson = jsonEncode({
        ...checkpoint,
        'approvalDecision': 'approved',
      });
      task.status = AgentTaskStatus.queued;
      await database.agentTaskBox.put(task.id, task);
      await runner.run(task, WorkTaskCancellation());
    }

    await runner.run(task, WorkTaskCancellation());
    expect(task.status, AgentTaskStatus.waitingForApproval,
        reason: '首次追加是 create，必须审批');
    await approveAndRun();
    expect(task.status, AgentTaskStatus.waitingForApproval,
        reason: '第二次追加是 modify，动作不在已批准集合内，需要补充审批');
    await approveAndRun();
    expect(task.status, AgentTaskStatus.completed,
        reason: '第三次追加落在已批准范围内，不再弹窗：${task.lastError}');

    final output = File(
      '${authorizedDirectory.path}/conversations/group_stage02-append-group/report.md',
    );
    expect(await output.readAsString(), '第一段第二段第三段');
  });
```

并新增一个只产追加动作的 gateway 夹具（紧跟 `_SequencedGateway` 之后）：

```dart
/// 连续三次追加同一个交付物，然后收尾；用来钉住"create 一次 + modify 一次
/// 之后同路径免费"的审批次数。
class _AppendGateway extends AiRequestGateway {
  _AppendGateway()
      : super(
          store: MemoryGovernanceStore(),
          client: _UnusedClient(),
        );

  int calls = 0;
  static const List<String> chunks = ['第一段', '第二段', '第三段'];

  @override
  Future<Map<String, dynamic>> sendChatMessageStreamed({
    required String apiKey,
    required ApiProvider provider,
    ApiProtocol apiProtocol = ApiProtocol.defaultValue,
    String? customBaseUrl,
    required String model,
    required List<Map<String, dynamic>> messages,
    required AiRequestPurpose purpose,
    required String conversationId,
    required String characterId,
    double temperature = 0.85,
    int maxTokens = 1024,
    Duration receiveTimeout = const Duration(seconds: 120),
    int maxRetries = 5,
    CancelToken? cancelToken,
    bool requiresTools = false,
    bool userInitiated = false,
    void Function(ChatStreamEvent event)? onEvent,
  }) async {
    calls++;
    if (calls <= chunks.length) {
      return {
        'success': true,
        'message': jsonEncode({
          'action': 'tool',
          'public_update': '正在追加第 $calls 段。',
          'tool': {
            'name': 'workspace.patch',
            'arguments': {
              'path': 'report.md',
              'content': chunks[calls - 1],
              'append': true,
            },
          },
          'completion': null,
        }),
      };
    }
    return {
      'success': true,
      'message': jsonEncode({
        'action': 'finish',
        'public_update': '分块写入已完成。',
        'tool': null,
        'completion': {
          'summary': '已生成 report.md。',
          'evidence': ['文件可重新读取'],
        },
      }),
    };
  }
}
```

- [ ] **Step 3: 跑测试确认失败**

Run: `flutter test test/work_mode/default_work_task_runner_stage02_test.dart --plain-name "appends through Stage02"`
Expected: FAIL —— handler 不认识 `append`，会被当作整文件写（内容只有最后一段），断言 `第一段第二段第三段` 失败。

- [ ] **Step 4: 接线 schema 与 handler**

`default_work_task_runner_tools.dart` 里 schema 增加两个字段：

```dart
        schema: const WorkToolSchema(
          fields: {
            'path': WorkToolValueType.string,
            'content': WorkToolValueType.string,
            'append': WorkToolValueType.boolean,
            'parts': WorkToolValueType.stringList,
            'expectedSha256': WorkToolValueType.string,
            'expectedFragment': WorkToolValueType.string,
            'replacement': WorkToolValueType.string,
            'overwrite': WorkToolValueType.boolean,
          },
          required: {'path'},
        ),
```

handler 改为（保留 `content`/精确补丁两条现状分支）：

```dart
        handler: (invocation) async {
          final denied = permission(ToolPermission.workspacePatch);
          if (!denied.succeeded) return denied;
          final args = invocation.arguments;
          final path = await _mutationPath(
            task,
            stage02,
            args['path'],
            allowAutoRename:
                !_isExactPatch(args) && !_isMergePatch(args),
          );
          final parts = args['parts'];
          if (parts is List && parts.every((part) => part is String)) {
            // 合并目标就是交付物：自动改名会造出"报告 (1).md"这类近似重复，
            // 而模型随后会按原路径去读它，见到的却是旧文件。
            final effective = parts
                .map((part) => _effectivePath(task, workspaceRoot, part))
                .toList(growable: false);
            return _mapFileResult(
              await stage02.merge(
                path: path,
                parts: effective,
              ),
            );
          }
          final content = args['content'];
          if (content is String) {
            if (args['append'] == true) {
              return _mapFileResult(await stage02.append(path, content));
            }
            if (args['overwrite'] == false && await File(path).exists()) {
              return const WorkToolResult.failed(
                message: '目标文件已存在且 overwrite=false，未执行写入。',
                failureCode: 'targetExists',
              );
            }
            final raw = await stage02.write(path, content);
            return _mapFileResult(raw);
          }
          final patch = <String, dynamic>{
            'path': path,
            'expectedSha256': args['expectedSha256'],
            'expectedFragment': args['expectedFragment'],
            'replacement': args['replacement'],
          };
          return _mapFileResult(await stage02.applyPatch(jsonEncode(patch)));
        },
```

`default_work_task_runner_context.dart` 里 `_isExactPatch`（`:172`）之后新增：

```dart
  /// 合并形态（`parts`）与精确补丁一样不接受自动改名：它的 `path` 是交付物
  /// 本身，改名只会让模型随后读回旧文件。
  bool _isMergePatch(Map<String, dynamic> args) => args['parts'] is List;
```

`default_work_task_runner_file_policy.dart:17` 的计划器同步：

```dart
        allowAutoRename: call.name == AgentToolName.workspacePatch &&
            !_isExactPatch(call.arguments) &&
            !_isMergePatch(call.arguments),
```

- [ ] **Step 5: 跑测试确认通过**

Run: `flutter test test/work_mode/default_work_task_runner_stage02_test.dart`
Expected: PASS（含既有 `routes approved workspace.patch through Stage02` 与 `refreshes Stage02 approval between file mutations`）。

- [ ] **Step 6: 提交**

```bash
git add lib/features/work_mode/default_work_task_runner_tools.dart lib/features/work_mode/default_work_task_runner_context.dart lib/features/work_mode/default_work_task_runner_file_policy.dart test/work_mode/default_work_task_runner_stage02_test.dart docs/work_mode_chunked_writes_design.md
git commit -m "feat(work-mode): route append and parts through the patch tool"
```

---

### Task 5: 契约文案与文档

**Files:**
- Modify: `lib/features/agentic/agent_prompt_builder.dart:48`
- Modify: `lib/features/agentic/document_skill_templates.dart:50`
- Modify: `lib/features/work_mode/work_agent_loop_retry.dart:10`（`_truncatedOutputChunkingAdvice`）
- Modify: `test/agentic/agent_prompt_builder_test.dart`
- Modify: `test/work_mode/work_agent_loop_test.dart:1626`、`:1658`（既有断言跟随新措辞）
- Modify: `CLAUDE.md`（「分块写」契约段）

**Interfaces:**
- Consumes: Task 4 定下的工具形态（`append` / `parts`）。
- Produces: 模型看到的唯一一份分块配方；`_truncatedOutputChunkingAdvice` 与提示词主契约共用的措辞（`拆成多次动作` 保留，既有测试与文案一致性都依赖它）。

- [ ] **Step 1: 写失败测试**

在 `test/agentic/agent_prompt_builder_test.dart` 追加：

```dart
  test('chunked writing contract uses append and a tool merge, not pandoc',
      () {
    final prompt = AgentPromptBuilder.buildAgentDecisionPrompt(
      rolePlaySystemPrompt: '角色提示',
      skills: const [],
      userRequest: '把报告写到桌面',
    );

    expect(prompt, contains('拆成多次动作'));
    expect(prompt, contains('append'));
    expect(prompt, contains('parts'));
    // 纯文本拼接不再要求 shell：合并是受治理的工具动作。
    expect(prompt, isNot(contains('pandoc 一次吃多个分段')));
  });
```

- [ ] **Step 2: 跑测试确认失败**

Run: `flutter test test/agentic/agent_prompt_builder_test.dart --plain-name "chunked writing contract"`
Expected: FAIL —— 现有契约整段是「独立文件 + pandoc 合并」，不含 `append` / `parts`。

- [ ] **Step 3: 改写契约文案**

`agent_prompt_builder.dart:48` 整条替换为：

```dart
-- 交付物正文很长时（报告类 3000 字以上、长 HTML、长脚本文本）必须拆成多次动作写：先用 workspace.patch 建一个分段文件（{"path":"report.part1.md","content":"第一段"}），此后每次用 append 追加一段（{"path":"report.part1.md","content":"下一段","append":true}），每次 content 控制在 3000 字以内——单次决策的输出有上限，把整篇正文放进一次 content 会被截断、整条动作作废。全部分段写完后用一次 workspace.patch 合并成交付物（{"path":"report.md","parts":["report.part1.md"]}，数组顺序即拼接顺序），再读回验证并交付。**不要**反复往交付物本身写：追加序列会先把交付物建成半成品。只有需要转换格式时才用 command.run（如 Markdown 转 DOCX 用 pandoc），纯文本拼接不需要 shell。
```

`document_skill_templates.dart:50` 的同类句子替换为：

```dart
      '正文较长（三千字以上）时把 Markdown 源分 2～4 段：先 workspace.patch 建 report.part1.md，再用 append 追加后续各段，最后用一次 workspace.patch 的 parts 合并成 out.md——单次决策的输出有上限，整篇正文塞进一次写入会被截断。需要 DOCX 时再用 pandoc 把合并后的 .md 转过去。',
```

`work_agent_loop_retry.dart:10` 的 `_truncatedOutputChunkingAdvice` 替换为：

```dart
const String _truncatedOutputChunkingAdvice =
    '这一次的输出太大：把内容拆成多次动作——先用 workspace.patch 写一个分段文件'
    '（每次 content 控制在 3000 字以内），再用 append 把后续各段追加到同一个'
    '分段文件，全部写完后用一次 workspace.patch 的 parts 合并成目标文件，'
    '然后读回并交付；不要反复往目标文件写，也不要把整份内容放进一次动作。';
```

- [ ] **Step 4: 跟随更新既有断言并跑测试**

`test/work_mode/work_agent_loop_test.dart` 的两处 `contains('拆成多次动作')` 保持不变（新措辞保留了这句）；若断言了旧措辞的其它片段（如 `pandoc`），一并改为新措辞。

Run: `flutter test test/agentic/agent_prompt_builder_test.dart test/work_mode/work_agent_loop_test.dart`
Expected: PASS。

- [ ] **Step 5: 同步 CLAUDE.md**

把「工作模式一次模型请求的输出上限」条目里「每个分段各写独立文件（每次 content ≤3000 字）+ 一次 `command.run` 合并（`pandoc part1.md part2.md -o out.docx`；shell 需单独确认…）」改写成 append + parts 的配方，并保留「只有 `buildAgentDecisionPrompt` 是工作模式实际发送的提示词」这句约束。

- [ ] **Step 6: 提交**

```bash
git add lib/features/agentic/agent_prompt_builder.dart lib/features/agentic/document_skill_templates.dart lib/features/work_mode/work_agent_loop_retry.dart test/agentic/agent_prompt_builder_test.dart test/work_mode/work_agent_loop_test.dart CLAUDE.md
git commit -m "docs(work-mode): teach the chunked-write contract via append and tool merge"
```

---

### Task 6: 抢救提取与分段命名（纯函数）

**Files:**
- Create: `lib/features/work_mode/work_truncation_salvage.dart`
- Test: `test/work_mode/work_truncation_salvage_test.dart`（新建）
- Modify: `docs/work_mode_chunked_writes_design.md`（§4.3 命名修正）

**Interfaces:**
- Produces:
  - `class WorkTruncationSalvage { final String targetPath; final String content; }`
  - `static WorkTruncationSalvage? WorkTruncationSalvage.extract(String body)`——body 是被切断的响应正文；无法判为「workspace.patch 动作 JSON 前缀」时返回 null。
  - `static String WorkTruncationSalvage.rescuePath(String targetPath, String content)`——`同目录/stem.rescue-<sha256 前 8 位><扩展名>`；同内容必然同名（重复抢救幂等）。

**命名修正（写进 spec）**：设计文档写的是 `stem.partN.ext`。实现改用**内容哈希后缀**：模型自己的分段文件也用 `partN` 命名空间，二者混在一起会让"追加到 part1"把两次尝试的内容拼在一个文件里；哈希后缀既避开冲突（相同内容同名、不同内容不同名），又不需要探测文件是否存在、也能扛住任务恢复。

- [ ] **Step 1: 先修正 spec 命名**

在 `docs/work_mode_chunked_writes_design.md` §4.3 的第一条替换为：

```markdown
- 目标路径：由模型自己的动作目标派生——同目录、`stem.rescue-<内容 sha256 前 8 位><扩展名>`（如 `三国杀.rescue-3f9a2b1c.html`）。用内容哈希而不是 `partN`：模型自己的分段文件也在 `partN` 命名空间里，撞名会把两次尝试的内容拼进同一个文件；哈希后缀让"同内容同名、不同内容不同名"，无需探测文件是否存在，任务恢复后依然幂等。
```

- [ ] **Step 2: 写失败测试**

新建 `test/work_mode/work_truncation_salvage_test.dart`：

```dart
import 'package:chat_group/features/work_mode/work_truncation_salvage.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('WorkTruncationSalvage.extract', () {
    test('recovers the content prefix cut mid-string', () {
      final body = '{"action":"tool","public_update":"正在写文件。","tool":'
          '{"name":"workspace.patch","arguments":{"path":"report.md",'
          '"content":"第一行\\n第二行';

      final salvage = WorkTruncationSalvage.extract(body);

      expect(salvage, isNotNull);
      expect(salvage!.targetPath, 'report.md');
      expect(salvage.content, '第一行\n第二行');
    });

    test('drops a half-written escape sequence', () {
      final salvage = WorkTruncationSalvage.extract(
        '{"action":"tool","tool":{"name":"workspace.patch","arguments":'
        '{"path":"a.md","content":"正文\\\\',
      );

      expect(salvage?.content, '正文');
    });

    test('drops a half-written unicode escape', () {
      final salvage = WorkTruncationSalvage.extract(
        '{"action":"tool","tool":{"name":"workspace.patch","arguments":'
        '{"path":"a.md","content":"正文\\u4e',
      );

      expect(salvage?.content, '正文');
    });

    test('recovers the replacement argument of an exact patch', () {
      final salvage = WorkTruncationSalvage.extract(
        '{"action":"tool","tool":{"name":"workspace.patch","arguments":'
        '{"path":"a.md","expectedSha256":"ff","expectedFragment":"x",'
        '"replacement":"替换正文',
      );

      expect(salvage?.content, '替换正文');
      expect(salvage?.targetPath, 'a.md');
    });

    test('ignores a truncation that is not a file write', () {
      // 现场最常见的截断是模型在写正文说明，没有可捞的动作参数。
      final salvage = WorkTruncationSalvage.extract(
        '{"action":"tool","tool":{"name":"command.run","arguments":'
        '{"executable":"python3","arguments":["script.py"]',
      );

      expect(salvage, isNull);
    });

    test('ignores a body that is not a decision prefix at all', () {
      expect(WorkTruncationSalvage.extract('陆教授：我先把报告写到桌面'), isNull);
      expect(WorkTruncationSalvage.extract(''), isNull);
    });
  });

  group('WorkTruncationSalvage.rescuePath', () {
    test('keeps the directory and the extension', () {
      final first = WorkTruncationSalvage.rescuePath('/work/report.md', '内容');
      final second = WorkTruncationSalvage.rescuePath('/work/report.md', '内容');
      final other = WorkTruncationSalvage.rescuePath('/work/report.md', '别的');

      expect(first, startsWith('/work/report.rescue-'));
      expect(first, endsWith('.md'));
      expect(first, second, reason: '同内容必须同名，重复抢救才是幂等的');
      expect(other, isNot(first));
    });

    test('handles a path without extension', () {
      expect(
        WorkTruncationSalvage.rescuePath('/work/README', 'x'),
        startsWith('/work/README.rescue-'),
      );
    });
  });
}
```

- [ ] **Step 3: 跑测试确认失败**

Run: `flutter test test/work_mode/work_truncation_salvage_test.dart`
Expected: FAIL —— 文件不存在（`Target of URI doesn't exist`）。

- [ ] **Step 4: 实现**

新建 `lib/features/work_mode/work_truncation_salvage.dart`：

```dart
import 'dart:convert';

import 'package:crypto/crypto.dart';

/// 被输出上限截断的响应里，可以救回来的那部分内容。
///
/// 截断发生在动作 JSON 中间：整条动作作废、一个字都没落盘，而模型已经烧掉
/// 整份输出预算。把这段前缀落盘成暂存分段、让模型只补写余下部分，是唯一能
/// 把那笔预算变成进度的做法。
class WorkTruncationSalvage {
  /// 模型本来要写的目标路径（原样保留，由调用方做路径解析与授权）。
  final String targetPath;

  /// 已成功解码出的内容前缀。
  final String content;

  const WorkTruncationSalvage({
    required this.targetPath,
    required this.content,
  });

  /// 从被截断的正文里取出「workspace.patch 动作的大字符串参数」。
  ///
  /// 只在能确定是这类前缀时返回结果：正文不是决策 JSON、动作不是
  /// workspace.patch、或没有大字符串参数时一律返回 null，由调用方退回话术路径。
  static WorkTruncationSalvage? extract(String body) {
    if (body.trim().isEmpty) return null;
    if (!body.contains('workspace.patch')) return null;
    final path = _readStringField(body, 'path');
    if (path == null || path.trim().isEmpty) return null;
    // content 是整文件写/追加的正文，replacement 是精确补丁的正文；两者都可能
    // 长到撞上限，取先出现且非空的那个。
    for (final key in const ['content', 'replacement']) {
      final value = _readStringField(body, key);
      if (value != null && value.trim().isNotEmpty) {
        return WorkTruncationSalvage(targetPath: path, content: value);
      }
    }
    return null;
  }

  /// 抢救内容的落盘路径。
  ///
  /// 内容哈希而不是序号：模型自己的分段文件也占用 `partN` 命名空间，撞名会把
  /// 两次尝试的内容拼进同一个文件；哈希后缀让同内容同名、不同内容不同名，
  /// 既不需要探测文件是否存在，任务恢复后也仍然幂等。
  static String rescuePath(String targetPath, String content) {
    final digest = sha256.convert(utf8.encode(content)).toString();
    final short = digest.substring(0, 8);
    final normalized = targetPath.replaceAll('\\', '/');
    final slash = normalized.lastIndexOf('/');
    final directory = slash < 0 ? '' : normalized.substring(0, slash + 1);
    final name = slash < 0 ? normalized : normalized.substring(slash + 1);
    final dot = name.lastIndexOf('.');
    if (dot <= 0) return '$directory$name.rescue-$short';
    return '$directory${name.substring(0, dot)}.rescue-$short'
        '${name.substring(dot)}';
  }

  /// 从残缺 JSON 里读一个字符串字段：找到 `"key"` 后的冒号与开引号，按 JSON
  /// 字符串规则解码到闭合引号或正文结束。
  ///
  /// 尾部的残缺转义（半个 `\`、半截 `\uXX`）一律丢弃——留下半个转义会让落盘
  /// 内容出现非法字符或反斜杠字面量。
  static String? _readStringField(String body, String key) {
    final marker = '"$key"';
    var searchFrom = 0;
    while (true) {
      final keyAt = body.indexOf(marker, searchFrom);
      if (keyAt < 0) return null;
      searchFrom = keyAt + marker.length;
      var index = searchFrom;
      while (index < body.length && body[index].trim().isEmpty) {
        index++;
      }
      if (index >= body.length || body[index] != ':') continue;
      index++;
      while (index < body.length && body[index].trim().isEmpty) {
        index++;
      }
      if (index >= body.length || body[index] != '"') continue;
      return _decodeJsonString(body, index + 1);
    }
  }

  static String _decodeJsonString(String body, int start) {
    final buffer = StringBuffer();
    var index = start;
    while (index < body.length) {
      final char = body[index];
      if (char == '"') return buffer.toString();
      if (char != '\\') {
        buffer.write(char);
        index++;
        continue;
      }
      index++;
      if (index >= body.length) return buffer.toString();
      final escape = body[index];
      switch (escape) {
        case 'n':
          buffer.write('\n');
        case 't':
          buffer.write('\t');
        case 'r':
          buffer.write('\r');
        case 'b':
          buffer.write('\b');
        case 'f':
          buffer.write('\f');
        case '"':
          buffer.write('"');
        case '\\':
          buffer.write('\\');
        case '/':
          buffer.write('/');
        case 'u':
          if (index + 4 >= body.length) return buffer.toString();
          final hex = body.substring(index + 1, index + 5);
          final code = int.tryParse(hex, radix: 16);
          if (code == null) return buffer.toString();
          buffer.writeCharCode(code);
          index += 4;
        default:
          // 未知转义：按字面量保留反斜杠后的字符，不猜测。
          buffer.write(escape);
      }
      index++;
    }
    return buffer.toString();
  }
}
```

- [ ] **Step 5: 跑测试确认通过**

Run: `flutter test test/work_mode/work_truncation_salvage_test.dart`
Expected: PASS。

- [ ] **Step 6: 提交**

```bash
git add lib/features/work_mode/work_truncation_salvage.dart test/work_mode/work_truncation_salvage_test.dart docs/work_mode_chunked_writes_design.md
git commit -m "feat(work-mode): salvage the cut prefix of a truncated write action"
```

---

### Task 7: 循环集成——抢救落盘、事件与续写提示

**Files:**
- Modify: `lib/features/work_mode/work_agent_loop.dart:560-590`（截断失败分支）
- Modify: `lib/features/work_mode/work_agent_loop_retry.dart:354-364`（提示构造）
- Modify: `lib/features/work_mode/work_agent_loop_checkpoint.dart:259`、`:277`（续写提示走独立 message）
- Test: `test/work_mode/work_agent_loop_test.dart`

**Interfaces:**
- Consumes: Task 6 的 `WorkTruncationSalvage.extract` / `rescuePath`；`_handleDecision`（`work_agent_loop_actions.dart`，`:337` 起）；`_emit`；`state.recentResults`。
- Produces:
  - `_buildMessages(task, context, {String continuationHint = ''})`——`continuationHint` 不经上下文压缩，作为独立 system message 附加。
  - 抢救事件的 `safeMetadata`：`salvagedCharacters`、`partPath`、`truncatedTargetPath`。

**为什么独立 message**：`truncatedOutputHint` 目前混在 `公开任务检查点：{...}` 那个大 JSON 里（`work_agent_loop_checkpoint.dart:306`），而检查点在超预算时会被 `WorkPromptContextCompactor` 压缩（`work_prompt_context_compactor.dart:41`，检查点预算仅 2048 字）。续写指令必须走独立参数，否则压缩一次就静默消失。

- [ ] **Step 1: 写失败测试**

在 `test/work_mode/work_agent_loop_test.dart` 的截断用例附近新增：

```dart
  test('a truncated write action is salvaged into a staged part file',
      () async {
    final model = _FakeModel()
      ..responses.add({
        'success': true,
        'truncated': true,
        'content': '{"action":"tool","public_update":"正在写报告。","tool":'
            '{"name":"workspace.patch","arguments":{"path":"report.md",'
            '"content":"第一段\\n第二段',
      })
      ..responses.add(_finishDecision('按抢救结果续写完成。'));
    final tool = _FakeTool();
    final events = <WorkTaskEvent>[];
    final loop = _loop(
      model: model,
      registry: WorkToolRegistry(
        definitions: [_definition(AgentToolName.workspacePatch, tool)],
      ),
      events: events,
    );

    final task = _task(id: 'truncation-salvage');
    final result = await loop.execute(task);

    expect(result.status, WorkAgentLoopStatus.completed,
        reason: '${result.message}; ${task.lastError}');
    expect(tool.calls, 1, reason: '抢救就是一次真实的工具请求');
    final args = tool.arguments.single;
    expect(args['path'], startsWith('report.rescue-'));
    // 落盘的必须是模型原本要写的字符，而不是带反斜杠的 JSON 字面量。
    expect(args['content'], '第一段\n第二段');
    expect(
      events.any((event) => event.safeMetadata['salvagedCharacters'] != null),
      isTrue,
    );
    final retryPrompt = model.requests.last.messages
        .map((message) => message['content']?.toString() ?? '')
        .join('\n');
    expect(retryPrompt, contains('report.rescue-'),
        reason: '续写指令必须点名已抢救的分段文件');
  });

  test('the continuation hint survives context compaction', () async {
    final model = _FakeModel()
      ..responses.add({
        'success': true,
        'truncated': true,
        'content': '{"action":"tool","tool":{"name":"workspace.patch",'
            '"arguments":{"path":"report.md","content":"被截断的正文',
      })
      ..responses.add(_finishDecision('完成。'));
    final tool = _FakeTool();
    final loop = _loop(
      model: model,
      registry: WorkToolRegistry(
        definitions: [_definition(AgentToolName.workspacePatch, tool)],
      ),
      promptCompactionBudgetTokens: 1,
    );

    final task = _task(id: 'truncation-salvage-compaction');
    await loop.execute(task);

    final retryPrompt = model.requests.last.messages
        .map((message) => message['content']?.toString() ?? '')
        .join('\n');
    expect(retryPrompt, contains('report.rescue-'),
        reason: '检查点被压缩后续写指令仍必须到达模型');
  });
```

- [ ] **Step 2: 跑测试确认失败**

Run: `flutter test test/work_mode/work_agent_loop_test.dart --plain-name "salvaged"`
Expected: FAIL —— `tool.calls == 0`（现在不发起任何抢救写入）。

- [ ] **Step 3: 续写提示走独立 message**

`work_agent_loop_checkpoint.dart`：`_buildMessages`（`:259`）签名加参数并透传，`_assembleMessages`（`:277`）在同一步追加：

```dart
  List<Map<String, dynamic>> _buildMessages(
    AgentTask task,
    Map<String, dynamic> context, {
    String continuationHint = '',
  }) {
    final budget = promptCompactionBudgetTokens;
    final effective = budget == null
        ? context
        : const WorkPromptContextCompactor().compactIfNeeded(
            context,
            budgetTokens: budget,
            measureTokens: (candidate) =>
                ContextWindowManager.estimateRequestTokens(
              _assembleMessages(task, candidate, includeNativeImages: false),
            ),
          );
    return _assembleMessages(task, effective, continuationHint: continuationHint);
  }
```

`_assembleMessages` 的签名与消息列表（`:277`、`:290`）：

```dart
  List<Map<String, dynamic>> _assembleMessages(
    AgentTask task,
    Map<String, dynamic> context, {
    bool includeNativeImages = true,
    String continuationHint = '',
  }) {
```

```dart
    final messages = <Map<String, dynamic>>[
      {
        'role': 'system',
        'content': '${(systemPromptBuilder?.call() ?? systemPrompt).trim()}\n'
            '工作模式只允许输出一个严格 AgentDecision JSON object；'
            'public_update 只能描述公开动作、依据或结论，不得输出思维链。\n'
            '$planningInstruction',
      },
      {
        'role': 'user',
        'content': _publicText(
          WorkDiscussionState.currentRequestScope(task),
        ),
      },
      // 续写指令不放进检查点：检查点超预算时会被压缩，压缩一次这条指令就静默
      // 消失，模型会退回"一次写完整份"的老动作。
      if (continuationHint.trim().isNotEmpty)
        {'role': 'system', 'content': _publicText(continuationHint)},
      {
        'role': 'system',
        'content': '公开任务检查点：${jsonEncode(promptContext)}',
      },
    ];
```

- [ ] **Step 4: 实现抢救落盘与提示**

`work_agent_loop_retry.dart` 里把 `_withTruncatedOutputHint` 换成构造续写指令：

```dart
  /// 截断之后的续写指令：告诉模型哪一段已经落盘、从哪里继续、最后怎么合并。
  ///
  /// 不写回任务上下文：它是这次重试的指令，不是任务的持久状态，重试成功后即失效。
  String _continuationHint({
    required String targetPath,
    required String? rescuedPath,
    required int rescuedCharacters,
    required String rescuedTail,
  }) {
    if (rescuedPath == null) return _truncatedOutputChunkingAdvice;
    return '上一次输出被上限截断，已把已生成的部分抢救到分段文件 `$rescuedPath`'
        '（$rescuedCharacters 字）。继续用 workspace.patch 的 append 往这个文件'
        '补写余下内容（每次 content 控制在 3000 字以内），不要重写已写入的前缀；'
        '全文写完后用一次 workspace.patch 的 parts 合并到 `$targetPath`，再读回'
        '验证并交付。已写入内容的结尾是：「$rescuedTail」。';
  }
```

`work_agent_loop.dart` 的截断失败分支（`:560` 起）保持原有事件与重试记账，只把提示换成抢救结果——
截断后的落盘与提示整体抽成 `_salvageTruncatedOutput`（避免把这个已经很长的循环函数继续撑大）：

具体落法：新增一个私有方法 `_salvageTruncatedOutput(state, response)`，返回一个记录：

```dart
/// 抢救结果：无论成功与否，`hint` 都是下一次决策要带的续写指令。
class _TruncationSalvageOutcome {
  final WorkAgentLoopResult? stop;
  final String hint;
  final String? rescuedPath;
  final int rescuedCharacters;

  const _TruncationSalvageOutcome({
    this.stop,
    required this.hint,
    this.rescuedPath,
    this.rescuedCharacters = 0,
  });
}
```

并在 `work_agent_loop.dart` 里：

```dart
  Future<_TruncationSalvageOutcome> _salvageTruncatedOutput(
    _LoopState state,
    Map<String, dynamic> response,
  ) async {
    final fallback = _TruncationSalvageOutcome(
      hint: _truncatedOutputChunkingAdvice,
    );
    final salvage = WorkTruncationSalvage.extract(_responseBody(response) ?? '');
    if (salvage == null) return fallback;
    final rescuedPath = WorkTruncationSalvage.rescuePath(
      salvage.targetPath,
      salvage.content,
    );
    const notice = '已抢救被截断的输出，先写入分段文件再继续。';
    final stop = await _handleDecision(
      state,
      AgentToolDecision(
        publicUpdate: notice,
        tool: AgentToolCall(
          name: AgentToolName.workspacePatch,
          arguments: {'path': rescuedPath, 'content': salvage.content},
        ),
      ),
      notice,
    );
    if (stop != null) {
      return _TruncationSalvageOutcome(stop: stop, hint: fallback.hint);
    }
    final committed = state.recentResults.isNotEmpty &&
        state.recentResults.last['committed'] == true;
    await _emit(
      state,
      WorkTaskEventKind.toolOutput,
      committed
          ? '已抢救被截断的输出：${salvage.content.length} 字写入分段文件。'
          : '抢救被截断的输出未落盘，将按精简指令重试。',
      detail: committed ? rescuedPath : '分段文件未能写入。',
      safeMetadata: {
        'scope': 'truncationSalvage',
        'salvaged': committed,
        'salvagedCharacters': salvage.content.length,
        'partPath': rescuedPath,
        'truncatedTargetPath': salvage.targetPath,
      },
    );
    return _TruncationSalvageOutcome(
      hint: committed
          ? _continuationHint(
              targetPath: salvage.targetPath,
              rescuedPath: rescuedPath,
              rescuedCharacters: salvage.content.length,
              rescuedTail: _boundedTail(salvage.content),
            )
          : fallback.hint,
      rescuedPath: committed ? rescuedPath : null,
      rescuedCharacters: committed ? salvage.content.length : 0,
    );
  }

  /// 抢救内容的结尾片段，用来让模型无缝接上：只取有界的一段，绝不把整份
  /// 已生成内容回灌进 prompt。
  String _boundedTail(String content) => content.length <= _salvageTailCharacters
      ? content
      : content.substring(content.length - _salvageTailCharacters);
```

（`const int _salvageTailCharacters = 200;` 放在 `work_agent_loop.dart` 顶部常量区。）

截断失败分支里改成：

```dart
          String continuationHint = '';
          if (truncated) {
            final outcome = await _salvageTruncatedOutput(state, response);
            if (outcome.stop != null) return outcome.stop!;
            continuationHint = outcome.hint;
            salvaged = outcome.rescuedPath != null;
          }
```

事件标题要跟着事实走：抢救成功时下一次不再是"改用精简指令"，而是按已落盘的内容续写。把 `_protocolRetryTitle`（`work_agent_loop_retry.dart:297`）扩一个参数：

```dart
  String _protocolRetryTitle({
    required bool truncated,
    required bool repairRequestFailed,
    bool salvaged = false,
  }) {
    if (salvaged) return '模型输出被上限截断，已抢救已生成部分，按续写指令重试。';
    if (truncated) return '模型输出被上限截断，改用精简指令重试。';
    if (repairRequestFailed) return '模型响应无法解析，修复请求失败，正在重试。';
    return '模型返回格式无效，正在自动重试。';
  }
```

（`salvaged` 是循环内与 `continuationHint` 同寿命的局部变量，初值 `false`；既有调用处 `work_agent_loop.dart:573` 补上 `salvaged: salvaged`。）

循环里缓存 `continuationHint`（与 `truncatedOutputRetry` 同寿命）：

```dart
      var truncatedOutputRetry = false;
      var continuationHint = '';
```

构造请求时：

```dart
          messages: _buildMessages(
            task,
            context,
            continuationHint: continuationHint,
          ),
```

并在 `_repairModel`（`work_agent_loop_retry.dart:366`）里把 `_withTruncatedOutputHint(context)` 的用法替换为 `repairContext` 内的 `repairInstruction`（现状已如此），删除 `_withTruncatedOutputHint`。

- [ ] **Step 5: 跑测试确认通过**

Run: `flutter test test/work_mode/work_agent_loop_test.dart`
Expected: PASS，含既有的 `truncated response is repaired with a compact instruction` 与 `a truncation that survives repair retries with a chunking instruction`（两条用例的正文都不是可抢救的动作 JSON，走话术路径）。

- [ ] **Step 6: 提交**

```bash
git add lib/features/work_mode/work_agent_loop.dart lib/features/work_mode/work_agent_loop_retry.dart lib/features/work_mode/work_agent_loop_checkpoint.dart test/work_mode/work_agent_loop_test.dart
git commit -m "feat(work-mode): salvage a truncated write into a staged part file"
```

---

### Task 8: 全量回归与验证

**Files:**
- Modify: `docs/work_mode_chunked_writes_design.md`（状态改为「已实现」，补 §7 的 `append_requires_full_read` / `invalid_merge` 两行失败路径）

**Interfaces:**
- Consumes: Task 1-7 的全部产出。
- Produces: 可交付的分支状态与一次完整的验证记录。

- [ ] **Step 1: 补失败路径表**

`docs/work_mode_chunked_writes_design.md` §7 增加两行：

```markdown
| 追加目标超过读取上限 | 拒绝（`append_requires_full_read`），不改动目标文件；提示模型改用分段文件 |
| 合并缺分段或分段超上限 | 拒绝（`invalid_merge`，`missingParts` 点名缺失分段），不改动目标文件 |
```

并把文档头部的「状态：设计待评审」改为「状态：已实现」。

- [ ] **Step 2: 静态分析**

Run: `flutter analyze`
Expected: 无 error（warning/info 不阻塞）。

- [ ] **Step 3: 相关单测**

Run: `flutter test test/work_mode/ test/agentic/`
Expected: PASS。

- [ ] **Step 4: 全量测试**

Run: `flutter test`
Expected: PASS。若出现 `TimeoutException after 0:10:00` 且用例体本身报错，按 CLAUDE.md 的假区 Hive 规则定位（Hive 写必须在 `tester.runAsync()` 内），不要重试掩盖。

- [ ] **Step 5: 记录验证结论并提交**

在提交前逐项记录：已执行命令、通过项、失败项、未检查项及原因。**未做真机验证**（本计划不含运行 App 与真实模型调用）——"测试通过"不等于"验收通过"，这一点必须在结论里写明。

```bash
git add docs/work_mode_chunked_writes_design.md
git commit -m "docs(work-mode): record the implemented chunked-write behaviour"
```

---

## 执行提示

- 任务顺序有依赖：Task 1 → 2 → 3 → 4 是执行链；Task 5 独立；Task 6 → 7 是抢救链；Task 8 收尾。
- 每个任务结束时都要单独跑一次该任务的测试文件，不要攒到最后。
- 若任一任务发现设计文档与代码冲突（例如新的约束、新的失败码），先改文档再改代码，并把这个改动写进该任务的提交。
