import 'dart:convert';

import 'package:chat_group/features/work_mode/work_change_plan.dart';
import 'package:flutter_test/flutter_test.dart';

WorkChangePlan _plan({
  WorkChangeActionType action = WorkChangeActionType.modify,
  List<String> exactPaths = const ['/workspace/report.md'],
  List<String> affectedDirectories = const ['/workspace'],
  int estimatedBytes = 128,
  bool snapshotAvailable = true,
  bool reversible = true,
  WorkChangeCommand? command,
  String? commandReason,
  String riskReason = '根据任务要求更新报告。',
}) {
  return WorkChangePlan(
    taskId: 'task-09',
    actionType: action,
    exactPaths: exactPaths,
    knownAffectedDirectories: affectedDirectories,
    estimatedBytes: estimatedBytes,
    snapshotAvailable: snapshotAvailable,
    reversible: reversible,
    command: command,
    commandReason: commandReason,
    riskReason: riskReason,
  );
}

void main() {
  group('WorkChangePlan', () {
    test('serializes every required change and command field', () {
      final plan = _plan(
        action: WorkChangeActionType.command,
        exactPaths: const ['/workspace/build.log'],
        affectedDirectories: const ['/workspace/build'],
        estimatedBytes: 2048,
        snapshotAvailable: false,
        reversible: false,
        command: const WorkChangeCommand(
          executable: 'flutter',
          arguments: ['build', 'macos'],
          workingDirectory: '/workspace',
          knownFiles: ['/workspace/build.log'],
          possibleDirectories: ['/workspace/build'],
          impactUncertain: true,
        ),
        commandReason: '生成 macOS 构建产物。',
        riskReason: '构建可能改写 build 目录，影响范围无法完全枚举。',
      );

      final json = plan.toJson();
      expect(json['taskId'], 'task-09');
      expect(json['actionType'], 'command');
      expect(json['exactPaths'], ['/workspace/build.log']);
      expect(json['knownAffectedDirectories'], ['/workspace/build']);
      expect(json['estimatedBytes'], 2048);
      expect(json['snapshotAvailable'], isFalse);
      expect(json['reversible'], isFalse);
      expect(json['impactUncertain'], isTrue);
      expect(json['commandReason'], '生成 macOS 构建产物。');
      expect(json['riskReason'], contains('无法完全枚举'));
      expect((json['command'] as Map)['executable'], 'flutter');
      expect((json['command'] as Map)['arguments'], ['build', 'macos']);
      expect((json['command'] as Map)['workingDirectory'], '/workspace');
      expect((json['command'] as Map)['knownFiles'], ['/workspace/build.log']);
      expect(
        (json['command'] as Map)['possibleDirectories'],
        ['/workspace/build'],
      );
      expect((json['command'] as Map)['impactUncertain'], isTrue);
    });

    test('rejects relative paths and wildcard task-wide scopes', () {
      expect(
        () => _plan(exactPaths: const ['relative/report.md']),
        throwsArgumentError,
      );
      expect(
        () => WorkApprovalScope(
          taskId: 'task-09',
          entries: const [
            WorkApprovalScopeEntry(
              path: '*',
              kind: WorkApprovalScopePathKind.directory,
              actions: {WorkChangeActionType.modify},
            ),
          ],
        ),
        throwsArgumentError,
      );
    });

    test('normalizes Windows absolute paths without widening the scope', () {
      final plan = _plan(
        exactPaths: const [r'C:\\Workspace\\Report.md'],
        affectedDirectories: const [r'C:\\Workspace'],
      );

      expect(plan.exactPaths, [r'C:/Workspace/Report.md']);
      expect(plan.knownAffectedDirectories, [r'C:/Workspace']);
      expect(
        WorkApprovalScope.fromPlan(plan).allows(
          _plan(
            exactPaths: const [r'c:\\workspace\\Report.md'],
            affectedDirectories: const [r'c:\\workspace'],
          ),
        ),
        isTrue,
      );
    });
  });

  group('WorkChangePolicy', () {
    test('prompts before the first reversible ordinary write', () {
      final result = WorkChangePolicy.evaluate(
        plan: _plan(),
        settings: const WorkChangePolicySettings(confirmOrdinaryWrites: true),
      );

      expect(result.requirement, WorkChangeApprovalRequirement.initial);
      expect(result.requiresPrompt, isTrue);
      expect(result.reason, contains('不在本任务已批准的路径范围内'));
    });

    test('does not prompt again inside the same approved file set', () {
      final plan = _plan();
      final scope = WorkApprovalScope.fromPlan(plan);

      final result = WorkChangePolicy.evaluate(
        plan: plan,
        scope: scope,
        settings: const WorkChangePolicySettings(confirmOrdinaryWrites: true),
      );

      expect(result.requirement, WorkChangeApprovalRequirement.none);
      expect(result.requiresPrompt, isFalse);
    });

    test('requests supplemental approval when a new file is added', () {
      final approved = _plan();
      final scope = WorkApprovalScope.fromPlan(approved);
      final expanded = _plan(
        exactPaths: const ['/workspace/report.md', '/workspace/summary.md'],
      );

      final result = WorkChangePolicy.evaluate(
        plan: expanded,
        scope: scope,
        settings: const WorkChangePolicySettings(confirmOrdinaryWrites: true),
      );

      expect(result.requirement, WorkChangeApprovalRequirement.supplemental);
      expect(result.requiresPrompt, isTrue);
      expect(result.reason, contains('新增'));
    });

    test('treats an approval from another task as a first approval', () {
      final otherTaskScope = WorkApprovalScope(
        taskId: 'other-task',
        entries: const [
          WorkApprovalScopeEntry(
            path: '/workspace/report.md',
            kind: WorkApprovalScopePathKind.file,
            actions: {WorkChangeActionType.modify},
          ),
        ],
      );

      final result = WorkChangePolicy.evaluate(
        plan: _plan(),
        scope: otherTaskScope,
        settings: const WorkChangePolicySettings(confirmOrdinaryWrites: true),
      );

      expect(result.requirement, WorkChangeApprovalRequirement.initial);
    });

    test('still prompts for delete when ordinary write prompts are disabled',
        () {
      final result = WorkChangePolicy.evaluate(
        plan: _plan(action: WorkChangeActionType.delete),
        settings: const WorkChangePolicySettings(confirmOrdinaryWrites: false),
      );

      expect(result.requirement, WorkChangeApprovalRequirement.alwaysConfirm);
      expect(result.requiresPrompt, isTrue);
    });

    test('still prompts for an overwrite without a safe snapshot', () {
      final result = WorkChangePolicy.evaluate(
        plan: _plan(snapshotAvailable: false),
        settings: const WorkChangePolicySettings(confirmOrdinaryWrites: false),
      );

      expect(result.requirement, WorkChangeApprovalRequirement.alwaysConfirm);
      expect(result.requiresPrompt, isTrue);
      expect(result.reason, contains('撤销'));
    });

    test('still prompts for a create without a safe snapshot', () {
      final result = WorkChangePolicy.evaluate(
        plan: _plan(
          action: WorkChangeActionType.create,
          snapshotAvailable: false,
          reversible: false,
        ),
        settings: const WorkChangePolicySettings(confirmOrdinaryWrites: false),
      );

      expect(result.requirement, WorkChangeApprovalRequirement.alwaysConfirm);
      expect(result.requiresPrompt, isTrue);
    });

    test('still prompts for an irreversible overwrite', () {
      final result = WorkChangePolicy.evaluate(
        plan: _plan(reversible: false),
        settings: const WorkChangePolicySettings(confirmOrdinaryWrites: false),
      );

      expect(result.requirement, WorkChangeApprovalRequirement.alwaysConfirm);
      expect(result.requiresPrompt, isTrue);
    });

    test('still prompts for an uncertain-impact command', () {
      final result = WorkChangePolicy.evaluate(
        plan: _plan(
          action: WorkChangeActionType.command,
          command: const WorkChangeCommand(
            executable: 'flutter',
            arguments: ['build', 'macos'],
            workingDirectory: '/workspace',
            knownFiles: ['/workspace/build.log'],
            possibleDirectories: ['/workspace/build'],
            impactUncertain: true,
          ),
        ),
        settings: const WorkChangePolicySettings(confirmOrdinaryWrites: false),
      );

      expect(result.requirement, WorkChangeApprovalRequirement.alwaysConfirm);
      expect(result.requiresPrompt, isTrue);
      expect(result.reason, contains('不确定'));
    });

    test('ordinary reversible writes follow the setting toggle', () {
      final result = WorkChangePolicy.evaluate(
        plan: _plan(),
        settings: const WorkChangePolicySettings(confirmOrdinaryWrites: false),
      );

      expect(result.requirement, WorkChangeApprovalRequirement.none);
      expect(result.requiresPrompt, isFalse);
    });

    test(
        'a same-task new path still needs supplemental approval when toggled off',
        () {
      final approved = _plan();
      final result = WorkChangePolicy.evaluate(
        plan: _plan(
          exactPaths: const ['/workspace/report.md', '/workspace/summary.md'],
        ),
        scope: WorkApprovalScope.fromPlan(approved),
        settings: const WorkChangePolicySettings(confirmOrdinaryWrites: false),
      );

      expect(result.requirement, WorkChangeApprovalRequirement.supplemental);
      expect(result.requiresPrompt, isTrue);
    });

  test('serializes an explicit task scope without task-wide permission', () {
    final scope = WorkApprovalScope.fromPlan(_plan());
    final encoded = scope.toJsonString();
    final decoded = WorkApprovalScope.fromJsonString(encoded);

    expect(jsonDecode(encoded), isA<Map<String, dynamic>>());
    expect(decoded.taskId, 'task-09');
    expect(decoded.entries, hasLength(2));
    expect(encoded, isNot(contains('allTask')));
    expect(encoded, isNot(contains('全写')));
    expect(decoded.allows(_plan()), isTrue);
  });

  group('命令审批继承已批准范围', () {
    test('同一路径上的第二次命令不再要新审批', () {
      final scope = WorkApprovalScope.fromPlan(
        _commandPlan(arguments: const ['-i', 's/a/b/', '/workspace/report.md']),
      );
      final result = WorkChangePolicy.evaluate(
        plan: _commandPlan(
          arguments: const ['-i', 's/version/ver/g', '/workspace/report.md'],
        ),
        scope: scope,
        settings: const WorkChangePolicySettings(confirmOrdinaryWrites: false),
      );

      expect(result.requirement, WorkChangeApprovalRequirement.none);
      expect(result.requiresPrompt, isFalse);
    });

    test('删除命令即使路径已批准仍需单独确认', () {
      final scope = WorkApprovalScope.fromPlan(
        _commandPlan(arguments: const ['-i', 's/a/b/', '/workspace/report.md']),
      );
      final result = WorkChangePolicy.evaluate(
        plan: _commandPlan(executable: 'rm', arguments: const ['report.md']),
        scope: scope,
        settings: const WorkChangePolicySettings(confirmOrdinaryWrites: false),
      );

      expect(result.requirement, WorkChangeApprovalRequirement.alwaysConfirm);
      expect(result.requiresPrompt, isTrue);
    });

    test('解释器脚本即使路径已批准仍需单独确认', () {
      final scope = WorkApprovalScope.fromPlan(
        _commandPlan(arguments: const ['-i', 's/a/b/', '/workspace/report.md']),
      );
      final result = WorkChangePolicy.evaluate(
        plan: _commandPlan(
          executable: 'python3',
          arguments: const ['fix_layout.py'],
        ),
        scope: scope,
        settings: const WorkChangePolicySettings(confirmOrdinaryWrites: false),
      );

      expect(result.requirement, WorkChangeApprovalRequirement.alwaysConfirm);
      expect(result.requiresPrompt, isTrue);
    });

    test('影响范围不确定的命令不会被旧的路径批准放过', () {
      final scope = WorkApprovalScope.fromPlan(
        _commandPlan(arguments: const ['-i', 's/a/b/', '/workspace/report.md']),
      );
      final result = WorkChangePolicy.evaluate(
        plan: _commandPlan(
          arguments: const ['-i', 's/a/b/', '/workspace/report.md'],
          impactUncertain: true,
        ),
        scope: scope,
        settings: const WorkChangePolicySettings(confirmOrdinaryWrites: false),
      );

      expect(result.requirement, WorkChangeApprovalRequirement.alwaysConfirm);
      expect(result.reason, contains('不确定'));
    });

    test('find -delete 的匹配集不在参数里，不能继承目录批准范围', () {
      // 回归：find 的可执行名与参数里都没有"危险标志"，规划器会把它归到
      // "本地变更"，于是只要目录已批准就免审批删除匹配到的任意文件。
      final scope = WorkApprovalScope.fromPlan(_commandPlan());
      final result = WorkChangePolicy.evaluate(
        plan: _commandPlan(
          executable: 'find',
          arguments: const ['.', '-name', '*.dart', '-delete'],
          directories: const ['/workspace/report.md'],
        ),
        scope: scope,
        settings: const WorkChangePolicySettings(confirmOrdinaryWrites: false),
      );

      expect(result.requirement, WorkChangeApprovalRequirement.alwaysConfirm);
      expect(result.reason, contains('无法从参数完整枚举'));
    });

    test('xargs 的影响散在输入里，不能继承已批准范围', () {
      final scope = WorkApprovalScope.fromPlan(_commandPlan());
      final result = WorkChangePolicy.evaluate(
        plan: _commandPlan(
          executable: 'xargs',
          arguments: const ['rm', '-f'],
          directories: const ['/workspace/report.md'],
        ),
        scope: scope,
        settings: const WorkChangePolicySettings(confirmOrdinaryWrites: false),
      );

      expect(result.requirement, WorkChangeApprovalRequirement.alwaysConfirm);
    });

    test('sed -i 带通配符会改到没点名的文件，仍需确认', () {
      final scope = WorkApprovalScope.fromPlan(_commandPlan());
      final result = WorkChangePolicy.evaluate(
        plan: _commandPlan(
          arguments: const ['-i', 's/a/b/', '/workspace/*.md'],
          directories: const ['/workspace/report.md'],
        ),
        scope: scope,
        settings: const WorkChangePolicySettings(confirmOrdinaryWrites: false),
      );

      expect(result.requirement, WorkChangeApprovalRequirement.alwaysConfirm);
    });

    test('只读检索仍然继承已批准范围，不因收紧判据回到逐条审批', () {
      // 收紧的边界必须只切"影响不可枚举"的命令：把 grep 也切进去，就回到了
      // 2026-10-23 那次「991 次 grep 全部因正则里的 | 被拦」。
      final scope = WorkApprovalScope.fromPlan(_commandPlan());
      final result = WorkChangePolicy.evaluate(
        plan: _commandPlan(
          executable: 'grep',
          arguments: const ['-nE', '<section|</section>', 'report.md'],
          directories: const ['/workspace/report.md'],
        ),
        scope: scope,
        settings: const WorkChangePolicySettings(confirmOrdinaryWrites: false),
      );

      expect(result.requirement, WorkChangeApprovalRequirement.none);
    });
  });
  });
}

WorkChangePlan _commandPlan({
  String executable = 'sed',
  List<String> arguments = const ['-i', 's/a/b/', '/workspace/report.md'],
  bool impactUncertain = false,
  List<String> directories = const ['/workspace/report.md'],
}) {
  return WorkChangePlan(
    taskId: 'task-09',
    actionType: WorkChangeActionType.command,
    exactPaths: const <String>[],
    knownAffectedDirectories: directories,
    estimatedBytes: 0,
    snapshotAvailable: false,
    reversible: false,
    command: WorkChangeCommand(
      executable: executable,
      arguments: arguments,
      workingDirectory: '/workspace',
      knownFiles: const <String>[],
      possibleDirectories: directories,
      impactUncertain: impactUncertain,
    ),
    riskReason: '命令可能修改工作区文件。',
  );
}
