part of 'work_discussion_runner.dart';

/// 旧值到新值之间的"变更连接"。
///
/// 中文是变更动词（"改名为""改成"…），英语是 `to` / `into` / `as`。动词前只允许
/// 空白、引号、括号与"的文件名"这类结构性字词，于是
/// "game.html 文件名，不要改成 game2.html" 里的逗号会直接断开匹配——名称共现
/// 因此成不了改名授权。
const String _changeLinkSource = r'[\s"‘’“”()（）]*'
    r'(?:(?:的)?(?:文件名|名称|名字|路径|格式|输出|产物|文件|的))*'
    r'[\s"‘’“”()（）]*'
    r'(?:改名为|改名成|改名|改称|更名(?:为|成)?|重命名(?:为|成)?|改成|改为|换成|换为'
    r'|替换(?:为|成)|变为|变成|调整为|修改(?:为|成)|切换(?:为|成)|to|into|as)'
    r'[\s"‘’“”()（）]*';

/// 否定或"保持原样"的语义。它出现在变更连接里就不是改名授权（"不要改成
/// game2.html"）；紧贴在旧值之前也一样（"保持 game.html 文件名"，见
/// [_prohibitionAdjacentBefore]）。
final RegExp _userProhibition = RegExp(
    r'不要|不用|不需要|不必|不想|无需|无须|禁止|不得|不许|不能|不可|不准|请勿|勿'
    r'|不改名|不改|不换|不动|不重命名'
    r'|别改|别换|别动|别把|别重|别用|别再'
    r'|保持|维持|沿用|保留|不变|照旧|原样|依旧'
    r"|do not|don't|dont|never|not\b|no need|keep|retain|unchanged",
    caseSensitive: false);

/// 紧贴在旧值**之前**的否定（"保持 game.html 文件名"）。
///
/// 必须紧贴旧值，但允许“不要把 X”或“don't rename X”的结构性连接。
/// “在保持内容不变的前提下
/// 把 game.html 改名为 game2.html"里的"保持"管的是内容，与改名无关，放宽成
/// "旧值所在从句出现否定就拦"会把这类正常改名句整句挡下来。
final RegExp _prohibitionAdjacent = RegExp(
    r'(?:不要|不用|不需要|不必|不想|无需|无须|禁止|不得|不许|不能|不可|不准|请勿|勿'
    r'|不改名|不改|不换|不动|不重命名'
    r'|别改|别换|别动|别把|别重|别用|别再'
    r'|保持|维持|沿用|保留|不变|照旧|原样|依旧'
    r"|do not|don't|dont|never|not\b|no need|keep|retain|unchanged)"
    r'[\s"‘’“”()（）的]*(?:把|将|让|rename\b|change\b|convert\b|replace\b|switch\b|turn\b)?'
    r'[\s"‘’“”()（）的]*$',
    caseSensitive: false);

/// 把变更放进"要不要做"的评估框架，而不是下达变更指令。
///
/// 判据是变更所在**从句**里的疑问或讨论标记："先讨论把 game.html 改名为
/// game2.html 是否合适"里那句改名只是被讨论的提议，用户并没有授权改名。
final RegExp _evaluationFrame = RegExp(
    r'是否|吗|？|\?|合不合适|妥不妥|该不该|可行性|先讨论|讨论一下|讨论下|评估一下|商量|询问',
    caseSensitive: false);

/// 紧跟在目标值之后的否定（"…改成 game2.html 是不允许的"）。
///
/// 只认紧邻的"是/就/也/都/则 + 否定"：放宽成"目标之后出现否定就算"会把下一个
/// 从句里的"内容保持不变"也当成禁止改名，把正常的改名句挡下来。
final RegExp _userPostProhibition =
    RegExp(r'^[\s"‘’“”()（）]*(?:是|就|也|都|则)?[\s"‘’“”()（）]*'
        r'(?:不行|不可|不允许|不被允许|不该|不应该|不能|禁止)');

/// 汉字与日文假名的范围，用来决定词元该按哪套词字符收边。
final RegExp _cjkCharacter =
    RegExp(r'[\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff\u3040-\u30ff]');

extension _V2DiscussionActions on _V2DiscussionSession {
  Future<void> _consume(
      AICharacter member, WorkDiscussionV2Turn turn, String responseRef) async {
    for (final issue in turn.issues) {
      if (state.issues.any((i) =>
          i['id'] == issue['id'] ||
          i['kind'] == issue['kind'] &&
              i['target'] == issue['target'] &&
              (i['problem'] as String).trim() ==
                  (issue['problem'] as String).trim())) {
        throw StateError('问题 ID 重复');
      }
      final normalized = {
        ...issue,
        'sourceId': member.id,
        'status': 'open',
        'evidenceRef':
            issue['evidenceRef'] == '' ? responseRef : issue['evidenceRef'],
        'resolution': '',
        'resolutionRef': '',
        'requestRevision': state.requestRevision
      };
      if (!_knownRef(normalized['evidenceRef'] as String, responseRef)) {
        throw StateError('问题证据不存在');
      }
      await _commit('member', member.id, {
        'issues': [...state.issues, normalized],
        'verificationRevision': state.verificationRevision + 1
      });
    }
    if (turn.resolutions.isNotEmpty) {
      await _resolve(member, turn.resolutions, responseRef);
    }
    switch (turn.action) {
      case 'investigate':
        await _investigate(member, turn, responseRef);
      case 'propose':
        await _proposal(member, turn.proposal!, responseRef, turn.issueId);
      case 'approve':
        await _approve(member, turn.approval!, responseRef);
      case 'decide':
        final d = turn.decision!;
        await _decision(d['kind'] as String, d['targetId'] as String,
            d['reason'] as String, d['evidence'] as String,
            options: (d['options'] as List)
                .map((o) => Map<String, dynamic>.from(o as Map))
                .toList());
      default:
        break;
    }
  }

  bool _knownRef(String ref, String currentResponse) =>
      ref == currentResponse ||
      evidence.containsKey(ref) ||
      state.decisions.any((d) =>
          d['responseRef'] == ref &&
          {'answered', 'waived'}.contains(d['status'])) ||
      runner.database.messageBox.get(ref)?.groupId == task.groupId;

  Future<void> _resolve(AICharacter member,
      List<Map<String, dynamic>> resolutions, String responseRef) async {
    final updated =
        state.issues.map((i) => Map<String, dynamic>.from(i)).toList();
    for (final resolution in resolutions) {
      final issue = updated
          .where((i) => i['id'] == resolution['id'] && i['status'] == 'open')
          .firstOrNull;
      if (issue == null ||
          issue['kind'] == 'idea' ||
          !_knownRef(resolution['evidenceRef'] as String, responseRef)) {
        throw StateError('问题或依据无效');
      }
      // Code claims require a real read; an explanatory chat message cannot
      // substitute for a tool receipt on a code investigation.
      if ((issue['target'] == 'code' ||
              issue['kind'] == 'defect' &&
                  WorkRoleRouter.requestsSoftwareImplementation(
                      task.userRequest) ||
              (issue['evidenceRef'] as String).startsWith('investigation:')) &&
          !evidence.containsKey(resolution['evidenceRef'])) {
        throw StateError('代码判断需要实际工具结果');
      }
      issue.addAll({
        'status': 'resolved',
        'resolution': resolution['resolution'],
        'resolutionRef': resolution['evidenceRef']
      });
    }
    await _commit('memberResolution', member.id, {
      'issues': updated,
      'verificationRevision': state.verificationRevision + 1
    });
  }

  Future<void> _investigate(
      AICharacter member, WorkDiscussionV2Turn turn, String responseRef) async {
    final binding = WorkInvestigationBinding(
        taskId: task.id,
        memberId: member.id,
        issueId: turn.issueId,
        requestRevision: state.requestRevision,
        teamRevision: state.teamRevision);
    if (!binding.matches(task)) throw StateError('调查问题或版本无效');
    final investigate = runner.investigate;
    if (investigate == null) {
      await _decision('question', turn.issueId, '当前受控调查工具未接入，请补充环境。', '未运行工具。');
      return;
    }
    final result =
        await investigate(task, member, turn.tool!, binding, cancellation);
    if (cancellation.isCancelled || !binding.matches(task)) return;
    if (!result.result.succeeded ||
        result.result.data['rejected'] == true ||
        result.result.data['skipped'] == true) {
      await _decision('question', turn.issueId, result.result.message,
          '工具返回 ${result.result.status.name}，未得到可用于判断的证据。');
      return;
    }
    final ref = result.evidenceRef;
    if (ref.isEmpty) throw StateError('工具结果缺少真实凭据');
    evidence[ref] = {
      'memberId': member.id,
      'issueId': turn.issueId,
      'requestRevision': binding.requestRevision,
      'tool': turn.tool!.name.wireName,
      'arguments': turn.tool!.arguments,
      'result': result.result.data
    };
    await _attachDetail(
        {...evidence[ref]!, 'evidenceRef': ref}, responseRef, '调查来源与结果.json');
    if (evidence.length > WorkDiscussionRunner.maxMembers) {
      evidence.remove(evidence.keys.first);
    }
    await _commit('tool', member.id, {
      'issues': [
        for (final i in state.issues)
          i['id'] == turn.issueId ? {...i, 'evidenceRef': ref} : i
      ],
      'verificationRevision': state.verificationRevision + 1
    });
    await _rememberInvestigation(
        member, responseRef, ref, turn.tool!.name.wireName, turn.issueId);
    requestedSpeaker = member.id;
    if (result.stalled) {
      await _decision(
          'dispute', turn.issueId, '调查没有取得新的有效进展，请补充条件。', 'P2 进展保护已触发。');
    }
  }

  Future<void> _rememberInvestigation(AICharacter member, String messageId,
      String evidenceRef, String tool, String issueId) async {
    try {
      final message = runner.database.messageBox.get(messageId);
      if (message == null ||
          message.senderId != member.id ||
          cancellation.isCancelled) {
        return;
      }
      message.workMemoryEvidence = {
        'taskId': task.id,
        'scopeId': state.projectScopeId,
        'evidenceRef': evidenceRef,
        'tool': tool,
        'issueId': issueId,
        'requestRevision': state.requestRevision,
      };
      await runner.database.updateMessage(message);
      await ObservationEntry(db: runner.database).recordWorkExperience(message);
    } on Object {
      // A memory write cannot turn a successful investigation into failure.
    }
  }

  Future<void> _proposal(AICharacter member, Map<String, dynamic> proposal,
      String responseRef, String issueId) async {
    if (member.id != state.coordinatorId) throw StateError('仅协调成员收敛方案');
    _validateProposal(proposal);
    _validateContract(proposal);
    final idea = state.issues
        .where((i) =>
            i['id'] == issueId && i['kind'] == 'idea' && i['status'] == 'open')
        .firstOrNull;
    if (idea == null && _proposalUnchanged(proposal)) return;
    final acceptanceChanged = state.plan.isNotEmpty &&
            state.acceptances.isNotEmpty &&
            jsonEncode([
                  for (final a in state.acceptances)
                    {
                      'id': a['id'],
                      'method': a['method'],
                      'requiredCapability': a['requiredCapability']
                    }
                ]) !=
                jsonEncode(proposal['acceptances']) ||
        state.plan.isNotEmpty &&
            jsonEncode(state.artifactContract['verificationCommands']) !=
                jsonEncode((proposal['artifactContract']
                    as Map)['verificationCommands']);
    if (proposal['scope'] != state.scope || idea != null || acceptanceChanged) {
      if (idea == null) throw StateError('新增范围或验收修改必须关联完整提案并逐人确认');
      await _recordScopeProposal(proposal, responseRef, idea);
    } else {
      await _detail(proposal, responseRef);
      await _installProposal(proposal);
    }
  }

  bool _scopeConflicts(Map<String, dynamic> proposal) {
    final scope = proposal['scope'] as String;
    if (!scope.startsWith(state.scope)) return true;
    final extra = scope
        .substring(state.scope.length)
        .split(RegExp(r'[，,。；;\n]'))
        .where((clause) =>
            !RegExp(r'禁止|不得|不要|不允许|never|must not|do not', caseSensitive: false)
                .hasMatch(clause))
        .join(' ');
    final prohibited = RegExp(
            r'(?:禁止|不得|不要|不允许|never|must not|do not)\s*([^，,。；;\n]+)',
            caseSensitive: false)
        .allMatches(task.userRequest);
    return prohibited.any((m) {
      final subject = m
          .group(1)!
          .trim()
          .replaceFirst(
              RegExp(
                  r'^(?:先|直接)?(?:添加|增加|生成|实现|制作|写|做|使用|执行|进行|开发|安装|运行|add |create |use |run )',
                  caseSensitive: false),
              '')
          .trim();
      return subject.isNotEmpty && extra.contains(subject);
    });
  }

  Future<void> _recordScopeProposal(Map<String, dynamic> proposal,
      String responseRef, Map<String, dynamic> issue) async {
    // Conservatively ask the user around a prohibition; never let a model
    // reinterpret it or expand the actual tool permission set.
    if (_scopeConflicts(proposal)) {
      await _detail(proposal, responseRef);
      await _decision('dispute', issue['id'] as String, '提案涉及用户原范围或明确禁止事项，请裁决。',
          issue['problem'] as String,
          options: [
            {
              'id': 'reject-idea',
              'label': '不采用新范围，保留原要求',
              'impact': '禁止事项与工具授权保持原约束。'
            },
            {
              'id': 'revise-idea',
              'label': '改成不冲突的提案再讨论',
              'impact': '不采纳当前提案，重新逐人确认。'
            }
          ]);
      return;
    }
    final ref = _key('proposal', jsonEncode(proposal));
    if (issue['resolutionRef'] == ref &&
        issue['requestRevision'] == state.requestRevision) {
      return;
    }
    await _detail(proposal, responseRef);
    await _commit('coordinator', state.coordinatorId, {
      'issues': [
        for (final i in state.issues)
          i['id'] == issue['id']
              ? {
                  ...i,
                  'resolution': 'scope-proposal',
                  'resolutionRef': ref,
                  'requestRevision': state.requestRevision
                }
              : i
      ],
      'verificationRevision': state.verificationRevision + 1
    });
  }

  void _validateContract(Map<String, dynamic> proposal) {
    final contract =
        Map<String, dynamic>.from(proposal['artifactContract'] as Map);
    for (final key in state.artifactContract.keys) {
      final original = state.artifactContract[key];
      if (original is String &&
          original.isNotEmpty &&
          original != 'unspecified' &&
          original != 'generic' &&
          !_sameContractValue(key, original, contract[key])) {
        throw StateError('用户产物合同不可覆盖');
      }
    }
    if (state.artifactContract['type'] == 'document' &&
        contract['type'] != 'document') {
      throw StateError('文档任务不能转开发');
    }
  }

  /// 合同字段的等价判定。
  ///
  /// `type` 走统一词表：模型把 v1 的 `source` 抄成 v2 的 `software`（或反过来）
  /// 说的是同一个交付类型，不该被当成改动用户合同。
  bool _sameContractValue(String key, String pinned, Object? proposed) {
    if (proposed == pinned) return true;
    if (key != 'type' || proposed is! String) return false;
    return WorkRoleRouter.canonicalArtifactType(proposed) ==
        WorkRoleRouter.canonicalArtifactType(pinned);
  }

  /// 用户在自己的补充要求里点名改写的合同字段：`{字段: 用户点名的新值}`。
  ///
  /// 只认用户原话，而且必须是一句**变更**：旧值后面紧接变更动词，随后才是新值。
  /// 名称共现本身不是授权——"保持 game.html 文件名，不要改成 game2.html" 里两个
  /// 名称也都在，而它恰恰是用户禁止改名。提案里的新值还必须与用户点名的那一个完全
  /// 一致，模型不能借"用户授权"之名改合同——这条判据是 `_validateContract` 拒绝
  /// 模型擅改之外的唯一例外。
  Map<String, String> _userRewrittenContractFields(
      Map<String, dynamic> proposal) {
    final proposed = proposal['artifactContract'];
    if (proposed is! Map) return const {};
    final supplement = WorkDiscussionState.latestRequestScope(task);
    if (supplement.trim().isEmpty) return const {};
    final rewritten = <String, String>{};
    for (final key in const ['type', 'format', 'location']) {
      final pinned = state.artifactContract[key];
      final next = proposed[key];
      if (pinned is! String || next is! String) continue;
      if (pinned.isEmpty || pinned == 'unspecified' || pinned == 'generic') {
        continue;
      }
      if (_sameContractValue(key, pinned, next)) continue;
      if (!_statesChange(supplement,
          from: pinned, to: next, asFormat: key == 'format')) {
        continue;
      }
      rewritten[key] = next;
    }
    return rewritten;
  }

  /// 用户是否在 [text] 里**下达**了把 [from] 改成 [to] 的指令。
  ///
  /// 判据是"旧值 → 变更连接 → 新值"的相邻结构，不是两个名称同时出现：变更连接
  /// （见 [_changeLinkSource]）只允许夹着"的文件名"这类结构性字词，所以
  /// "game.html 文件名，不要改成 game2.html" 里的逗号直接断开匹配。三处否定都必须
  /// 弄清作用对象才算拦得住：连接自身带否定（"不要改成 X"）、旧值**紧邻**之前是
  /// "保持/不要"（见 [_prohibitionAdjacent]）、目标之后紧跟否定——每一处都只处理
  /// 与这次变更相邻的字词，不是整句扫一遍。最后，这次变更必须是指令而不是被讨论的
  /// 提议（见 [_evaluationFrame]）。[to] 还必须逐字出现在这句指令里：模型提案里的
  /// 新值只有被用户原话点名才算数，不能反过来由提案推定用户授权。
  bool _statesChange(String text,
      {required String from, required String to, required bool asFormat}) {
    final origins = _valueSpellings(from, asFormat: asFormat);
    final targets = _valueSpellings(to, asFormat: asFormat);
    if (origins.isEmpty || targets.isEmpty) return false;
    final lower = text.toLowerCase();
    final pattern = RegExp(
      '(?:${origins.map(_tokenSource).join('|')})'
      '($_changeLinkSource)'
      '(?:${targets.map(_tokenSource).join('|')})',
      unicode: true,
    );
    for (final match in pattern.allMatches(lower)) {
      if (_userProhibition.hasMatch(match.group(1)!)) continue;
      if (_prohibitionAdjacent.hasMatch(lower.substring(0, match.start))) {
        continue;
      }
      if (_userPostProhibition.hasMatch(_clauseAfter(lower, match.end))) {
        continue;
      }
      final clause = _clauseBefore(lower, match.start) +
          match.group(0)! +
          _clauseAfter(lower, match.end);
      if (_evaluationFrame.hasMatch(clause)) continue;
      return true;
    }
    return false;
  }

  /// 用户可能写出的该值拼写。
  ///
  /// 格式词按别名族展开（用户写 "Word"、合同写 `docx` 是同一个交付格式），
  /// 其余字段只有原值本身。
  List<String> _valueSpellings(String value, {required bool asFormat}) {
    final normalized = value.trim().toLowerCase();
    if (normalized.isEmpty) return const [];
    final spellings = <String>{normalized};
    if (asFormat) {
      final canonical = WorkArtifactDeliveryGuard.formatAliases[normalized];
      if (canonical != null) {
        spellings.addAll(WorkArtifactDeliveryGuard.formatAliases.entries
            .where((entry) => entry.value == canonical)
            .map((entry) => entry.key.trim().toLowerCase()));
      }
    }
    return spellings.toList();
  }

  /// 值的匹配源，两侧都要求独立成词。
  ///
  /// 拉丁词元只看 **ASCII** 词字符：中文里名称与汉字直接相邻是正常写法
  /// （"把game.html改名为game2.html"），把相邻汉字也算词字符会让这类句子永远
  /// 点不到名。CJK 词元仍按 Unicode 词字符收边，否则"软件"会点着"软件开发"。
  String _tokenSource(String token) {
    final normalized = token.trim().toLowerCase();
    final edge =
        _cjkCharacter.hasMatch(normalized) ? r'[\p{L}\p{N}_]' : r'[A-Za-z0-9_]';
    return '(?<!$edge)${RegExp.escape(normalized)}(?!$edge)';
  }

  /// [index] 之前、最近一个句读之后的文本。
  String _clauseBefore(String lower, int index) {
    final start =
        lower.substring(0, index).lastIndexOf(RegExp(r'[，,。；;！!？?：:\n]'));
    return lower.substring(start + 1, index);
  }

  /// [index] 之后、最近一个句读之前的文本。
  String _clauseAfter(String lower, int index) {
    final end = lower.substring(index).indexOf(RegExp(r'[，,。；;！!？?：:\n]'));
    return end < 0
        ? lower.substring(index)
        : lower.substring(index, index + end);
  }

  /// 由**用户身份**落盘用户明确改写的产物目标。
  ///
  /// 模型这次的提案仍然作废——它是照着旧合同写的；合同一改，需求版本随之递增，
  /// 旧工作项、验收与认可全部失效，必须由协调成员在新版本下重新形成方案。
  Future<bool> _adoptUserRewrittenContract(
      Map<String, dynamic> proposal) async {
    final rewritten = _userRewrittenContractFields(proposal);
    if (rewritten.isEmpty) return false;
    await _commit('user', 'user', {
      'artifactContract': <String, dynamic>{
        ...state.artifactContract,
        ...rewritten
      },
      'requestRevision': state.requestRevision + 1,
    });
    return true;
  }

  Future<void> _installProposal(Map<String, dynamic> proposal,
      {List<Map<String, dynamic>>? issues}) async {
    final request = state.requestRevision + 1;
    final verification = state.verificationRevision + 1;
    final userReview = _preservesUserReview(proposal);
    await _commit('coordinator', state.coordinatorId, {
      'scope': proposal['scope'],
      'plan': proposal['plan'],
      'artifactContract': proposal['artifactContract'],
      'workItems': _proposalWorkItems(proposal, userReview, request),
      'acceptances':
          _proposalAcceptances(proposal, userReview, request, verification),
      if (issues != null) 'issues': issues,
      'requestRevision': request,
      'verificationRevision': verification,
      'phase': 'clarifying'
    });
  }

  List<Map<String, dynamic>> _proposalWorkItems(
          Map<String, dynamic> proposal, bool userReview, int request) =>
      (proposal['workItems'] as List)
          .map((i) => {
                ...Map<String, dynamic>.from(i as Map),
                'status': userReview &&
                        state.workItems.any((old) =>
                            old['id'] == i['id'] &&
                            old['ownerId'] == i['ownerId'] &&
                            old['status'] == 'done')
                    ? 'done'
                    : 'pending',
                'requestRevision': request
              })
          .toList();

  List<Map<String, dynamic>> _proposalAcceptances(Map<String, dynamic> proposal,
          bool userReview, int request, int verification) =>
      (proposal['acceptances'] as List)
          .map((i) => {
                ...Map<String, dynamic>.from(i as Map),
                'status': userReview
                    ? (state.acceptances
                            .where((old) => old['id'] == i['id'])
                            .firstOrNull?['status'] ??
                        'pending')
                    : 'pending',
                'evidenceRef': userReview
                    ? (state.acceptances
                            .where((old) => old['id'] == i['id'])
                            .firstOrNull?['evidenceRef'] ??
                        '')
                    : '',
                'requestRevision': request,
                'verificationRevision': verification
              })
          .toList();

  bool _preservesUserReview(Map<String, dynamic> proposal) {
    return state.decisions.any((d) =>
            {'answered', 'waived'}.contains(d['status']) &&
            {'manual', 'waiver'}.contains(d['answerKind'])) &&
        jsonEncode(proposal['artifactContract']) ==
            jsonEncode(state.artifactContract) &&
        !state.acceptances.any((a) => a['status'] == 'failed') &&
        state.acceptances.any((a) =>
            {'manual', 'waived'}.contains(a['status']) &&
            a['requestRevision'] == state.requestRevision) &&
        jsonEncode([
              for (final a in proposal['acceptances'] as List)
                {
                  for (final key in ['id', 'method', 'requiredCapability'])
                    key: a[key]
                }
            ]) ==
            jsonEncode([
              for (final a in state.acceptances)
                {
                  for (final key in ['id', 'method', 'requiredCapability'])
                    key: a[key]
                }
            ]) &&
        jsonEncode([
              for (final i in proposal['workItems'] as List)
                {
                  for (final key in ['id', 'ownerId', 'kind', 'dependencies'])
                    key: i[key]
                }
            ]) ==
            jsonEncode([
              for (final i in state.workItems)
                {
                  for (final key in ['id', 'ownerId', 'kind', 'dependencies'])
                    key: i[key]
                }
            ]);
  }

  void _validateProposal(Map<String, dynamic> proposal) {
    final items = (proposal['workItems'] as List).cast<Map>();
    if (items.isEmpty || (proposal['acceptances'] as List).isEmpty) {
      throw StateError('方案缺少可执行工作项或验收');
    }
    final ids = items.map((i) => i['id']).toSet();
    if (ids.length != items.length ||
        items.any((i) =>
            !state.activeMembers.contains(i['ownerId']) ||
            i['dependencies'] is! List ||
            (i['dependencies'] as List)
                .any((d) => !ids.contains(d) || d == i['id']))) {
      throw StateError('工作项责任或依赖无效');
    }
    final resolved = <Object?>{};
    for (var pass = 0; pass < items.length; pass++) {
      resolved.addAll(items
          .where((i) => (i['dependencies'] as List).every(resolved.contains))
          .map((i) => i['id']));
    }
    if (resolved.length != items.length) {
      throw StateError('工作项依赖不能成环');
    }
  }

  bool _proposalUnchanged(Map<String, dynamic> proposal) {
    if (state.acceptances.any((a) => a['status'] == 'failed')) return false;
    if (state.workItems
            .any((i) => i['requestRevision'] != state.requestRevision) ||
        state.acceptances
            .any((i) => i['requestRevision'] != state.requestRevision)) {
      return false;
    }
    bool same(Object? a, Object? b) {
      if (a is Map && b is Map) {
        return a.length == b.length &&
            a.keys.every((k) => b.containsKey(k) && same(a[k], b[k]));
      }
      if (a is List && b is List) {
        return a.length == b.length &&
            List.generate(a.length, (i) => same(a[i], b[i])).every((v) => v);
      }
      return a == b;
    }

    return same(proposal, {
      'scope': state.scope,
      'plan': state.plan,
      'artifactContract': state.artifactContract,
      'workItems': [
        for (final i in state.workItems)
          {
            'id': i['id'],
            'ownerId': i['ownerId'],
            'dependencies': i['dependencies']
          }
      ],
      'acceptances': [
        for (final i in state.acceptances)
          {
            'id': i['id'],
            'method': i['method'],
            'requiredCapability': i['requiredCapability']
          }
      ]
    });
  }

  Future<void> _detail(Map<String, dynamic> proposal, String responseRef) =>
      _attachDetail(proposal, responseRef, '方案与验收详情.json');
}
