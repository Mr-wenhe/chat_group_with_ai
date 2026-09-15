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
    if (enforceRevision && revision != null) {
      final absoluteRevision = _isAbsolutePath(revision)
          ? revision
          : '${workspaceRoot.replaceAll('\\', '/')}/$revision';
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

  bool _isAbsolutePath(String value) {
    final path = value.trim();
    return path.startsWith('/') ||
        path.startsWith('\\') ||
        RegExp(r'^[A-Za-z]:[\\/]').hasMatch(path);
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
    return AgentAttachmentContext.buildHistory(
      messages: messages.length <= 24
          ? messages
          : messages.sublist(messages.length - 24),
      currentUserRequest: task.userRequest,
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
      userRequest: task.userRequest,
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
      {required String workspaceRoot}) {
    final base = WorkModePolicy.planningContext(character);
    final discoverable = WorkModePolicy.discoverableSkills(
      character: character,
      installedSkills: database.characterSkillBox.values,
      resolvedSkills: CharacterSkillResolver.resolveFor(
        character,
        task.userRequest,
      ).skills,
    );
    final skillCatalog = discoverable.isEmpty
        ? '无（需要时可通过 meta.find-skills 查找或安装）'
        : discoverable.map(_compactSkillCatalogEntry).join('\n');
    final tools = registry.definitions
        .map((definition) =>
            '${definition.name.wireName}(${definition.access.name})')
        .join('、');
    final summary = task.contextSummary.trim();
    final handoff = WorkHandoffState.fromTask(task);
    final targetsDesktop =
        WorkModeDirectoryService.requestTargetsDesktop(task.userRequest);
    return [
      base,
      '角色可发现技能目录（全局技能按需加载；角色已绑定技能正文会注入；权限仍需通过角色授权与工具策略交集校验）：\n$skillCatalog',
      '当前生产 WorkAgentLoop 已注册工具：$tools。',
      '当前授权工作区绝对路径：$workspaceRoot。command.run 的 workingDirectory 为空时会自动解析为当前授权工作区；不要填写 "."，也禁止填写工作区外路径。',
      if (targetsDesktop)
        '用户明确指定“桌面”：当前工作区已绑定到授权的桌面根目录；请直接使用相对文件名，不要再添加 Desktop/ 或 conversations/ 前缀。',
      if (task.plan.trim().isNotEmpty) '公开角色路由计划：${task.plan.trim()}',
      if (handoff != null)
        '当前接力阶段：${handoff.stageLabel}；交付物：${handoff.deliverables.join('、')}；完成标准：${handoff.completionCriteria.join('、')}。',
      if (handoff?.lastSummary.trim().isNotEmpty == true)
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
    return '- ${skill.id}｜${skill.domain}｜${skill.name}：$clipped';
  }

  List<CharacterSkill> _skillsFor(AICharacter character, String request) {
    final resolution = CharacterSkillResolver.resolveFor(character, request);
    final installed = database.characterSkillBox.values.where(
      (skill) =>
          skill.isGlobal ||
          skill.characterId == character.id ||
          character.skillIds.contains(skill.id),
    );
    return WorkModePolicy.resolveSkills(
      character: character,
      userRequest: request,
      installedSkills: installed,
      resolvedSkills: resolution.skills,
    );
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
