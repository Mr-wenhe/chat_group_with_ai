part of 'work_collaboration_state.dart';

/// 保留当前授权和未决义务；模型投影与权威落盘使用不同入口。
extension WorkCollaborationHistory on WorkCollaborationState {
  /// 落盘前的历史窗口：把**已了结**条目移出状态，只留最新 [WorkCollaborationState.maxSettledHistory] 条。
  ///
  /// `issues` 与 `decisions` 都是只追加的台账。它们与签字不同，旧记录**仍会被读**：
  /// [issuesResolved] 遍历全部问题、[_userResolved] 回扫决策找 `targetId`，所以既
  /// 不能像签字那样"保留列表、只把容量判据收窄"（列表会无界增长），也不能在**读取**
  /// 时裁——`_validateMemberResolution` / `_validateReview` 是按下标比对新旧问题的，
  /// 读取时裁会让下标错位、把一次正常答复判成篡改。窗口因此只挂在**唯一落盘入口**
  /// `WorkDiscussionState.mergeIntoExecutionState`：内存里的台账始终完整，写进任务
  /// 检查点的才是有界镜像。
  ///
  /// 只丢**判据不依赖会变的当前版本**的已了结条目：`idea` 且 `resolved` 的判据是
  /// `ideaApproved`（读当前团队与认可），团队一换就可能翻回未满足，故不参与窗口；
  /// `open` / `deferred` 是未决义务，永不丢弃。决策与问题同批处理——只为**保留下来
  /// 的**问题与验收留 `answered` / `waived` 决策，否则 [issuesResolved] 会因为找不到
  /// 用户裁决而判不齐。
  WorkCollaborationState boundedHistory() {
    final keptIssues = _windowedIssues(issues);
    final liveIds = <String>{
      for (final issue in keptIssues) issue['id'] as String,
      for (final acceptance in acceptances) acceptance['id'] as String,
    };
    final keptDecisions = _windowedDecisions(decisions, liveIds);
    if (keptIssues.length == issues.length &&
        keptDecisions.length == decisions.length) {
      return this;
    }
    return WorkCollaborationState.tryParse(toJson()
          ..['issues'] = keptIssues
          ..['decisions'] = keptDecisions) ??
        this;
  }

  /// 模型只需当前门禁事实；完整签字与版本历史仍由 [toJson] 保存。
  /// 不改变需求、问题、验收或用户决策，也不把投影写回权威检查点。
  Map<String, dynamic> toPromptJson() => toJson()
    ..['approvals'] = currentApprovals.toList()
    ..['iterations'] = [if (currentIteration != null) currentIteration!];

  /// 问题的历史窗口：未决义务一条不丢，已了结的只留最新 [WorkCollaborationState.maxSettledHistory] 条。
  List<Map<String, dynamic>> _windowedIssues(
      List<Map<String, dynamic>> records) {
    var toDrop = records.where(_isSettledIssue).length -
        WorkCollaborationState.maxSettledHistory;
    if (toDrop <= 0) return records;
    final kept = <Map<String, dynamic>>[];
    for (final issue in records) {
      if (toDrop > 0 && _isSettledIssue(issue)) {
        toDrop--;
        continue;
      }
      kept.add(issue);
    }
    return kept;
  }

  /// 该问题**自己**是否已经满足 [issuesResolved] 的判据。
  ///
  /// 恰好照抄那道闸门逐条的分支：`issuesResolved` 是 `every`，丢掉一条已满足的既不会
  /// 让它从 true 变 false，也不会让它从 false 变 true——门槛结论因此完全不变；反过来
  /// 只要有一条判据不成立就绝不丢，未决义务不会静默消失。
  ///
  /// `idea` 且 `resolved` 除外：它的判据是 `ideaApproved`，读的是当前团队与认可，团队
  /// 或验证版本一换就可能翻回未满足，留着才不会让一条已被推翻的认可被裁掉。
  bool _isSettledIssue(Map<String, dynamic> issue) {
    if ('${issue['target']}'.trim().isEmpty ||
        '${issue['problem']}'.trim().isEmpty ||
        '${issue['evidenceRef']}'.trim().isEmpty ||
        '${issue['retestCondition']}'.trim().isEmpty) {
      return false;
    }
    final status = issue['status'];
    if (issue['kind'] == 'idea' && status == 'resolved') return false;
    if (status == 'waived') return _userResolved(issue['id'] as String);
    if (status == 'rejected') {
      return issue['kind'] == 'idea' && _userResolved(issue['id'] as String);
    }
    return status == 'resolved' &&
        '${issue['resolution']}'.trim().isNotEmpty &&
        '${issue['resolutionRef']}'.trim().isNotEmpty;
  }

  /// 决策的历史窗口：未决（`pending` / `deferred`）与仍被保留的问题、验收引用的
  /// 裁决一条不丢，其余已了结的只留最新 [WorkCollaborationState.maxSettledHistory] 条。
  List<Map<String, dynamic>> _windowedDecisions(
      List<Map<String, dynamic>> records, Set<String> liveIds) {
    bool droppable(Map<String, dynamic> decision) =>
        (decision['status'] == 'answered' || decision['status'] == 'waived') &&
        (decision['responseRef'] as String).isNotEmpty &&
        !_authorizesCurrentMember(decision) &&
        !liveIds.contains(decision['targetId']) &&
        !liveIds.contains(decision['id']);
    var toDrop = records.where(droppable).length -
        WorkCollaborationState.maxSettledHistory;
    if (toDrop <= 0) return records;
    final kept = <Map<String, dynamic>>[];
    for (final decision in records) {
      if (toDrop > 0 && droppable(decision)) {
        toDrop--;
        continue;
      }
      kept.add(decision);
    }
    return kept;
  }

  // 加入角色库成员的答复是持续授权，不是已消费的普通问答；人工审查同理。
  bool _authorizesCurrentMember(Map<String, dynamic> decision) =>
      decision['kind'] == 'member' &&
      decision['status'] == 'answered' &&
      decision['answerKind'] == 'choice' &&
      (decision['options'] as List? ?? const []).whereType<Map>().any(
          (option) =>
              option['label'] == decision['answer'] &&
              (option['id'] == 'human-review' ||
                  team.any((member) => member['memberId'] == option['id'])));
}
