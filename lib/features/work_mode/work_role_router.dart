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

  /// Returns the roles that pass the same local stage/occupation checks used
  /// by S1 routing. Discussion may ask every available group member for an
  /// opinion, but it must use this result when it elects the final executor;
  /// a model recommendation or a display name can never create a new
  /// qualification.
  static List<AICharacter> qualifiedCandidatesForRequest({
    required String request,
    required Iterable<AICharacter> characters,
    Iterable<CharacterSkill> skills = const [],
    String? deliverableFormatOverride,
  }) {
    final normalizedRequest = request.trim();
    final contract = _deliverableContract(
      normalizedRequest,
      requestRevision: 1,
    );
    final kinds = _inferStages(
      normalizedRequest,
      deliverableFormat: _effectiveDeliverableFormat(
        deliverableFormatOverride,
        contract.format,
      ),
    );
    final members = _eligible(List<AICharacter>.from(characters));
    return List<AICharacter>.unmodifiable(
      _qualifiedCandidates(kinds, members, List<CharacterSkill>.from(skills)),
    );
  }

  /// Whether the active request starts with QA rather than implementation.
  /// Shared by routing and work-mode preflight so an HTML input reference does
  /// not trigger frontend-only setup in a Markdown testing stage.
  static bool startsWithTestingStage(String request) {
    final contract = _deliverableContract(request, requestRevision: 1);
    return _inferStages(
          request,
          deliverableFormat: contract.format,
        ).first ==
        WorkRoleStageKind.testing;
  }

  /// S3 uses this predicate before accepting a group recommendation.  Keep
  /// it next to the router's private scoring implementation so a discussion
  /// cannot drift from the S1 role contract.
  static bool isQualifiedForRequest({
    required String request,
    required AICharacter character,
    Iterable<CharacterSkill> skills = const [],
    String? deliverableFormatOverride,
  }) {
    return qualifiedCandidatesForRequest(
      request: request,
      characters: [character],
      skills: skills,
      deliverableFormatOverride: deliverableFormatOverride,
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

  /// v2 `artifactContract.type` 的唯一词表：v1 写的 `source` 就是 v2 的
  /// `software`，运行期判据（软件闭环材料、测试覆盖、独立审查资格）只认后者。
  ///
  /// 两套词表并存过一次的后果是整段软件检查失效：真实入口把「制作 HTML 游戏」
  /// 判成 `source`，而闭环检查、测试覆盖与专业审查资格分支都在比 `software`，
  /// 于是读一遍正文就能宣称这个游戏通过审查。
  static String canonicalArtifactType(String? raw) {
    final value = raw ?? '';
    return value.trim().toLowerCase() == 'source' ? 'software' : value;
  }

  /// Delivery intent wins over topic words: a game's requirements document
  /// does not create implementation or execution-test responsibilities.
  static bool requestsSoftwareImplementation(String request) {
    final clauses = request.split(RegExp(r'[；;。\n]|并且|同时|然后|以及|并'));
    return clauses.any((clause) =>
        !RegExp(r'需求文档|需求说明|技术文档|调研报告|requirements document|specification',
                caseSensitive: false)
            .hasMatch(clause) &&
        // 动词表必须与 _hasFrontendImplementationBeforeTesting 保持一致。少
        // 「生成/创建」会让"生成一份飞行棋游戏的HTML"判成非软件实现，于是
        // selectTeam 不追加 testing 阶段、测试工程师整队不进人，讨论退化成
        // 一人自提案自签字（2026-10-10 现场）。
        RegExp(r'(?:(?:开发|实现|制作|构建|编写|创建|生成|修复|修改|做)|\b(?:build|create|develop|implement|make|generate|fix|repair)\b).{0,48}(?:软件|程序|应用|游戏|网页|网站|代码|html|flutter|python|app|game|website|code)',
                caseSensitive: false)
            .hasMatch(clause));
  }

  /// Minimal relevant team from current membership. Missing responsibilities
  /// remain gaps; library candidates require a persisted user decision.
  static WorkTeamSelection selectTeam(
      {required String request,
      required List<AICharacter> characters,
      Iterable<CharacterSkill> skills = const [],
      List<String> confirmedMemberIds = const []}) {
    final availableSkills = skills.toList();
    final contract = _deliverableContract(request, requestRevision: 1);
    final software = requestsSoftwareImplementation(request);
    final documentOnly = !software &&
        RegExp(r'需求文档|需求说明|技术文档|调研报告|requirements document|specification',
                caseSensitive: false)
            .hasMatch(request);
    final kinds = documentOnly
        ? <WorkRoleStageKind>[WorkRoleStageKind.product]
        : _inferStages(request,
            deliverableFormat: software ? 'unspecified' : contract.format);
    if (requestsSoftwareImplementation(request) &&
        !kinds.contains(WorkRoleStageKind.testing)) {
      kinds.add(WorkRoleStageKind.testing);
    }
    final mentions = analyzeMentionedCharacterIds(request, characters);
    final intent = _workRoleMentionIntent(request, characters);
    final errors = <String>[
      if (intent.ambiguousExecutorIds.isNotEmpty) '指定多个最终执行人，请明确责任，未自动选择。',
      if (mentions.ambiguousNames.isNotEmpty)
        '成员重名：${mentions.ambiguousNames.join('、')}，请使用唯一名称。',
      if (mentions.unknownNames.isNotEmpty)
        '指定成员不存在：${mentions.unknownNames.join('、')}，未自动替换。',
    ];
    final selected = <Map<String, dynamic>>[];
    final used = <String>{};
    final missing = <WorkRoleStageKind>[];
    final explicit = intent.explicitMentionedIds;
    for (var i = 0; i < kinds.length; i++) {
      final kind = kinds[i];
      final pinned =
          i < explicit.length ? _findUnique(characters, explicit[i]) : null;
      final member = pinned ??
          _bestCandidate(_eligible(characters), kind, availableSkills, used);
      if (member == null ||
          // 用户点名的人只按候选口径核（引擎/后端开发能担前端责任），自动选出来的
          // 人仍必须严格对口——`_bestCandidate` 本来就只返回严格合格的人。
          !_isSuitable(member, kind, availableSkills,
              allowImplementationBridge: pinned != null) ||
          _availabilityFailure(member) != null ||
          used.contains(member.id)) {
        missing.add(kind);
        if (pinned != null) {
          errors.add(
              '指定成员 ${pinned.name}：${_availabilityFailure(pinned) ?? '不具备${_stageLabel(kind)}资格'}，未自动替换。');
        }
        continue;
      }
      used.add(member.id);
      selected.add({
        'memberId': member.id,
        'role': kind.name,
        'qualificationRef': 'role:${member.id}:${kind.name}',
        'qualified': true,
        'available': true
      });
    }
    for (final id in {...intent.consultedCharacterIds, ...confirmedMemberIds}) {
      final member = _findUnique(characters, id);
      if (member == null || _availabilityFailure(member) != null) {
        errors.add('指定成员 $id 不可用，责任保留，需用户处理。');
      } else if (used.add(id)) {
        selected.add({
          'memberId': id,
          'role': 'consultation',
          'qualificationRef': 'role:$id',
          'qualified': true,
          'available': true
        });
      }
    }
    return WorkTeamSelection(selected, missing, errors);
  }

  static bool qualifiesForResponsibility(AICharacter character, String role,
          Iterable<CharacterSkill> skills) =>
      _availabilityFailure(character) == null &&
      _isSuitable(
          character,
          WorkRoleStageKind.values
                  .where((k) =>
                      k.name ==
                      (role == 'developer'
                          ? 'development'
                          : role == 'tester'
                              ? 'testing'
                              : role))
                  .firstOrNull ??
              WorkRoleStageKind.general,
          skills.toList(),
          // 这条判据同时决定"谁算合格候选""换人时谁可选""已选定的成员是否仍然
          // 合格"，所以必须与候选口径一致：引擎/后端开发在前端责任上也算合格。
          allowImplementationBridge: true);

  Future<WorkRoleRouteResult> route({
    required String request,
    bool hasAttachments = false,
    required List<AICharacter> characters,
    String? deliverableFormatOverride,
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
    final stageFormat = _effectiveDeliverableFormat(
      deliverableFormatOverride,
      contract.format,
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
          deliverableFormatOverride: stageFormat,
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

    final inferredStages = _inferStages(
      normalizedRequest,
      deliverableFormat: stageFormat,
    );
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
    String? deliverableFormatOverride,
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
    final kinds = _inferStages(
      request,
      deliverableFormat: _effectiveDeliverableFormat(
          deliverableFormatOverride, contract.format),
    );
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
    if (!_isSuitable(receiver, stageKind, skills,
        allowImplementationBridge: true)) {
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
    // 群里**只有一位**成员本职合格时不再走推举：模型推荐只能重排候选，而这里
    // 连候选都不用排——唯一那个人就是答案。这条分支刻意放在模型选人之前，因为
    // 那个调用在"唯一匹配"的场景里只买到延迟与失败面（2026-10-12 现场：为一句
    // "生成一份飞行棋游戏的HTML"多跑一整轮推举，推举结论与模型推荐完全一致）。
    //
    // 只认本职合格（不开实现桥梁）：桥接进来的引擎/后端实现人可以当候选、可以被
    // 用户点名，但不该让"群里唯一一个真做界面的人"变成一个需要讨论的悬念。
    //
    // 用户 @ 了某人只是征求意见时不做自动指定：那条路由自己的结论就是"没有人被
    // 指派"（`_looksLikeConsultation`），把它升级成"唯一合格者接手"等于把一句提问
    // 静默变成一次派活。判错的方向必须是保守——退回旧行为（群内推举），而不是替
    // 用户决定谁来干。
    final native = consultedCharacterIds.isEmpty
        ? _nativelyQualified(kinds, candidates, skills)
        : const <AICharacter>[];
    if (native.length == 1) {
      final sole = native.single;
      final plan = _stagePlan(
        request,
        kinds,
        candidates,
        skills,
        forcedFirstRoleId: sole.id,
      );
      // 后续阶段缺人时落回下面的候选路径：那仍是一条可恢复的推迟，不该在这次
      // 判定的名义下变成硬失败。
      if (plan.isSuccess) {
        return _success(
          sole.id,
          WorkRoleRouteSource.soleQualifiedCandidate,
          '按职业资格指定「${sole.name}」执行本任务：群内只有这一位成员具备'
          '${_stageLabel(kinds.first)}职责，不再进行群内推举。'
          '接下来由群讨论确认方案、验收与分工，你无需操作。',
          1,
          plan.stages,
          conversationId,
          needsHandoff: plan.stages.length > 1,
          // 刻意不写 explicitExecutorId：那是"用户钉定"，讨论将无权改派，不一致
          // 时还会要求用户确认。自动指定不是用户声明，讨论仍应有权改派。
          deliverableContract: contract,
          discussionCharacterIds: discussionCharacterIds,
          consultedCharacterIds: consultedCharacterIds,
        );
      }
    }
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
          } else if (selected == null ||
              !_isSuitable(selected, kinds.first, skills,
                  allowImplementationBridge: true)) {
            modelNote = '模型推荐角色不满足本任务的${_stageLabel(kinds.first)}资格，未采纳模型选择。';
          } else {
            ordered = [
              selected,
              ...qualified.where((character) => character.id != selected.id),
            ];
            final reason = decision.publicReason.trim();
            modelNote = reason.isEmpty
                ? '模型建议「${selected.name}」作为首位候选，仍需群内推举。'
                : '模型建议「${selected.name}」作为首位候选（$reason），仍需群内推举。';
          }
        }
      } on WorkRoleModelSelectionException catch (error) {
        modelNote = _modelFailureNote(error);
      } on Object catch (error) {
        // 未分类的异常也必须把原因带回公开说明：一句固定文案会让现场无法归因
        // ——网络失败、凭据读不出来、模型写坏 JSON 在用户侧长得一模一样。
        final cause = redactSensitiveText(error, maximum: 160);
        modelNote = '模型候选推荐未完成：'
            '${cause.isEmpty ? error.runtimeType : cause}，未采纳模型选择。';
      }
    }
    final names = ordered.map(_candidateDisplayName).join('、');
    final stageName = _stageLabel(kinds.first);
    return WorkRoleRouteResult(
      characterId: null,
      source: WorkRoleRouteSource.candidateSelection,
      publicReason:
          '${modelNote == null ? '' : '$modelNote '}尚未指定最终执行人。候选角色：$names；'
          '任务需要$stageName能力，已交给群内讨论自动推举，你无需操作；'
          // 旧文案写的是"直接在群里 @ 一位候选角色即可"，但那并不是这条路上的
          // 真出口：任务在讨论中时新消息只走 follow-up（`enqueueFollowUp`），
          // 不会重跑路由，@ 只会被当成一句补充要求。面板才是真的能指定的地方。
          '想自己指定，请在任务面板点选一位候选角色。',
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

  /// 把选人失败翻译成一句可归因的公开说明。
  ///
  /// 每一类都要能指向不同的下一步：截断是预算/策略问题，凭据要去配置，超时
  /// 可以重试，形状不对要换模型。写死一句"暂不可用"等于把处置权也一起藏起来。
  static String _modelFailureNote(WorkRoleModelSelectionException error) {
    final clause = switch (error.kind) {
      WorkRoleModelFailureKind.credential => '没有可用的模型凭据',
      WorkRoleModelFailureKind.timeout => '模型请求超时',
      WorkRoleModelFailureKind.request =>
        '模型请求失败（${redactSensitiveText(error.detail, maximum: 120)}）',
      WorkRoleModelFailureKind.empty => '模型没有返回内容',
      WorkRoleModelFailureKind.oversized => '模型响应过大',
      WorkRoleModelFailureKind.truncated => error.outputTokenLimit == null
          ? '模型输出被截断'
          : '模型输出被截断（用满 ${error.outputTokenLimit} token 上限）',
      WorkRoleModelFailureKind.malformed => '模型响应无法解析为决策 JSON',
    };
    final snippet = error.responseSnippet;
    // 证据片段一律放到句末：夹在从句里会让"—（（））"这种嵌套括号读不出来。
    final evidence =
        snippet == null || snippet.isEmpty ? '' : '（响应开头：$snippet）';
    return '模型候选推荐未完成：$clause，未采纳模型选择。$evidence';
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
      if (_isSuitable(candidate, requiredKind, skills,
          allowImplementationBridge: true)) {
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

class WorkTeamSelection {
  final List<Map<String, dynamic>> team;
  final List<WorkRoleStageKind> missing;
  final List<String> errors;
  const WorkTeamSelection(this.team, this.missing, this.errors);
}
