import 'dart:convert';

import 'work_role_router.dart';

part 'work_collaboration_state_gate.dart';
part 'work_collaboration_state_history.dart';
part 'work_collaboration_state_updates.dart';

/// The bounded business facts of a v2 group task. Full conversation and test
/// logs live in existing message/event stores; these records contain IDs only.
class WorkCollaborationState {
  final String taskId;
  final String conversationId;
  final String projectScopeId;
  final int revision;
  final int requestRevision;
  final int teamRevision;
  final int verificationRevision;
  final String requestMessageId;
  final String scope;
  final String plan;
  final String coordinatorId;
  final String phase;
  final Map<String, dynamic> artifactContract;
  final List<Map<String, dynamic>> team;
  final List<Map<String, dynamic>> workItems;
  final List<Map<String, dynamic>> issues;
  final List<Map<String, dynamic>> acceptances;
  final List<Map<String, dynamic>> iterations;
  final List<Map<String, dynamic>> approvals;
  final List<Map<String, dynamic>> decisions;
  final List<String> pendingInputIds;
  final List<String> appliedEventIds;

  WorkCollaborationState({
    required this.taskId,
    required this.conversationId,
    required this.projectScopeId,
    required this.revision,
    required this.requestRevision,
    required this.teamRevision,
    required this.verificationRevision,
    required this.requestMessageId,
    required this.scope,
    required this.plan,
    required this.coordinatorId,
    required this.phase,
    required Map<String, dynamic> artifactContract,
    required List<Map<String, dynamic>> team,
    required List<Map<String, dynamic>> workItems,
    required List<Map<String, dynamic>> issues,
    required List<Map<String, dynamic>> acceptances,
    required List<Map<String, dynamic>> iterations,
    required List<Map<String, dynamic>> approvals,
    required List<Map<String, dynamic>> decisions,
    required List<String> pendingInputIds,
    required List<String> appliedEventIds,
  })  : artifactContract =
            Map.unmodifiable(canonicalContract(artifactContract)),
        team = List.unmodifiable(
            team.map((e) => Map<String, dynamic>.unmodifiable(e))),
        workItems = List.unmodifiable(
            workItems.map((e) => Map<String, dynamic>.unmodifiable({
                  ...e,
                  if (e['dependencies'] is List)
                    'dependencies':
                        List.unmodifiable(e['dependencies'] as List),
                }))),
        issues = List.unmodifiable(
            issues.map((e) => Map<String, dynamic>.unmodifiable(e))),
        acceptances = List.unmodifiable(
            acceptances.map((e) => Map<String, dynamic>.unmodifiable(e))),
        iterations = List.unmodifiable(
            iterations.map((e) => Map<String, dynamic>.unmodifiable(e))),
        approvals = List.unmodifiable(
            approvals.map((e) => Map<String, dynamic>.unmodifiable(e))),
        decisions = List.unmodifiable(
            decisions.map((e) => Map<String, dynamic>.unmodifiable(e))),
        pendingInputIds = List.unmodifiable(pendingInputIds),
        appliedEventIds = List.unmodifiable(appliedEventIds);

  /// 合同类型收敛到唯一词表：v1 的 `source` 与 v2 的 `software` 说的是同一个交付
  /// 类型（入口见 `WorkRoleRouter.canonicalArtifactType`）。
  ///
  /// 归一化挂在**唯一构造点**而不是写入点：状态既能从落盘 JSON 读回，也能由内存
  /// 增量构造。只在提交时归一化会漏掉两条路——已经 `ready` 的旧任务不再经过提交，
  /// 原样读回就让软件材料、文件清单与验证命令整段闭环检查失效；其余路径则会让基线
  /// 比较把一次等价拼写差异当成"合同被改写、必须递增需求版本"，任务被永久卡住。
  static Map<String, dynamic> canonicalContract(Map<String, dynamic> contract) {
    final type = contract['type'];
    if (type is! String) return contract;
    final canonical = WorkRoleRouter.canonicalArtifactType(type);
    return canonical == type ? contract : {...contract, 'type': canonical};
  }

  static const phases = {
    'forming',
    'clarifying',
    'ready',
    'producing',
    'verifying',
    'reviewing',
    'delivered'
  };
  static const issueKinds = {'defect', 'idea', 'decision'};
  static const issueStatuses = {
    'open',
    'resolved',
    'deferred',
    'waived',
    'rejected'
  };
  static const acceptanceStatuses = {
    'pending',
    'passed',
    'failed',
    'deferred',
    'waived',
    'manual'
  };
  static const approvalKinds = {'plan', 'delivery', 'idea'};
  static const _fields = {
    'taskId',
    'conversationId',
    'projectScopeId',
    'revision',
    'requestRevision',
    'teamRevision',
    'verificationRevision',
    'requestMessageId',
    'scope',
    'plan',
    'coordinatorId',
    'phase',
    'artifactContract',
    'team',
    'workItems',
    'issues',
    'acceptances',
    'iterations',
    'approvals',
    'decisions',
    'pendingInputIds',
    'appliedEventIds'
  };
  static bool _only(Map<String, dynamic> value, Set<String> keys) =>
      value.keys.every(keys.contains);

  static bool _id(Object? value) =>
      value is String &&
      value.trim().isNotEmpty &&
      value.length <= 128 &&
      !value.contains(RegExp(r'[\u0000-\u001f\u007f]'));
  static bool _text(Object? value, {int max = 4096}) =>
      value is String &&
      value.length <= max &&
      !value.contains(RegExp(r'[\u0000-\u001f\u007f]'));
  static bool _revision(Object? value) =>
      value is int && value >= 1 && value <= 2147483647;
  // 每类最多 64 条**当前**记录，账台在构造前先归一化，不让历史把容量占满：
  // 签字台账按同键只留最新一条（见 [compactedApprovals]，上限因此限的是有效认可
  // 数），候选索引只留最新 `maxIterations` 条（见 [boundedIterations]）。
  static bool _records(List<Map<String, dynamic>> records,
          bool Function(Map<String, dynamic>) valid,
          {int? max = 64}) =>
      (max == null || records.length <= max) && records.every(valid);
  static bool _unique(List<Map<String, dynamic>> records, String key) =>
      records.map((e) => e[key]).toSet().length == records.length;
  static bool _refs(List<String> refs) =>
      refs.length <= 64 &&
      refs.toSet().length == refs.length &&
      refs.every(_id);

  /// Imported history must be re-planned and verified on the new device.
  /// The caller archives the old record before applying this exact transition.
  Map<String, dynamic> portableProjectBindingPatch(String projectScope) {
    if (projectScopeId != 'portable-unbound' ||
        !_id(projectScope) ||
        projectScope == 'portable-unbound') {
      throw StateError('仅导入历史允许重新核对项目绑定。');
    }
    return {
      'projectScopeId': projectScope,
      'phase': 'clarifying',
      'plan': '',
      'requestRevision': requestRevision + 1,
      'verificationRevision': verificationRevision + 1,
      'teamRevision': teamRevision + 1,
      'team': [
        for (final m in team) {...m, 'available': false}
      ],
      'workItems': [
        for (final i in workItems)
          {
            ...i,
            'status': 'pending',
            'resultRef': '',
            'requestRevision': requestRevision + 1
          }
      ],
      'acceptances': [
        for (final a in acceptances)
          {
            ...a,
            'status': a['status'] == 'deferred' ? 'deferred' : 'pending',
            'evidenceRef': '',
            'requestRevision': requestRevision + 1,
            'verificationRevision': verificationRevision + 1
          }
      ],
      ..._portableUnresolvedPatch(),
    };
  }

  Map<String, dynamic> _portableUnresolvedPatch() => {
        'issues': [
          for (final i in issues)
            {
              ...i,
              if ({'resolved', 'waived'}.contains(i['status'])) ...{
                'status': 'open',
                'resolution': '',
                'resolutionRef': ''
              },
              'requestRevision': requestRevision + 1
            }
        ],
        // Reconfirm old decisions instead of carrying human approvals or waivers
        // into a new environment; deferred questions remain deferred.
        'decisions': [
          for (final d in decisions)
            {
              ...d,
              'revision': (d['revision'] as int) + 1,
              'status': d['status'] == 'deferred' ? 'deferred' : 'pending',
              'answer': '',
              'responseRef': '',
              if (d.containsKey('answerKind')) 'answerKind': 'text',
            }..remove('promptedReminder')
        ],
      };

  Map<String, dynamic> toJson() => {
        'taskId': taskId,
        'conversationId': conversationId,
        'projectScopeId': projectScopeId,
        'revision': revision,
        'requestRevision': requestRevision,
        'teamRevision': teamRevision,
        'verificationRevision': verificationRevision,
        'requestMessageId': requestMessageId,
        'scope': scope,
        'plan': plan,
        'coordinatorId': coordinatorId,
        'phase': phase,
        'artifactContract': artifactContract,
        'team': team,
        'workItems': workItems,
        'issues': issues,
        'acceptances': acceptances,
        'iterations': iterations,
        'approvals': approvals,
        'decisions': decisions,
        'pendingInputIds': pendingInputIds,
        'appliedEventIds': appliedEventIds
      };

  static WorkCollaborationState? tryParse(Object? value,
      {void Function(String section)? onInvalid}) {
    if (value is! Map || value.keys.any((k) => k is! String)) {
      onInvalid?.call('record');
      return null;
    }
    try {
      final m = Map<String, dynamic>.from(value);
      if (!_only(m, _fields)) {
        onInvalid?.call('record');
        return null;
      }
      List<Map<String, dynamic>> list(String key) => (m[key] as List)
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
      final state = WorkCollaborationState(
          taskId: m['taskId'] as String,
          conversationId: m['conversationId'] as String,
          projectScopeId: m['projectScopeId'] as String,
          revision: m['revision'] as int,
          requestRevision: m['requestRevision'] as int,
          teamRevision: m['teamRevision'] as int,
          verificationRevision: m['verificationRevision'] as int,
          requestMessageId: m['requestMessageId'] as String,
          scope: m['scope'] as String,
          plan: m['plan'] as String,
          coordinatorId: m['coordinatorId'] as String,
          phase: m['phase'] as String,
          artifactContract:
              Map<String, dynamic>.from(m['artifactContract'] as Map),
          team: list('team'),
          workItems: list('workItems'),
          issues: list('issues'),
          acceptances: list('acceptances'),
          iterations: boundedIterations(list('iterations')),
          approvals: compactedApprovals(list('approvals')),
          decisions: list('decisions'),
          pendingInputIds: List<String>.from(m['pendingInputIds'] as List),
          appliedEventIds: List<String>.from(m['appliedEventIds'] as List));
      final invalidSection = state.invalidSection;
      if (invalidSection != null) {
        onInvalid?.call(invalidSection);
        return null;
      }
      return state;
    } on Object {
      onInvalid?.call('record');
      return null;
    }
  }

  /// 候选版本索引上限。
  ///
  /// 与 `appliedEventIds` 同一形状：**最新 N 条**的滚动窗口，超出的最旧那条丢弃。
  /// 丢弃不等于丢数据——权威记录不在状态里：每轮候选目录与 `candidate.json` 仍完整
  /// 盘在工作区，`WorkCandidatePublisher.recover` 会从磁盘重建整个候选列表并重写
  /// `index.json`；而状态里的这一行只是有界镜像，所有读取判据（`currentIteration`、
  /// 交付门槛、发布编号分配、候选索引校验）都只钉最新一条。不设窗口就会撞上
  /// `_records` 的 64 条上限：第 65 轮候选让整个状态解析成 null，任务被永久卡住。
  static const maxIterations = 64;

  static List<Map<String, dynamic>> boundedIterations(
          List<Map<String, dynamic>> records) =>
      records.length <= maxIterations
          ? records
          : records.sublist(records.length - maxIterations);

  /// 已了结的历史条目上限（问题与决策各算各的）。
  static const maxSettledHistory = 64;

  /// 归档历史签字：每组同键记录只留最新的一条。
  ///
  /// `approvals` 是只追加的台账，而每一个读取判据（方案/交付全员认可、采纳范围
  /// 提案的认可、候选结论归档）都只取每组里的**最后一条**。于是同键的旧记录对任何
  /// 判据都不再可见，留着只会撞上"每类最多 64 条"的容量上限：迭代够久，第 65 条
  /// 签字就让整个状态解析失败、任务被永久卡住，而工具侧既没有归档入口也不允许丢掉
  /// 旧签字。签字者自己那句公开认可仍在群里（`evidenceRef` 指向它），事件 id 也仍
  /// 在 `appliedEventIds` 里。
  ///
  /// 键里保留 `approved`：同意→反对→同意这种反复各自留证，合并成一条会让成员增量
  /// 校验里的"只追加一条"判据认不出这次追加。
  static List<Map<String, dynamic>> compactedApprovals(
      List<Map<String, dynamic>> records) {
    final keys = <String>{};
    final kept = <Map<String, dynamic>>[];
    for (final record in records.reversed) {
      if (keys.add(_approvalKey(record))) kept.add(record);
    }
    return kept.reversed.toList();
  }

  /// 归档判据用到的全部维度：任何读取都是这些字段的子集，取最后一条即可代表这一组。
  ///
  /// 需求版本与团队版本只对 `idea` 留在键里：`ideaApproved` 读的是**问题自己携带
  /// 的**需求版本（`issue['requestRevision']`），所以同一成员在不同版本上的
  /// idea 认可各自有效；其余 kind（plan / delivery）的判据一律只比当前版本，
  /// 更早的版本对任何读取都不可见，留在键里就等于让历史签字永久占着容量——迭代
  /// 32 个需求版本就能攒满 64 条。`iterationId` / `artifactDigest` 同理：delivery
  /// 签字的 `subjectId` 就是迭代 id，而摘要由该迭代唯一确定。
  static String _approvalKey(Map<String, dynamic> record) => [
        record['memberId'],
        record['kind'],
        record['subjectId'],
        if (record['kind'] == 'idea') ...[
          record['requestRevision'],
          record['teamRevision'],
        ],
        record['approved'],
      ].map((value) => '$value').join('\u0000');

  /// 一条签字的**不可变内容**指纹。
  ///
  /// 用于"公开增量只能原样携带已有签字"的门禁：只比 `eventId` 不够——id 由调用方
  /// 给出，而台账解析会归档被同键新签字顶掉的旧记录，旧 id 一旦滚出索引，换掉验证
  /// 版本（或任何内容）的同 id 记录就会被当成全新签字放行。字段顺序固定拼接，不走
  /// map 的插入顺序，避免同一份签字因为构造路径不同而得到两个指纹。
  static String approvalFingerprint(Map<String, dynamic> record) => [
        for (final key in const [
          'eventId',
          'memberId',
          'kind',
          'subjectId',
          'requestRevision',
          'teamRevision',
          'iterationId',
          'artifactDigest',
          'verificationRevision',
          'approved',
          'evidenceRef',
          'source'
        ])
          '${record[key]}'
      ].join('\u0000');

  /// Applies one provenance-checked transition; duplicate events are no-ops.
  WorkCollaborationState apply(WorkCollaborationUpdate update) =>
      _apply(update);

  /// V1 records are converted only by an explicit caller and start blocked.
  static WorkCollaborationState fromLegacy(
          {required String taskId,
          required String conversationId,
          required String projectScopeId,
          required int requestRevision,
          required String requestMessageId,
          required String scope,
          required Map<String, dynamic> artifactContract}) =>
      WorkCollaborationState(
          taskId: taskId,
          conversationId: conversationId,
          projectScopeId: projectScopeId,
          revision: 1,
          requestRevision: requestRevision,
          teamRevision: 1,
          verificationRevision: 1,
          requestMessageId: requestMessageId,
          scope: scope,
          plan: '',
          coordinatorId: '',
          phase: 'clarifying',
          artifactContract: artifactContract,
          team: const [],
          workItems: const [],
          issues: const [],
          acceptances: const [],
          iterations: const [],
          approvals: const [],
          decisions: const [],
          pendingInputIds: const [],
          appliedEventIds: const []);
}

class WorkCollaborationUpdate {
  final String taskId;
  final String conversationId;
  final int expectedRevision;
  final String eventId;
  final String sourceRole;
  final String sourceId;
  final WorkCollaborationState next;

  const WorkCollaborationUpdate(
      {required this.taskId,
      required this.conversationId,
      required this.expectedRevision,
      required this.eventId,
      required this.sourceRole,
      required this.sourceId,
      required this.next});
}
