part of 'work_discussion_runner.dart';

extension _WorkDiscussionRunnerSetup on WorkDiscussionRunner {
  Future<void> _implRunDiscussion(
    AgentTask task,
    WorkTaskCancellation cancellation,
    WorkTaskDiscussionStateSink updateState,
  ) async {
    final decoded = WorkDiscussionState.decodeExecutionState(
      task.executionStateJson,
    );
    var initial = decoded.state;
    if (!decoded.present || initial == null || cancellation.isCancelled) return;
    final group = database.chatGroupBox.get(task.groupId);
    if (group == null) {
      await _finishBlocked(
        task,
        initial,
        updateState,
        blocker: 'groupUnavailable',
        question: '群组已不存在，无法继续讨论。',
        cancellation: cancellation,
      );
      return;
    }
    if (initial.phase == WorkDiscussionPhase.blocked) return;
    final userBlocker = initial.blockers.firstWhere(
      WorkDiscussionRunner.userDecisionBlockers.contains,
      orElse: () => '',
    );
    if (userBlocker.isNotEmpty) {
      await _finishBlocked(
        task,
        initial,
        updateState,
        blocker: userBlocker,
        question: initial.openQuestions.isEmpty
            ? '讨论需要你的补充，已暂停等待。'
            : initial.openQuestions.first,
        mentionOwner: true,
        cancellation: cancellation,
      );
      return;
    }

    final allCharacters = _groupCharacters(group);
    if (group.aiCharacterIds.toSet().length > allCharacters.length) {
      await _publish(
        task,
        group,
        '本轮最多邀请 $WorkDiscussionRunner.maxMembers 名群成员参与讨论；超出上限或已移除的成员会在任务记录中保留为未参与，不会伪造发言。',
        cancellation: cancellation,
      );
      if (cancellation.isCancelled) return;
    }
    final skills = database.characterSkillBox.values.toList(growable: false);
    final rerouted = await _routeFreshDiscussion(
      task: task,
      initial: initial,
      group: group,
      characters: allCharacters,
      skills: skills,
      cancellation: cancellation,
      updateState: updateState,
    );
    if (rerouted == null || cancellation.isCancelled) return;
    initial = rerouted;
    final stateExecutor = initial.executorId?.trim() ?? '';
    final taskExecutor = task.characterId.trim();
    if (stateExecutor.isNotEmpty &&
        taskExecutor.isNotEmpty &&
        stateExecutor != taskExecutor) {
      await _finishBlocked(
        task,
        initial,
        updateState,
        blocker: 'executorIdentityMismatch',
        question: '任务记录与讨论记录的执行角色不一致，已暂停等待重新确认，未自动换人。',
        mentionOwner: true,
        cancellation: cancellation,
      );
      return;
    }
    final qualified = WorkRoleRouter.qualifiedCandidatesForRequest(
      request: task.userRequest,
      characters: allCharacters,
      skills: skills,
    );
    final qualifiedIds = qualified.map((item) => item.id).toSet();
    final existingCandidateIds = initial.candidateCharacterIds
        .where((id) => allCharacters.any((item) => item.id == id))
        .toSet();
    // Every renewed request version must re-evaluate the occupation set.  The
    // old candidate list is retained only as a durable audit hint; otherwise a
    // target change could leave the previous role as the sole eligible choice.
    final candidateIds = (initial.requestRevision > 1
            ? qualifiedIds
            : existingCandidateIds.isEmpty
                ? qualifiedIds
                : existingCandidateIds.intersection(qualifiedIds))
        .toList(growable: false);
    final members = await _resolveMembers(allCharacters, cancellation);
    if (cancellation.isCancelled) return;
    final membersById = <String, _DiscussionMember>{
      for (final member in members) member.character.id: member,
    };
    final availableMembers =
        members.where((member) => member.available).toList();
    final availableIds =
        availableMembers.map((item) => item.character.id).toSet();
    final qualifiedAvailableIds =
        candidateIds.where(availableIds.contains).toList(growable: false);

    final requestedExecutor = initial.executorId?.trim().isNotEmpty == true
        ? initial.executorId!.trim()
        : task.characterId.trim().isEmpty
            ? null
            : task.characterId.trim();
    if (requestedExecutor != null &&
        (!qualifiedAvailableIds.contains(requestedExecutor) ||
            membersById[requestedExecutor]?.available != true)) {
      await _finishBlocked(
        task,
        initial,
        updateState,
        blocker: 'executorUnavailable',
        question: '指定的最终执行角色当前职业资格或模型凭据不可用，未自动改派其他角色。',
        mentionOwner: true,
        cancellation: cancellation,
      );
      return;
    }

    await _publishUnavailableMembers(
      task,
      group,
      members,
      candidateIds.toSet(),
      cancellation,
    );
    if (cancellation.isCancelled) return;
    if (qualifiedAvailableIds.isEmpty) {
      var blockedState = initial;
      for (final member in members.where((item) => !item.available)) {
        blockedState = _markParticipant(
          blockedState,
          member.character.id,
          status: 'unavailable',
          contribution: member.unavailableReason ?? '不可用',
        );
      }
      await _finishBlocked(
        task,
        blockedState,
        updateState,
        blocker: 'missingQualifiedRole',
        question: '当前没有同时满足职业资格、启用状态和模型凭据的执行角色，请先补充或配置对应角色。',
        mentionOwner: true,
        cancellation: cancellation,
      );
      return;
    }

    var state = _prepareInitialState(
      initial,
      task,
      allCharacters,
      qualifiedAvailableIds,
      availableIds,
    );
    for (final member in members.where((item) => !item.available)) {
      state = _markParticipant(
        state,
        member.character.id,
        status: 'unavailable',
        contribution: member.unavailableReason ?? '不可用',
      );
    }
    if (!await _pushState(task, state, updateState, cancellation)) return;
    if (state.round == 0) {
      await _publish(
        task,
        group,
        '群讨论已启动：首轮邀请所有已配置且启用的成员分别从自己的职业职责发言；当前理解进度 ${state.understandingPercent}%。',
        cancellation: cancellation,
      );
      if (state.executorId == null && state.coordinatorId != null) {
        final coordinator = membersById[state.coordinatorId!];
        if (coordinator != null) {
          await _publish(
            task,
            group,
            '暂由${discussionRoleLabel(coordinator.character)}负责收集意见；最终执行人仍需由具备任务资格的角色公开推举。',
            senderId: coordinator.character.id,
            cancellation: cancellation,
          );
        }
      }
    }

    await _DiscussionSession(
      runner: this,
      task: task,
      cancellation: cancellation,
      updateState: updateState,
      group: group,
      membersById: membersById,
      availableMembers: availableMembers,
      qualifiedAvailableIds: qualifiedAvailableIds,
      memberIds: allCharacters.map((item) => item.id).toList(growable: false),
      state: state,
    ).run();
  }

  List<AICharacter> _groupCharacters(ChatGroup group) {
    final seen = <String>{};
    return group.aiCharacterIds
        .map(database.aiCharacterBox.get)
        .whereType<AICharacter>()
        .where((character) => seen.add(character.id))
        .take(WorkDiscussionRunner.maxMembers)
        .toList(growable: false);
  }

  Future<List<_DiscussionMember>> _resolveMembers(
    List<AICharacter> characters,
    WorkTaskCancellation cancellation,
  ) async {
    if (characters.isEmpty || cancellation.isCancelled) {
      return const <_DiscussionMember>[];
    }
    // ponytail: resolve the bounded member list in parallel so one broken
    // credential provider cannot make a 32-member group wait 4+ minutes.
    return Future.wait(
      characters.map((character) => _resolveMember(character)),
    );
  }

  Future<_DiscussionMember> _resolveMember(AICharacter character) async {
    if (!character.isActive) {
      return _DiscussionMember(
          character: character, unavailableReason: '当前未启用');
    }
    if (!character.agenticEnabled) {
      return _DiscussionMember(
        character: character,
        unavailableReason: '未启用 Agentic 能力',
      );
    }
    final config = _resolveApiConfig(character);
    if (config == null) {
      return _DiscussionMember(
        character: character,
        unavailableReason: '没有绑定模型配置',
      );
    }
    try {
      final key = await credentials.resolve(config).timeout(credentialTimeout);
      if (key == null || key.trim().isEmpty) {
        return _DiscussionMember(
          character: character,
          config: config,
          unavailableReason: '模型凭据不可用',
        );
      }
      return _DiscussionMember(
        character: character,
        config: config,
        apiKey: key,
        provider: _providerFor(config),
      );
    } on TimeoutException {
      return _DiscussionMember(
        character: character,
        config: config,
        unavailableReason: '模型凭据解析超时',
      );
    } on Object {
      return _DiscussionMember(
        character: character,
        config: config,
        unavailableReason: '模型凭据解析失败',
      );
    }
  }

  WorkDiscussionState _prepareInitialState(
    WorkDiscussionState state,
    AgentTask task,
    List<AICharacter> allCharacters,
    List<String> candidateIds,
    Set<String> availableIds,
  ) {
    final taskExecutor = task.characterId.trim();
    final requestedExecutor = state.executorId?.trim().isNotEmpty == true
        ? state.executorId!.trim()
        : taskExecutor.isEmpty
            ? null
            : taskExecutor;
    final executor = requestedExecutor != null &&
            candidateIds.contains(requestedExecutor) &&
            availableIds.contains(requestedExecutor)
        ? requestedExecutor
        : null;
    final coordinator = executor ??
        (state.coordinatorId != null &&
                availableIds.contains(state.coordinatorId)
            ? state.coordinatorId
            : allCharacters
                .firstWhere(
                  (character) => availableIds.contains(character.id),
                  orElse: () => allCharacters.first,
                )
                .id);
    final participants = _ensureParticipants(
      state,
      allCharacters.map((item) => item.id).toList(growable: false),
    );
    final contract = _mergeContract(
      state.deliverableContract,
      <String, dynamic>{
        if (state.deliverableContract?['contentScope'] is! String ||
            (state.deliverableContract?['contentScope'] as String)
                .trim()
                .isEmpty)
          'contentScope': task.userRequest,
        'requestRevision': state.requestRevision,
      },
    );
    final preservedBlockers = state.blockers
        .where(
          (blocker) =>
              blocker != 'discussionRequired' &&
              blocker != 'executorSelectionRequired',
        )
        .toList(growable: false);
    return state.copyWith(
      phase: executor == null
          ? WorkDiscussionPhase.awaitingExecutor
          : WorkDiscussionPhase.awaitingDiscussion,
      coordinatorId: coordinator,
      executorId: executor,
      candidateCharacterIds: candidateIds,
      participants: participants,
      blockers: _discussionBlockers(
        preservedBlockers,
        hasExecutor: executor != null,
      ),
      deliverableContract: contract,
    );
  }

  Future<WorkDiscussionState?> _routeFreshDiscussion({
    required AgentTask task,
    required WorkDiscussionState initial,
    required ChatGroup group,
    required List<AICharacter> characters,
    required List<CharacterSkill> skills,
    required WorkTaskCancellation cancellation,
    required WorkTaskDiscussionStateSink updateState,
  }) async {
    if (initial.executorId != null ||
        initial.candidateCharacterIds.isNotEmpty) {
      return initial;
    }
    final route = await const WorkRoleRouter().route(
      request: task.userRequest,
      characters: characters,
      conversationId: group.id,
      requestRevision: initial.requestRevision,
      skills: skills,
    );
    if (cancellation.isCancelled) return null;
    final routeContract = route.deliverableContract?.toJson();
    final mergedContract = routeContract == null
        ? initial.deliverableContract
        : _mergeContract(initial.deliverableContract, routeContract);
    // `routePending` is a durable reminder for the earlier failed route, not
    // a conclusion about the renewed request. Once the same route call has
    // either produced qualified candidates or selected an executor, remove
    // that transient marker so a repaired group can actually converge. A
    // genuine route failure below keeps it and remains user-actionable.
    final reroutedBlockers = initial.blockers
        .where((blocker) => blocker != 'routePending')
        .toList(growable: false);
    if (!route.isSuccess) {
      if (route.needsExecutorSelection) {
        return initial.copyWith(
          candidateCharacterIds: route.candidateCharacterIds,
          blockers: reroutedBlockers,
          deliverableContract: mergedContract,
        );
      }
      final explicitExecutor = routeContract?['explicitExecutorId'];
      await _finishBlocked(
        task,
        initial.copyWith(deliverableContract: mergedContract),
        updateState,
        blocker: route.needsMentionClarification
            ? 'mentionClarification'
            : explicitExecutor is String && explicitExecutor.trim().isNotEmpty
                ? 'executorUnavailable'
                : 'routingUnavailable',
        question: route.reason,
        mentionOwner: true,
        cancellation: cancellation,
      );
      return null;
    }
    final executor = route.characterId;
    if (executor == null || executor.trim().isEmpty) return initial;
    return initial.copyWith(
      coordinatorId: route.discussionCharacterIds.isEmpty
          ? initial.coordinatorId
          : route.discussionCharacterIds.first,
      executorId: executor,
      candidateCharacterIds: <String>[executor],
      blockers: reroutedBlockers,
      deliverableContract: mergedContract,
    );
  }
}
