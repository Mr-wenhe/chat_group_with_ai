part of 'work_discussion_runner.dart';

/// Bookkeeping blockers that are not natural-language questions. They must be
/// excluded before `openQuestions + blockers` is matched against member names,
/// because `structuredResponseInvalid:<characterId>` embeds a member id: leaving
/// it in would match that very member every round and re-invite the one who
/// already failed, forever.
bool _isInternalDiscussionMarker(String value) {
  final trimmed = value.trim();
  if (trimmed.startsWith('structuredResponseInvalid')) return true;
  return const <String>{
    'coordinatorResponseInvalid',
    'coordinatorUnavailable',
    'missingUserInformation',
    'discussionRequired',
    'executorSelectionRequired',
    'discussionNotConverged',
    'discussionRoundLimit',
    'routePending',
    'executorIdentityMismatch',
    'executorUnavailable',
    'missingQualifiedRole',
    'groupUnavailable',
    'mentionClarification',
  }.contains(trimmed);
}

extension _WorkDiscussionRunnerModelIo on WorkDiscussionRunner {
  List<String> _speakerIds({
    required int round,
    required WorkDiscussionState state,
    required List<_DiscussionMember> allMembers,
    required String? coordinatorId,
  }) {
    if (round == 1) {
      return allMembers
          .map((item) => item.character.id)
          .toList(growable: false);
    }
    final contributors = <_DiscussionMember>[];
    for (final member in allMembers) {
      final record = state.participants.where(
        (item) => item.characterId == member.character.id,
      );
      final count = record.isEmpty ? 0 : record.single.contributionCount;
      if (count < 2) {
        contributors.add(member);
      }
    }
    final unresolved = <String>[
      ...state.openQuestions,
      ...state.blockers.where((item) => !_isInternalDiscussionMarker(item)),
    ].join(' ');
    final targeted = unresolved.trim().isEmpty
        ? contributors
        : allMembers
            .where((member) =>
                _memberMatchesUnresolved(member.character, unresolved))
            .take(3)
            .toList(growable: false);
    final participants = <String>[
      ...targeted.map((member) => member.character.id),
    ];
    if (participants.isEmpty && contributors.isNotEmpty) {
      // A question may describe a capability without using the saved role
      // label. Keep the bounded discussion alive by asking the remaining
      // contributors for a clarification rather than silently dropping them.
      participants.addAll(
        contributors.take(2).map((member) => member.character.id),
      );
    }
    if (coordinatorId != null && !participants.contains(coordinatorId)) {
      participants.add(coordinatorId);
    }
    return participants
        .take(WorkDiscussionRunner.maxMembers)
        .toList(growable: false);
  }

  bool _memberMatchesUnresolved(AICharacter character, String unresolved) {
    final normalized = unresolved.toLowerCase();
    final labels = <String>{
      character.name.trim(),
      character.role.trim(),
      character.id.trim(),
    }..removeWhere((label) => label.length < 2);
    for (final label in labels) {
      if (normalized.contains(label.toLowerCase())) return true;
      final compact = label.replaceAll(RegExp(r'工程师|经理|专员|负责人'), '');
      if (compact.length >= 2 && normalized.contains(compact.toLowerCase())) {
        return true;
      }
      final roleMarker =
          RegExp(r'开发|测试|设计|产品|项目|安全|运维|运营').firstMatch(label)?.group(0);
      if (roleMarker != null && normalized.contains(roleMarker)) return true;
    }
    return false;
  }

  Future<WorkDiscussionTurn> _requestTurn({
    required AgentTask task,
    required ChatGroup group,
    required _DiscussionMember member,
    required WorkDiscussionState state,
    required List<String> publicResponses,
    required bool isCoordinator,
    required WorkTaskCancellation cancellation,
  }) async {
    if (!member.available || cancellation.isCancelled) {
      return const WorkDiscussionTurn.invalid();
    }
    final cancelToken = CancelToken();
    unawaited(cancellation.whenCancelled.then((_) {
      if (!cancelToken.isCancelled) cancelToken.cancel('用户已停止讨论');
    }));
    try {
      final prompt = await _buildPrompt(
        task: task,
        group: group,
        character: member.character,
        state: state,
        publicResponses: publicResponses,
        isCoordinator: isCoordinator,
      );
      // Project inventory is asynchronous. A stop can arrive while it is
      // being assembled, so do not start a model request after cancellation.
      if (cancellation.isCancelled) {
        return const WorkDiscussionTurn.invalid();
      }
      final response = await (completion ?? _complete)(
        character: member.character,
        config: member.config!,
        apiKey: member.apiKey!,
        provider: member.provider!,
        conversationId: task.groupId,
        messages: prompt,
        // 与修复重发路径使用同一次限：发起后由外层 `.timeout(roleTimeout)`
        // 兜底，这里把限值透传给网关，避免个别 provider 的接收超时被放大。
        timeout: roleTimeout,
        cancelToken: cancelToken,
      ).timeout(roleTimeout);
      final turn = WorkDiscussionTurn.fromResponse(response);
      if (turn.valid ||
          !_canRepairDiscussionResponse(turn) ||
          cancellation.isCancelled) {
        return turn;
      }
      // Some OpenAI-compatible gateways ignore response_format. Give the
      // same model one bounded repair opportunity, while keeping the strict
      // parser and execution gate unchanged if it fails again.
      await _recordDiagnostic(task, '讨论模型未返回 JSON，已请求一次协议修复。');
      final originalReply = boundedDiscussionText(
        _firstNonEmptyResponseText(response),
        maximum: 4000,
      );
      // Keep the repair request deliberately small. Replaying the complete
      // project dossier and group transcript makes weaker gateways continue
      // the conversational answer instead of performing the requested
      // protocol conversion. The original answer is untrusted text here; it
      // is only data for a fresh, schema-focused conversion request.
      final repairMessages = <Map<String, dynamic>>[
        {
          'role': 'system',
          'content':
              '你是严格的 JSON 协议修复器。只输出一个合法 JSON object，禁止 Markdown、解释、分析过程或前后缀。必须包含字段：public_update（字符串）、understanding_percent（0 到 100 的整数）、understanding_evidence（字符串数组）、open_questions（字符串数组）、resolved_questions（字符串数组）、blockers（字符串数组）、resolved_blockers（字符串数组）、substantive_progress（布尔值）、needs_user（布尔值）、user_question（字符串）、recommend_executor_id（字符串或 null）、contract（对象或 null）。若原意见明确推荐了合格执行角色，必须保留其 ID；无明确推荐时填 null。若原意见包含交付格式、位置、范围、显式执行人或修订目标，必须写入 contract 对象；没有合同建议时填 null。未知内容使用空数组、0、false、null 和空字符串；不得虚报 100%。输出形状示例：{"public_update":"已确认本轮范围。","understanding_percent":40,"understanding_evidence":["范围已确认"],"open_questions":[],"resolved_questions":[],"blockers":[],"resolved_blockers":[],"substantive_progress":true,"needs_user":false,"user_question":"","recommend_executor_id":null,"contract":null}。',
        },
        {
          'role': 'user',
          'content':
              '请将下面这段职业意见安全转换为上述 JSON。保留原意，不要补造项目事实；如果意见提出了未确认的数值或前置条件，把它放入 open_questions。\n\n原始职业意见：\n$originalReply',
        },
      ];
      final repairedResponse = completion != null
          ? await completion!(
              character: member.character,
              config: member.config!,
              apiKey: member.apiKey!,
              provider: member.provider!,
              conversationId: task.groupId,
              messages: repairMessages,
              timeout: roleTimeout,
              cancelToken: cancelToken,
            ).timeout(roleTimeout)
          : await _complete(
              character: member.character,
              config: member.config!,
              apiKey: member.apiKey!,
              provider: member.provider!,
              conversationId: task.groupId,
              messages: repairMessages,
              timeout: roleTimeout,
              cancelToken: cancelToken,
              // Repair through the plain response path. Some compatible
              // providers reject response_format even when the prompt itself
              // requests a JSON object; the strict parser still gates the
              // result after this one fallback attempt.
              structuredJson: false,
            ).timeout(roleTimeout);
      return WorkDiscussionTurn.fromResponse(repairedResponse);
    } on TimeoutException {
      if (!cancelToken.isCancelled) {
        cancelToken.cancel('模型请求超时');
      }
      await _recordDiagnostic(task, '讨论模型请求超时，未伪造成员发言。');
      return const WorkDiscussionTurn.invalid(failureReason: '模型请求超时');
    } on DioException catch (error) {
      final failureReason = _discussionRequestFailureReason(error);
      if (!cancellation.isCancelled) {
        await _recordDiagnostic(task, '讨论模型请求失败：$failureReason');
      }
      return WorkDiscussionTurn.invalid(failureReason: failureReason);
    } on Object catch (error) {
      final failureReason = _discussionRequestFailureReason(error);
      if (!cancellation.isCancelled) {
        await _recordDiagnostic(task, '讨论模型请求失败：$failureReason');
      }
      return WorkDiscussionTurn.invalid(failureReason: failureReason);
    }
  }

  String _firstNonEmptyResponseText(Map<String, dynamic> response) {
    for (final value in <Object?>[
      response['content'],
      response['message'],
      response['reasoning_content'],
    ]) {
      if (value is String && value.trim().isNotEmpty) return value;
    }
    return '';
  }

  bool _canRepairDiscussionResponse(WorkDiscussionTurn turn) {
    // A provider can honor JSON mode while still omitting a required field or
    // using the wrong type. Treat those protocol failures like plain text and
    // give the same model exactly one bounded conversion attempt. Transport,
    // credential, timeout, and cancellation failures must remain actionable
    // failures rather than being hidden behind a repair request.
    return const {
      '模型返回了非结构化公开内容',
      '结构化回复无效',
      '模型没有提供公开职责意见',
    }.contains(turn.failureReason);
  }

  /// Keeps request availability failures distinct from a valid response that
  /// merely violates the discussion JSON protocol.  The latter can be
  /// repaired once; the former needs an actionable provider/configuration fix.
  String _discussionRequestFailureReason(Object error) {
    final statusCode =
        error is DioException ? error.response?.statusCode : null;
    if (statusCode != null) return '模型请求失败（HTTP $statusCode）';
    final sanitized = sanitizeWorkTaskError(error);
    return sanitized == '任务执行失败' ? '模型请求异常' : sanitized;
  }

  Future<Map<String, dynamic>> _complete({
    required AICharacter character,
    required ApiConfig config,
    required String apiKey,
    required ApiProvider provider,
    required String conversationId,
    required List<Map<String, dynamic>> messages,
    required Duration timeout,
    CancelToken? cancelToken,
    // Keep the JSON contract in the prompt and validate it locally. Some
    // configured providers reject response_format or stall while handling it,
    // which blocks discussion before the protocol-repair path can run.
    bool structuredJson = false,
  }) {
    final completionBaseUrl =
        WorkDiscussionRunner.structuredDiscussionBaseUrlFor(config);
    return gateway.sendChatMessageWithResponseLimit(
      apiKey: apiKey,
      provider: provider,
      apiProtocol: config.protocol,
      customBaseUrl: completionBaseUrl,
      model: config.modelName,
      messages: messages,
      purpose: AiRequestPurpose.agent,
      conversationId: conversationId,
      characterId: character.id,
      temperature: 0.35,
      maxTokens: WorkDiscussionRunner.discussionMaxTokens,
      receiveTimeout: timeout,
      maxRetries: 0,
      cancelToken: cancelToken,
      requiresTools: false,
      userInitiated: true,
      maxResponseBytes: WorkDiscussionRunner.maxResponseBytes,
      structuredJson: structuredJson,
    );
  }

  Future<List<Map<String, dynamic>>> _buildPrompt({
    required AgentTask task,
    required ChatGroup group,
    required AICharacter character,
    required WorkDiscussionState state,
    required List<String> publicResponses,
    required bool isCoordinator,
  }) async {
    final messages = <Map<String, dynamic>>[
      {
        'role': 'system',
        'content': [
          '你是${discussionRoleLabel(character)}，只代表自己的职业职责发言。',
          if (character.systemPrompt.trim().isNotEmpty)
            boundedDiscussionText(character.systemPrompt, maximum: 4000),
          '当前处于群工作讨论阶段；禁止调用工具、写文件、安装插件、访问浏览器或声称已经执行。',
          '允许从多个模块、风险和替代方案发散思考，但每条意见都必须回扣当前任务主题、项目事实或可验证验收项；禁止把闲聊、饮品、私人安排等无关内容带入工作讨论。',
          isCoordinator
              ? '你是本轮协调/执行人：要主动收集意见、指出取舍、追问未决项，并公开给出理解百分比。'
              : '你是参与成员：只提供与你职业相关的可行性、风险、测试或交付建议，不代替其他职业做决定。',
          '当任务上下文包含 available=true 的 projectDossier 时，它是群主明确授权后本地读取的项目事实。必须据此完成职业判断和方案取舍：不得要求用户粘贴源码、重复授权路径、选择本应由产品经理比较决定的优化方向，或把可由清单推断的问题标为 needs_user。应以可复核的假设和验收标准记录仍然存在的技术风险。',
          '群成员必须优先自行讨论并确定文件名、优先级、阈值、重试次数/间隔、验收口径等普通方案细节；只有确实没有合适的执行角色、需要群主添加或选择角色时，才将 needs_user 设为 true 并 @群主。普通细节问题放入 open_questions，继续由群内角色解决。',
          'groupMembers 中角色名包含“产品”“开发”“测试”“设计”即可提供对应职业意见；不要因为开发角色的专业标签不是 Flutter 就要求群主新增角色，先由该开发成员说明可复用能力、适用边界和需要验证的部分。',
          '不得把 projectDossier、群公开讨论或附件上下文中不存在的文件、日志、指标当作事实或阻塞问题。对于尚未建立的性能基线、遥测值或运行日志，需将其明确为交付后的验收采集项和暂定阈值，而不是向群主追问或因此阻塞需求收敛。',
          '本任务的项目范围边界优先于角色人格和通用知识：优化候选只能围绕 projectDossier 明确列出的实际目录、代码能力、测试链路和可复核事实提出。区块链、DID、Gas、支付、链上存证等未被清单证实的方案只能在 public_update 中标记为“超出本轮范围，不纳入需求”，不得写入 open_questions、blockers、contract 或最终执行方向。',
          '已明确标注为“本轮不重构”“本轮范围外”或“仅记录当前默认值”的事项必须写入范围边界、风险或验收项；不得继续放入 open_questions、needs_user 或 blockers。参数取舍由群内执行人作暂定决定并在文档中标明复核时点。',
          '当四个角色均已完成职责意见、open_questions 与 blockers 为空、交付格式/位置/范围已明确且理解证据齐全时，讨论理解度必须返回 100；产品经理后续实际生成 Word 文件属于执行阶段，不得因为文件尚未写入而把已收集完成的讨论停在 99。',
          '只能返回一个 JSON object，字段必须包含 public_update、understanding_percent、understanding_evidence、open_questions、resolved_questions、blockers、resolved_blockers、substantive_progress；已解决的问题必须原样放入 resolved_questions 或 resolved_blockers，理解达到 100 时，understanding_evidence 至少分别说明目标/范围、方案/取舍、格式位置/验收；没有把握时必须保留问题，禁止虚报 100。',
          '输出形状示例（只模仿结构，不要复制示例内容）：{"public_update":"本轮公开结论","understanding_percent":50,"understanding_evidence":["目标/范围"],"open_questions":["待确认项"],"resolved_questions":[],"blockers":[],"resolved_blockers":[],"substantive_progress":true,"needs_user":false,"user_question":""}',
        ].join('\n'),
      },
      {
        'role': 'user',
        'content': _discussionPromptContent(
          context: {
            'task': boundedDiscussionText(
              WorkDiscussionState.currentRequestScope(task),
              maximum: 4000,
            ),
            'projectDossier': await _projectDossier(
              WorkDiscussionState.currentRequestScope(task),
            ),
            'group': {
              'name': boundedDiscussionText(group.name, maximum: 256),
              'theme': boundedDiscussionText(group.theme, maximum: 512),
              'description':
                  boundedDiscussionText(group.description, maximum: 2000),
              'announcement':
                  boundedDiscussionText(group.announcement, maximum: 2000),
            },
            // Candidate IDs alone are not enough for a model to elect the
            // right profession in a large group. Expose only public identity
            // fields, bounded to the same member cap used by the scheduler.
            'groupMembers': _groupCharacters(group)
                .map(
                  (member) => <String, String>{
                    'id': boundedDiscussionText(member.id, maximum: 128),
                    'name': boundedDiscussionText(member.name, maximum: 128),
                    'role': boundedDiscussionText(member.role, maximum: 256),
                  },
                )
                .toList(growable: false),
            'discussionState': state.compactForContext().toJson(),
            // The attachment message IDs are durable input context.  Keep
            // names/types in the discussion prompt so a new request version
            // can explicitly consider the supplement without exposing file
            // bodies or inventing an attachment.
            'attachmentContext': _attachmentContext(task),
            'recentChatMessages': _recentChatMessages(
              group.id,
              character.id,
            ),
            'publicDiscussionReplies': publicResponses
                .skip(publicResponses.length > 32
                    ? publicResponses.length - 32
                    : 0)
                .map((value) => boundedDiscussionText(value, maximum: 600))
                .toList(growable: false),
          },
          protocol: {
            'public_update': '只写可公开的结论、理由、建议和取舍，不能写私有推理。',
            'recommend_executor_id': '仅在你认为某个候选具备该任务职业资格时填写角色 ID，否则为 null。',
            'contract':
                '可补充 deliverableType、format、location、contentScope、revisionTarget；requestRevision 必须保持不变。',
            'needs_user': '仅当没有合适执行角色、需要群主添加或选择角色时为 true；普通方案细节必须由群内角色自行取舍。',
            'resolved_questions': '只填写本轮已经用公开事实解决的原问题，内容要与之前问题相同。',
            'resolved_blockers': '只填写本轮已经用公开事实消除的可恢复阻塞，不要移除用户信息或资格阻塞。',
            'blockers':
                '复杂任务确实需要额外讨论时，可加入 extendDiscussion:公开理由；这不是用户授权，也不能无限延长。',
          },
        ),
      },
    ];
    return messages;
  }

  String _discussionPromptContent({
    required Map<String, dynamic> context,
    required Map<String, String> protocol,
  }) {
    final protocolText = jsonEncode(protocol);
    final contextBudget =
        WorkDiscussionRunner.maxPromptCharacters - protocolText.length - 64;
    final contextText = _boundedPrompt(
      jsonEncode(context),
      maximum: contextBudget < 1 ? 1 : contextBudget,
    );
    return '任务上下文（上下文过长时仅截断资料，输出协议始终完整）：\n'
        '$contextText\n输出协议：\n$protocolText';
  }

  String _boundedPrompt(String value,
      {int maximum = WorkDiscussionRunner.maxPromptCharacters}) {
    final limit =
        maximum.clamp(1, WorkDiscussionRunner.maxPromptCharacters).toInt();
    if (value.length <= limit) return value;
    return '${value.substring(0, limit - 1)}…';
  }

  List<String> _recentChatMessages(String groupId, String characterId) {
    final messages = database.messageBox.values.where((message) {
      if (message.groupId != groupId ||
          (message.content.trim().isEmpty &&
              message.media?.isNotEmpty != true)) {
        return false;
      }
      final visible = message.visibleToCharacterIds;
      return visible.isNotEmpty && visible.contains(characterId);
    }).toList()
      ..sort((left, right) => left.timestamp.compareTo(right.timestamp));
    return messages
        .skip(messages.length > 16 ? messages.length - 16 : 0)
        .map((message) {
          final attachments = (message.media ?? const [])
              .map((item) => (item.fileName ?? '').trim())
              .where((name) => name.isNotEmpty)
              .join('、');
          final suffix = attachments.isEmpty ? '' : ' [附件：$attachments]';
          return boundedDiscussionText(
            '${message.senderId}: ${message.content}$suffix',
            maximum: 600,
          );
        })
        .where((value) => value.isNotEmpty)
        .toList(growable: false);
  }

  List<Map<String, String>> _attachmentContext(AgentTask task) {
    final metadata = _decodeExecutionMap(task.executionStateJson);
    final ids = <String>{
      if (metadata['attachmentMessageId'] is String)
        metadata['attachmentMessageId'] as String,
      if (metadata['discussionAttachmentMessageIds'] is List)
        ...(metadata['discussionAttachmentMessageIds'] as List)
            .whereType<String>(),
      if (metadata['queuedAttachmentMessageIds'] is List)
        ...(metadata['queuedAttachmentMessageIds'] as List).whereType<String>(),
    }..removeWhere((id) => id.trim().isEmpty);
    final result = <Map<String, String>>[];
    for (final id in ids.take(32)) {
      final message = database.messageBox.get(id.trim());
      if (message?.groupId != task.groupId || message?.senderType != 'user') {
        continue;
      }
      for (final media in message?.media ?? const []) {
        final fileName = boundedDiscussionText(
          (media.fileName ?? '').trim(),
          maximum: 256,
        );
        final mimeType = boundedDiscussionText(
          (media.mimeType ?? '').trim(),
          maximum: 128,
        );
        if (fileName.isEmpty && mimeType.isEmpty) continue;
        result.add(<String, String>{
          'messageId': boundedDiscussionText(id, maximum: 128),
          if (fileName.isNotEmpty) 'fileName': fileName,
          if (mimeType.isNotEmpty) 'mimeType': mimeType,
        });
        if (result.length >= 32) return result;
      }
    }
    return result;
  }

  Map<String, dynamic> _decodeExecutionMap(String raw) {
    if (raw.trim().isEmpty) return <String, dynamic>{};
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map
          ? Map<String, dynamic>.from(decoded)
          : <String, dynamic>{};
    } on Object {
      return <String, dynamic>{};
    }
  }

  Future<void> _publishUnavailableMembers(
    AgentTask task,
    ChatGroup group,
    List<_DiscussionMember> members,
    Set<String> candidateIds,
    WorkTaskCancellation cancellation,
  ) async {
    for (final member in members) {
      if (member.unavailableReason == null || cancellation.isCancelled) {
        continue;
      }
      final isCandidate = candidateIds.contains(member.character.id);
      await _publish(
        task,
        group,
        '记录：${member.character.name}（${member.character.role}）${isCandidate ? '是候选执行角色，' : ''}${member.unavailableReason}，本轮未发言。',
        cancellation: cancellation,
      );
    }
  }

  Future<void> _publishFailure(
    AgentTask task,
    ChatGroup group,
    AICharacter character,
    String text,
    WorkTaskCancellation cancellation,
  ) =>
      _publish(
        task,
        group,
        '记录：${character.name} $text',
        cancellation: cancellation,
      );

  Future<void> _publish(
    AgentTask task,
    ChatGroup group,
    String content, {
    String? senderId,
    bool isMention = false,
    required WorkTaskCancellation cancellation,
  }) async {
    if (cancellation.isCancelled || content.trim().isEmpty) return;
    final ids = group.aiCharacterIds.toSet().toList(growable: false);
    await database.persistMessage(Message(
      groupId: task.groupId,
      senderId: senderId ?? 'system',
      // A coordination/status update has no character identity. Persist it as
      // a system message instead of attaching an invented `system` AI sender;
      // only a real discussion member may speak with `senderType: ai`.
      senderType: senderId == null ? 'system' : 'ai',
      content: boundedDiscussionText(content, maximum: 2400),
      isMention: isMention,
      mentionedAiIds: senderId == null ? ids : const [],
      visibleToCharacterIds: ids,
      timestamp: clock(),
    ));
  }

  Future<void> _recordEvent(
    AgentTask task,
    WorkTaskEventKind kind,
    String title, {
    required int current,
    required int total,
    required Map<String, Object?> metadata,
  }) async {
    final store = eventStore;
    if (store == null) return;
    try {
      await store.append(
        taskId: task.id,
        kind: kind,
        title: title,
        progressCurrent: current,
        progressTotal: total,
        safeMetadata: metadata,
      );
    } on Object {
      // The task state and chat transcript remain authoritative when the
      // diagnostic stream is temporarily unavailable.
    }
  }

  Future<void> _recordDiagnostic(AgentTask task, String detail) async {
    final store = eventStore;
    if (store == null) return;
    try {
      await store.append(
        taskId: task.id,
        kind: WorkTaskEventKind.failed,
        title: '讨论成员调用未完成',
        detail: detail,
      );
    } on Object {
      // Diagnostics never replace the durable discussion state.
    }
  }

  Future<bool> _pushState(
    AgentTask task,
    WorkDiscussionState state,
    WorkTaskDiscussionStateSink updateState,
    WorkTaskCancellation cancellation,
  ) async {
    if (cancellation.isCancelled) return false;
    try {
      await updateState(state);
      return true;
    } on Object catch (error) {
      if (!cancellation.isCancelled) {
        await _recordDiagnostic(
          task,
          sanitizeWorkTaskError(error),
        );
        rethrow;
      }
      return false;
    }
  }
}
