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
    final candidates = runner.database.aiCharacterBox.values
        .where((c) =>
            !state.team.any((m) => m['memberId'] == c.id) &&
            WorkRoleRouter.qualifiesForResponsibility(
                c, role, runner.database.characterSkillBox.values))
        .toList();
    final options = <Map<String, dynamic>>[];
    for (final candidate in candidates) {
      if (options.length == 12) break;
      final member = await runner._resolveV2Member(candidate);
      if (!member.available) continue;
      options.add({
        'id': candidate.id,
        'label':
            '${candidate.name}（${candidate.role}，${member.config!.modelName}）',
        'impact': '只加入本次任务的 $role 责任；保留目录、工具和模型治理边界。'
      });
    }
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
      bool router = false}) async {
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
      'impact': '待答事项未解决前不开始制作；用户答复后重新核对方案。',
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
