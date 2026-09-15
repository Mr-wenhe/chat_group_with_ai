import 'dart:async';

import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/character_skill.dart';
import 'package:chat_group/features/chat_group/chat_room_utils.dart';

import 'work_handoff_state.dart';
import 'work_mode_policy.dart';

part 'work_role_router_models.dart';
part 'work_role_router_planner.dart';

/// Routes one conversation turn without creating a second conversation runner.
class WorkRoleRouter {
  final WorkRoleModelSelector? modelSelector;

  const WorkRoleRouter({this.modelSelector});

  /// Returns the roles that pass the same local stage/occupation checks used
  /// by S1 routing. Discussion may ask every available group member for an
  /// opinion, but it must use this result when it elects the final executor;
  /// a model recommendation or a display name can never create a new
  /// qualification.
  static List<AICharacter> qualifiedCandidatesForRequest({
    required String request,
    required Iterable<AICharacter> characters,
    Iterable<CharacterSkill> skills = const [],
  }) {
    final kinds = _inferStages(request.trim());
    final members = _eligible(List<AICharacter>.from(characters));
    return List<AICharacter>.unmodifiable(
      _qualifiedCandidates(kinds, members, List<CharacterSkill>.from(skills)),
    );
  }

  /// S3 uses this predicate before accepting a group recommendation.  Keep
  /// it next to the router's private scoring implementation so a discussion
  /// cannot drift from the S1 role contract.
  static bool isQualifiedForRequest({
    required String request,
    required AICharacter character,
    Iterable<CharacterSkill> skills = const [],
  }) {
    return qualifiedCandidatesForRequest(
      request: request,
      characters: [character],
      skills: skills,
    ).any((candidate) => candidate.id == character.id);
  }

  /// Reuses the router's deterministic deliverable parsing when a durable
  /// follow-up creates a fresh discussion task.  The coordinator must be able
  /// to rebuild the current request contract without selecting an executor;
  /// role qualification and election remain discussion responsibilities.
  static WorkDeliverableContract deliverableContractForRequest(
    String request, {
    int requestRevision = 1,
    String? explicitExecutorId,
  }) {
    final normalizedRevision = requestRevision < 1 ? 1 : requestRevision;
    return _deliverableContract(
      request.trim(),
      explicitExecutorId: explicitExecutorId,
      requestRevision: normalizedRevision,
    );
  }

  Future<WorkRoleRouteResult> route({
    required String request,
    bool hasAttachments = false,
    required List<AICharacter> characters,
    String? conversationId,
    int requestRevision = 1,
    bool isDirectChat = false,
    String? directCharacterId,
    WorkHandoffState? handoff,
    Iterable<CharacterSkill> skills = const [],
  }) async {
    final rawRequest = request.trim();
    // ponytail: attachments are a complete work input even when the composer
    // has no text; keep a small internal routing label instead of rejecting it.
    final normalizedRequest = rawRequest.isEmpty && hasAttachments
        ? WorkModePolicy.attachmentOnlyRequest
        : rawRequest;
    final conversation = conversationId?.trim() ?? '';
    if (normalizedRequest.isEmpty) {
      return _failure(
        WorkRoleRouteSource.unavailable,
        '当前工作指令为空，无法选择执行角色。',
      );
    }
    if (conversation.isEmpty) {
      return _failure(
        WorkRoleRouteSource.unavailable,
        '缺少 conversationId，无法安全隔离角色执行上下文。',
      );
    }

    final members = List<AICharacter>.from(characters);
    final availableSkills = List<CharacterSkill>.from(skills);
    final effectiveRequestRevision = requestRevision < 1 ? 1 : requestRevision;
    final conversationDirectId = _directCharacterId(conversation);
    final suppliedDirectId = directCharacterId?.trim().isNotEmpty == true
        ? directCharacterId!.trim()
        : null;
    if (conversationDirectId != null &&
        suppliedDirectId != null &&
        conversationDirectId != suppliedDirectId) {
      return _failure(
        WorkRoleRouteSource.privateChat,
        '私聊固定角色 ID 与 conversationId 不一致，已拒绝跨角色改派。',
      );
    }
    final directId = conversationDirectId ?? suppliedDirectId;
    final mentions = analyzeMentionedCharacterIds(normalizedRequest, members);
    final mentionIntent = _workRoleMentionIntent(normalizedRequest, members);
    final contract = _deliverableContract(
      normalizedRequest,
      explicitExecutorId: mentionIntent.explicitExecutorId,
      requestRevision: effectiveRequestRevision,
    );
    final privateConversation = isDirectChat || directId != null;
    if (!privateConversation) {
      if (mentionIntent.ambiguousExecutorIds.isNotEmpty) {
        final ambiguousNames = mentionIntent.ambiguousExecutorIds.map(
          (id) => _findUnique(members, id)?.name ?? id,
        );
        return _failure(
          WorkRoleRouteSource.explicitMention,
          '检测到多个最终执行人（${ambiguousNames.map((name) => '@$name').join('、')}），请明确只由一位角色最终输出。',
          deliverableContract: contract,
          discussionCharacterIds: mentionIntent.discussionCharacterIds,
          consultedCharacterIds: mentionIntent.consultedCharacterIds,
          ambiguousExecutorIds: mentionIntent.ambiguousExecutorIds,
        );
      }
      if (mentions.ambiguousNames.isNotEmpty) {
        return _failure(
          WorkRoleRouteSource.explicitMention,
          '角色重名，无法确定 @${mentions.ambiguousNames.join('、@')} 对应的执行者；请使用唯一名称。',
          deliverableContract: contract,
          discussionCharacterIds: mentionIntent.discussionCharacterIds,
          consultedCharacterIds: mentionIntent.consultedCharacterIds,
          ambiguousMentionNames: mentions.ambiguousNames,
        );
      }
      if (mentions.unknownNames.isNotEmpty) {
        return _failure(
          WorkRoleRouteSource.explicitMention,
          '未找到角色 @${mentions.unknownNames.join('、@')}，没有静默替换其他角色。',
          deliverableContract: contract,
          discussionCharacterIds: mentionIntent.discussionCharacterIds,
          consultedCharacterIds: mentionIntent.consultedCharacterIds,
          unknownMentionNames: mentions.unknownNames,
        );
      }
      final explicitlyAssignedIds = mentionIntent.explicitExecutorId == null
          ? mentionIntent.explicitMentionedIds
          : <String>[mentionIntent.explicitExecutorId!];
      if (explicitlyAssignedIds.isNotEmpty &&
          (!mentions.mentionsAll || mentionIntent.explicitExecutorId != null)) {
        return _routeExplicit(
          normalizedRequest,
          conversation,
          explicitlyAssignedIds,
          members,
          availableSkills,
          contract,
          discussionCharacterIds: mentionIntent.discussionCharacterIds,
          consultedCharacterIds: mentionIntent.consultedCharacterIds,
        );
      }
    } else {
      // A DM is a hard conversation boundary: @ text cannot switch its fixed
      // character to another participant.
      return _routePrivate(
        normalizedRequest,
        conversation,
        directId,
        members,
        availableSkills,
        contract,
      );
    }

    if (handoff != null && !handoff.isComplete) {
      if (handoff.conversationId != conversation) {
        return _failure(
          WorkRoleRouteSource.handoff,
          '当前接力状态属于另一个 conversationId，已拒绝跨对话改派角色。',
          deliverableContract: contract,
        );
      }
      return _routeHandoff(
        handoff,
        members,
        availableSkills,
        contract,
      );
    }

    final inferredStages = _inferStages(normalizedRequest);
    final candidates = _eligible(members);
    if (candidates.isEmpty) {
      return _failure(
        WorkRoleRouteSource.unavailable,
        '没有同时满足“活跃、已启用 Agentic 且已配置模型”的角色。',
        deliverableContract: contract,
        discussionCharacterIds: mentionIntent.discussionCharacterIds,
        consultedCharacterIds: mentionIntent.consultedCharacterIds,
      );
    }

    // No explicit executor means this is a candidate recommendation only.
    // S3 will let the group discuss and elect the final owner; selecting the
    // first capable member here would silently bypass that decision.
    return _pendingExecutorSelection(
      normalizedRequest,
      conversation,
      inferredStages,
      candidates,
      availableSkills,
      contract: contract,
      discussionCharacterIds: mentionIntent.discussionCharacterIds,
      consultedCharacterIds: mentionIntent.consultedCharacterIds,
    );
  }

  Future<WorkRoleRouteResult> _routePrivate(
    String request,
    String conversationId,
    String? directId,
    List<AICharacter> members,
    List<CharacterSkill> skills,
    WorkDeliverableContract contract,
  ) async {
    if (directId == null || directId.isEmpty) {
      return _failure(
        WorkRoleRouteSource.privateChat,
        '私聊缺少固定角色 ID，无法把任务交给其他角色。',
        deliverableContract: contract,
      );
    }
    final role = _findUnique(members, directId);
    if (role == null) {
      return _failure(
        WorkRoleRouteSource.privateChat,
        '私聊固定角色“$directId”不存在，没有静默替换其他角色。',
        deliverableContract: contract,
      );
    }
    final availability = _availabilityFailure(role);
    if (availability != null) {
      return _failure(
        WorkRoleRouteSource.privateChat,
        '私聊固定角色${role.name}$availability',
        deliverableContract: contract,
      );
    }
    final stages = _stagePlan(
      request,
      [WorkRoleStageKind.general],
      [role],
      skills,
      forcedFirstRoleId: role.id,
    );
    return _success(
      role.id,
      WorkRoleRouteSource.privateChat,
      '这是私聊，会话固定由角色「${role.name}」执行。',
      1,
      stages.stages,
      conversationId,
      needsHandoff: false,
      deliverableContract: contract.copyWith(explicitExecutorId: role.id),
    );
  }

  WorkRoleRouteResult _routeExplicit(
    String request,
    String conversationId,
    List<String> ids,
    List<AICharacter> members,
    List<CharacterSkill> skills,
    WorkDeliverableContract contract, {
    List<String> discussionCharacterIds = const [],
    List<String> consultedCharacterIds = const [],
  }) {
    final first = _findUnique(members, ids.first);
    if (first == null) {
      return _failure(
        WorkRoleRouteSource.explicitMention,
        '被 @ 的角色不存在，没有静默替换其他角色。',
        deliverableContract: contract,
        discussionCharacterIds: discussionCharacterIds,
        consultedCharacterIds: consultedCharacterIds,
      );
    }
    final availability = _availabilityFailure(first);
    if (availability != null) {
      return _failure(
        WorkRoleRouteSource.explicitMention,
        '被 @ 的角色「${first.name}」$availability',
        deliverableContract: contract,
        discussionCharacterIds: discussionCharacterIds,
        consultedCharacterIds: consultedCharacterIds,
      );
    }
    final kinds = _inferStages(request);
    if (ids.length > kinds.length) {
      return _failure(
        WorkRoleRouteSource.explicitMention,
        '当前任务只有 ${kinds.length} 个可识别阶段，却指定了 ${ids.length} 个角色；请减少 @ 角色或明确产品、开发、测试阶段。',
        deliverableContract: contract,
        discussionCharacterIds: discussionCharacterIds,
        consultedCharacterIds: consultedCharacterIds,
      );
    }
    final eligible = _eligible(members);
    // With two or more explicit mentions every stage must stay within the
    // mentioned set.  A single @ still pins only the first stage and may
    // intentionally auto-fill later handoff stages.
    final candidates = ids.length > 1
        ? eligible.where((member) => ids.contains(member.id)).toList()
        : eligible;
    final plan = _stagePlan(
      request,
      kinds,
      candidates,
      skills,
      forcedFirstRoleId: first.id,
      explicitRoleIds: ids,
    );
    if (!plan.isSuccess) {
      return _failure(
        WorkRoleRouteSource.explicitMention,
        plan.failure!,
        deliverableContract: contract,
        discussionCharacterIds: discussionCharacterIds,
        consultedCharacterIds: consultedCharacterIds,
      );
    }
    return _success(
      first.id,
      WorkRoleRouteSource.explicitMention,
      '已按 @${first.name} 指定初始执行角色；后续阶段仍按同一 conversationId 串行接力。',
      1,
      plan.stages,
      conversationId,
      needsHandoff: plan.stages.length > 1,
      deliverableContract: contract.copyWith(explicitExecutorId: first.id),
      discussionCharacterIds: discussionCharacterIds,
      consultedCharacterIds: consultedCharacterIds,
    );
  }

  WorkRoleRouteResult _routeHandoff(
    WorkHandoffState state,
    List<AICharacter> members,
    List<CharacterSkill> skills,
    WorkDeliverableContract contract,
  ) {
    final receiverId = state.currentRoleId;
    if (receiverId.isEmpty) {
      return _failure(
        WorkRoleRouteSource.handoff,
        '当前接力没有下一位接收角色，不能静默改派。',
        deliverableContract: contract,
      );
    }
    final receiver = _findUnique(members, receiverId);
    if (receiver == null) {
      return _failure(
        WorkRoleRouteSource.handoff,
        '当前接力指定的角色「$receiverId」不存在，没有静默替换其他角色。',
        deliverableContract: contract,
      );
    }
    final availability = _availabilityFailure(receiver);
    if (availability != null) {
      return _failure(
        WorkRoleRouteSource.handoff,
        '当前接力指定的角色「${receiver.name}」$availability',
        deliverableContract: contract,
      );
    }
    final stageKind = _stageKind(state.currentStage.id);
    if (!_isSuitable(receiver, stageKind, skills)) {
      return _failure(
        WorkRoleRouteSource.handoff,
        '当前接力指定的角色「${receiver.name}」不具备${_stageLabel(stageKind)}所需的职业或 Skill 能力。',
        deliverableContract: contract,
      );
    }
    final activatedState =
        state.isAwaitingReceiver ? state.activateReceiver() : state;
    return WorkRoleRouteResult(
      characterId: receiver.id,
      source: WorkRoleRouteSource.handoff,
      publicReason: state.isAwaitingReceiver
          ? '当前阶段已完成，前一角色释放执行锁后由「${receiver.name}」接手。'
          : '当前接力阶段继续由「${receiver.name}」执行。',
      confidence: 1,
      needsHandoff: activatedState.needsHandoff,
      stages: state.stages,
      handoffState: activatedState,
      deliverableContract: contract.copyWith(explicitExecutorId: receiver.id),
    );
  }

  Future<WorkRoleRouteResult> _pendingExecutorSelection(
    String request,
    String conversationId,
    List<WorkRoleStageKind> kinds,
    List<AICharacter> candidates,
    List<CharacterSkill> skills, {
    required WorkDeliverableContract contract,
    List<String> discussionCharacterIds = const [],
    List<String> consultedCharacterIds = const [],
  }) async {
    final qualified = _qualifiedCandidates(kinds, candidates, skills);
    if (qualified.isEmpty) {
      final label = _stageLabel(kinds.first);
      return _failure(
        WorkRoleRouteSource.unavailable,
        '没有活跃角色具备$label所需的职业或 Skill 能力；请 @用户加入匹配角色。',
        deliverableContract: contract,
        discussionCharacterIds: discussionCharacterIds,
        consultedCharacterIds: consultedCharacterIds,
      );
    }
    var ordered = qualified;
    String? modelNote;
    final selector = modelSelector;
    if (selector != null) {
      try {
        final rawDecision = await selector(
          WorkRoleRoutingContext(
            request: request,
            conversationId: conversationId,
            characters: candidates,
            skills: skills,
            candidateCharacterIds: qualified.map((character) => character.id),
            inferredStages: kinds,
            deliverableContract: contract,
          ),
        );
        if (rawDecision != null) {
          final decision = _coerceDecision(rawDecision);
          final selected = decision == null
              ? null
              : _findUnique(candidates, decision.characterId);
          if (decision == null) {
            modelNote = '模型候选推荐格式无效，未采纳模型选择。';
          } else if (!decision.confidence.isFinite ||
              decision.confidence < 0 ||
              decision.confidence > 1) {
            modelNote = '模型候选推荐置信度无效，未采纳模型选择。';
          } else if (decision.publicReason.trim().isEmpty) {
            modelNote = '模型候选推荐缺少可展示依据，未采纳模型选择。';
          } else if (selected == null ||
              !_isSuitable(selected, kinds.first, skills)) {
            modelNote = '模型推荐角色不满足本任务的${_stageLabel(kinds.first)}资格，未采纳模型选择。';
          } else {
            ordered = [
              selected,
              ...qualified.where((character) => character.id != selected.id),
            ];
            modelNote =
                '模型建议「${selected.name}」作为首位候选（${decision.publicReason.trim()}），仍需群内推举。';
          }
        }
      } on Object {
        modelNote = '模型候选推荐暂不可用，保留本地资格候选并等待群内推举。';
      }
    }
    final names = ordered.map(_candidateDisplayName).join('、');
    final stageName = _stageLabel(kinds.first);
    return WorkRoleRouteResult(
      characterId: null,
      source: WorkRoleRouteSource.candidateSelection,
      publicReason:
          '${modelNote == null ? '' : '$modelNote '}尚未指定最终执行人。候选角色：$names；任务需要$stageName能力，请由群内讨论后推举一位。',
      confidence: 0,
      needsHandoff: false,
      deliverableContract: contract,
      discussionCharacterIds: discussionCharacterIds,
      consultedCharacterIds: consultedCharacterIds,
      candidateCharacterIds:
          List<String>.unmodifiable(ordered.map((character) => character.id)),
      needsExecutorSelection: true,
    );
  }

  static List<AICharacter> _qualifiedCandidates(
    List<WorkRoleStageKind> kinds,
    List<AICharacter> candidates,
    List<CharacterSkill> skills,
  ) {
    if (kinds.isEmpty) return const [];
    // Candidate selection names the role that can own the first required
    // deliverable. Other stages may contribute to discussion or an explicit
    // later handoff, but a test-only role must not be advertised as an HTML
    // executor merely because testing is another stage in the same request.
    final requiredKind = kinds.first;
    final result = <AICharacter>[];
    for (final candidate in candidates) {
      if (_isSuitable(candidate, requiredKind, skills)) {
        result.add(candidate);
      }
    }
    return result;
  }

  static List<AICharacter> _eligible(List<AICharacter> members) => members
      .where((character) => _availabilityFailure(character) == null)
      .toList(growable: false);

  static String? _availabilityFailure(AICharacter character) {
    if (!character.isActive) return '当前未启用';
    if (!character.agenticEnabled) return '未启用 Agentic 能力';
    if (character.apiConfigId.trim().isEmpty &&
        character.apiKey.trim().isEmpty) {
      return '尚未配置可用模型';
    }
    return null;
  }

  static AICharacter? _findUnique(List<AICharacter> members, String id) {
    final matches = members.where((character) => character.id == id).toList();
    return matches.length == 1 ? matches.single : null;
  }

  static WorkRoleModelDecision? _coerceDecision(Object raw) {
    if (raw is WorkRoleModelDecision) return raw;
    if (raw is Map) {
      try {
        return WorkRoleModelDecision.fromJson(Map<String, dynamic>.from(raw));
      } on Object {
        return null;
      }
    }
    return null;
  }

  static String? _directCharacterId(String conversationId) {
    if (!conversationId.startsWith('dm:') || conversationId.length <= 3) {
      return null;
    }
    return conversationId.substring(3);
  }

  static WorkRoleRouteResult _success(
    String roleId,
    WorkRoleRouteSource source,
    String reason,
    double confidence,
    List<WorkHandoffStage> stages,
    String conversationId, {
    required bool needsHandoff,
    WorkDeliverableContract? deliverableContract,
    List<String> discussionCharacterIds = const [],
    List<String> consultedCharacterIds = const [],
  }) {
    final safeStages = List<WorkHandoffStage>.unmodifiable(stages);
    final state = WorkHandoffState(
      conversationId: conversationId,
      stages: safeStages,
    );
    return WorkRoleRouteResult(
      characterId: roleId,
      source: source,
      publicReason: reason,
      confidence: confidence.isFinite ? confidence.clamp(0, 1).toDouble() : 0,
      needsHandoff: needsHandoff,
      stages: safeStages,
      handoffState: state,
      deliverableContract: deliverableContract,
      discussionCharacterIds: discussionCharacterIds,
      consultedCharacterIds: consultedCharacterIds,
    );
  }

  static WorkRoleRouteResult _failure(
    WorkRoleRouteSource source,
    String reason, {
    WorkDeliverableContract? deliverableContract,
    List<String> discussionCharacterIds = const [],
    List<String> consultedCharacterIds = const [],
    List<String> unknownMentionNames = const [],
    List<String> ambiguousMentionNames = const [],
    List<String> ambiguousExecutorIds = const [],
  }) =>
      WorkRoleRouteResult(
        characterId: null,
        source: source,
        publicReason: reason,
        confidence: 0,
        needsHandoff: false,
        deliverableContract: deliverableContract,
        discussionCharacterIds: discussionCharacterIds,
        consultedCharacterIds: consultedCharacterIds,
        unknownMentionNames: unknownMentionNames,
        ambiguousMentionNames: ambiguousMentionNames,
        ambiguousExecutorIds: ambiguousExecutorIds,
      );
}

String _candidateDisplayName(AICharacter character) {
  final role = character.role.trim();
  return role.isEmpty ? character.name : '${character.name}（$role）';
}

String _modelText(Object? value) => value is String ? value.trim() : '';
