part of 'chat_room_page.dart';

extension _ChatRoomAgenticApprovalSupport on _ChatRoomPageState {
  Future<bool> _handlePendingAgentApproval(String text) async {
    final pending = _pendingAgentApproval;
    if (pending == null) return false;
    final action = WorkModeTaskLifecycle.actionForInput(text);
    if (action == WorkModeApprovalAction.reject) {
      // 拒绝：先清空待审批项，再让 runtime 跳过该工具继续推进。
      _pendingAgentApproval = null;
      final workModeRun = _workModeSession.beginRun();
      final cancelToken = workModeRun.token;
      _beginWorkActivity();
      try {
        final runtime = _agentRuntimeFor(
          character: pending.character,
          config: pending.config,
          provider: pending.provider,
          task: pending.task,
          workMode: true,
          cancelToken: cancelToken,
          workModeRun: workModeRun,
        );
        final result = await runtime.skipRejectedTool(
          character: pending.character,
          request: pending.request,
          userRequest: pending.userRequest,
          priorExecutedRequests: pending.priorExecutedRequests,
          conversationHistory: pending.conversationHistory,
        );
        // 跳过后又碰到新的待审批工具：递归进入下一轮审批。
        if (result.status == AgentRuntimeStatus.waitingForApproval &&
            result.pendingToolRequest != null) {
          final nextApproval = PendingAgentToolApproval(
            character: pending.character,
            config: pending.config,
            provider: pending.provider,
            userRequest: pending.userRequest,
            request: result.pendingToolRequest!,
            priorExecutedRequests: result.executedToolRequests,
            conversationHistory: pending.conversationHistory,
            task: pending.task,
          );
          return _presentPendingAgentApproval(nextApproval);
        }
        await _finishAgentTask(pending.task, result);
        final content =
            _stripNamePrefix(result.message, pending.character.name);
        final attachments = await _attachmentsForAgentToolResult(
          character: pending.character,
          result: result,
        );
        await _appendMessage(Message(
          groupId: widget.groupId,
          senderId: pending.character.id,
          senderType: 'ai',
          content: content,
          media: attachments.isEmpty ? null : attachments,
        ));
        return true;
      } finally {
        _workModeSession.finishRun(workModeRun);
        await _finishWorkActivityAndDispatchNext();
      }
    }
    if (action == WorkModeApprovalAction.cancelPending) {
      // 用户没在回答审批，而是发了新指令：取消旧任务，返回 false 让这条
      // 新输入按普通消息继续走发送流程。
      _pendingAgentApproval = null;
      await _cancelAgentTask(
        pending.task,
        reason: '用户发送了新的工作指令，旧审批任务已取消。',
      );
      _conversationController.complete();
      if (_canTouchUi) _setUiState(() {});
      return false;
    }

    // 批准：执行该工具，然后继续 agent 循环。
    _pendingAgentApproval = null;
    final workModeRun = _workModeSession.beginRun();
    final cancelToken = workModeRun.token;
    _beginWorkActivity();
    try {
      final runtime = _agentRuntimeFor(
        character: pending.character,
        config: pending.config,
        provider: pending.provider,
        task: pending.task,
        workMode: true,
        cancelToken: cancelToken,
        workModeRun: workModeRun,
      );
      final result = await runtime.executeApprovedTool(
        character: pending.character,
        request: pending.request,
        userRequest: pending.userRequest,
        priorExecutedRequests: pending.priorExecutedRequests,
        conversationHistory: pending.conversationHistory,
      );
      if (result.status == AgentRuntimeStatus.waitingForApproval &&
          result.pendingToolRequest != null) {
        final nextApproval = PendingAgentToolApproval(
          character: pending.character,
          config: pending.config,
          provider: pending.provider,
          userRequest: pending.userRequest,
          request: result.pendingToolRequest!,
          priorExecutedRequests: result.executedToolRequests,
          conversationHistory: pending.conversationHistory,
          task: pending.task,
        );
        return _presentPendingAgentApproval(nextApproval);
      }
      await _finishAgentTask(pending.task, result);
      // 工具跑完但模型没给文字总结时，也要给用户一个明确的完成反馈。
      final content = _stripNamePrefix(
        result.message.trim().isEmpty
            ? '[${pending.character.name} 工具执行完成，但没有返回内容]'
            : result.message.trim(),
        pending.character.name,
      );
      final attachments = await _attachmentsForAgentToolResult(
        character: pending.character,
        result: result,
      );
      final message = Message(
        groupId: widget.groupId,
        senderId: pending.character.id,
        senderType: 'ai',
        content: content,
        media: attachments.isEmpty ? null : attachments,
      );
      await _appendMessage(message);
      await _recordReplyUsage(pending.character);
      _registerUserMentionIfNeeded(message);
      return true;
    } finally {
      _workModeSession.finishRun(workModeRun);
      await _finishWorkActivityAndDispatchNext();
    }
  }

  /// 挂起任务并弹出工具审批对话框，把用户的选择交给 [_handlePendingAgentApproval]。
  ///
  /// 对话框被返回键关闭（decision 为 null）会被统一当作取消任务，
  /// 避免任务永久停在 waitingForApproval 检查点上。
  Future<bool> _presentPendingAgentApproval(
    PendingAgentToolApproval approval,
  ) async {
    _pendingAgentApproval = approval;
    // 从"恢复任务"路径进来时可能还没有活跃回合，这里补一个。
    if (!_conversationController.isBusy) {
      _conversationController.beginWork();
    }
    _conversationController.waitForApproval();
    if (_canTouchUi) _setUiState(() {});
    final decision = await _showAgentApprovalDialog(
      approval.request,
      approval.character,
    );
    final action = WorkModeTaskLifecycle.actionForDialogDecision(decision);
    if (action == WorkModeApprovalAction.cancelPending) {
      // identical 校验：期间可能已被别的路径替换成新的审批项，只清自己那个。
      if (identical(_pendingAgentApproval, approval)) {
        _pendingAgentApproval = null;
      }
      await _cancelAgentTask(
        approval.task,
        reason: '用户关闭了工具审批对话框，任务已取消。',
      );
      _conversationController.complete();
      if (_canTouchUi) _setUiState(() {});
      return true;
    }
    // 复用文本审批入口，保证弹层与打字两种方式走完全相同的后续逻辑。
    return _handlePendingAgentApproval(
      action == WorkModeApprovalAction.approve ? '批准' : '拒绝',
    );
  }

  /// 标记进入"工作执行中"状态（恢复已挂起的回合，或开启新回合）。
  void _beginWorkActivity() {
    if (!_conversationController.resumeWork()) {
      _conversationController.beginWork();
    }
    if (_canTouchUi) _setUiState(() {});
  }

  /// 结束工作活动：仍有待审批项时停在"等待审批"，否则彻底完成本回合。
  void _finishWorkActivity() {
    if (_pendingAgentApproval != null) {
      _conversationController.waitForApproval();
    } else {
      _conversationController.complete();
    }
    if (_canTouchUi) _setUiState(() {});
  }

  /// 以弹层（AlertDialog）形式请求用户批准/拒绝工具调用，替代原来的“打字批准”。
  ///
  /// 返回 `true`=批准，`false`=拒绝，`null`=返回键关闭或无法弹层。
  /// 所有入口都由 [_presentPendingAgentApproval] 将 null 统一转为任务取消，
  /// 避免多步审批遗留 waitingForApproval 检查点。
  Future<bool?> _showAgentApprovalDialog(
    ToolRequest request,
    AICharacter character,
  ) async {
    if (!_canTouchUi || !mounted) return null;
    final decision = await showDialog<bool>(
      context: context,
      // 不允许点遮罩关闭：审批是明确的二选一决定。
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: Text('${character.name} 请求使用工具'),
        content: SingleChildScrollView(
          child: Text(
            '工具：${request.tool.wireName}\n'
            '范围：${WorkModePolicy.approvalSummary(request)}\n\n'
            '原因：${request.reason}',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('拒绝'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('批准'),
          ),
        ],
      ),
    );
    return decision;
  }

  /// `skill_create` 工具的落地实现：把 LLM 给出的技能定义存为 [CharacterSkill]
  /// 并挂到该角色的 skillIds 上。
  ///
  /// 返回给 runtime 的 Map 即工具执行结果（`ok` / `error` 约定）。
  /// instructions 缺失时直接失败，因为没有步骤的技能没有意义。
  Future<Map<String, dynamic>> _saveGeneratedSkillFromArgs({
    required AICharacter character,
    required Map<String, dynamic> args,
  }) async {
    final instructionsRaw = args['instructions'];
    if (instructionsRaw is! List) {
      return {'ok': false, 'error': 'instructions_missing'};
    }
    // 兼容 LLM 可能用 permissions 或 requiredPermissions 两种键名。
    final permissionNames = (args['permissions'] is List
            ? args['permissions'] as List
            : args['requiredPermissions'] is List
                ? args['requiredPermissions'] as List
                : const [])
        .whereType<String>()
        .toSet();
    // 只保留枚举里真实存在的权限名，杜绝模型臆造出的权限被写入。
    final permissions = ToolPermission.values
        .where((permission) => permissionNames.contains(permission.name))
        .toList();
    final skill = CharacterSkill(
      characterId: character.id,
      name: args['name'] as String? ?? 'Generated Skill',
      domain: args['domain'] as String? ?? 'general',
      description: args['description'] as String? ?? '',
      instructions: instructionsRaw.whereType<String>().toList(),
      requiredPermissions: permissions,
    );
    await _db.characterSkillBox.put(skill.id, skill);
    if (!character.skillIds.contains(skill.id)) {
      character.skillIds = [...character.skillIds, skill.id];
      await _db.aiCharacterBox.put(character.id, character);
    }
    return {
      'ok': true,
      'skillId': skill.id,
      'name': skill.name,
      'permissions': permissions.map((p) => p.name).toList(),
    };
  }

  /// `skill_download` 工具的落地实现：从内置专家技能目录安装一个模板技能。
  ///
  /// templateId 缺省时按角色特征推荐一个。已安装过同名同领域技能则复用，
  /// 避免重复下载产生多份副本。
  Future<Map<String, dynamic>> _downloadExpertSkillFromArgs({
    required AICharacter character,
    required Map<String, dynamic> args,
  }) async {
    // 兼容 templateId / id 两种键名，都没有就按角色推荐。
    final templateId = args['templateId'] as String? ??
        args['id'] as String? ??
        _recommendedTemplateIdFor(character, args['domain'] as String?);
    if (templateId == null) {
      return {'ok': false, 'error': 'template_not_found'};
    }
    final template = ExpertSkillCatalog.findById(templateId);
    if (template == null) {
      return {
        'ok': false,
        'error': 'template_not_found',
        'templateId': templateId
      };
    }
    // 幂等：同名 + 同领域视为已安装，直接复用而不新建。
    final existing = _db.characterSkillBox.values.where(
      (skill) =>
          skill.characterId == character.id &&
          skill.name == template.name &&
          skill.domain == template.domain,
    );
    final skill = existing.isNotEmpty
        ? existing.first
        : template.instantiateFor(character.id);
    if (existing.isEmpty) {
      await _db.characterSkillBox.put(skill.id, skill);
    }
    // 用 Set 合并，保证 skillIds 不出现重复项。
    final skillIds = <String>{...character.skillIds, skill.id};
    character.skillIds = skillIds.toList();
    await _db.aiCharacterBox.put(character.id, character);
    return {
      'ok': true,
      'skillId': skill.id,
      'templateId': template.id,
      'name': skill.name,
      'permissions': template.requiredPermissions.map((p) => p.name).toList(),
    };
  }

  /// 为角色推荐一个专家技能模板 id：优先匹配指定 [domain]，否则取推荐列表第一个。
  String? _recommendedTemplateIdFor(AICharacter character, String? domain) {
    final templates = SkillDownloadService.recommendedTemplatesFor(character);
    if (domain != null && domain.trim().isNotEmpty) {
      for (final template in templates) {
        if (template.domain == domain) return template.id;
      }
    }
    return templates.isEmpty ? null : templates.first.id;
  }

  /// 汇总本次 agentic 运行可用的技能：已安装技能 + 本次解析出的技能。
  ///
  /// 归属判断放宽为"skill.characterId 匹配 **或** 出现在 character.skillIds 里"，
  /// 兼容通过 skillIds 关联的共享技能。
  List<CharacterSkill> _agenticSkillsFor(
      AICharacter character, String userRequest,
      {CharacterSkillBundle? resolution}) {
    final saved = _db.characterSkillBox.values.where(
      (skill) =>
          skill.characterId == character.id ||
          character.skillIds.contains(skill.id),
    );
    return WorkModePolicy.resolveSkills(
      character: character,
      userRequest: userRequest,
      installedSkills: saved,
      resolvedSkills: resolution?.skills,
    );
  }

  /// 判断该角色已保存的技能中是否已有能覆盖本次请求的，
  /// 用于避免"每次都强制新建技能"。
  ///
  /// 匹配方式：技能描述包含整段请求，或技能名/领域拆出的关键词出现在请求里。
  /// `general` / `custom` 这类泛化词被排除，否则几乎任何请求都会误命中。
  bool _savedSkillMatchesRequest(
    AICharacter character,
    String userRequest,
  ) {
    final request = userRequest.toLowerCase().trim();
    final saved = _db.characterSkillBox.values.where(
      (skill) =>
          skill.characterId == character.id ||
          character.skillIds.contains(skill.id),
    );
    for (final skill in saved) {
      if (skill.description.toLowerCase().contains(request)) return true;
      final capability = '${skill.name} ${skill.domain}'.toLowerCase();
      // \u540c\u65f6\u5339\u914d\u82f1\u6587/\u6570\u5b57\u8bcd\uff08\u22652 \u5b57\u7b26\uff09\u4e0e\u4e2d\u6587\u8bcd\uff082~8 \u5b57\uff09\uff0c\u9002\u914d\u4e2d\u82f1\u6df7\u6392\u6280\u80fd\u540d\u3002
      final tokens = RegExp(r'[a-z0-9_+#.-]{2,}|[\u4e00-\u9fff]{2,8}')
          .allMatches(capability)
          .map((match) => match.group(0)!)
          .where((token) => token != 'general' && token != 'custom');
      if (tokens.any(request.contains)) return true;
    }
    return false;
  }

  /// 停止当前流式生成：取消订阅并保留已生成的（部分）内容落库。
}
