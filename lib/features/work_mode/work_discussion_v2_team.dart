part of 'work_discussion_runner.dart';

extension _V2DiscussionTeam on _V2DiscussionSession {
  Future<bool> _formTeam() async {
    if (group == null) {
      await _decision('question', '', '当前群组已删除，请停止或重新绑定任务。', '群组记录不存在。',
          router: true);
      return false;
    }
    final confirmed = <String, String>{};
    for (final decision in state.decisions.where((d) =>
        d['kind'] == 'member' &&
        d['status'] == 'answered' &&
        d['answerKind'] == 'choice')) {
      final options = (decision['options'] as List?) ?? const [];
      final selected = options
          .whereType<Map>()
          .where((o) => o['label'] == decision['answer'])
          .firstOrNull;
      if (selected != null) {
        confirmed[decision['targetId'] as String] = selected['id'] as String;
      }
    }
    if (state.team.isNotEmpty) {
      final team = state.team.map((m) => Map<String, dynamic>.from(m)).toList();
      var changed = false;
      for (final entry in confirmed.entries) {
        final role = entry.key.startsWith('role:')
            ? entry.key.substring(5)
            : team.where((m) => m['memberId'] == entry.key).firstOrNull?['role']
                as String?;
        final character = runner.database.aiCharacterBox.get(entry.value);
        if (role == null ||
            character == null ||
            !WorkRoleRouter.qualifiesForResponsibility(
                character, role, runner.database.characterSkillBox.values)) {
          continue;
        }
        final resolved = await runner._resolveV2Member(character);
        if (!resolved.available) continue;
        if (team
            .any((m) => m['memberId'] == character.id && m['role'] == role)) {
          continue;
        }
        if (!entry.key.startsWith('role:')) {
          team.removeWhere((m) => m['memberId'] == entry.key);
        }
        team.add({
          'memberId': character.id,
          'role': role,
          'qualificationRef': 'user:${character.id}:$role',
          'qualified': true,
          'available': true
        });
        changed = true;
      }
      if (changed) {
        await _commit('router', 'router', {
          'team': team,
          'teamRevision': state.teamRevision + 1,
          'coordinatorId': team.any((m) => m['memberId'] == state.coordinatorId)
              ? state.coordinatorId
              : team.first['memberId'],
          'phase': 'clarifying'
        });
      }
      return !state.hasBlockingDecision && await _checkTeam();
    }
    final characters = group!.aiCharacterIds
        .map(runner.database.aiCharacterBox.get)
        .whereType<AICharacter>()
        .toList();
    for (final id in confirmed.values) {
      final member = runner.database.aiCharacterBox.get(id);
      if (member != null && !characters.any((c) => c.id == id)) {
        characters.add(member);
      }
    }
    final selected = WorkRoleRouter.selectTeam(
        request: task.userRequest,
        characters: characters,
        skills: runner.database.characterSkillBox.values);
    final team =
        selected.team.map((m) => Map<String, dynamic>.from(m)).toList();
    for (final m in team) {
      final member = await runner
          ._resolveV2Member(runner.database.aiCharacterBox.get(m['memberId'])!);
      m['available'] = member.available;
    }
    if (team.isNotEmpty) {
      await _commit('router', 'router', {
        'team': team,
        'coordinatorId': team.first['memberId'],
        'teamRevision': state.teamRevision + 1,
        'phase': 'clarifying'
      });
    }
    if (selected.errors.isNotEmpty) {
      await _decision('question', '', selected.errors.join('；'), '未自动替换指定成员。',
          router: true);
      return false;
    }
    for (final role in selected.missing) {
      await _missingRole(role.name);
    }
    // A fast user reply may arrive while the decision sink is awaiting.
    // End this run so the next session applies the confirmed membership first.
    if (selected.missing.isNotEmpty || state.hasBlockingDecision) return false;
    return await _checkTeam();
  }

  Future<bool> _checkTeam() async {
    var available = true;
    for (final responsibility in state.team.toList()) {
      final id = responsibility['memberId'] as String;
      final member = runner.database.aiCharacterBox.get(id);
      final userJoined = state.decisions.any((d) =>
          d['kind'] == 'member' &&
          d['status'] == 'answered' &&
          d['answerKind'] == 'choice' &&
          (d['options'] as List? ?? const [])
              .whereType<Map>()
              .any((o) => o['id'] == id && o['label'] == d['answer']));
      String? reason;
      if (member == null) {
        reason = '成员已删除';
      } else if (!group!.aiCharacterIds.contains(id) && !userJoined) {
        reason = '成员已离开当前群，未获任务加入确认';
      } else if (!WorkRoleRouter.qualifiesForResponsibility(
          member,
          responsibility['role'] as String,
          runner.database.characterSkillBox.values)) {
        reason = '成员当前资格或配置不可用';
      } else {
        final resolved = await runner._resolveV2Member(member);
        reason = resolved.available ? null : resolved.unavailableReason;
      }
      if (reason != null) {
        await _memberGap(id, reason);
        available = false;
      } else if (responsibility['available'] != true) {
        await _commit('router', 'router', {
          'team': [
            for (final m in state.team)
              m['memberId'] == id ? {...m, 'available': true} : m
          ],
          'teamRevision': state.teamRevision + 1
        });
      }
    }
    if (available &&
        state.teamQualified &&
        state.issues.any((i) =>
            i['kind'] == 'idea' &&
            i['status'] == 'resolved' &&
            !state.ideaApproved(i['id'] as String,
                requestRevision: i['requestRevision'] as int) &&
            !_userAdopted(i))) {
      await _commit('coordinator', state.coordinatorId, {
        'issues': [
          for (final i in state.issues)
            i['kind'] == 'idea' &&
                    i['status'] == 'resolved' &&
                    !state.ideaApproved(i['id'] as String,
                        requestRevision: i['requestRevision'] as int) &&
                    !_userAdopted(i)
                ? {
                    ...i,
                    'status': 'open',
                    'resolution': '',
                    'resolutionRef': '',
                    'requestRevision': state.requestRevision + 1
                  }
                : i
        ],
        'requestRevision': state.requestRevision + 1,
        'verificationRevision': state.verificationRevision + 1,
      });
    }
    return available && state.teamQualified;
  }

  bool _userAdopted(Map<String, dynamic> issue) => state.decisions.any((d) =>
      d['kind'] == 'dispute' &&
      d['targetId'] == issue['id'] &&
      d['status'] == 'answered' &&
      d['answerKind'] == 'choice' &&
      (d['options'] as List? ?? const []).whereType<Map>().any((o) =>
          (o['id'] as String).startsWith('adopt:proposal:') &&
          o['label'] == d['answer']));

  Future<void> _missingRole(String role,
      {String? replaceId, String? reason}) async {
    // 下面可能再追加"我承担本次测试或审查"一项；它和换人候选共享同一个决策容量，
    // 所以候选必须先把这一个名额让出来。
    final extraControls = role == 'testing' ? 1 : 0;
    final options = (await _replacementOptions(role, reserve: extraControls)).options;
    if (replaceId == null && role == 'testing') {
      options.add({
        'id': 'human-review',
        'label': '我承担本次测试或审查',
        'impact': '制作后仍须对具体候选明确人工验收或豁免；现在不代表验收通过。'
      });
    }
    await _decision(
        'member',
        replaceId ?? 'role:$role',
        reason ?? '当前群缺少 $role 能力，请确认本次任务成员或补充合格角色。',
        options.isEmpty ? '角色库中没有同时具备资格和可用模型的候选。' : '候选来自已有角色库，资格与模型配置已核验。',
        options: options,
        router: true);
  }

  /// 具备该责任资格、凭据可解析、且不在当前团队里的候选成员，以及因与失败成员
  /// 同模型而未列出的条数、因决策选项数量上限而未列出的可用候选条数。
  ///
  /// [avoidModelOf] 是刚刚失败的成员：与它同 provider、同模型名的候选换上去也不会
  /// 改变上游那边的失败，所以只要还有别的选择就不列它们；但合格候选全部撞同一个
  /// 模型时不能清空列表——那样用户就只剩改配置一条路，应用内没有换人入口了。判据按
  /// provider + 模型名比，不按 `apiConfigId`：两张配置指向同一个上游模型时，换配置号
  /// 不改变结果。换人确认与「本轮模型失败」的诚实阻塞项共用这一份枚举，两处各维护
  /// 一遍时总有一边列不出候选来。
  ///
  /// [reserve] 是调用方在这个决策里固定附带、不由本方法产出的选项数量（保留原成员
  /// 重试、人工承担等）。候选名额必须先扣掉它：拼出来的决策总数一旦超出
  /// [WorkDiscussionRunner.maxDecisionOptions]，整条增量会被状态闸门拒绝，用户连
  /// 最需要的"重试"都看不到。
  Future<
      ({
        List<Map<String, dynamic>> options,
        int hiddenSameModel,
        int hiddenDifferentModel,
      })> _replacementOptions(String role,
          {_DiscussionMember? avoidModelOf, int reserve = 0}) async {
    final failingModel = avoidModelOf == null
        ? null
        : '${avoidModelOf.provider}/${avoidModelOf.config?.modelName}';
    final sameModel = <Map<String, dynamic>>[];
    final options = <Map<String, dynamic>>[];
    // 循环里每轮都要 await 凭据解析（最长凭据超时），必须先对角色库取快照：
    // 期间用户增删角色会让惰性迭代撞上并发修改。
    final candidates = runner.database.aiCharacterBox.values
        .where((c) =>
            !state.team.any((m) => m['memberId'] == c.id) &&
            WorkRoleRouter.qualifiesForResponsibility(
                c, role, runner.database.characterSkillBox.values))
        .toList();
    // 与 `_resolveV2Members` 同一条理由：逐个 await 凭据解析时，一个挂住的
    // 凭据提供方会让这个阻塞弹窗推迟 N × 凭据超时（几十个角色就是几分钟）。
    // 先并发解析整份候选，再按原顺序组装——顺序即用户看到的顺序。
    final resolved = await Future.wait(
      candidates.map(runner._resolveV2Member),
    );
    // 先在**全量**候选上分流，再对最终展示的列表限名额。名额若在分流之前就被
    // 消耗，排在前面的同模型候选会把它占满，后面真正换了模型的候选一个都不会被
    // 遍历——列表看起来"只有同模型可选"，实际可用的替换者根本没被检查过。
    for (var index = 0; index < candidates.length; index++) {
      final candidate = candidates[index];
      final member = resolved[index];
      if (!member.available) continue;
      final option = {
        'id': candidate.id,
        'label':
            '${candidate.name}（${candidate.role}，${member.config!.modelName}）',
        'impact': '只加入本次任务的 $role 责任；保留目录、工具和模型治理边界。'
      };
      if (failingModel != null &&
          failingModel == '${member.provider}/${member.config!.modelName}') {
        sameModel.add(option);
        continue;
      }
      options.add(option);
    }
    final limit = max(0, WorkDiscussionRunner.maxDecisionOptions - reserve);
    // 名额之外的候选一律如实计数，且**区分两种原因**：同模型（换人不解决上游失败）
    // 与单纯装不下（它们确实可用）。只报前者会让用户以为角色库里已经没有别的选择了。
    if (options.isNotEmpty || sameModel.isEmpty) {
      final visible = options.take(limit).toList();
      return (
        // 可变列表：调用方还会往里追加"我承担"这类控制项。
        options: visible,
        hiddenSameModel: sameModel.length,
        hiddenDifferentModel: options.length - visible.length,
      );
    }
    final visibleSameModel = sameModel.take(limit).toList();
    return (
      options: [
        for (final option in visibleSameModel)
          {
            ...option,
            'impact': '与你现有成员是同一个模型，换人不改变上游失败；'
                '请优先调整该成员的模型配置或缩小本轮回应要求。'
          }
      ],
      hiddenSameModel: sameModel.length - visibleSameModel.length,
      hiddenDifferentModel: 0,
    );
  }

  Future<void> _memberGap(String id, String reason) async {
    final record = state.team.where((m) => m['memberId'] == id).single;
    if (record['available'] == true) {
      await _commit('router', 'router', {
        'team': [
          for (final m in state.team)
            m['memberId'] == id ? {...m, 'available': false} : m
        ],
        'teamRevision': state.teamRevision + 1
      });
    }
    await _missingRole(record['role'] as String,
        replaceId: id, reason: '成员 $id：$reason。原责任仍保留，请确认补人、恢复配置或调整责任。');
  }

  Future<void> _decision(
      String kind, String target, String reason, String facts,
      {List<Map<String, dynamic>> options = const [],
      bool router = false,
      String impact = '待答事项未解决前不开始制作；用户答复后重新核对方案。'}) async {
    final pending = state.decisions.any((d) =>
        d['kind'] == kind &&
        d['targetId'] == target &&
        d['reason'] == reason &&
        {'pending', 'deferred'}.contains(d['status']));
    if (pending) return;
    final id =
        _key('decision', '$kind:$target:$reason:${state.requestRevision}');
    if (state.decisions.any((d) =>
        d['id'] == id && {'pending', 'deferred'}.contains(d['status']))) {
      return;
    }
    final decision = {
      'id': id,
      'revision': 1,
      'status': 'pending',
      'reason': reason,
      'answer': '',
      'impact': impact,
      'responseRef': '',
      'evidence': facts,
      'options': options,
      'targetId': target,
      'kind': kind
    };
    await _commit(router || !state.teamQualified ? 'router' : 'coordinator',
        router || !state.teamQualified ? 'router' : state.coordinatorId, {
      'decisions': [...state.decisions, decision],
      'requestRevision': state.requestRevision + 1
    });
  }
}
