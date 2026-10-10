part of 'work_discussion_v2_test.dart';

void _registerDiscussionHistoryRegressions() {
  test('认可阶段的聚焦提示把协议标识与公开文本分开', () async {
    var checked = false;
    await modelRunner((member, context) async {
      final focus = context['turnFocus'] as Map;
      if (focus['stage'] == 'reviewApproval') {
        checked = true;
        final objective = focus['objective'] as String;
        expect(objective, contains('approvalIdentifiers 只用于 approval'));
        expect(objective, contains('public_update'));
        expect(objective, contains('不出现 artifactContract'));
        expect(objective, contains('①②③④ 式清单'));
        expect(objective, contains('写进 issues'));
        expect(focus['approvalIdentifiers'], isNotNull);
      }
      return confirm(member, context);
    }).runCollaboration(task, WorkTaskCancellation(), apply);
    expect(checked, isTrue);
  });

  test('v2 协议把内部标识符与编号清单挡在公开正文外', () {
    expect(WorkDiscussionV2Turn.protocol, contains('不出现 artifactContract'));
    expect(WorkDiscussionV2Turn.protocol, contains('①②③④ 式清单'));
    expect(WorkDiscussionV2Turn.protocol, contains('协议标识'));
  });

  test('协议可从前置说明中读取唯一 JSON 对象，仍拒绝尾随正文', () {
    final response = _turn('respond');
    final json = response['message'] as String;
    response['message'] = 'I reviewed the proposal first.\n\n$json';
    expect(WorkDiscussionV2Turn.parse(response), isNotNull);

    response['message'] = '$json\nExtra text after the object.';
    expect(WorkDiscussionV2Turn.parse(response), isNull);
  });

  test('协议前置说明最多容错 256 字符', () {
    final response = _turn('respond');
    final json = response['message'] as String;
    response['message'] = '${'x' * 256}$json';
    expect(WorkDiscussionV2Turn.parse(response), isNotNull);

    response['message'] = '${'x' * 257}$json';
    expect(WorkDiscussionV2Turn.parse(response), isNull);

    response['message'] = '说明 {placeholder}：$json';
    expect(WorkDiscussionV2Turn.parse(response), isNotNull);
  });

  test('协议快速拒绝字符上限内含大量花括号的畸形前置响应', () {
    final response = {
      'success': true,
      'message': '说明：${'{' * (48 * 1024 - 3)}',
    };
    final watch = Stopwatch()..start();
    final parsed = WorkDiscussionV2Turn.parse(response);
    watch.stop();

    expect(parsed, isNull);
    expect(watch.elapsedMilliseconds, lessThan(1000),
        reason: '同步解析不能因每个左花括号重新扫描剩余正文而卡住 UI。');
  });

  test('历史提案含非法合同字段时转成可裁决的修订问题', () async {
    await modelRunner(confirm)
        .runCollaboration(task, WorkTaskCancellation(), apply);
    final discussion = WorkDiscussionState.fromExecutionState(
      task.executionStateJson,
    )!;
    final current = discussion.collaboration!;
    final storedProposal = proposal(current.toJson());
    storedProposal['artifactContract'] = {
      ...current.artifactContract,
      'outputDir': '/tmp/legacy-output'
    };
    final serialized = jsonEncode(storedProposal);
    final digest =
        sha256.convert(utf8.encode(serialized)).toString().substring(0, 24);
    await events.writeDiscussionDetail(task.id, digest, serialized);
    final reference = 'proposal:$digest';
    const issueId = 'legacy-contract-proposal';
    final raw = current.toJson()
      ..['revision'] = current.revision + 1
      ..['issues'] = [
        ...current.issues,
        {
          'id': issueId,
          'sourceId': 'dev',
          'kind': 'idea',
          'status': 'open',
          'target': 'scope',
          'problem': '历史提案合同包含未知字段',
          'evidenceRef': 'proposal-evidence',
          'resolution': 'scope-proposal',
          'resolutionRef': reference,
          'retestCondition': '重新生成合法合同并审批',
          'requestRevision': current.requestRevision
        }
      ]
      ..['approvals'] = [
        ...current.approvals,
        for (final memberId in current.activeMembers)
          {
            'eventId': 'legacy-idea-$memberId',
            'memberId': memberId,
            'kind': 'idea',
            'subjectId': issueId,
            'requestRevision': current.requestRevision,
            'teamRevision': current.teamRevision,
            'iterationId': '',
            'artifactDigest': '',
            'verificationRevision': current.verificationRevision,
            'approved': true,
            'evidenceRef': 'legacy-vote-$memberId',
            'source': 'memberModel'
          }
      ]
      ..['decisions'] = [
        ...current.decisions,
        {
          'id': 'legacy-adopt-decision',
          'revision': 1,
          'status': 'answered',
          'reason': '采用历史提案',
          'answer': '采用这份提案',
          'impact': '按完整提案更新方案',
          'responseRef': 'legacy-user-answer',
          'evidence': '全员认可历史提案',
          'options': [
            {'id': 'adopt:$reference', 'label': '采用这份提案', 'impact': '采用已存提案'}
          ],
          'targetId': issueId,
          'kind': 'dispute',
          'answerKind': 'choice'
        }
      ];
    final next = WorkCollaborationState.tryParse(raw);
    expect(next, isNotNull);
    task.executionStateJson = WorkDiscussionState.mergeIntoExecutionState(
      task.executionStateJson,
      discussion.copyWith(collaboration: next),
      expectedCollaborationRevision: current.revision,
    );

    var memberCalls = 0;
    await modelRunner((member, context) async {
      memberCalls++;
      return confirm(member, context);
    }).runCollaboration(task, WorkTaskCancellation(), apply);

    final updated = WorkDiscussionState.fromExecutionState(
      task.executionStateJson,
    )!
        .collaboration!;
    expect(memberCalls, 0);
    expect(updated.plan, current.plan);
    expect(
      updated.issues
          .singleWhere((issue) => issue['id'] == issueId)['resolutionRef'],
      reference,
    );
    final decision = updated.decisions.singleWhere((item) =>
        item['kind'] == 'dispute' &&
        item['targetId'] == issueId &&
        item['status'] == 'pending');
    expect(
      (decision['options'] as List)
          .whereType<Map>()
          .map((option) => option['id']),
      contains('revise-idea'),
    );
  });

  test('认可回执缺版本整数时报告具体字段路径', () {
    final approval = <String, dynamic>{
      'kind': 'idea',
      'subjectId': 'ISS-VC-01',
      'approved': true,
      'requestRevision': 2,
      'teamRevision': 1,
    };
    String? reason;
    expect(
        WorkDiscussionV2Turn.parse(_turn('approve', approval: approval),
            onInvalid: (value) => reason = value),
        isNull);
    expect(reason, contains('verificationRevision'));
    expect(WorkDiscussionV2Turn.protocol, contains('六个字段'));
    expect(WorkDiscussionV2Turn.protocol, contains('JSON 整数'));
  });

  test('verificationCommands 要求 command.run 的紧凑 JSON 字符串', () {
    final command = jsonEncode({
      'executable': 'node',
      'arguments': ['verify.js']
    });
    final proposal = {
      'scope': '实现并验证计数器',
      'plan': 'Node 环境运行 verify.js。',
      'artifactContract': {
        'type': 'software',
        'format': 'html',
        'location': '/tmp/game.html',
        'revisionTarget': 'game.html',
        'files': ['game.html', 'verify.js'],
        'verificationCommands': [
          {
            'executable': 'node',
            'arguments': ['verify.js']
          }
        ],
      },
      'workItems': [
        {
          'id': 'implementation',
          'ownerId': 'dev',
          'dependencies': <String>[],
          'kind': 'produce'
        }
      ],
      'acceptances': [
        {
          'id': 'AC-01',
          'method': '打开文件并观察初始值',
          'requiredCapability': 'workspaceRead'
        }
      ],
    };
    String? reason;
    expect(
        WorkDiscussionV2Turn.parse(_turn('propose', proposal: proposal),
            onInvalid: (value) => reason = value),
        isNull);
    expect(reason, contains('verificationCommands'));
    expect(WorkDiscussionV2Turn.protocol, contains('紧凑 JSON 参数字符串'));
    expect(WorkDiscussionV2Turn.protocol, contains('相对路径字符串'));

    proposal['artifactContract'] = {
      ...proposal['artifactContract'] as Map<String, dynamic>,
      'verificationCommands': [command],
    };
    proposal['workItems'] = [
      {
        'id': 'implementation',
        'ownerId': 'dev',
        'dependencies': <String>[],
        'kind': 'produce',
        'description': 'extra field rejected by state storage'
      }
    ];
    reason = null;
    expect(
        WorkDiscussionV2Turn.parse(_turn('propose', proposal: proposal),
            onInvalid: (value) => reason = value),
        isNull);
    expect(reason, contains('proposal.workItems'));

    proposal['workItems'] = [
      {
        'id': 'implementation',
        'ownerId': 'dev',
        'dependencies': <String>[],
        'kind': 'produce'
      }
    ];
    expect(WorkDiscussionV2Turn.parse(_turn('propose', proposal: proposal)),
        isNotNull);
  });

  test('公开正文的编号清单被计数，正常句子不算', () {
    expect(WorkPublicUpdateStream.listMarkerCount('①甲 ②乙 ③丙'), 3);
    expect(WorkPublicUpdateStream.listMarkerCount('我认可当前方案，按钮要防重复。'), 0);
  });

  test('编号清单判据只认两处以上的行首编号', () {
    expect(
        WorkPublicUpdateStream.looksLikeNumberedList(
            '前端最终确认：\n1. 布局标签：simplified variant\n2. 三项默认值：全部接受'),
        isTrue);
    expect(WorkPublicUpdateStream.looksLikeNumberedList('①甲 ②乙 ③丙'), isTrue);
    expect(
        WorkPublicUpdateStream.looksLikeNumberedList('我认可当前方案，按钮要防重复。'),
        isFalse);
    // 单处编号只是正常引用，不构成清单体。
    expect(
        WorkPublicUpdateStream.looksLikeNumberedList('按第 1. 条口径执行即可。'),
        isFalse);
  });

  test('重写公开正文只换气泡文本，立场与认可字段原样保留', () {
    final turn = WorkDiscussionV2Turn.parse(_turn('approve',
        text: '1. 已确认范围\n2. 已确认默认值',
        approval: {
          'kind': 'plan',
          'subjectId': 'task-1',
          'approved': true,
          'requestRevision': 1,
          'teamRevision': 1,
          'verificationRevision': 1
        }))!;
    expect(
        WorkPublicUpdateStream.looksLikeNumberedList(turn.publicUpdateFull),
        isTrue,
        reason: '用例前提：这条正文确实会被判成清单体');

    final rewritten = turn.withPublicUpdate('我认可当前方案，按钮要防重复。');

    expect(rewritten.publicUpdate, '我认可当前方案，按钮要防重复。');
    expect(rewritten.publicUpdateFull, '我认可当前方案，按钮要防重复。');
    // 文风重写不能顺手改掉成员的立场：其余字段逐个比对。
    expect(rewritten.action, turn.action);
    expect(rewritten.approval, turn.approval);
    expect(rewritten.issueId, turn.issueId);
    expect(rewritten.nextMemberId, turn.nextMemberId);
    expect(rewritten.issues, turn.issues);
    expect(rewritten.resolutions, turn.resolutions);
    expect(rewritten.decision, turn.decision);
    expect(rewritten.tool, turn.tool);
  });

  test('重写结果超过气泡目标时按同一目标截断，完整正文留在完整字段', () {
    final turn = WorkDiscussionV2Turn.parse(_turn('respond'))!;
    final long = '我确认当前方案，按钮要防重复。' * 40;
    final rewritten = turn.withPublicUpdate(long);

    expect(rewritten.publicUpdate, contains('已截断'));
    expect(rewritten.publicUpdate.length,
        lessThanOrEqualTo(WorkPublicUpdateStream.bubbleTargetCharacters));
    expect(rewritten.publicUpdateFull, long,
        reason: '截的是气泡不是内容：完整正文仍交给详情附件');
  });

  test('重写结果带代码围栏时剥掉围栏，行内反引号不动', () {
    expect(WorkPublicUpdateStream.stripCodeFence('```\n我认可当前方案。\n```'),
        '我认可当前方案。');
    expect(
        WorkPublicUpdateStream.stripCodeFence('```text\n我认可当前方案。\n```'),
        '我认可当前方案。');
    expect(WorkPublicUpdateStream.stripCodeFence('我认可当前方案。'), '我认可当前方案。');
    // 只有开头没有结尾：仍然按围栏剥，正文不整段作废。
    expect(WorkPublicUpdateStream.stripCodeFence('```\n我认可当前方案。'),
        '我认可当前方案。');
    expect(WorkPublicUpdateStream.stripCodeFence('用 `game.html` 这个名字即可。'),
        '用 `game.html` 这个名字即可。');
  });

  test('重写结果被围栏包裹时气泡里不出现反引号', () async {
    var listTurnServed = false;
    await modelRunner((member, context) async {
      if (context.containsKey('rewriteTarget')) {
        return {
          'success': true,
          'message': '```\n已确认范围与默认值，我认可当前方案。\n```'
        };
      }
      if (!listTurnServed) {
        listTurnServed = true;
        return _turn('respond', text: '1. 已确认范围\n2. 已确认默认值');
      }
      return confirm(member, context);
    }).runCollaboration(task, WorkTaskCancellation(), apply);

    final published = db.messageBox.values.map((m) => m.content).toList();
    expect(published, contains('已确认范围与默认值，我认可当前方案。'));
    expect(published.any((c) => c.contains('```')), isFalse,
        reason: '围栏不该进气泡');
  });

  test('命中编号清单的公开正文被打回重写一次', () async {
    var rewriteRequests = 0;
    var listTurnServed = false;
    await modelRunner((member, context) async {
      if (context.containsKey('rewriteTarget')) {
        rewriteRequests++;
        return {
          'success': true,
          'message': '已确认范围与默认值，我认可当前方案。'
        };
      }
      if (!listTurnServed) {
        listTurnServed = true;
        return _turn('respond', text: '1. 已确认范围\n2. 已确认默认值');
      }
      return confirm(member, context);
    }).runCollaboration(task, WorkTaskCancellation(), apply);

    expect(rewriteRequests, 1, reason: '命中清单只打回一次');
    final published = db.messageBox.values.map((m) => m.content).toList();
    expect(published, contains('已确认范围与默认值，我认可当前方案。'));
    expect(published.any((c) => c.startsWith('1. 已确认范围')), isFalse,
        reason: '命中清单的原文不应原样发布');
  });

  test('重写仍写清单时按原正文发布，不丢成员真实说过的内容', () async {
    var listTurnServed = false;
    await modelRunner((member, context) async {
      if (context.containsKey('rewriteTarget')) {
        return {'success': true, 'message': '1. 还是清单\n2. 又分点了'};
      }
      if (!listTurnServed) {
        listTurnServed = true;
        return _turn('respond', text: '1. 已确认范围\n2. 已确认默认值');
      }
      return confirm(member, context);
    }).runCollaboration(task, WorkTaskCancellation(), apply);

    final published = db.messageBox.values.map((m) => m.content).toList();
    expect(published.any((c) => c.startsWith('1. 已确认范围')), isTrue,
        reason: '重写未改善时用原正文发布，任务不被文风问题卡住');
  });

  test('内部标识符与验证命令编号也计入协议标识', () {
    expect(
        WorkPublicUpdateStream.protocolNotations(
            'V-08 的 requiredCapability 与运行时执行通道不符。'),
        isNotEmpty);
    expect(WorkPublicUpdateStream.protocolNotations('我认可当前方案。'), isEmpty);
  });

  test('接近旧上限的长气泡也按目标截断，不再整条放行', () {
    // 线上实测的形态：700 字上下的气泡落在上限下方，于是整条发布、观感没改善。
    final body = '前端最终确认，全部决策锁定。' * 50;
    expect(body.length, greaterThan(600));
    expect(body.length, lessThan(800), reason: '前置：它必须落在旧上限下方');
    final turn = WorkDiscussionV2Turn.parse({
      'success': true,
      'message': jsonEncode({
        'schemaVersion': 2,
        'action': 'respond',
        'public_update': body,
        'issue_id': '',
        'next_member_id': '',
        'issues': <Object>[],
        'resolutions': <Object>[],
        'proposal': null,
        'approval': null,
        'decision': null,
        'tool': null
      })
    });
    expect(turn, isNotNull);
    expect(turn!.publicUpdate, contains('已截断'));
    expect(turn.publicUpdate.length,
        lessThanOrEqualTo(WorkPublicUpdateStream.bubbleTargetCharacters));
    expect(turn.publicUpdateFull, body,
        reason: '截的是气泡不是内容：完整正文必须原样交给详情附件');
  });

  test('公开正文超出气泡上限时可见截断，协议仍按完整正文校验', () {
    final long = '我确认当前方案。' * 300;
    final turn = WorkDiscussionV2Turn.parse({
      'success': true,
      'message': jsonEncode({
        'schemaVersion': 2,
        'action': 'respond',
        'public_update': long,
        'issue_id': '',
        'next_member_id': '',
        'issues': <Object>[],
        'resolutions': <Object>[],
        'proposal': null,
        'approval': null,
        'decision': null,
        'tool': null
      })
    });
    expect(turn, isNotNull);
    expect(turn!.publicUpdate.length,
        lessThanOrEqualTo(WorkPublicUpdateStream.bubbleTargetCharacters));
    expect(turn.publicUpdate, contains('已截断，原文 ${long.length} 字'));
  });

  test('气泡截断时完整正文转存详情附件，群里只留可见截断', () async {
    final long = '需要说明这个边界：${'必要证据解释。' * 400}';
    await modelRunner((member, context) async {
      final s = Map<String, dynamic>.from(context['collaboration'] as Map);
      return (s['plan'] as String).isEmpty
          ? _turn('propose', text: long, proposal: proposal(s))
          : _turn('approve', text: '我认可本轮方案。', approval: approval(s));
    }).runCollaboration(task, WorkTaskCancellation(), apply);
    final bubble = db.messageBox.values
        .map((m) => m.content)
        .firstWhere((c) => c.startsWith('需要说明这个边界：'));
    expect(bubble.length,
        lessThanOrEqualTo(WorkPublicUpdateStream.bubbleTargetCharacters));
    expect(bubble, contains('已截断，原文 ${long.length} 字'));
    final detail = db.messageBox.values
        .expand((m) => m.media ?? [])
        .singleWhere((a) => a.fileName == '完整公开正文.json');
    expect(await File(detail.localPath).readAsString(), contains(long));
  });

  test('公开正文里的协议标识被识别出来，只用于诊断', () {
    expect(
        WorkPublicUpdateStream.protocolNotations(
            'req=48 / team=22 / ver=10 下我仍判 approved:false，请按 reviewApproval 出下一版。'),
        isNotEmpty);
    expect(
        WorkPublicUpdateStream.protocolNotations('按钮连点要防重复，我认可当前方案。'), isEmpty);
  });

  test('公开正文泄漏协议标识时只记诊断，正文照常发布', () async {
    const leaked = 'ver=3 下我判 approved:false，方案要重出。';
    await modelRunner((member, context) async {
      final s = Map<String, dynamic>.from(context['collaboration'] as Map);
      return (s['plan'] as String).isEmpty
          ? _turn('propose', text: leaked, proposal: proposal(s))
          : _turn('approve', text: '我认可本轮方案。', approval: approval(s));
    }).runCollaboration(task, WorkTaskCancellation(), apply);
    expect(db.messageBox.values.map((m) => m.content), contains(leaked));
    expect(
        (await events.read(task.id))
            .events
            .where((e) => e.detail.contains('协议标识'))
            .toList(),
        hasLength(1));
  });

  test('输出预算被推理吃光时改用精简指令重试，成功的这一轮照常采纳', () async {
    var calls = 0;
    var sawCompact = false;
    final runner = WorkDiscussionRunner(
        database: db,
        credentials: _Credentials(),
        eventStore: events,
        investigate: execution.investigate,
        completion: (
            {required character,
            required config,
            required apiKey,
            required provider,
            required conversationId,
            required messages,
            required timeout,
            cancelToken}) async {
          calls++;
          if (messages.any((m) =>
              m['content'] is String &&
              (m['content'] as String).contains('不展开推理过程'))) {
            sawCompact = true;
          }
          if (calls == 1) {
            return {
              'success': false,
              'failureCode': 'emptyResponse',
              'retryable': true,
              'emptyCompletionDetail': {
                'finishReason': 'length',
                'completionTokens': 20480,
                'reasoningTokens': 20480,
              },
              'message': '模型返回了空内容'
            };
          }
          return confirm(character,
              jsonDecode(messages.last['content'] as String)
                  as Map<String, dynamic>);
        });
    await runner.runCollaboration(task, WorkTaskCancellation(), apply);
    expect(sawCompact, isTrue, reason: '预算耗尽后必须换指令，原样重发只会再撞一次上限');
    expect(calls, greaterThanOrEqualTo(2));
    expect(
        (await events.read(task.id))
            .events
            .any((e) => e.title == '输出预算被推理耗尽，改用精简指令重试'),
        isTrue);
    expect(
        WorkDiscussionState.fromExecutionState(task.executionStateJson)!
            .collaboration!
            .plan,
        isNotEmpty);
  });

  test('精简指令也救不回来时如实记为成员缺口，不无限重试', () async {
    var calls = 0;
    final runner = WorkDiscussionRunner(
        database: db,
        credentials: _Credentials(),
        eventStore: events,
        investigate: execution.investigate,
        completion: (
            {required character,
            required config,
            required apiKey,
            required provider,
            required conversationId,
            required messages,
            required timeout,
            cancelToken}) async {
          calls++;
          return {
            'success': false,
            'failureCode': 'emptyResponse',
            'retryable': true,
            'emptyCompletionDetail': {
              'finishReason': 'length',
              'completionTokens': 20480,
              'reasoningTokens': 20480,
            },
            'message': '模型返回了空内容'
          };
        });
    await runner.runCollaboration(task, WorkTaskCancellation(), apply);
    // 首次 + 精简指令各一次，不因为再失败而继续试。
    expect(calls, 2);
  });

  test('协议失败诊断区分首次与修复响应，并标明正文是否含 JSON 起点', () async {
    const prose = '我先说明一下当前判断：这份方案还有四处前置没有落到正文里，需要重出。';
    var calls = 0;
    await modelRunner((member, context) async {
      if (context.containsKey('originalFinal')) {
        return {'success': true, 'message': prose};
      }
      calls++;
      return {'success': true, 'message': prose};
    }).runCollaboration(task, WorkTaskCancellation(), apply);
    expect(calls, greaterThan(0));
    final details = (await events.read(task.id))
        .events
        .where((e) => e.detail.contains('未符合 v2 协议'))
        .map((e) => e.detail)
        .toList();
    expect(details, isNotEmpty);
    expect(details.first, contains('首次响应正文开头'));
    expect(details.first, contains('含 JSON 起点：否'));
    expect(details.last, contains('修复响应正文开头'));
  });

  test('正文含 JSON 起点但未通过校验时诊断标明起点存在', () async {
    await modelRunner((member, context) async =>
        {'success': true, 'message': '{"action":"respond" 这里少了个右花括号'})
        .runCollaboration(task, WorkTaskCancellation(), apply);
    final details = (await events.read(task.id))
        .events
        .where((e) => e.detail.contains('未符合 v2 协议'))
        .map((e) => e.detail)
        .toList();
    expect(details, isNotEmpty);
    expect(details.first, contains('含 JSON 起点：是'));
  });

  test('线上样本：台账黑话式正文同时命中协议标识与编号清单', () {
    const sample = 'req=48 / team=22 / ver=10 下 ISS-VC-01 我仍判 approved:false。'
        '四处补丁必须同版一次性写齐：①verify.js 的产出者 ②V-01~V-08 每条命令的原样字符串 '
        '③jsdom 同步事件派发下验证的是 +1 累加逻辑 ④AC-02 的 requiredCapability="workspaceRead"。'
        '本 turn 严格按 reviewApproval 走。';
    final notations = WorkPublicUpdateStream.protocolNotations(sample);
    expect(notations, contains('req=48'));
    expect(notations, contains('approved:false'));
    expect(notations, contains('reviewApproval'));
    expect(notations, contains('requiredCapability'));
    expect(notations, contains('V-08'));
    expect(WorkPublicUpdateStream.listMarkerCount(sample), 4);
  });

  test('编号清单式正文同样只记诊断，不改写正文', () async {
    const formatted = '两处要补：①产物的产出者 ②每条命令的执行环境。';
    await modelRunner((member, context) async {
      final s = Map<String, dynamic>.from(context['collaboration'] as Map);
      return (s['plan'] as String).isEmpty
          ? _turn('propose', text: formatted, proposal: proposal(s))
          : _turn('approve', text: '我认可本轮方案。', approval: approval(s));
    }).runCollaboration(task, WorkTaskCancellation(), apply);
    expect(db.messageBox.values.map((m) => m.content), contains(formatted));
    expect(
        (await events.read(task.id))
            .events
            .where((e) => e.detail.contains('编号清单'))
            .toList(),
        hasLength(1));
  });

  test('未被采纳的回应不把正文留在群里，也不进后续预览', () async {
    const leaked = 'ver=3 下我判 approved:false，方案要重出。';
    final previews = <String>[];
    await modelRunner((member, context) async {
      previews.add(jsonEncode(context['recentDiscussion']));
      return _turn('respond', text: leaked, issues: [
        {
          'id': 'unverified',
          'kind': 'defect',
          'target': 'dev',
          'problem': '需要核对事件处理',
          'evidenceRef': 'invented-reference',
          'retestCondition': '取得真实事件依据'
        }
      ]);
    }).runCollaboration(task, WorkTaskCancellation(), apply);
    final contents = db.messageBox.values.map((m) => m.content);
    expect(contents, isNot(contains(leaked)));
    expect(contents, contains(WorkDiscussionRunner.rejectedTurnNotice));
    expect(previews.length, greaterThan(1));
    expect(previews.join(), contains(WorkDiscussionRunner.rejectedTurnNotice));
    expect(previews.join(), isNot(contains(leaked)));
    expect(db.conversationSummaries()[task.groupId]?.preview,
        isNot(contains(leaked)));
  });

  test('无进展待决携带实际引用错误，不能用自造证据新增问题', () async {
    await modelRunner((member, context) async => _turn('respond', issues: [
          {
            'id': 'unverified',
            'kind': 'defect',
            'target': 'dev',
            'problem': '需要核对事件处理',
            'evidenceRef': 'invented-reference',
            'retestCondition': '取得真实事件依据'
          }
        ])).runCollaboration(task, WorkTaskCancellation(), apply);
    final state =
        WorkDiscussionState.fromExecutionState(task.executionStateJson)!
            .collaboration!;
    expect(state.issues, isEmpty);
    expect(state.decisions.last['evidence'], contains('问题证据不存在'));
    expect(state.planReady, isFalse);
  });
  test('协议修复转换实际最终正文，保留权威台账而不重放人格和聊天', () async {
    String? original;
    String? reply;
    var repaired = false;
    await modelRunner((member, context) async {
      if (context.containsKey('originalFinal')) {
        expect(context['originalFinal'], original);
        expect(context['protocolError'], contains('JSON 语法错误'));
        expect(context['taskId'], task.id);
        expect(context['memberId'], member.id);
        expect(context['collaboration']['scope'], contains('开发游戏'));
        expect(context['collaboration']['artifactContract'], isNotEmpty);
        expect(context.containsKey('skills'), isFalse);
        expect(context.containsKey('recentDiscussion'), isFalse);
        repaired = true;
        return {'success': true, 'message': reply!};
      }
      final result = await confirm(member, context);
      if (original == null) {
        reply = result['message'] as String;
        original = '```json\n$reply\n```';
        return {'success': true, 'message': original!};
      }
      return result;
    }).runCollaboration(task, WorkTaskCancellation(), apply);
    expect(repaired, isTrue);
    expect(
        WorkDiscussionState.fromExecutionState(task.executionStateJson)!
            .isPlanReady,
        isTrue);
  });
  test('协议诊断仅报告结构错误，不暴露异常或任意字段值', () {
    String? reason;
    final malformed = _turn('respond');
    final raw = jsonDecode(malformed['message'] as String) as Map;
    raw['schemaVersion'] = 'PRIVATE_ERROR_VALUE';
    expect(
        WorkDiscussionV2Turn.parse(
            {'success': true, 'message': jsonEncode(raw)},
            onInvalid: (value) => reason = value),
        isNull);
    expect(reason, contains('顶层必填字段'));
    expect(reason, isNot(contains('PRIVATE_ERROR_VALUE')));
  });
  test('恢复摘要不重复注入协作台账，保留其它恢复事实', () async {
    task.contextSummary = jsonEncode({
      'schemaVersion': 1,
      'conversationId': task.groupId,
      'target': task.userRequest,
      'errors': ['保留恢复错误'],
      'artifactPaths': ['game.html'],
    });
    await modelRunner((member, context) async {
      final snapshot = jsonDecode(context['currentTaskContext'] as String);
      expect(snapshot['discussionState'], isNull);
      expect(snapshot['errors'], contains('保留恢复错误'));
      expect(snapshot['artifactPaths'], contains('game.html'));
      expect(context['collaboration']['scope'], contains('开发游戏'));
      expect(context['collaboration']['requestRevision'], isNotNull);
      return confirm(member, context);
    }).runCollaboration(task, WorkTaskCancellation(), apply);
    expect(
        WorkDiscussionState.fromExecutionState(task.executionStateJson)!
            .isPlanReady,
        isTrue);
  });

  test('单次聚焦方案或本人认可，正文建议额度充足且不伪造硬预留', () async {
    final stages = <String>[];
    await modelRunner((member, context) async {
      final s = context['collaboration'] as Map;
      final focus = context['turnFocus'] as Map;
      final budget = context['outputGuidance'] as Map;
      final total = budget['sharedMaxTokens'] as int;
      final finalTarget = budget['preferredFinalTokens'] as int;
      expect(finalTarget, greaterThanOrEqualTo((total / 2).ceil()));
      expect(finalTarget, lessThanOrEqualTo(total));
      expect(budget['separateReasoningLimitEnforced'], isFalse);
      expect(context['userRequest'], task.userRequest);
      stages.add(focus['stage'] as String);
      if ((s['plan'] as String).isEmpty) {
        expect(focus['stage'], 'prepareProposal');
      } else {
        expect(focus['stage'], 'reviewApproval');
        final identifiers = focus['approvalIdentifiers'] as Map;
        expect(identifiers['subjectId'], task.id);
        expect(identifiers['requestRevision'], s['requestRevision']);
        expect(identifiers.containsKey('approved'), isFalse);
      }
      return confirm(member, context);
    }).runCollaboration(task, WorkTaskCancellation(), apply);
    expect(stages.first, 'prepareProposal');
    expect(stages.skip(1).every((s) => s == 'reviewApproval'), isTrue);
    expect(
        WorkDiscussionState.fromExecutionState(task.executionStateJson)!
            .isPlanReady,
        isTrue);
  });

  test('聚焦提示不把未决问题转成自动认可，也不丢其它未决义务', () async {
    var introduced = false;
    var sawIssue = false;
    await modelRunner((member, context) async {
      if (!introduced) {
        introduced = true;
        return _turn('respond', issues: [
          {
            'id': 'first',
            'kind': 'defect',
            'target': 'dev',
            'problem': '按钮重复触发',
            'evidenceRef': '',
            'retestCondition': '连续点击检查'
          },
          {
            'id': 'second',
            'kind': 'defect',
            'target': 'qa',
            'problem': '归零条件未知',
            'evidenceRef': '',
            'retestCondition': '核对归零结果'
          }
        ]);
      }
      final focus = context['turnFocus'] as Map;
      expect(focus['stage'], 'resolveIssue');
      expect(focus['issueId'], 'first');
      expect(focus.containsKey('approvalIdentifiers'), isFalse);
      expect((context['collaboration']['issues'] as List).length, 2);
      sawIssue = true;
      return _turn('silent', text: '');
    }).runCollaboration(task, WorkTaskCancellation(), apply);
    expect(sawIssue, isTrue);
    final state =
        WorkDiscussionState.fromExecutionState(task.executionStateJson)!
            .collaboration!;
    expect(state.approvals, isEmpty);
    expect(state.issues.where((i) => i['status'] == 'open').length, 2);
    expect(state.planReady, isFalse);
  });

  test('冗余聊天预览有界，保留权威需求与问题供成员逐项处理', () async {
    for (var i = 0; i < 16; i++) {
      await db.messageBox.put(
          'preview-$i',
          Message(
              id: 'preview-$i',
              groupId: task.groupId,
              senderId: 'dev',
              senderType: 'ai',
              content: '历史预览$i：${'衔接说明。' * 500}',
              visibleToCharacterIds: const ['dev', 'qa'],
              timestamp: DateTime(2026, 1, 1).add(Duration(minutes: i))));
    }
    var seen = false;
    await modelRunner((member, context) async {
      final previews = context['recentChatMessages'] as List;
      expect(previews.length, 6);
      if (!seen) {
        expect(previews.first, contains('历史预览10'));
        expect(previews.last, contains('历史预览15'));
      }
      expect(previews.every((text) => (text as String).length <= 600), isTrue);
      expect(
          (context['recentDiscussion'] as List).length, lessThanOrEqualTo(6));
      expect(context['userRequest'], task.userRequest);
      expect(context['collaboration']['scope'], contains('开发游戏'));
      seen = true;
      return confirm(member, context);
    }).runCollaboration(task, WorkTaskCancellation(), apply);
    expect(seen, isTrue);
    expect(
        WorkDiscussionState.fromExecutionState(task.executionStateJson)!
            .isPlanReady,
        isTrue);
  });
  test('SenseNova 6.8 讨论请求不再单独抬高采样温度，模型身份不变', () async {
    // 2026-10-10 改：原先该模型走 temperature 1.0（"官方通用思考采样"）。实测群
    // 「我的世界」4 名成员全为该模型：执行路径（temperature 0.2）2073 步只失败 17 次
    // 格式无效，讨论路径却失败 1135 次，两个最坏群都是全员同款。本用例改钉"与其它
    // 模型同一温度"这条契约；要恢复 1.0 请先拿出讨论路径的对照数据。
    for (final id in ['dev', 'qa']) {
      final config = db.apiConfigBox.get('config-$id')!
        ..provider = 'sensenova'
        ..modelName = 'sensenova-6.8-flash-lite';
      await db.apiConfigBox.put(config.id, config);
    }
    final adapter = _ReasoningEnvelopeAdapter();
    final dio = Dio()..httpClientAdapter = adapter;
    addTearDown(dio.close);
    await WorkDiscussionRunner(
            database: db,
            credentials: _Credentials(),
            eventStore: events,
            gateway: AiRequestGateway(
                store: MemoryGovernanceStore(),
                client: ChatApiService(dio: dio)),
            investigate: execution.investigate)
        .runCollaboration(task, WorkTaskCancellation(), apply);
    expect(adapter.temperatures, isNotEmpty);
    expect(
        adapter.temperatures.every(
            (t) => t == WorkDiscussionRunner.defaultDiscussionTemperature),
        isTrue);
    expect(db.apiConfigBox.get('config-dev')!.modelName,
        'sensenova-6.8-flash-lite');
    expect(
        WorkDiscussionState.fromExecutionState(task.executionStateJson)!
            .isPlanReady,
        isTrue);
  });
  test('较大推理响应容器不挤掉合法公开协议，也不公开私有推理', () async {
    final adapter = _ReasoningEnvelopeAdapter();
    final dio = Dio()..httpClientAdapter = adapter;
    addTearDown(dio.close);
    final gateway = AiRequestGateway(
        store: MemoryGovernanceStore(), client: ChatApiService(dio: dio));
    await WorkDiscussionRunner(
            database: db,
            credentials: _Credentials(),
            eventStore: events,
            gateway: gateway,
            investigate: execution.investigate)
        .runCollaboration(task, WorkTaskCancellation(), apply);
    expect(adapter.calls, greaterThanOrEqualTo(3));
    expect(
        WorkDiscussionState.fromExecutionState(task.executionStateJson)!
            .isPlanReady,
        isTrue);
    expect(
        db.messageBox.values
            .any((m) => m.content.contains('PRIVATE_REASONING_ENVELOPE')),
        isFalse);
    expect(
        WorkDiscussionV2Turn.parse(_turn('respond', text: 'x' * (48 * 1024))),
        isNull,
        reason: '传输容器放宽不能放宽公开协议上限');
  });
  test('方案名字不能代替任务认可标识，纠正后才允许签字', () async {
    var rejected = false;
    var recovered = false;
    await modelRunner((member, context) async {
      final current =
          Map<String, dynamic>.from(context['collaboration'] as Map);
      if ((current['plan'] as String).isNotEmpty && !rejected) {
        rejected = true;
        return _turn('approve', approval: {
          ...approval(current),
          'subjectId': 'v0.1',
        });
      }
      if (rejected && !recovered) {
        expect(context['lastValidationError'], contains('taskId'));
        expect(current['approvals'], isEmpty);
        recovered = true;
      }
      return confirm(member, context);
    }).runCollaboration(task, WorkTaskCancellation(), apply);
    expect(recovered, isTrue);
    final state =
        WorkDiscussionState.fromExecutionState(task.executionStateJson)!
            .collaboration!;
    expect(state.planReady, isTrue);
    expect(state.approvals.every((a) => a['subjectId'] == task.id), isTrue);
  });
  test('合同误写返回具体字段，原成员纠正后才建立方案', () async {
    var calls = 0;
    var feedbackSeen = false;
    await modelRunner((member, context) async {
      calls++;
      final current =
          Map<String, dynamic>.from(context['collaboration'] as Map);
      if (calls == 1) {
        final wrong = proposal(current);
        wrong['artifactContract'] = {
          ...current['artifactContract'] as Map,
          'location': 'unauthorized.html',
        };
        return _turn('propose', proposal: wrong);
      }
      if (calls == 2) {
        expect(member.id, 'dev');
        expect(context['lastValidationError'], contains('location'));
        expect(current['artifactContract']['location'], 'game.html');
        expect(current['plan'], isEmpty);
        expect(current['approvals'], isEmpty);
        feedbackSeen = true;
      }
      return confirm(member, context);
    }).runCollaboration(task, WorkTaskCancellation(), apply);
    expect(feedbackSeen, isTrue);
    final state =
        WorkDiscussionState.fromExecutionState(task.executionStateJson)!
            .collaboration!;
    expect(state.artifactContract['location'], 'game.html');
    expect(state.planReady, isTrue);
  });
  for (final failure in [
    '429',
    'timeout',
    '401',
    'cancel',
    'exhausted',
    'empty',
    'empty-exhausted',
    'empty-budget'
  ]) {
    test('v2 transport recovery keeps member and model: $failure', () async {
      var calls = 0;
      CancelToken? previous;
      final cancellation = WorkTaskCancellation();
      final runner = WorkDiscussionRunner(
          database: db,
          credentials: _Credentials(),
          eventStore: events,
          completion: (
              {required character,
              required config,
              required apiKey,
              required provider,
              required conversationId,
              required messages,
              required timeout,
              cancelToken}) async {
            calls++;
            if (previous != null) expect(previous!.isCancelled, true);
            previous = cancelToken;
            if (calls <= 2) expect(character.id, 'dev');
            expect(config.modelName,
                db.apiConfigBox.get(character.apiConfigId)!.modelName);
            if (failure == 'cancel') cancellation.cancel();
            if (calls == 1 ||
                failure == '401' ||
                failure == 'cancel' ||
                failure == 'exhausted' ||
                failure == 'empty-exhausted' ||
                failure == 'empty-budget') {
              if (failure == 'timeout') throw TimeoutException('test timeout');
              if (failure.startsWith('empty')) {
                return {
                  'success': false,
                  'failureCode': 'emptyResponse',
                  'retryable': true,
                  if (failure == 'empty-budget')
                    'emptyCompletionDetail': {
                      'finishReason': 'length',
                      'completionTokens': 20480,
                      'reasoningTokens': 20480,
                    },
                  'message': '模型返回了空内容'
                };
              }
              return {
                'success': false,
                'statusCode': failure == '401' ? 401 : 429,
                'message': 'HTTP $failure'
              };
            }
            // A real second response must still pass the protocol gate.
            return confirm(
                character,
                jsonDecode(messages.last['content'] as String)
                    as Map<String, dynamic>);
          });
      await runner.runCollaboration(task, cancellation, apply);
      final recovered =
          failure == '429' || failure == 'timeout' || failure == 'empty';
      expect(
          calls,
          recovered
              ? greaterThan(1)
              : failure == 'exhausted'
                  ? 5
                  : failure == 'empty-exhausted'
                      ? 2
                      // 预算被推理吃光：首次 + 一次精简指令重试（换指令而非原样重发），
                      // 再耗尽就如实记为成员缺口。
                      : failure == 'empty-budget'
                          ? 2
                          : 1);
      final state =
          WorkDiscussionState.fromExecutionState(task.executionStateJson)!
              .collaboration!;
      expect(state.planReady, recovered);
      if (!recovered) expect(state.approvals, isEmpty);
      expect(state.team.any((m) => m['memberId'] == 'dev'), true);
      if (failure == 'cancel') {
        expect(state.team.every((m) => m['available'] == true), true);
        expect(state.hasPendingDecision, false);
      }
    }, timeout: const Timeout(Duration(seconds: 30)));
  }
  for (final allow in [false, true]) {
    test('CUA v2 discussion requests its directory before binding: $allow',
        () async {
      final project = await Directory('${dir.path}/new-project').create();
      await db.workModeWorkspaceBox.delete(task.groupId);
      task.userRequest = '开发游戏，项目目录 ${project.path}';
      task.executionStateJson = WorkDiscussionState.mergeIntoExecutionState(
          '', WorkDiscussionState.forNewTask(task));
      var picks = 0;
      var calls = 0;
      final discussion = WorkDiscussionRunner(
          database: db,
          credentials: _Credentials(),
          workspaceService: execution.workspaceService,
          eventStore: events,
          completion: (
              {required character,
              required config,
              required apiKey,
              required provider,
              required conversationId,
              required messages,
              required timeout,
              cancelToken}) async {
            calls++;
            return confirm(
                character,
                jsonDecode(messages.last['content'] as String)
                    as Map<String, dynamic>);
          });
      final coordinator = WorkTaskCoordinator(
          taskBox: db.agentTaskBox,
          runner: execution,
          eventStore: events,
          discussionRunner: discussion,
          folderGrantService: execution.folderGrantService,
          folderPicker: ([initialDirectory]) async {
            picks++;
            return allow ? project.path : null;
          },
          folderGrantConsent: (_) async => true);
      try {
        await coordinator.submit(task);
        await waitFor(() => picks > 0 && (calls > 0 || task.resumeRequired));
        expect(picks, 1);
        if (allow) {
          expect(calls, greaterThan(0), reason: task.lastError);
          expect(db.workModeWorkspaceBox.get(task.groupId)!.workDirPath,
              project.path);
        } else {
          expect(calls, 0);
          expect(task.status, AgentTaskStatus.paused);
          expect(
              jsonDecode(task.executionStateJson)['folderGrantPending'], true);
          expect(db.workModeWorkspaceBox.get(task.groupId), isNull);
        }
      } finally {
        await coordinator.dispose();
      }
    }, timeout: const Timeout(Duration(seconds: 30)));
  }

  test('历史回归：explicit negative rename must keep the pinned file', () async {
    await db.agentTaskBox.put(task.id, task);
    final coordinator = WorkTaskCoordinator(
        taskBox: db.agentTaskBox, runner: execution, eventStore: events);
    addTearDown(coordinator.dispose);
    const supplement = '不要把game.html改名为game2.html，保持现有文件名。';
    await coordinator.enqueueFollowUp(task.id, supplement,
        sourceMessageId: 'rereview3-negative');
    final discussion = modelRunner((member, context) async {
      final current =
          Map<String, dynamic>.from(context['collaboration'] as Map);
      if ((current['plan'] as String).isEmpty) {
        final next = proposal(current);
        next['workItems'] = [
          {
            'id': 'implementation',
            'ownerId': current['coordinatorId'],
            'dependencies': <String>[]
          }
        ];
        next['artifactContract'] = {
          ...current['artifactContract'] as Map,
          'location': 'game2.html'
        };
        return _turn('propose', proposal: next);
      }
      return _turn('approve', approval: approval(current));
    });
    await discussion.runCollaboration(task, WorkTaskCancellation(), apply);
    final current =
        WorkDiscussionState.fromExecutionState(task.executionStateJson)!
            .collaboration!;
    expect(current.artifactContract['location'], 'game.html',
        reason: '$supplement; ${task.lastError}');
  }, timeout: const Timeout(Duration(seconds: 30)));

  test(
      '历史回归：settled history must preserve a current member joining authorization',
      () async {
    final group = db.chatGroupBox.get(task.groupId)!;
    await db.chatGroupBox.put(
        group.id,
        ChatGroup(
            id: group.id,
            name: group.name,
            theme: group.theme,
            aiCharacterIds: const ['dev']));
    await db.agentTaskBox.put(task.id, task);
    final discussion = modelRunner(confirm);
    await discussion.runCollaboration(task, WorkTaskCancellation(), apply);
    var current =
        WorkDiscussionState.fromExecutionState(task.executionStateJson)!
            .collaboration!;
    final joining = current.decisions.singleWhere(
        (d) => d['kind'] == 'member' && d['targetId'] == 'role:testing');
    final option = (joining['options'] as List)
        .cast<Map>()
        .singleWhere((o) => o['id'] == 'qa');
    const choiceEvent = 'user-confirm-qa-rereview3';
    final answered = WorkCollaborationState.tryParse(current.toJson()
      ..['revision'] = current.revision + 1
      ..['requestRevision'] = current.requestRevision + 1
      ..['appliedEventIds'] = [...current.appliedEventIds, choiceEvent]
          .skip(current.appliedEventIds.length == 64 ? 1 : 0)
          .toList()
      ..['decisions'] = [
        for (final d in current.decisions)
          if (d['id'] == joining['id'])
            {
              ...d,
              'status': 'answered',
              'answer': option['label'],
              'answerKind': 'choice',
              'responseRef': 'user-answer-qa'
            }
          else
            d
      ]);
    expect(answered, isNotNull);
    await apply(WorkCollaborationUpdate(
        taskId: task.id,
        conversationId: task.groupId,
        expectedRevision: current.revision,
        eventId: choiceEvent,
        sourceRole: 'user',
        sourceId: 'user',
        next: answered!));
    await discussion.runCollaboration(task, WorkTaskCancellation(), apply);
    current = WorkDiscussionState.fromExecutionState(task.executionStateJson)!
        .collaboration!;
    expect(current.planReady, isTrue);
    expect(current.team.singleWhere((m) => m['memberId'] == 'qa')['available'],
        isTrue);
    expect(current.decisions.any((d) => d['id'] == joining['id']), isTrue);
    expect(db.chatGroupBox.get(group.id)!.aiCharacterIds, const ['dev']);
    const historyEvent = 'user-history-rereview3';
    final withHistory = WorkCollaborationState.tryParse(current.toJson()
      ..['revision'] = current.revision + 1
      ..['requestRevision'] = current.requestRevision + 1
      ..['appliedEventIds'] = [...current.appliedEventIds, historyEvent]
          .skip(current.appliedEventIds.length == 64 ? 1 : 0)
          .toList()
      ..['decisions'] = [
        ...current.decisions,
        for (var i = 0; i < 64; i++)
          {
            'id': 'answered-$i',
            'revision': i + 1,
            'status': 'answered',
            'kind': 'question',
            'targetId': 'other-$i',
            'reason': '已经确认的细节 $i',
            'evidence': '用户已答复',
            'answer': '继续',
            'answerKind': 'text',
            'impact': '保持方案',
            'responseRef': 'user-$i'
          }
      ]);
    expect(withHistory, isNotNull);
    await apply(WorkCollaborationUpdate(
        taskId: task.id,
        conversationId: task.groupId,
        expectedRevision: current.revision,
        eventId: historyEvent,
        sourceRole: 'user',
        sourceId: 'user',
        next: withHistory!));
    await discussion.runCollaboration(task, WorkTaskCancellation(), apply);
    final after =
        WorkDiscussionState.fromExecutionState(task.executionStateJson)!
            .collaboration!;
    expect(after.team.singleWhere((m) => m['memberId'] == 'qa')['available'],
        isTrue,
        reason: '有效加入授权不应被普通已答复问题挤掉。${jsonEncode(after.decisions)}');
    expect(after.decisions.any((d) => d['id'] == joining['id']), isTrue);
  }, timeout: const Timeout(Duration(seconds: 30)));

  for (final withHistoricalApprovals in [false, true]) {
    test(
        '历史回归：archive signatures do not consume current discussion window: $withHistoricalApprovals',
        () async {
      await db.agentTaskBox.put(task.id, task);
      await modelRunner(confirm)
          .runCollaboration(task, WorkTaskCancellation(), apply);
      final before =
          WorkDiscussionState.fromExecutionState(task.executionStateJson)!;
      final current = before.collaboration!;
      expect(current.productionReady, isTrue);
      final checkpoint = WorkCollaborationState.tryParse(current.toJson()
        ..['revision'] = current.revision + 1
        ..['requestRevision'] = current.requestRevision + 1
        ..['phase'] = 'clarifying'
        ..['iterations'] = [
          for (var i = 1; i <= 70; i++)
            {
              'id': 'r${i.toString().padLeft(3, '0')}',
              'artifactDigest': 'digest-$i',
              'requestRevision': current.requestRevision,
              'teamRevision': current.teamRevision,
              'manifestRef': 'candidate:r$i',
              'reviewRef': 'report-$i',
              'status': 'reviewed'
            }
        ]
        ..['approvals'] = [
          ...current.approvals,
          if (withHistoricalApprovals)
            for (var i = 1; i <= 70; i++)
              for (final member in current.activeMembers)
                {
                  'eventId': 'delivery-$member-$i',
                  'memberId': member,
                  'kind': 'delivery',
                  'subjectId': 'r${i.toString().padLeft(3, '0')}',
                  'requestRevision': current.requestRevision,
                  'teamRevision': current.teamRevision,
                  'verificationRevision': current.verificationRevision,
                  'iterationId': 'r${i.toString().padLeft(3, '0')}',
                  'artifactDigest': 'digest-$i',
                  'approved': true,
                  'evidenceRef': 'reply-$member-$i',
                  'source': 'memberModel'
                }
        ]);
      expect(checkpoint, isNotNull);
      expect(checkpoint!.isValid, isTrue);
      expect(checkpoint.productionReady, isFalse);
      task.executionStateJson = WorkDiscussionState.mergeIntoExecutionState(
          task.executionStateJson,
          before.copyWith(
              collaboration: checkpoint,
              requestRevision: checkpoint.requestRevision),
          expectedCollaborationRevision: current.revision);
      task.contextSummary = jsonEncode({
        'schemaVersion': 1,
        'conversationId': task.groupId,
        'discussionState': before
            .copyWith(
                collaboration: checkpoint,
                requestRevision: checkpoint.requestRevision)
            .toJson()
      });
      await db.agentTaskBox.put(task.id, task);
      var calls = 0;
      final discussion = modelRunner((member, context) async {
        calls++;
        return confirm(member, context);
      });
      await discussion.runCollaboration(task, WorkTaskCancellation(), apply);
      final after =
          WorkDiscussionState.fromExecutionState(task.executionStateJson)!
              .collaboration!;
      expect(calls, greaterThan(0),
          reason:
              'archive=$withHistoricalApprovals; ${jsonEncode(after.decisions)}');
      expect(after.approvals.where((a) => a['kind'] == 'delivery').length,
          withHistoricalApprovals ? 140 : 0,
          reason: '模型投影不能改写权威历史');
      expect(after.productionReady, isTrue,
          reason:
              'archive=$withHistoricalApprovals; ${jsonEncode(after.decisions)}');
    }, timeout: const Timeout(Duration(seconds: 30)));
  }

  test('已被采纳的问题证据不因后续项被拒绝而失真', () async {
    // 一轮发言是逐项落盘的（`_validateHumanMember` 只接受一次追加一条 issue），
    // 所以"第二项证据不存在"并不等于整轮都没被采纳：第一条已经提交，并把这条消息
    // 记为它的 evidenceRef。撤回若改写正文，那条问题的"依据"就变成一句中性说明。
    const original = '按钮可能重复触发；依据是用户要求防止重复，需核对实现。';
    var first = true;
    await modelRunner((member, context) async {
      if (!first) return _turn('silent', text: '');
      first = false;
      return _turn('respond', text: original, issues: [
        {
          'id': 'valid-first',
          'kind': 'defect',
          'target': 'dev',
          'problem': '按钮重复触发',
          'evidenceRef': '',
          'retestCondition': '实际核对点击事件'
        },
        {
          'id': 'invalid-second',
          'kind': 'defect',
          'target': 'qa',
          'problem': '第二个问题',
          'evidenceRef': 'invented-reference',
          'retestCondition': '需要证据'
        }
      ]);
    }).runCollaboration(task, WorkTaskCancellation(), apply);

    final state =
        WorkDiscussionState.fromExecutionState(task.executionStateJson)!
            .collaboration!;
    final issue = state.issues.singleWhere((i) => i['id'] == 'valid-first');
    final message = db.messageBox.get(issue['evidenceRef']);
    expect(message, isNotNull);
    expect(message!.content, original,
        reason: '第一条问题已提交并引用这条正文，撤回第二项不能改写它');
  });

  test('后续环节失败同样不改写已提交问题的证据正文', () async {
    // 上面的守卫不只在同意轮发言的项之间生效：issue 已提交、随后 `_resolve` 才
    // 因答复指向不存在的问题而失败时，那条证据同样是已落盘状态的一部分。
    const original = '按钮可能重复触发；依据是用户要求防止重复，需核对实现。';
    var first = true;
    await modelRunner((member, context) async {
      if (!first) return _turn('silent', text: '');
      first = false;
      return _turn('respond', text: original, issues: [
        {
          'id': 'valid-first',
          'kind': 'defect',
          'target': 'dev',
          'problem': '按钮重复触发',
          'evidenceRef': '',
          'retestCondition': '实际核对点击事件'
        }
      ], resolutions: [
        {
          'id': 'unknown-issue',
          'resolution': '已经修好了',
          'evidenceRef': 'invented-reference'
        }
      ]);
    }).runCollaboration(task, WorkTaskCancellation(), apply);

    final state =
        WorkDiscussionState.fromExecutionState(task.executionStateJson)!
            .collaboration!;
    final issue = state.issues.singleWhere((i) => i['id'] == 'valid-first');
    final message = db.messageBox.get(issue['evidenceRef']);
    expect(message, isNotNull);
    expect(message!.content, original, reason: '证据正文不能因为答复环节失败而消失');
    final rejected = (await events.read(task.id))
        .events
        .where((event) => event.detail.contains('未被采纳'))
        .toList();
    expect(rejected, isNotEmpty, reason: '拒绝仍必须留下可追溯的诊断');
  });
}
