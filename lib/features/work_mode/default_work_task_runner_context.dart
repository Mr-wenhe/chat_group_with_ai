part of 'default_work_task_runner.dart';

extension _DefaultWorkTaskRunnerContext on DefaultWorkTaskRunner {
  bool _sensitiveReadAllowed(
    AgentTask task,
    Stage02WorkspaceFileTool stage02, {
    required String operation,
    required String path,
    int startByte = 0,
    int? byteLength,
    String? query,
    bool recursive = false,
    bool caseSensitive = true,
  }) {
    final decision = _approvalDecision(task.executionStateJson);
    final checkpoint = _decodeMap(task.executionStateJson);
    if (decision?.permitsExecution != true ||
        checkpoint['approvalCapability'] !=
            WorkApprovalCapability.sensitiveRead) {
      return false;
    }
    final expected = stage02.sensitiveReadFingerprint(
      operation: operation,
      path: path,
      startByte: startByte,
      byteLength: byteLength,
      query: query,
      recursive: recursive,
      caseSensitive: caseSensitive,
    );
    return checkpoint['approvalOperationFingerprint'] == expected;
  }

  void _recordSensitiveReadApproval(
    AgentTask task,
    Stage02WorkspaceFileTool stage02,
    Map<String, dynamic> result, {
    required String operation,
    required String path,
    int startByte = 0,
    int? byteLength,
    String? query,
    bool recursive = false,
    bool caseSensitive = true,
  }) {
    if (result['requiresApproval'] != true || result['sensitive'] != true) {
      return;
    }
    task.executionStateJson = _withApprovalMetadata(
      task.executionStateJson,
      capability: WorkApprovalCapability.sensitiveRead,
      fingerprint: stage02.sensitiveReadFingerprint(
        operation: operation,
        path: path,
        startByte: startByte,
        byteLength: byteLength,
        query: query,
        recursive: recursive,
        caseSensitive: caseSensitive,
      ),
    );
  }

  String _withFolderRequest(String raw, String path) {
    final current = _decodeMap(raw)..['folderRequestPath'] = path.trim();
    return jsonEncode(current);
  }

  String _withExplicitCommandRequest(String raw) {
    final current = _decodeMap(raw)..['explicitCommandRequestRequired'] = true;
    return jsonEncode(current);
  }

  String _withoutApprovalCheckpoint(String raw) {
    final current = _decodeMap(raw)
      ..remove('approvalDecision')
      ..remove('approvalPlan')
      ..remove('approvalScope')
      ..remove('approvalCapability')
      ..remove('approvalOperationFingerprint')
      ..remove('approvalConsumed');
    return current.isEmpty ? '' : jsonEncode(current);
  }

  WorkChangeApprovalDecision? _approvalDecision(String raw) =>
      WorkChangeApprovalDecision.fromWire(_decodeMap(raw)['approvalDecision']);

  WorkApprovalScope? _approvalScope(String raw) {
    final value = _decodeMap(raw)['approvalScope'];
    if (value is! Map) return null;
    try {
      return WorkApprovalScope.fromJson(Map<String, dynamic>.from(value));
    } on Object {
      return null;
    }
  }

  Map<String, dynamic> _decodeMap(String raw) {
    if (raw.trim().isEmpty) return <String, dynamic>{};
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map ? Map<String, dynamic>.from(decoded) : {};
    } on Object {
      return <String, dynamic>{};
    }
  }

  String _effectivePath(
    AgentTask? task,
    String workspaceRoot,
    Object? raw, {
    bool enforceRevision = true,
  }) {
    final value = raw?.toString().trim() ?? '';
    if (value.isEmpty) throw const FormatException('工作区路径不能为空');
    if (_containsParentTraversal(value)) {
      throw const FormatException('工作区路径不能包含 ..');
    }
    final revision = task == null ? null : _revisionTarget(task);
    // A revision target is a durable capability boundary. The model may use a
    // relative or absolute spelling, but it cannot redirect the mutation to a
    // different basename after the user queued “modify the same file”.
    //
    // Only a path naming that same file is rewritten. Applying the pin to every
    // mutation made the deliverable the only writable file in the task, so the
    // scripts and part files the prompt contract asks for silently landed on
    // the deliverable instead of existing — the model then re-listed, saw no
    // script, and wrote another one, forever.
    if (enforceRevision &&
        revision != null &&
        _namesSameFile(value, revision)) {
      final normalizedRoot = workspaceRoot.replaceAll('\\', '/');
      // A public contract may say Desktop/foo.html while the authorized root
      // is already /Users/.../Desktop. Do not resolve that as Desktop/Desktop.
      final relativeRevision = _stripAuthorizedRootLeaf(
        revision,
        normalizedRoot,
      );
      final absoluteRevision = _isAbsolutePath(relativeRevision)
          ? relativeRevision
          : '$normalizedRoot/$relativeRevision';
      final isWindows = workspaceFileService?.pathPolicy.isWindows ??
          RegExp(r'^[A-Za-z]:').hasMatch(absoluteRevision);
      return WorkspacePathPolicy.normalizePath(
        absoluteRevision,
        isWindows: isWindows,
      );
    }
    final absolute = _isAbsolutePath(value)
        ? value
        : '${workspaceRoot.replaceAll('\\', '/')}/$value';
    final isWindows = workspaceFileService?.pathPolicy.isWindows ??
        RegExp(r'^[A-Za-z]:').hasMatch(absolute);
    return WorkspacePathPolicy.normalizePath(absolute, isWindows: isWindows);
  }

  bool _requiresDocumentTool(String path) {
    final normalized = path.trim().replaceAll('\\', '/').toLowerCase();
    return RegExp(r'\.(?:pdf|docx|xlsx)$').hasMatch(normalized);
  }

  String? _revisionTarget(AgentTask task) {
    final value = _decodeMap(task.executionStateJson)['revisionTargetPath'];
    if (value is! String ||
        value.trim().isEmpty ||
        _containsParentTraversal(value)) {
      return null;
    }
    return value.replaceAll('\\', '/').trim();
  }

  bool _isExactPatch(Map<String, dynamic> args) =>
      args['expectedSha256'] is String &&
      args['expectedFragment'] is String &&
      args['replacement'] is String;

  /// 合并形态（`parts`）与精确补丁一样不接受自动改名：它的 `path` 是交付物
  /// 本身，改名只会让模型随后读回旧文件。
  bool _isMergePatch(Map<String, dynamic> args) => args['parts'] is List;

  /// Whether a model-supplied path spells the same file as the revision target.
  ///
  /// Only the basename decides — the directory spelling varies (relative vs
  /// absolute, with or without the authorized-root leaf) and is resolved by the
  /// caller. Case is folded so a differently-cased spelling of the deliverable
  /// pins to the stored path instead of creating a near-duplicate beside it,
  /// matching how the delivery guard compares artifact paths.
  static bool _namesSameFile(String requested, String revisionTarget) {
    String basename(String path) {
      final normalized = path.replaceAll('\\', '/');
      return normalized.substring(normalized.lastIndexOf('/') + 1);
    }

    return basename(requested).toLowerCase() ==
        basename(revisionTarget).toLowerCase();
  }

  bool _isAbsolutePath(String value) {
    final path = value.trim();
    return path.startsWith('/') ||
        path.startsWith('\\') ||
        RegExp(r'^[A-Za-z]:[\\/]').hasMatch(path);
  }

  /// Removes a leading authorized-root leaf from a contract-supplied path.
  ///
  /// A public contract may name `Desktop/report.md` while the authorized root
  /// already ends in `Desktop`; resolving that literally would produce
  /// `Desktop/Desktop/report.md` and be rejected as out of scope. Absolute
  /// paths and paths that do not start with the leaf are returned unchanged.
  String _stripAuthorizedRootLeaf(String path, String normalizedRoot) {
    final candidate = path.replaceAll('\\', '/');
    if (_isAbsolutePath(candidate)) return candidate;
    final rootLeaf =
        normalizedRoot.split('/').where((segment) => segment.isNotEmpty).last;
    if (candidate.startsWith('$rootLeaf/')) {
      return candidate.substring(rootLeaf.length + 1);
    }
    return candidate == rootLeaf ? '' : candidate;
  }

  bool _containsParentTraversal(String value) =>
      value.replaceAll('\\', '/').split('/').any((segment) => segment == '..');

  String _basename(String value) {
    final normalized = value.replaceAll('\\', '/');
    final index = normalized.lastIndexOf('/');
    return index < 0 ? normalized : normalized.substring(index + 1);
  }

  String _safeCommandDisplay(WorkCommand command) {
    var display = const SearchSecretScanner().redact(
      command.displayCommand,
      includeOpaqueTokens: true,
    );
    display = display
        .replaceAll(RegExp(r'[\u0000-\u001f\u007f]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    const maximum = 1200;
    return display.length <= maximum
        ? display
        : '${display.substring(0, maximum - 1)}…';
  }

  int _intArgument(Object? value, int fallback) =>
      value is int && value >= 0 ? value : fallback;

  /// Normalizes an optional tool path. Anything other than a non-blank string
  /// means "the current authorized workspace root": a model may omit the
  /// argument, send an explicit `null`, or send an empty string, and
  /// `null.toString()` would otherwise become the literal path `null`.
  /// Exactly `.` and `./` also fold to the root so every spelling resolves to
  /// the same authorized directory.
  String _workspaceListPath(Object? rawPath) {
    if (rawPath is! String) return '.';
    final value = rawPath.trim().replaceAll('\\', '/');
    if (value.isEmpty) return '.';
    final withoutTrailingSeparator =
        value.length > 1 ? value.replaceFirst(RegExp(r'/+$'), '') : value;
    return withoutTrailingSeparator.isEmpty ? '.' : withoutTrailingSeparator;
  }

  String _defaultWeatherLocation() {
    try {
      final profile = database.userProfileBox.get('me');
      final clues = <String>[
        if (profile != null) ...profile.importantBackground,
        if (profile != null) profile.bio,
      ];
      final locationPattern = RegExp(
        r'(?:住在|来自|位于|所在地(?:是)?)[：:\s]*([\u4e00-\u9fffA-Za-z·-]{2,24})',
      );
      for (final clue in clues) {
        final match = locationPattern.firstMatch(clue);
        final location = match?.group(1)?.trim();
        if (location != null && location.isNotEmpty) return location;
      }
    } on Object {
      // A missing profile must not prevent a safe built-in default forecast.
    }
    return WeatherForecastService.defaultLocation;
  }

  int? _nullableInt(Object? value) => value is int && value >= 0 ? value : null;

  ApiConfig? _resolveApiConfig(AICharacter character) {
    if (character.apiConfigId.trim().isNotEmpty) {
      final configured = database.apiConfigBox.get(character.apiConfigId);
      if (configured != null) return configured;
    }
    for (final config in database.apiConfigBox.values) {
      if (config.provider == character.apiProvider &&
          config.modelName == character.modelName) {
        return config;
      }
    }
    return null;
  }

  ApiProvider _providerFor(ApiConfig config) => ApiProvider.values.firstWhere(
        (provider) => provider.name == config.provider,
        orElse: () => throw StateError('模型提供商配置无效：${config.provider}'),
      );

  Future<List<Map<String, dynamic>>> _conversationHistory(
    AgentTask task,
  ) async {
    final messages = database.messageBox.values
        .where((message) =>
            message.groupId == task.groupId &&
            !message.id.startsWith('agent-progress:'))
        .toList()
      ..sort((left, right) => left.timestamp.compareTo(right.timestamp));
    // 分界线之前的历史属于已被删除的任务，不该再作为当前任务的上下文。
    final visible = WorkContextBoundary.visible(
      database.appSettingsBox,
      task.groupId,
      messages,
    );
    return AgentAttachmentContext.buildHistory(
      messages:
          visible.length <= 24 ? visible : visible.sublist(visible.length - 24),
      currentUserRequest: WorkDiscussionState.currentRequestScope(task),
    );
  }

  Future<String> _requestWithAttachmentContext(AgentTask task) async {
    final sourceId = _attachmentMessageId(task.executionStateJson);
    Message? source;
    if (sourceId != null) {
      final candidate = database.messageBox.get(sourceId);
      if (candidate != null &&
          candidate.groupId == task.groupId &&
          candidate.senderType == 'user' &&
          candidate.media?.isNotEmpty == true) {
        source = candidate;
      }
    }
    if (source == null) {
      final candidates = database.messageBox.values
          .where((message) =>
              message.groupId == task.groupId &&
              message.senderType == 'user' &&
              message.content.trim() == task.userRequest.trim())
          .toList()
        ..sort((left, right) => right.timestamp.compareTo(left.timestamp));
      source = candidates.isEmpty ? null : candidates.first;
    }
    if (source == null &&
        task.userRequest.trim() == WorkModePolicy.attachmentOnlyRequest) {
      // Attachment-only follow-ups use an internal label because the durable
      // queue cannot store an empty request. Resolve that label to the newest
      // user attachment without changing the original message content.
      final messages = database.messageBox.values
          .where((message) =>
              message.groupId == task.groupId &&
              message.senderType == 'user' &&
              message.media?.isNotEmpty == true)
          .toList()
        ..sort((left, right) => right.timestamp.compareTo(left.timestamp));
      source = messages.isEmpty ? null : messages.first;
    }
    return AgentAttachmentContext.enhanceCurrentRequest(
      userRequest: WorkDiscussionState.currentRequestScope(task),
      media: source?.media,
    );
  }

  String? _attachmentMessageId(String rawExecutionState) {
    try {
      final decoded = jsonDecode(rawExecutionState);
      final value = decoded is Map ? decoded['attachmentMessageId'] : null;
      return value is String && value.trim().isNotEmpty ? value.trim() : null;
    } on Object {
      return null;
    }
  }

  Set<String> _attachmentPathsForTask(AgentTask task) {
    final metadata = _decodeMap(task.executionStateJson);
    final ids = <String>{
      if (metadata['attachmentMessageId'] is String)
        metadata['attachmentMessageId'] as String,
      if (metadata['discussionAttachmentMessageIds'] is List)
        ...(metadata['discussionAttachmentMessageIds'] as List)
            .whereType<String>(),
      if (metadata['queuedAttachmentMessageIds'] is List)
        ...(metadata['queuedAttachmentMessageIds'] as List).whereType<String>(),
    };
    final paths = <String>{};
    for (final id in ids) {
      final message = database.messageBox.get(id.trim());
      if (message?.groupId != task.groupId || message?.senderType != 'user') {
        continue;
      }
      for (final attachment in message?.media ?? const []) {
        final path = attachment.localPath.trim();
        if (path.isNotEmpty) paths.add(path);
      }
    }
    return paths;
  }

  bool _isReferencedAttachmentPath(
    String rawPath,
    Iterable<String> attachmentPaths, {
    required bool isWindows,
  }) {
    try {
      final normalized = WorkspacePathPolicy.normalizePath(
        rawPath,
        isWindows: isWindows,
      );
      return attachmentPaths.any(
        (path) =>
            WorkspacePathPolicy.normalizePath(
              path,
              isWindows: isWindows,
            ) ==
            normalized,
      );
    } on Object {
      return false;
    }
  }

  String _workModeContext(
      AgentTask task, AICharacter character, WorkToolRegistry registry,
      {required String workspaceRoot, WorkCandidate? candidate}) {
    final currentRequest = WorkDiscussionState.currentRequestScope(task);
    final base = WorkModePolicy.planningContext(character);
    final discoverable = WorkModePolicy.discoverableSkills(
      character: character,
      installedSkills: database.characterSkillBox.values,
      resolvedSkills: CharacterSkillResolver.resolveFor(
        character,
        currentRequest,
      ).skills,
    );
    final skillCatalog = discoverable.isEmpty
        ? '无（需要时可通过 meta.find-skills 查找或安装）'
        : discoverable.map(_compactSkillCatalogEntry).join('\n');
    final matchedTemplate = _matchingSkillTemplate(currentRequest);
    final skillPreflight = matchedTemplate == null
        ? null
        : '技能预检：已从内置目录匹配「${matchedTemplate.id}」。若角色尚未安装，任务启动阶段会先调用 skill.download；本轮禁止创建重复 Skill。';
    final tools = registry.definitions
        .map((definition) =>
            '${definition.name.wireName}(${definition.access.name})')
        .join('、');
    final summary = WorkTaskExecutionPolicy.isValidatedV2GroupTask(task)
        ? const WorkContextBuilder().fromTask(task).toJsonString()
        : task.contextSummary.trim();
    final handoff = WorkHandoffState.fromTask(task);
    final execution = _decodeMap(task.executionStateJson)['workItemExecution'];
    final usageAssignment = execution is Map &&
            const {'usage', 'verify'}.contains(execution['stage'])
        ? WorkDiscussionState.fromExecutionState(task.executionStateJson)
            ?.collaboration
            ?.usageAssignments
            .where((item) => item['memberId'] == task.characterId)
            .firstOrNull
        : null;
    final usageCapabilities = usageAssignment == null
        ? const <String>{}
        : (usageAssignment['requiredCapabilities'] as List)
            .cast<String>()
            .toSet();
    final canUseBrowserContext = usageAssignment != null &&
        candidate != null &&
        _canUseBrowserContext(
          task,
          character,
          usageAssignment,
          candidate,
        );
    final documentFiles = candidate?.files
            .where((entry) => const {'docx', 'pdf'}.contains(p
                .extension(entry['path'] as String)
                .toLowerCase()
                .replaceFirst('.', '')))
            .map((entry) => {
                  'path': candidate.file(entry['path'] as String).absolute.path,
                  'fileName': p.basename(entry['path'] as String),
                  'sha256': entry['sha256'],
                })
            .toList(growable: false) ??
        const <Map<String, dynamic>>[];
    final targetsDesktop =
        WorkModeDirectoryService.requestTargetsDesktop(currentRequest);
    return [
      base,
      if (_decodeMap(task.executionStateJson)['workItemExecution'] is Map)
        '当前成员工作项：${jsonEncode(_decodeMap(task.executionStateJson)['workItemExecution'])}；协作方案与验收：${jsonEncode(WorkDiscussionState.fromExecutionState(task.executionStateJson)?.collaboration?.toPromptJson())}。只完成当前工作项，不代表整个任务完成。',
      if ((_decodeMap(task.executionStateJson)['workItemExecution']
              as Map?)?['stage'] ==
          'material')
        '当前仅制作需求/技术/测试工作材料。写入后用 workspace.read 读回核对，finish.evidence 必须是已实际读取成功的材料文件完整路径数组，不放 JSON 测试报告、说明文字或尚未生成的交付文件。材料可打开且内容完整即可提交本工作项，不运行最终 HTML 的校验命令、不声称游戏测试通过；后续 produce 与独立验证仍由原流程执行。',
      if (WorkTaskExecutionPolicy.isValidatedV2GroupTask(task) &&
          const {'material', 'produce'}.contains(
              (_decodeMap(task.executionStateJson)['workItemExecution']
                  as Map?)?['stage']))
        '分段写入与连续修复：先按当前工作项和已确认合同选定正式文件完整路径；已有内容有重复或缺项时，保留该目标路径修复。分段文件只是中间稿：先读回本轮已写分段，再用 append:true 仅追加尚不存在的后续内容。修复重复内容必须使用 expectedSha256、expectedFragment、replacement 精确替换；expectedSha256 逐字复制最近 workspace.read 返回的 sha256，不猜测、不省略；没有摘要时先取得真实摘要，不能反复提交缺字段补丁。若确需完整重写，必须显式 append:false、overwrite:true 且 content 包含完整待保留内容，不能把新的 head/style 追加到旧稿末尾，也不能用不完整头部覆盖已完成脚本。workspace.read 返回 truncated:true 只代表本次读取被截断，不代表磁盘文件缺失后半段；用 startByte、byteLength（每段不超过 6000 字节）分段读取到实际末尾再决定续写位置，不反复从 0 读取同一预览。写全后用 workspace.patch 的 parts 按序合并到该正式目标，再读回这个目标；不能只改分段又反复读取未更新的旧合并版，不能靠改分段名称重新起稿。审批恢复后先根据真实写入记录确认当前分段与待合并目标，继续未完成的续写或合并，不重建已完成部分。恢复不是重新开工，artifacts 与 completedActions 中的已写文件仍然存在；软件头部与样式已写好时，先读回末尾接着追加界面和脚本逻辑，不再换名重写 head/style；最终合并到合同要求的 HTML，不能把中间稿当作候选交付。',
      if ((_decodeMap(task.executionStateJson)['workItemExecution']
              as Map?)?['stage'] ==
          'produce')
        '当前按已确认合同制作交付文件，finish.evidence 使用实际生成的文件路径。本工作项须有真实工具写入，且合同目标的内容摘要相对开工基线实际变化；历史写入、只读旧文件、只写分段、改时间或重写相同内容不算本轮制作完成。优化或修复必须落实到目标文件，再读回验证，不能只重复旧功能介绍。制作人自检不代替冻结候选后的独立测试，不把材料完成当作软件完成。交付文件已合并、内容完整且本轮合同静态命令已有实际成功记录时，提交 finish 结束制作工作项，由运行时冻结候选并安排独立测试；这里的 finish 只提交候选，不代表整个任务通过。独立浏览器只支持具名控件 click、observe、assert、resize，以及 open 时已确认的 queryParameters，不支持键盘或输入框填值；测试入口须用可点击按钮或已确认参数，不能只用快捷键，棋子须有可区分的可访问名称。没有新缺陷或文件变化时，不重复读同一文件、不换名创建尾部/结构/最终检查脚本、不重跑已成功的同一检查。额外自检工具缺失或跳过必须如实说明，不能记为通过；独立验收能力缺失仍须阻塞，不得降级。真实检查失败时修复对应缺陷再复查，文件变化后的旧结果不授权新文件。',
      if ((_decodeMap(task.executionStateJson)['workItemExecution']
              as Map?)?['stage'] ==
          'verify')
        'verify 工作项须实际读取或执行验证，禁止创建校验脚本、改产物和断言；已提供 browser.context 时直接 open 当前候选并按已确认步骤 click/assert，不能探测或安装其他浏览器来替代现有入口；finish.evidence 仅含一个 JSON 字符串 {method,result:"passed|failed|blocked",acceptanceIds:[全部覆盖项],report:"完整报告",defects:[{acceptanceId,reproduction,expected,actual,retestCondition}]}。软件测试命令标准输出须为 JSON {artifactDigest:"当前候选摘要",tests:[{id,status:"passed|failed",method:"对应 requiredCapability",reproduction,expected,actual}]}；必须实际执行对应测试，退出码0或 HTML 结构/打开不能替代交互覆盖，能力缺失返回 blocked。不删失败用例刷绿。',
      if ((_decodeMap(task.executionStateJson)['workItemExecution']
              as Map?)?['stage'] ==
          'usage')
        '你负责 own_usage 对应的本人场景，只使用当前冻结候选，并由自己的模型逐步决定实际动作。先核对候选版本、目标应用和前置测试数据，再查看真实窗口、页面或输出；每步依据操作后的真实结果继续，观察预期与实际、状态变化、持久化、结果文件和错误。原生、网页界面使用对应已注册操作工具，源码阅读、命令打印的 tests JSON、截图路径或他人报告都不能冒充本人使用；只有图像实际送达且当前模型能够看见时才报告视觉观察。executorId 始终是制作责任人，不能改派；不得修改候选、测试断言或必达验收，发现的问题交回群内下一轮制作。旧缺陷也要实际复测；候选变化后重新使用当前版本，旧截图和观察失效。窗口失焦或元素失效时先重新观察，不能向未知前台输入。报告全部发现；report 引用本人真实工具证据，defects 仅使用已解析字段 {acceptanceId,reproduction,expected,actual,retestCondition} 写清复现步骤、预期、实际和复测条件。文档缺陷按下方已解析结构增加 sourceLocation，不能添加其他字段。通过时说明本人完成的路径；没有真实操作证据不得签通过。finish.summary 写本人观察与反馈，finish.evidence 仅放一份本人反馈 JSON {method,result:"passed|failed|blocked",acceptanceIds:[本场景全部验收ID],report:"实际观察和结果",defects:[{acceptanceId,reproduction,expected,actual,retestCondition}]}；失败列全缺陷，通过不能带缺陷。工具运行时核验当前候选、真实操作与业务结果，模型填写 passed 不会生成通过收据；缺少工具、视觉能力、有效前置数据或场景无法验证时明确阻塞，不用源码阅读冒充使用。',
      if (usageAssignment != null && documentFiles.isNotEmpty)
        '当前冻结文档候选：${jsonEncode(documentFiles)}。只允许使用列出的 DOCX/PDF。'
            '${usageCapabilities.contains('document.body') ? ' 文字检查：从 workspace.document(operation:"read",startChunk:0) 开始，按 nextChunkStart 读完本人责任范围的 totalChunkCount；不能用搜索片段当全文，也不能用正文提取判断版式。检查错字、标点、术语、编号、引用、歧义、重复和空泛表达；文案要具体清楚、适合读者，不删事实、引用、数字或明示要求，也不以 AI 来源检测分数验收。' : ''}'
            '${usageCapabilities.contains('document.visual') ? ' 视觉检查：使用本人模型实际收到每个指定文件的必要页图，逐页调用 workspace.document(operation:"render",page:N)，核对页码、总页数和渲染 manifest；缺页要补齐，不能用正文提取代替版式检查。检查遮挡、错位、截断、分页、跨页表格、图文关系和样式一致性。模型看不到图、必要页/渲染器/字体覆盖不完整时明确 blocked。' : ''}'
            '${usageCapabilities.contains('document.body') || usageCapabilities.contains('document.visual') ? ' report 写出全部发现，引用真实原文或页图证据，指出原句/页码/区域、影响和可执行修改；不确定的专有名词或渲染差异先核实，不制造问题。缺陷的 sourceLocation 仅使用解析器允许的 fileName、paragraph、lineStart、lineEnd、page、sheet 字段，具体原句和区域写在 report/defects 文本中。文档反馈额外包含 documentEvidence:{pageNumbers:[本人实际看过的页码],sourceLocations:[本人实际读到的原文位置]}，每个缺陷都要有本人观察到的 sourceLocation。制作人修订并发布新候选后，重新读取/渲染对应内容再复测，旧页图与收据失效。' : ''}',
      if (canUseBrowserContext)
        '当前场景可使用 browser.context。工具参数必须使用实际 schema：open 为 {"operation":"open"}；click 为 {"operation":"click","sessionRef":"原样复制返回值","label":"控件可访问名称"}；observe/close 仅含 operation 与 sessionRef；assert 为 {"operation":"assert","sessionRef":"原样复制返回值","acceptanceId":"当前验收ID","expectedText":"已确认的预期文字"}。每完成一项就立即 assert 并记录该项结果，然后进入下一项，不把聊天中自述“通过”当作断言，不反复从已完成用例起步。browserCurrentPage 是最近工具实测页面，历史正文和更早截图不能当作当前局面；没有新证据不要重开已完成用例。open 只打开当前冻结候选中唯一的 HTML；可选 queryParameters 仅用于方案已确认的可复现测试夹具（最多 8 项、键值有长度限制且拒绝敏感字段名），不能指定路径或 URL。返回的 sessionRef 必须原样用于后续 observe、click、assert、resize、close。浏览器在隔离的离线 WKWebView 中运行，不提供任意路径、URL 或脚本执行。当前没有键盘、输入框填值、悬停或拖拽操作；click 只按可见文字或可访问名称点控件。制作确定性测试入口时使用具名按钮或已确认 queryParameters，不能只提供键盘快捷键；每枚棋子使用可区分的可访问名称。每次操作后检查页面实际文字和截图；textTruncated 为 true 时不能用截断文本断言。每项验收的 expectedText 必须来自该项已确认的 expectedResult 或 method。软件游戏要实际操作并观察状态变化，覆盖掷骰、回合、起飞与移动、撞子回基地、终点胜负和重新开始；按钮存在、读源码、打开页面或命令退出码都不算完成。出现页面卡住、操作结果不确定或控制项不可用时先 observe/close 并如实报告，不能盲目重放或改用源码通过。',
      if ((_decodeMap(task.executionStateJson)['workItemExecution']
                  as Map?)?['stage'] ==
              'usage' &&
          WorkDiscussionState.fromExecutionState(task.executionStateJson)
              ?.collaboration
              ?.artifactContract['nativeBundle'] is Map)
        '当前场景绑定已冻结候选中的 macOS .app；仅可用 native.app 的 open、observe、act、close。模型不能提供 appPath、bundleId 或任意坐标。open 会返回本成员当前会话的 sessionRef；后续 observe、act、close 必须原样带回运行时返回的 sessionRef，运行时会核对它属于本成员、当前场景和冻结候选。act 只能引用最近一次本成员 observe 返回的 elementId。只有 expectedResult 或验收 method 中用引号明确写出的可见文本可以作为 native.app assert 的 expectedText；每项 acceptance 都要单独 assert，点击、控件树变化或尺寸变化只证明操作，不代表业务验收通过。每次输入前核对焦点，失焦后必须先 observe。完成本场景后 close；目标进程、Appium 会话和 WDA 清理未核实前不能提交反馈。测试数据环境 CHAT_GROUP_TEST_DATA_DIR 用于应用数据路径验证，不代表操作系统安全沙箱。',
      '角色可发现技能目录（全局技能按需加载；角色已绑定技能正文会注入；权限仍需通过角色授权与工具策略交集校验）：\n$skillCatalog',
      if (skillPreflight != null) skillPreflight,
      '当前生产 WorkAgentLoop 已注册工具：$tools。',
      '当前授权工作区绝对路径：$workspaceRoot。command.run 的 workingDirectory 为空时会自动解析为当前授权工作区；不要填写 "."，也禁止填写工作区外路径。workspace.list 省略 path 即表示该根目录，无需再拼接绝对路径，也不要为列目录改用 command.run。',
      if (targetsDesktop)
        '用户明确指定“桌面”：当前工作区已绑定到授权的桌面根目录；请直接使用相对文件名，不要再添加 Desktop/ 或 conversations/ 前缀。',
      if (task.plan.trim().isNotEmpty) '公开角色路由计划：${task.plan.trim()}',
      if (handoff != null &&
          !WorkTaskExecutionPolicy.isValidatedV2GroupTask(task))
        '当前接力阶段：${handoff.stageLabel}；交付物：${handoff.deliverables.join('、')}；完成标准：${handoff.completionCriteria.join('、')}。',
      if (!WorkTaskExecutionPolicy.isValidatedV2GroupTask(task) &&
          handoff?.lastSummary.trim().isNotEmpty == true)
        '上一阶段公开摘要：${handoff!.lastSummary}',
      _runtimeToolAvailabilityContext(),
      if (summary.isNotEmpty) '持久化任务上下文（公开摘要）：$summary',
    ].join('\n');
  }

  String _runtimeToolAvailabilityContext() {
    final pathEntries = (Platform.environment['PATH'] ?? '')
        .split(Platform.isWindows ? ';' : ':')
        .where((entry) => entry.trim().isNotEmpty);
    final available = <String>[];
    for (final executable in const ['pandoc', 'tectonic', 'pdflatex']) {
      final found = pathEntries.any((directory) {
        final names = Platform.isWindows
            ? <String>[executable, '$executable.exe']
            : <String>[executable];
        return names.any((name) {
          final candidate = File(
            '${directory.trim()}${Platform.pathSeparator}$name',
          );
          return FileSystemEntity.typeSync(candidate.path) ==
              FileSystemEntityType.file;
        });
      });
      if (found) available.add(executable);
    }
    if (available.isEmpty) {
      return '当前运行时未检测到 pandoc/tectonic/pdflatex；只有在 command.run 实际返回缺失工具后，才能说明工具缺失。';
    }
    final pdfHint = available.contains('pandoc') &&
            available.contains('tectonic') &&
            !available.contains('pdflatex')
        ? ' 未检测到 pdflatex，生成 PDF 时应使用 --pdf-engine=tectonic；应用也会在未显式指定引擎时自动修复。'
        : '';
    return '当前运行时已检测到可执行工具：${available.join('、')}。$pdfHint 持久化上下文中旧的“缺少工具”提示可能已过期；不得据此再次声称工具缺失，必须优先按原目标调用 command.run 并根据真实输出继续。';
  }

  String _compactSkillCatalogEntry(CharacterSkill skill) {
    final description =
        skill.description.trim().replaceAll(RegExp(r'\s+'), ' ');
    final clipped = description.length <= 180
        ? description
        : '${description.substring(0, 179)}…';
    return '- ${skill.id}｜${skill.domain}｜${skill.name}：$clipped'
        '${skill.resourcePackId == null ? '' : '（资源包 ${skill.resourcePackId}；首次使用先通过 skill.resource.read 读取 SKILL.md 和其引用资源）'}';
  }

  ExpertSkillTemplate? _matchingSkillTemplate(String request) {
    if (WorkRoleRouter.startsWithTestingStage(request)) return null;
    final recommendations = ExpertSkillCatalog.recommendForText(request);
    final template = recommendations.isEmpty ? null : recommendations.first;
    if (template == null ||
        template.id == 'general.workbuddy-expert-builder' ||
        template.domain != 'frontend') {
      return null;
    }
    return template;
  }

  AgentToolCall? _preflightSkillTool(
    AgentTask task,
    AICharacter character,
  ) {
    final template = _matchingSkillTemplate(
      WorkDiscussionState.currentRequestScope(task),
    );
    if (template == null) return null;
    final installed = database.characterSkillBox.values.any((skill) =>
        ExpertSkillCatalog.isInstalledTemplate(skill, template, character.id));
    if (installed) return null;
    return AgentToolCall(
      name: AgentToolName.skillDownload,
      arguments: {'templateId': template.id},
    );
  }

  List<CharacterSkill> _skillsFor(AICharacter character, String request,
      {String? taskId}) {
    final resolution = CharacterSkillResolver.resolveFor(character, request);
    final installed = database.characterSkillBox.values.where(
      (skill) =>
          (skill.resourcePackId == null &&
              (skill.isGlobal || skill.characterId == character.id)) ||
          character.skillIds.contains(skill.id),
    );
    final result = WorkModePolicy.resolveSkills(
      character: character,
      userRequest: request,
      installedSkills: installed,
      resolvedSkills: resolution.skills,
    );
    if (taskId != null) {
      final key = '$taskId:${character.id}';
      final presented = _presentedLocalDrafts.putIfAbsent(key, () => {});
      for (final skill in result) {
        if (!skill.isGlobal &&
            skill.characterId == character.id &&
            skill.resourcePackId == null &&
            !character.skillIds.contains(skill.id)) {
          presented[skill.id] = SkillResourcePackStore.draftFingerprint(skill);
        }
      }
    }
    return result;
  }

  Future<T> _serializeSkillMutation<T>(Future<T> Function() operation) {
    final previous = _skillMutationQueue;
    late final Future<T> scheduled;
    scheduled = previous.catchError((Object _) {}).then((_) => operation());
    _skillMutationQueue = scheduled.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return scheduled;
  }
}
