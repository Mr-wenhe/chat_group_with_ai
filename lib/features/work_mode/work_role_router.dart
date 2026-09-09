import 'dart:async';

import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/character_skill.dart';
import 'package:chat_group/features/chat_group/chat_room_utils.dart';

import 'work_handoff_state.dart';
import 'work_mode_policy.dart';
import 'work_task_error_sanitizer.dart';

part 'work_role_router_models.dart';
part 'work_role_router_planner.dart';

/// Routes one conversation turn without creating a second conversation runner.
class WorkRoleRouter {
  final WorkRoleModelSelector? modelSelector;

  const WorkRoleRouter({this.modelSelector});

  Future<WorkRoleRouteResult> route({
    required String request,
    bool hasAttachments = false,
    required List<AICharacter> characters,
    String? conversationId,
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
    final privateConversation = isDirectChat || directId != null;
    if (!privateConversation) {
      if (mentions.mentionsAll) {
        return _failure(
          WorkRoleRouteSource.explicitMention,
          '工作模式一次只能由一个角色执行，@all 不能作为唯一执行者。',
        );
      }
      if (mentions.ambiguousNames.isNotEmpty) {
        return _failure(
          WorkRoleRouteSource.explicitMention,
          '角色重名，无法确定 @${mentions.ambiguousNames.join('、@')} 对应的执行者；请使用唯一名称。',
        );
      }
      if (mentions.unknownNames.isNotEmpty) {
        return _failure(
          WorkRoleRouteSource.explicitMention,
          '未找到角色 @${mentions.unknownNames.join('、@')}，没有静默替换其他角色。',
        );
      }
      if (mentions.characterIds.isNotEmpty) {
        return _routeExplicit(
          normalizedRequest,
          conversation,
          mentions.characterIds,
          members,
          availableSkills,
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
      );
    }

    if (handoff != null && !handoff.isComplete) {
      if (handoff.conversationId != conversation) {
        return _failure(
          WorkRoleRouteSource.handoff,
          '当前接力状态属于另一个 conversationId，已拒绝跨对话改派角色。',
        );
      }
      return _routeHandoff(
        handoff,
        members,
        availableSkills,
      );
    }

    final inferredStages = _inferStages(normalizedRequest);
    final candidates = _eligible(members);
    if (candidates.isEmpty) {
      return _failure(
        WorkRoleRouteSource.unavailable,
        '没有同时满足“活跃、已启用 Agentic 且已配置模型”的角色。',
      );
    }

    final selector = modelSelector;
    if (selector != null) {
      final context = WorkRoleRoutingContext(
        request: normalizedRequest,
        conversationId: conversation,
        characters: candidates,
        skills: availableSkills,
        candidateCharacterIds: candidates.map((item) => item.id),
        inferredStages: inferredStages,
      );
      Object? rawDecision;
      try {
        rawDecision = await selector(context);
      } on Object catch (error) {
        // A short routing request is an optimization, not the execution
        // authority.  When the configured router model is temporarily
        // unavailable, keep the conversation usable by applying the same
        // local role/skill heuristic used when no selector is configured.
        // The public reason names the degraded path so the user can decide
        // whether to fix the model configuration before the next task.
        final fallback = _routeDeterministically(
          normalizedRequest,
          conversation,
          inferredStages,
          candidates,
          availableSkills,
          fallbackDetail:
              '模型角色路由暂时不可用（${_safeError(error)}），已改用本地角色职业与 Skill 判断。',
        );
        return fallback.isSuccess
            ? fallback
            : _failure(
                WorkRoleRouteSource.model,
                '模型角色路由失败：${_safeError(error)}；本地角色判断也无法完成：${fallback.reason}',
              );
      }
      if (rawDecision != null) {
        final decision = _coerceDecision(rawDecision);
        if (decision == null) {
          // A malformed router response is equivalent to a temporary router
          // outage.  It must not make an otherwise routable conversation
          // unusable, and it must not silently choose a different API/model.
          // Reuse the local role/skill heuristic and tell the user why the
          // degraded path was selected.
          return _routeDeterministically(
            normalizedRequest,
            conversation,
            inferredStages,
            candidates,
            availableSkills,
            fallbackDetail: '模型角色路由结果格式无效，已改用本地角色职业与 Skill 判断。',
          );
        }
        return _routeModel(
          normalizedRequest,
          conversation,
          decision,
          inferredStages,
          candidates,
          availableSkills,
        );
      }
    }

    return _routeDeterministically(
      normalizedRequest,
      conversation,
      inferredStages,
      candidates,
      availableSkills,
    );
  }

  Future<WorkRoleRouteResult> _routePrivate(
    String request,
    String conversationId,
    String? directId,
    List<AICharacter> members,
    List<CharacterSkill> skills,
  ) async {
    if (directId == null || directId.isEmpty) {
      return _failure(
        WorkRoleRouteSource.privateChat,
        '私聊缺少固定角色 ID，无法把任务交给其他角色。',
      );
    }
    final role = _findUnique(members, directId);
    if (role == null) {
      return _failure(
        WorkRoleRouteSource.privateChat,
        '私聊固定角色“$directId”不存在，没有静默替换其他角色。',
      );
    }
    final availability = _availabilityFailure(role);
    if (availability != null) {
      return _failure(
          WorkRoleRouteSource.privateChat, '私聊固定角色${role.name}$availability');
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
    );
  }

  WorkRoleRouteResult _routeExplicit(
    String request,
    String conversationId,
    List<String> ids,
    List<AICharacter> members,
    List<CharacterSkill> skills,
  ) {
    final first = _findUnique(members, ids.first);
    if (first == null) {
      return _failure(
        WorkRoleRouteSource.explicitMention,
        '被 @ 的角色不存在，没有静默替换其他角色。',
      );
    }
    final availability = _availabilityFailure(first);
    if (availability != null) {
      return _failure(
        WorkRoleRouteSource.explicitMention,
        '被 @ 的角色「${first.name}」$availability',
      );
    }
    final kinds = _inferStages(request);
    if (ids.length > kinds.length) {
      return _failure(
        WorkRoleRouteSource.explicitMention,
        '当前任务只有 ${kinds.length} 个可识别阶段，却指定了 ${ids.length} 个角色；请减少 @ 角色或明确产品、开发、测试阶段。',
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
      return _failure(WorkRoleRouteSource.explicitMention, plan.failure!);
    }
    return _success(
      first.id,
      WorkRoleRouteSource.explicitMention,
      '已按 @${first.name} 指定初始执行角色；后续阶段仍按同一 conversationId 串行接力。',
      1,
      plan.stages,
      conversationId,
      needsHandoff: plan.stages.length > 1,
    );
  }

  WorkRoleRouteResult _routeHandoff(
    WorkHandoffState state,
    List<AICharacter> members,
    List<CharacterSkill> skills,
  ) {
    final receiverId = state.currentRoleId;
    if (receiverId.isEmpty) {
      return _failure(
        WorkRoleRouteSource.handoff,
        '当前接力没有下一位接收角色，不能静默改派。',
      );
    }
    final receiver = _findUnique(members, receiverId);
    if (receiver == null) {
      return _failure(
        WorkRoleRouteSource.handoff,
        '当前接力指定的角色「$receiverId」不存在，没有静默替换其他角色。',
      );
    }
    final availability = _availabilityFailure(receiver);
    if (availability != null) {
      return _failure(
        WorkRoleRouteSource.handoff,
        '当前接力指定的角色「${receiver.name}」$availability',
      );
    }
    final stageKind = _stageKind(state.currentStage.id);
    if (!_isSuitable(receiver, stageKind, skills)) {
      return _failure(
        WorkRoleRouteSource.handoff,
        '当前接力指定的角色「${receiver.name}」不具备${_stageLabel(stageKind)}所需的职业或 Skill 能力。',
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
    );
  }

  WorkRoleRouteResult _routeModel(
    String request,
    String conversationId,
    WorkRoleModelDecision decision,
    List<WorkRoleStageKind> kinds,
    List<AICharacter> candidates,
    List<CharacterSkill> skills,
  ) {
    if (!decision.confidence.isFinite ||
        decision.confidence < 0 ||
        decision.confidence > 1) {
      return _failure(
        WorkRoleRouteSource.model,
        '模型返回的置信度无效（必须是 0 到 1 之间的有限数值），未自动切换模型或角色。',
      );
    }
    final role = _findUnique(candidates, decision.characterId);
    if (role == null) {
      return _failure(
        WorkRoleRouteSource.model,
        '模型选择的角色「${decision.characterId}」不存在或不可用，没有静默替换其他角色。',
      );
    }
    final availability = _availabilityFailure(role);
    if (availability != null) {
      return _failure(
        WorkRoleRouteSource.model,
        '模型选择的角色「${role.name}」$availability',
      );
    }
    final plan = _stagePlan(
      request,
      kinds,
      candidates,
      skills,
      forcedFirstRoleId: role.id,
    );
    if (!plan.isSuccess) {
      return _failure(WorkRoleRouteSource.model, plan.failure!);
    }
    final reason = decision.publicReason.trim();
    if (reason.isEmpty) {
      return _failure(WorkRoleRouteSource.model, '模型没有返回可展示的角色选择理由。');
    }
    return _success(
      role.id,
      WorkRoleRouteSource.model,
      reason,
      decision.confidence,
      plan.stages,
      conversationId,
      needsHandoff: decision.needsHandoff || plan.stages.length > 1,
    );
  }

  WorkRoleRouteResult _routeDeterministically(
    String request,
    String conversationId,
    List<WorkRoleStageKind> kinds,
    List<AICharacter> candidates,
    List<CharacterSkill> skills, {
    String? fallbackDetail,
  }) {
    final plan = _stagePlan(request, kinds, candidates, skills);
    if (!plan.isSuccess) {
      return _failure(WorkRoleRouteSource.deterministicFallback, plan.failure!);
    }
    final first = _findUnique(candidates, plan.stages.first.roleId);
    if (first == null) {
      return _failure(
        WorkRoleRouteSource.deterministicFallback,
        '确定性路由没有找到可用执行角色。',
      );
    }
    final stageName = plan.stages.first.label;
    final specialized = kinds.first != WorkRoleStageKind.general;
    final heuristicReason = specialized
        ? '未使用 @；根据角色职业、persona 和 Skill 判断，这是「$stageName」任务，因此选择「${first.name}」。'
        : '未使用 @ 且任务未指明专业阶段，按活跃角色列表顺序选择「${first.name}」作为通用执行者。';
    final reason = fallbackDetail == null
        ? heuristicReason
        : '$fallbackDetail $heuristicReason';
    return _success(
      first.id,
      WorkRoleRouteSource.deterministicFallback,
      reason,
      specialized ? 0.78 : 0.35,
      plan.stages,
      conversationId,
      needsHandoff: plan.stages.length > 1,
    );
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

  static String? _directCharacterId(String conversationId) {
    if (!conversationId.startsWith('dm:') || conversationId.length <= 3) {
      return null;
    }
    return conversationId.substring(3);
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

  static WorkRoleRouteResult _success(
    String roleId,
    WorkRoleRouteSource source,
    String reason,
    double confidence,
    List<WorkHandoffStage> stages,
    String conversationId, {
    required bool needsHandoff,
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
    );
  }

  static WorkRoleRouteResult _failure(
    WorkRoleRouteSource source,
    String reason,
  ) =>
      WorkRoleRouteResult(
        characterId: null,
        source: source,
        publicReason: reason,
        confidence: 0,
        needsHandoff: false,
      );

  static String _safeError(Object error) {
    return sanitizeWorkTaskError(error);
  }
}

String _modelText(Object? value) => value is String ? value.trim() : '';

AICharacter _publicCharacter(AICharacter character) => AICharacter(
      id: character.id,
      name: character.name,
      avatar: character.avatar,
      age: character.age,
      role: character.role,
      personalityTags: List<String>.from(character.personalityTags),
      systemPrompt: character.systemPrompt,
      apiKey: '',
      apiProvider: character.apiProvider,
      modelName: character.modelName,
      customBaseUrl: '',
      apiConfigId: '',
      agenticEnabled: character.agenticEnabled,
      skillIds: List<String>.from(character.skillIds),
      toolPermissions: List.from(character.toolPermissions),
      gender: character.gender,
      hasKnownGender: character.hasKnownGender,
    );
