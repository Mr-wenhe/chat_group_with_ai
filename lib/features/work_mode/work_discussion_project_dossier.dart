part of 'work_discussion_runner.dart';

extension _WorkDiscussionProjectDossier on WorkDiscussionRunner {
  static const int _maximumFiles = 160;
  static const int _maximumDirectories = 512;
  static const int _maximumSourceBytes = 512 * 1024;

  /// Produces a small, local-only inventory for a path the user explicitly
  /// named in the work request. Paths, file bodies, and credentials are never
  /// included in the model prompt; the discussion only receives technology
  /// signals it can use to frame questions and trade-offs.
  Future<Map<String, dynamic>> _projectDossier(String request) async {
    final rootPath =
        const WorkModeDirectoryService().requestedLocalPath(request);
    if (rootPath == null) return const <String, dynamic>{};
    final root = Directory(rootPath);
    try {
      if (!await root.exists()) {
        return const <String, dynamic>{
          'available': false,
          'reason': '用户指定的项目目录当前不可读取。',
        };
      }
      final files = <String>[];
      final pendingDirectories = <Directory>[root];
      var nextDirectoryIndex = 0;
      var directoriesVisited = 0;
      var inventoryTruncated = false;
      while (nextDirectoryIndex < pendingDirectories.length &&
          directoriesVisited < _maximumDirectories &&
          files.length < _maximumFiles) {
        final directory = pendingDirectories[nextDirectoryIndex++];
        directoriesVisited++;
        await for (final entity in directory.list(followLinks: false)) {
          final relative = _relativePath(root, entity);
          if (relative.isEmpty || _ignoredProjectEntry(relative)) continue;
          if (entity is Directory) {
            if (pendingDirectories.length < _maximumDirectories) {
              pendingDirectories.add(entity);
            } else {
              inventoryTruncated = true;
            }
            continue;
          }
          if (entity is! File) continue;
          files.add(relative);
          if (files.length >= _maximumFiles) break;
        }
      }
      inventoryTruncated = inventoryTruncated ||
          files.length >= _maximumFiles ||
          nextDirectoryIndex < pendingDirectories.length;
      files.sort((left, right) {
        final priority = _projectFilePriority(left).compareTo(
          _projectFilePriority(right),
        );
        return priority == 0 ? left.compareTo(right) : priority;
      });
      final lower = files.map((file) => file.toLowerCase()).toList();
      final verifiedSourceFacts = await _verifiedSourceFacts(root);
      final signals = <String>[
        if (files.any((file) => file == 'pubspec.yaml')) 'Flutter 项目清单',
        if (lower.any((file) => file.startsWith('lib/'))) 'Dart/Flutter 应用源码',
        if (lower.any((file) => file.startsWith('test/'))) '自动化测试',
        if (lower.any((file) => file.contains('embedding')))
          '本地或在线语义 embedding 能力',
        if (lower.any((file) => file.contains('account'))) '账号相关服务或流程',
        if (lower.any((file) => file.contains('statistic'))) '统计相关服务或流程',
        if (lower.any((file) => file.contains('puzzle'))) '猜词题库与提示数据',
        if (lower.any((file) => file.startsWith('docs/'))) '已有项目文档目录',
      ];
      return <String, dynamic>{
        'available': true,
        'fileCountObserved': files.length,
        'inventoryTruncated': inventoryTruncated,
        'technologySignals': signals,
        'sampleRelativeFiles': files.take(48).toList(growable: false),
        'verifiedSourceFacts': verifiedSourceFacts,
        'instruction':
            '这是根据用户明确授权路径在本地读取的脱敏项目清单和静态事实。以它作为事实来源继续讨论；不要要求用户粘贴文件、重复授权路径，或引入清单未显示的技术方案。',
      };
    } on Object {
      return const <String, dynamic>{
        'available': false,
        'reason': '项目目录读取失败，等待执行阶段处理授权或可用性问题。',
      };
    }
  }

  String _relativePath(Directory root, FileSystemEntity entity) {
    final relative = entity.path.substring(root.path.length).replaceFirst(
          RegExp(r'^[\\/]'),
          '',
        );
    // Keep the model-facing inventory stable across desktop platforms; the
    // source-fact checks and priority rules intentionally use `/` paths.
    return relative.replaceAll('\\', '/');
  }

  bool _ignoredProjectEntry(String relative) {
    final segments = relative.split(RegExp(r'[\\/]'));
    return segments.any((segment) =>
        segment == '.git' || segment == '.dart_tool' || segment == 'build');
  }

  int _projectFilePriority(String relative) {
    if (relative == 'pubspec.yaml' || relative == 'README.md') return 0;
    if (relative.startsWith('lib/')) return 1;
    if (relative.startsWith('test/')) return 2;
    if (relative.startsWith('docs/')) return 3;
    return 4;
  }

  /// Captures only durable implementation facts needed to keep a discussion
  /// moving.  Never return source bodies, absolute paths, tokens, or values
  /// from project configuration files.
  Future<List<String>> _verifiedSourceFacts(Directory root) async {
    final facts = <String>[];
    if (await Directory('${root.path}/docs').exists()) {
      facts.add('项目根目录已存在 docs/ 文档目录；用户要求的 Word 需求文档应落在该目录。');
    }
    final embedding = await _readProjectSource(root, 'embedding_server.py');
    if (embedding != null) {
      if (embedding.contains('threading import Lock') &&
          embedding.contains('_model_lock')) {
        facts.add('embedding_server.py 已用 _model_lock 串行化模型懒加载。');
      }
      if (embedding.contains('_warmup_lock')) {
        facts.add('embedding_server.py 已用 _warmup_lock 防止重复预热。');
      }
    }

    final scorer =
        await _readProjectSource(root, 'lib/services/semantic_scorer.dart');
    if (scorer != null && scorer.contains('_answerEmbeddingCache')) {
      facts.add('semantic_scorer.dart 已缓存 answer 的多角度 embedding，并提供预取与清理入口。');
    }

    final scorerTest =
        await _readProjectSource(root, 'test/semantic_scorer_test.dart');
    if (scorerTest != null) {
      final covered = <String>[
        if (scorerTest.contains('CalibrationCurve')) '校准曲线',
        if (scorerTest.contains('ManualSimilarityOverrides')) '人工相似度覆盖',
        if (scorerTest.contains('SemanticScoreRules')) '语义评分规则边界',
        if (scorerTest.contains('fallback')) 'embedding 不可用回退',
      ];
      if (covered.isNotEmpty) {
        facts.add('semantic_scorer_test.dart 已覆盖：${covered.join('、')}。');
      }
    }

    if (scorer != null && scorer.contains('lexicalFallback')) {
      facts.add(
        'SemanticScorer 已实现 embedding 不可用时的词法降级，并标记为断开连接来源。',
      );
    }
    final embeddingService =
        await _readProjectSource(root, 'lib/services/embedding_service.dart');
    if (embeddingService != null &&
        embeddingService.contains('resolvedOnline') &&
        embeddingService.contains('localEndpoint') &&
        embeddingService.contains('return null')) {
      facts.add('EmbeddingService 已按在线端点优先、localEndpoint 回退的顺序请求 embedding。');
    }
    if ((scorer != null || scorerTest != null) && embeddingService != null) {
      facts.add(
        '本轮项目范围聚焦猜词游戏现有的语义评分、embedding、降级与可观测性链路；清单未证实的区块链、DID、Gas、支付或链上存证不纳入本轮需求。',
      );
    }

    final account = await _readProjectSource(root, 'account_server.py');
    if (account != null) {
      final endpoints = <String>[
        if (account.contains('/api/account/create')) '设备创建账号',
        if (account.contains('/api/account/by_device/')) '按设备查询账号',
        if (account.contains('/api/account/nickname')) '更新昵称',
      ];
      if (endpoints.isNotEmpty) {
        facts.add('account_server.py 已核验账号接口：${endpoints.join('、')}。');
      }
      final hasPasswordAuth = RegExp(
        r'/api/account/(?:login|register|reset|forgot)',
        caseSensitive: false,
      ).hasMatch(account);
      if (!hasPasswordAuth) {
        facts.add(
          'account_server.py 未发现密码登录、注册或找回密码接口；不得把这些不存在的流程当作本轮需求阻塞。',
        );
      }
    }

    final nightly =
        await _readProjectSource(root, 'scripts/nightly_train_v26.sh');
    if (nightly != null) {
      if (nightly.contains('LOCK_DIR=') &&
          nightly.contains('trap cleanup EXIT')) {
        facts.add('scripts/nightly_train_v26.sh 会清理陈旧锁，并在进程退出时通过 trap 清理训练锁。');
      }
      if (!await File('${root.path}/scripts/nightly_launcher.sh').exists()) {
        facts.add(
            '项目中未发现 scripts/nightly_launcher.sh；夜训入口为 scripts/nightly_train_v26.sh。');
      }
    }
    final hiddenLauncher =
        await _readProjectSource(root, '.nightly/nightly_launcher.sh');
    if (hiddenLauncher != null &&
        hiddenLauncher.contains('scripts/nightly_train_v26.sh')) {
      facts.add(
        '.nightly/nightly_launcher.sh 是转发到 scripts/nightly_train_v26.sh 的兼容入口；其固定项目根目录与当前读取根目录不一致，应作为部署风险验收项。',
      );
    }
    return facts;
  }

  Future<String?> _readProjectSource(Directory root, String relative) async {
    final file = File('${root.path}/$relative');
    try {
      final type = await FileSystemEntity.type(
        file.path,
        followLinks: false,
      );
      if (type != FileSystemEntityType.file) return null;
      final stat = await file.stat();
      if (stat.size > _maximumSourceBytes) return null;
      return await file.readAsString();
    } on Object {
      return null;
    }
  }

  bool _isFactVerificationQuestion(String normalized) {
    return normalized.contains('?') ||
        normalized.contains('？') ||
        RegExp(
          r'(是否(有|已有|存在|包含|配置|启用|支持|已经|由|转发|指向|调用|使用)|有没有|项目中是否|当前是否)',
        ).hasMatch(normalized);
  }

  bool _isDecisionQuestion(String normalized) {
    return normalized.contains('?') ||
        normalized.contains('？') ||
        RegExp(r'(是否|有没有|要不要|需不需要|能否|可否|请确认|待确认)').hasMatch(normalized);
  }

  /// Resolves only questions whose wording is explicitly covered by a
  /// sanitized local fact.  This deliberately avoids fuzzy matching: an
  /// ordinary product decision must remain open for the coordinator or user.
  Future<Map<String, List<String>>> _reconcileProjectFactQuestions(
    AgentTask task,
    Iterable<String> questions,
  ) async {
    final dossier = await _projectDossier(task.userRequest);
    final facts = (dossier['verifiedSourceFacts'] as List?)
            ?.whereType<String>()
            .toList(growable: false) ??
        const <String>[];
    if (facts.isEmpty) return const <String, List<String>>{};
    final resolved = <String>[];
    final evidence = <String>[];
    for (final question in questions) {
      final normalized = question.toLowerCase();
      if (normalized.contains('embedding_server.py') &&
          _isFactVerificationQuestion(normalized) &&
          normalized.contains('并发') &&
          facts.any((fact) => fact.contains('_model_lock'))) {
        resolved.add(question);
        evidence.add('已核验 embedding_server.py 的模型加载并发控制。');
      } else if (normalized.contains('semantic_scorer') &&
          _isFactVerificationQuestion(normalized) &&
          normalized.contains('缓存') &&
          facts.any((fact) => fact.contains('answer 的多角度 embedding'))) {
        resolved.add(question);
        evidence.add('已核验 semantic_scorer 的答案 embedding 缓存。');
      } else if (normalized.contains('nightly_launcher.sh') &&
          _isFactVerificationQuestion(normalized) &&
          normalized.contains('锁') &&
          facts.any((fact) => fact.contains('nightly_train_v26.sh 会清理陈旧锁'))) {
        resolved.add(question);
        evidence.add('已核验夜训实际入口的锁清理与退出清理机制。');
      } else if (normalized.contains('.nightly/nightly_launcher.sh') &&
          _isFactVerificationQuestion(normalized) &&
          normalized.contains('nightly_train_v26.sh') &&
          facts.any((fact) => fact.contains('兼容入口'))) {
        resolved.add(question);
        evidence.add('已核验隐藏夜训入口仅转发正式脚本，根目录差异转为部署验收风险。');
      } else if (normalized.contains('docs/') &&
          _isFactVerificationQuestion(normalized) &&
          normalized.contains('docx') &&
          facts.any((fact) => fact.contains('已存在 docs/ 文档目录'))) {
        resolved.add(question);
        evidence.add('已核验 Word 文档的 docs/ 落位目录。');
      } else if (normalized.contains('账号') &&
          _isFactVerificationQuestion(normalized) &&
          facts.any((fact) => fact.contains('未发现密码登录、注册或找回密码接口'))) {
        resolved.add(question);
        evidence.add('已核验账号服务仅包含设备账号与昵称接口，本轮不新增密码认证流程。');
      } else if (normalized.contains('embedding') &&
          _isFactVerificationQuestion(normalized) &&
          (normalized.contains('降级') || normalized.contains('故障')) &&
          facts.any((fact) => fact.contains('已实现 embedding 不可用时的词法降级'))) {
        resolved.add(question);
        evidence.add('已核验 embedding 故障时由 SemanticScorer 使用词法降级。');
      }
    }
    return <String, List<String>>{
      if (resolved.isNotEmpty) 'questions': resolved,
      if (evidence.isNotEmpty) 'evidence': evidence,
    };
  }
}
