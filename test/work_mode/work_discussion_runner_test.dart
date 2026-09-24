import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/models/agent_task.dart';
import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/api_config.dart';
import 'package:chat_group/core/models/chat_group.dart';
import 'package:chat_group/core/models/user_profile.dart';
import 'package:chat_group/core/storage/api_credential_resolver.dart';
import 'package:chat_group/features/work_mode/work_discussion_runner.dart';
import 'package:chat_group/features/work_mode/work_discussion_state.dart';
import 'package:chat_group/features/work_mode/work_task_coordinator.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/lifecycle_hive.dart';

class _Credentials implements ApiCredentialResolver {
  @override
  Future<String?> resolve(ApiConfig config) async => 'test-key-${config.id}';
}

AICharacter _character(String id, String name, String role, String configId) =>
    AICharacter(
      id: id,
      name: name,
      avatar: name.substring(0, 1),
      age: 30,
      role: role,
      personalityTags: const [],
      systemPrompt: '只使用公开职业判断。',
      apiKey: '',
      apiProvider: 'deepseek',
      modelName: 'deepseek-chat',
      apiConfigId: configId,
    );

Map<String, dynamic> _contract({
  String executorId = 'front',
  String scope = '实现页面并验证核心交互',
  String format = 'html',
  String location = 'desktop.html',
}) =>
    <String, dynamic>{
      'deliverableType': 'source',
      'format': format,
      'location': location,
      'contentScope': scope,
      'explicitExecutorId': executorId,
      'revisionTarget': '',
      'requestRevision': 1,
    };

AgentTask _task({
  required ChatGroup group,
  required String request,
  required String executorId,
  required Iterable<String> members,
}) {
  final task = AgentTask(
    id: '${group.id}-task',
    groupId: group.id,
    characterId: executorId,
    userRequest: request,
    assignedCharacterIds: members.toList(growable: false),
    workModeTask: true,
  );
  task.executionStateJson = WorkDiscussionState.mergeIntoExecutionState(
    '',
    WorkDiscussionState.initial(
      conversationId: group.id,
      executorId: executorId,
      candidateCharacterIds: [executorId],
      participantCharacterIds: members,
      deliverableContract: _contract(executorId: executorId),
    ),
  );
  return task;
}

Map<String, dynamic> _turn({
  required String update,
  int percent = 50,
  bool substantive = true,
  List<String> evidence = const [
    '目标和范围已确认。',
    '方案与职责取舍已记录。',
    '格式、位置和验收方式已确认。',
  ],
  List<String> questions = const [],
  List<String> resolvedQuestions = const [],
  List<String> resolvedBlockers = const [],
  Map<String, dynamic>? contract,
  bool needsUser = false,
}) {
  return <String, dynamic>{
    'success': true,
    'message': jsonEncode(<String, dynamic>{
      'public_update': update,
      'understanding_percent': percent,
      'understanding_evidence': evidence,
      'open_questions': questions,
      'resolved_questions': resolvedQuestions,
      'blockers': const <String>[],
      'resolved_blockers': resolvedBlockers,
      'substantive_progress': substantive,
      'needs_user': needsUser,
      if (contract != null) 'contract': contract,
      if (needsUser && questions.isNotEmpty) 'user_question': questions.first,
    }),
  };
}

bool _isCoordinatorPrompt(List<Map<String, dynamic>> messages) =>
    messages.first['content'].toString().contains('你是本轮协调/执行人');

bool _isRepairPrompt(List<Map<String, dynamic>> messages) =>
    messages.last['content'].toString().contains('不是合法 JSON');

/// Runs a one-member discussion where every member attempt is answered by
/// [memberResponse] (1-based attempt number) and the coordinator always
/// summarizes. Returns the final state plus every member prompt so a test can
/// assert whether the runner asked the same member again.
Future<
    ({
      WorkDiscussionState? state,
      List<List<Map<String, dynamic>>> memberPrompts,
    })> _runSingleMemberFixture(
  DatabaseService database, {
  required String characterId,
  required Map<String, dynamic> Function(int attempt) memberResponse,
}) async {
  final config = ApiConfig(
    id: 'cfg-$characterId',
    name: characterId,
    provider: 'deepseek',
    modelName: 'deepseek-chat',
    hasCredential: true,
    credentialId: 'credential-$characterId',
  );
  await database.apiConfigBox.put(config.id, config);
  final character = _character(characterId, '前端', '前端工程师', config.id);
  await database.aiCharacterBox.put(character.id, character);
  final group = ChatGroup(
    id: '$characterId-group',
    name: '重试群',
    theme: '网页',
    aiCharacterIds: [character.id],
  );
  await database.chatGroupBox.put(group.id, group);
  final task = _task(
    group: group,
    request: '实现 HTML 页面',
    executorId: character.id,
    members: [character.id],
  );
  final memberPrompts = <List<Map<String, dynamic>>>[];
  WorkDiscussionState? latest;
  final runner = WorkDiscussionRunner(
    database: database,
    credentials: _Credentials(),
    completion: ({
      required character,
      required config,
      required apiKey,
      required provider,
      required conversationId,
      required messages,
      required timeout,
      cancelToken,
    }) async {
      if (_isCoordinatorPrompt(messages)) {
        return _turn(update: '本轮公开结论已经收集齐全。', percent: 100);
      }
      memberPrompts.add(messages);
      return memberResponse(memberPrompts.length);
    },
  );
  await runner.runDiscussion(task, WorkTaskCancellation(), (state) async {
    latest = state;
    task.executionStateJson = WorkDiscussionState.mergeIntoExecutionState(
      task.executionStateJson,
      state,
    );
    return task;
  });
  return (state: latest, memberPrompts: memberPrompts);
}

void main() {
  late Directory directory;
  late DatabaseService database;

  setUp(() async {
    directory = await openLifecycleHive();
    database = DatabaseService();
  });

  tearDown(() async {
    await closeLifecycleHive(directory, database);
  });

  test('preserves the configured StepFun quota endpoint for discussion', () {
    final stepPlanConfig = ApiConfig(
      name: 'step-plan',
      provider: 'custom',
      modelName: 'step-3.5-flash',
      customBaseUrl: 'https://api.stepfun.com/step_plan/v1',
    );
    final ordinaryConfig = ApiConfig(
      name: 'ordinary',
      provider: 'custom',
      modelName: 'custom-model',
      customBaseUrl: 'https://example.com/step_plan/v1',
    );

    expect(
      WorkDiscussionRunner.structuredDiscussionBaseUrlFor(stepPlanConfig),
      stepPlanConfig.customBaseUrl,
    );
    expect(
      WorkDiscussionRunner.structuredDiscussionBaseUrlFor(ordinaryConfig),
      ordinaryConfig.customBaseUrl,
    );
  });

  test('adds a sanitized local project dossier for an explicit task path',
      () async {
    final project =
        await Directory.systemTemp.createTemp('discussion-project-');
    try {
      await File('${project.path}/pubspec.yaml').writeAsString('name: demo');
      await Directory('${project.path}/lib').create();
      await Directory('${project.path}/docs').create();
      await Directory('${project.path}/.nightly').create();
      await Directory('${project.path}/scripts').create();
      await File('${project.path}/lib/main.dart')
          .writeAsString('void main() {}');
      await File('${project.path}/embedding_server.py')
          .writeAsString('from threading import Lock\n_model_lock = Lock()');
      await Directory('${project.path}/lib/services').create(recursive: true);
      await File('${project.path}/lib/services/embedding_service.dart')
          .writeAsString('class EmbeddingService {}');
      await Directory('${project.path}/test').create();
      await File('${project.path}/test/semantic_scorer_test.dart')
          .writeAsString(
        'CalibrationCurve ManualSimilarityOverrides SemanticScoreRules fallback',
      );
      await File('${project.path}/.nightly/nightly_launcher.sh').writeAsString(
        'exec scripts/nightly_train_v26.sh',
      );
      await File('${project.path}/scripts/nightly_train_v26.sh').writeAsString(
        'LOCK_DIR=x\ntrap cleanup EXIT',
      );
      final config = ApiConfig(
        id: 'cfg-project-dossier',
        name: 'project-dossier',
        provider: 'deepseek',
        modelName: 'deepseek-chat',
        hasCredential: true,
        credentialId: 'credential-project-dossier',
      );
      await database.apiConfigBox.put(config.id, config);
      final character = _character(
        'project-dossier-product',
        '产品',
        '产品经理',
        config.id,
      );
      await database.aiCharacterBox.put(character.id, character);
      final group = ChatGroup(
        id: 'project-dossier-group',
        name: '项目清单群',
        theme: '需求讨论',
        aiCharacterIds: [character.id],
      );
      await database.chatGroupBox.put(group.id, group);
      final task = _task(
        group: group,
        request: '读取${project.path} 并制定需求文档',
        executorId: character.id,
        members: [character.id],
      );
      var sawDossier = false;
      var sawNoHallucinatedBlockerGuard = false;
      var sawProjectScopeGuard = false;
      final runner = WorkDiscussionRunner(
        database: database,
        credentials: _Credentials(),
        completion: ({
          required character,
          required config,
          required apiKey,
          required provider,
          required conversationId,
          required messages,
          required timeout,
          cancelToken,
        }) async {
          final systemPrompt = messages.first['content'].toString();
          final prompt = messages.last['content'].toString();
          sawDossier = sawDossier ||
              (prompt.contains('本地或在线语义 embedding 能力') &&
                  prompt.contains('embedding_server.py') &&
                  prompt.contains('lib/main.dart') &&
                  prompt.contains('embedding_server.py 已用 _model_lock') &&
                  prompt.contains('semantic_scorer_test.dart 已覆盖') &&
                  prompt.contains('项目根目录已存在 docs/ 文档目录') &&
                  prompt.contains('.nightly/nightly_launcher.sh 是转发') &&
                  !prompt.contains(project.path));
          sawNoHallucinatedBlockerGuard = sawNoHallucinatedBlockerGuard ||
              systemPrompt.contains('不存在的文件、日志、指标当作事实或阻塞问题');
          sawProjectScopeGuard = sawProjectScopeGuard ||
              (systemPrompt.contains('区块链、DID、Gas、支付、链上存证') &&
                  prompt.contains('本轮项目范围聚焦'));
          return _turn(update: '已基于项目清单讨论。', percent: 70);
        },
      );
      await runner.runDiscussion(task, WorkTaskCancellation(), (state) async {
        task.executionStateJson = WorkDiscussionState.mergeIntoExecutionState(
          task.executionStateJson,
          state,
        );
        return task;
      });

      expect(sawDossier, isTrue);
      expect(sawNoHallucinatedBlockerGuard, isTrue);
      expect(sawProjectScopeGuard, isTrue);
    } finally {
      await project.delete(recursive: true);
    }
  });

  test(
      'gives every role its own turn, then lets the elected executor summarize',
      () async {
    final configs = <ApiConfig>[
      ApiConfig(
        id: 'cfg-product',
        name: 'product',
        provider: 'deepseek',
        modelName: 'deepseek-chat',
        hasCredential: true,
        credentialId: 'credential-product',
      ),
      ApiConfig(
        id: 'cfg-front',
        name: 'front',
        provider: 'deepseek',
        modelName: 'deepseek-chat',
        hasCredential: true,
        credentialId: 'credential-front',
      ),
      ApiConfig(
        id: 'cfg-test',
        name: 'test',
        provider: 'deepseek',
        modelName: 'deepseek-chat',
        hasCredential: true,
        credentialId: 'credential-test',
      ),
    ];
    for (final config in configs) {
      await database.apiConfigBox.put(config.id, config);
    }
    final characters = <AICharacter>[
      _character('product', '产品', '产品经理', 'cfg-product'),
      _character('front', '前端', '前端工程师', 'cfg-front'),
      _character('test', '测试', '测试工程师', 'cfg-test'),
    ];
    for (final character in characters) {
      await database.aiCharacterBox.put(character.id, character);
    }
    final group = ChatGroup(
      id: 'discussion-group',
      name: '讨论群',
      theme: '产品开发',
      aiCharacterIds: characters.map((character) => character.id).toList(),
    );
    await database.chatGroupBox.put(group.id, group);

    final contract = <String, dynamic>{
      'deliverableType': 'source',
      'format': 'html',
      'location': 'desktop.html',
      'contentScope': '实现前端 HTML 页面并写入 desktop.html',
      'explicitExecutorId': null,
      'revisionTarget': '',
      'requestRevision': 1,
    };
    final task = AgentTask(
      id: 'discussion-task',
      groupId: group.id,
      characterId: '',
      userRequest: '实现前端 HTML 页面并写入 desktop.html',
      assignedCharacterIds: const ['front'],
      workModeTask: true,
    )..executionStateJson = WorkDiscussionState.mergeIntoExecutionState(
        '',
        WorkDiscussionState.initial(
          conversationId: group.id,
          executorId: null,
          candidateCharacterIds: const ['front'],
          participantCharacterIds: characters.map((item) => item.id),
          deliverableContract: contract,
        ),
      );

    final callIds = <String>[];
    final updates = <WorkDiscussionState>[];
    final runner = WorkDiscussionRunner(
      database: database,
      credentials: _Credentials(),
      completion: ({
        required character,
        required config,
        required apiKey,
        required provider,
        required conversationId,
        required messages,
        required timeout,
        cancelToken,
      }) async {
        callIds.add(character.id);
        final coordinator =
            messages.first['content'].toString().contains('协调/执行人');
        return <String, dynamic>{
          'success': true,
          'message': jsonEncode(<String, dynamic>{
            'public_update':
                coordinator ? '已取舍方案，确认由前端角色执行。' : '${character.name}完成职责评估。',
            'understanding_percent': coordinator ? 100 : 70,
            'understanding_evidence': const [
              '目标和范围已确认。',
              '方案取舍与角色职责已确认。',
              'HTML 格式、桌面位置和验收方式已确认。',
            ],
            'open_questions': const <String>[],
            'blockers': const <String>[],
            'recommend_executor_id': 'front',
            'substantive_progress': true,
          }),
        };
      },
    );

    final cancellation = WorkTaskCancellation();
    await runner.runDiscussion(task, cancellation, (state) async {
      updates.add(state);
      task.executionStateJson = WorkDiscussionState.mergeIntoExecutionState(
        task.executionStateJson,
        state,
      );
      return task;
    });

    final finalState = WorkDiscussionState.fromExecutionState(
      task.executionStateJson,
    )!;
    expect(finalState.isExecutionReady, isTrue);
    expect(finalState.executorId, 'front');
    expect(finalState.deliverableContract?['explicitExecutorId'], isNull);
    expect(finalState.understandingPercent, 100);
    expect(callIds.take(3), ['product', 'front', 'test']);
    expect(
        callIds.where((id) => id == 'product').length, greaterThanOrEqualTo(2));
    expect(callIds.where((id) => id == 'test').length, greaterThanOrEqualTo(2));
    expect(
        updates.map((state) => state.round).toSet(), containsAll(<int>[1, 2]));
    final messages = database.messageBox.values
        .where((message) => message.groupId == group.id)
        .toList();
    expect(messages.any((message) => message.senderId == 'product'), isTrue);
    expect(messages.any((message) => message.senderId == 'front'), isTrue);
    expect(messages.any((message) => message.senderId == 'test'), isTrue);
    expect(messages.where((message) => message.content.contains('理解进度')).length,
        greaterThanOrEqualTo(2));
  });

  test('protocol repair preserves executor recommendations and contract',
      () async {
    for (final id in ['front-a', 'front-b']) {
      await database.apiConfigBox.put(
        'cfg-$id',
        ApiConfig(
          id: 'cfg-$id',
          name: id,
          provider: 'deepseek',
          modelName: 'deepseek-chat',
          hasCredential: true,
          credentialId: 'credential-$id',
        ),
      );
      await database.aiCharacterBox.put(
        id,
        _character(id, id, '前端工程师', 'cfg-$id'),
      );
    }
    const request = '实现前端 HTML 页面，随后进行测试验收';
    const candidateIds = ['front-a', 'front-b'];
    final group = ChatGroup(
      id: 'repair-vote-group',
      name: '协议修复讨论群',
      theme: '前端开发与测试',
      aiCharacterIds: candidateIds,
    );
    await database.chatGroupBox.put(group.id, group);
    final task = AgentTask(
      id: 'repair-vote-task',
      groupId: group.id,
      characterId: '',
      userRequest: request,
      assignedCharacterIds: candidateIds,
      workModeTask: true,
    )..executionStateJson = WorkDiscussionState.mergeIntoExecutionState(
        '',
        WorkDiscussionState.initial(
          conversationId: group.id,
          coordinatorId: 'front-a',
          executorId: null,
          candidateCharacterIds: candidateIds,
          participantCharacterIds: candidateIds,
          deliverableContract: <String, dynamic>{
            'deliverableType': 'source',
            'format': 'unspecified',
            'location': 'unspecified',
            'contentScope': request,
            'explicitExecutorId': null,
            'revisionTarget': '',
            'requestRevision': 1,
          },
        ),
      );

    final repairSchemas = <String>[];
    final runner = WorkDiscussionRunner(
      database: database,
      credentials: _Credentials(),
      completion: ({
        required character,
        required config,
        required apiKey,
        required provider,
        required conversationId,
        required messages,
        required timeout,
        cancelToken,
      }) async {
        final systemPrompt = messages.first['content'].toString();
        if (!systemPrompt.contains('严格的 JSON 协议修复器')) {
          return <String, dynamic>{
            'success': true,
            'message':
                '我推荐 front-b 作为执行人，交付 HTML 页面到 Desktop/doudizhu_game.html。',
          };
        }

        repairSchemas.add(systemPrompt);
        return <String, dynamic>{
          'success': true,
          'message': jsonEncode(<String, dynamic>{
            'public_update': '已确认由 front-b 实现桌面 HTML 页面。',
            'understanding_percent': 100,
            'understanding_evidence': const [
              '目标和范围已确认。',
              '由 front-b 负责前端实现。',
              'HTML 格式、桌面路径和验收方式已确认。',
            ],
            'open_questions': const <String>[],
            'resolved_questions': const <String>[],
            'blockers': const <String>[],
            'resolved_blockers': const <String>[],
            'substantive_progress': true,
            'needs_user': false,
            'user_question': '',
            if (systemPrompt.contains('recommend_executor_id'))
              'recommend_executor_id': 'front-b',
            if (systemPrompt.contains('contract（对象或 null）'))
              'contract': <String, dynamic>{
                'format': 'html',
                'location': 'Desktop/doudizhu_game.html',
                'requestRevision': 1,
              },
          }),
        };
      },
    );

    await runner.runDiscussion(task, WorkTaskCancellation(), (state) async {
      task.executionStateJson = WorkDiscussionState.mergeIntoExecutionState(
        task.executionStateJson,
        state,
      );
      return task;
    });

    final finalState = WorkDiscussionState.fromExecutionState(
      task.executionStateJson,
    )!;
    expect(repairSchemas, isNotEmpty);
    expect(
      repairSchemas.every((prompt) =>
          prompt.contains('recommend_executor_id') &&
          prompt.contains('contract（对象或 null）')),
      isTrue,
    );
    expect(finalState.isExecutionReady, isTrue);
    expect(finalState.executorId, 'front-b');
    expect(finalState.deliverableContract?['format'], 'html');
    expect(
      finalState.deliverableContract?['location'],
      'Desktop/doudizhu_game.html',
    );
  });

  test('a QA revision routes from its current Markdown contract', () async {
    final configs = [
      for (final id in ['product', 'front', 'test'])
        ApiConfig(
          id: 'cfg-$id',
          name: id,
          provider: 'deepseek',
          modelName: 'deepseek-chat',
          hasCredential: true,
          credentialId: 'credential-$id',
        ),
    ];
    for (final config in configs) {
      await database.apiConfigBox.put(config.id, config);
    }
    final characters = <AICharacter>[
      _character('product', '产品', '产品经理', 'cfg-product'),
      _character('front', '前端', '前端工程师', 'cfg-front'),
      _character('test', '测试', '测试工程师', 'cfg-test'),
    ];
    for (final character in characters) {
      await database.aiCharacterBox.put(character.id, character);
    }
    final group = ChatGroup(
      id: 'qa-revision-group',
      name: 'QA 修订群',
      theme: '斗地主验收',
      aiCharacterIds: characters.map((item) => item.id).toList(),
    );
    await database.chatGroupBox.put(group.id, group);
    const qaScope = 'Test the existing Desktop/doudizhu_game.html against '
        'Desktop/doudizhu_design.md and create Desktop/doudizhu_test_report.md; '
        'only fix the HTML if QA finds a defect.';
    const request = 'Create the playable HTML game and save it to '
        'Desktop/doudizhu_game.html first. 用户补充要求：$qaScope';
    final task = AgentTask(
      id: 'qa-revision-task',
      groupId: group.id,
      characterId: '',
      userRequest: request,
      assignedCharacterIds: characters.map((item) => item.id).toList(),
      workModeTask: true,
    )..executionStateJson = WorkDiscussionState.mergeIntoExecutionState(
        '',
        WorkDiscussionState.initial(
          conversationId: group.id,
          requestRevision: 2,
          participantCharacterIds: characters.map((item) => item.id),
          deliverableContract: <String, dynamic>{
            'deliverableType': 'document',
            'format': 'markdown',
            'location': 'doudizhu_test_report.md',
            'contentScope': qaScope,
            'explicitExecutorId': null,
            'revisionTarget': '',
            'requestRevision': 2,
          },
        ),
      );
    final observedPrompts = <String>[];
    final runner = WorkDiscussionRunner(
      database: database,
      credentials: _Credentials(),
      completion: ({
        required character,
        required config,
        required apiKey,
        required provider,
        required conversationId,
        required messages,
        required timeout,
        cancelToken,
      }) async {
        observedPrompts.add(
          messages.map((message) => message['content'].toString()).join('\n'),
        );
        return <String, dynamic>{
          'success': true,
          'message': jsonEncode(<String, dynamic>{
            'public_update': '${character.name}确认测试阶段职责。',
            'understanding_percent': 100,
            'understanding_evidence': const [
              '当前阶段是对现有 HTML 文件执行 QA。',
              '测试工程师负责执行用例并输出 Markdown 报告。',
              '修复仅在 QA 发现缺陷后启动。',
            ],
            'open_questions': const <String>[],
            'blockers': const <String>[],
            'recommend_executor_id': 'test',
            'substantive_progress': true,
          }),
        };
      },
    );

    await runner.runDiscussion(task, WorkTaskCancellation(), (state) async {
      task.executionStateJson = WorkDiscussionState.mergeIntoExecutionState(
        task.executionStateJson,
        state,
      );
      return task;
    });

    final finalState = WorkDiscussionState.fromExecutionState(
      task.executionStateJson,
    )!;
    expect(finalState.isExecutionReady, isTrue);
    expect(finalState.executorId, 'test');
    expect(finalState.candidateCharacterIds, ['test']);
    expect(observedPrompts, isNotEmpty);
    expect(observedPrompts.every((prompt) => prompt.contains(qaScope)), isTrue);
    expect(
      observedPrompts.every(
        (prompt) => !prompt.contains('Create the playable HTML game'),
      ),
      isTrue,
    );
  });

  test('fresh discussion honors an explicit final executor mention', () async {
    final configs = <ApiConfig>[
      ApiConfig(
        id: 'cfg-front-a',
        name: 'front-a',
        provider: 'deepseek',
        modelName: 'deepseek-chat',
        hasCredential: true,
        credentialId: 'credential-front-a',
      ),
      ApiConfig(
        id: 'cfg-front-b',
        name: 'front-b',
        provider: 'deepseek',
        modelName: 'deepseek-chat',
        hasCredential: true,
        credentialId: 'credential-front-b',
      ),
    ];
    for (final config in configs) {
      await database.apiConfigBox.put(config.id, config);
    }
    final characters = <AICharacter>[
      _character('front-a', '前端甲', '前端工程师', 'cfg-front-a'),
      _character('front-b', '前端乙', '前端工程师', 'cfg-front-b'),
    ];
    for (final character in characters) {
      await database.aiCharacterBox.put(character.id, character);
    }
    final group = ChatGroup(
      id: 'fresh-explicit-owner-group',
      name: '新任务讨论群',
      theme: '网页',
      aiCharacterIds: characters.map((character) => character.id).toList(),
    );
    await database.chatGroupBox.put(group.id, group);

    const request = '新建一个 html 页面，保存到 desktop.html，最后由@前端乙输出';
    final task = AgentTask(
      id: 'fresh-explicit-owner-task',
      groupId: group.id,
      characterId: '',
      userRequest: request,
      assignedCharacterIds: const [],
      workModeTask: true,
    )..executionStateJson = WorkDiscussionState.mergeIntoExecutionState(
        '',
        WorkDiscussionState.initial(
          conversationId: group.id,
          executorId: null,
          candidateCharacterIds: const [],
          participantCharacterIds: const [],
          deliverableContract: const <String, dynamic>{
            'deliverableType': 'source',
            'format': 'html',
            'location': 'desktop.html',
            'contentScope': request,
            'explicitExecutorId': null,
            'revisionTarget': '',
            'requestRevision': 1,
          },
        ),
      );

    final calls = <String>[];
    final runner = WorkDiscussionRunner(
      database: database,
      credentials: _Credentials(),
      completion: ({
        required character,
        required config,
        required apiKey,
        required provider,
        required conversationId,
        required messages,
        required timeout,
        cancelToken,
      }) async {
        calls.add(character.id);
        final coordinator =
            messages.first['content'].toString().contains('协调/执行人');
        return <String, dynamic>{
          'success': true,
          'message': jsonEncode(<String, dynamic>{
            'public_update': '${character.name}已给出职业意见。',
            'understanding_percent': coordinator ? 100 : 70,
            'understanding_evidence': const [
              '目标和范围已确认。',
              '方案取舍与角色职责已确认。',
              'HTML 格式、桌面位置和验收方式已确认。',
            ],
            'open_questions': const <String>[],
            'blockers': const <String>[],
            // Deliberately recommend the other qualified role; the explicit
            // final mention must remain authoritative.
            'recommend_executor_id': 'front-a',
            'substantive_progress': true,
          }),
        };
      },
    );

    await runner.runDiscussion(task, WorkTaskCancellation(), (state) async {
      task.executionStateJson = WorkDiscussionState.mergeIntoExecutionState(
        task.executionStateJson,
        state,
      );
      return task;
    });

    final finalState = WorkDiscussionState.fromExecutionState(
      task.executionStateJson,
    )!;
    expect(finalState.isExecutionReady, isTrue);
    expect(finalState.executorId, 'front-b');
    expect(finalState.deliverableContract?['explicitExecutorId'], 'front-b');
    expect(calls, contains('front-b'));
  });

  test('normalizes a fully converged conservative 99 percent summary to 100',
      () async {
    final config = ApiConfig(
      id: 'cfg-converged-99',
      name: 'converged-99',
      provider: 'deepseek',
      modelName: 'deepseek-chat',
      hasCredential: true,
      credentialId: 'credential-converged-99',
    );
    await database.apiConfigBox.put(config.id, config);
    final character = _character('converged-99', '执行人', '前端工程师', config.id);
    await database.aiCharacterBox.put(character.id, character);
    final group = ChatGroup(
      id: 'converged-99-group',
      name: '收敛群',
      theme: '需求文档',
      aiCharacterIds: [character.id],
    );
    await database.chatGroupBox.put(group.id, group);
    final task = _task(
      group: group,
      request: '实现 HTML 页面并写入 desktop.html',
      executorId: character.id,
      members: [character.id],
    );
    final runner = WorkDiscussionRunner(
      database: database,
      credentials: _Credentials(),
      completion: ({
        required character,
        required config,
        required apiKey,
        required provider,
        required conversationId,
        required messages,
        required timeout,
        cancelToken,
      }) async =>
          _turn(
        update: '目标、方案、交付位置和验收均已收敛。',
        percent: 99,
      ),
    );

    await runner.runDiscussion(task, WorkTaskCancellation(), (state) async {
      task.executionStateJson = WorkDiscussionState.mergeIntoExecutionState(
        task.executionStateJson,
        state,
      );
      return task;
    });

    final finalState = WorkDiscussionState.fromExecutionState(
      task.executionStateJson,
    )!;
    expect(finalState.isExecutionReady, isTrue);
    expect(finalState.understandingPercent, 100);
  });

  test('keeps a deferred-scope decision question open', () async {
    final config = ApiConfig(
      id: 'cfg-deferred-scope-question',
      name: 'deferred-scope-question',
      provider: 'deepseek',
      modelName: 'deepseek-chat',
      hasCredential: true,
      credentialId: 'credential-deferred-scope-question',
    );
    await database.apiConfigBox.put(config.id, config);
    final character = _character(
      'deferred-scope-question',
      '执行人',
      '前端工程师',
      config.id,
    );
    await database.aiCharacterBox.put(character.id, character);
    final group = ChatGroup(
      id: 'deferred-scope-question-group',
      name: '范围确认群',
      theme: '需求讨论',
      aiCharacterIds: [character.id],
    );
    await database.chatGroupBox.put(group.id, group);
    final task = _task(
      group: group,
      request: '实现 HTML 页面并写入 desktop.html',
      executorId: character.id,
      members: [character.id],
    );
    const question = '是否本轮不重构区块链能力？';
    task.executionStateJson = WorkDiscussionState.mergeIntoExecutionState(
      '',
      WorkDiscussionState.initial(
        conversationId: group.id,
        executorId: character.id,
        candidateCharacterIds: [character.id],
        participantCharacterIds: [character.id],
        openQuestions: [question],
        deliverableContract: _contract(executorId: character.id),
      ),
    );
    final runner = WorkDiscussionRunner(
      database: database,
      credentials: _Credentials(),
      completion: ({
        required character,
        required config,
        required apiKey,
        required provider,
        required conversationId,
        required messages,
        required timeout,
        cancelToken,
      }) async =>
          _turn(update: '继续评估实现边界。', percent: 70),
    );

    await runner.runDiscussion(task, WorkTaskCancellation(), (state) async {
      task.executionStateJson = WorkDiscussionState.mergeIntoExecutionState(
        task.executionStateJson,
        state,
      );
      return task;
    });

    final finalState = WorkDiscussionState.fromExecutionState(
      task.executionStateJson,
    )!;
    expect(finalState.openQuestions, contains(question));
    expect(finalState.isExecutionReady, isFalse);
  });

  test(
      'keeps a model claimed 100 percent blocked while a critical question remains',
      () async {
    final config = ApiConfig(
      id: 'cfg-front',
      name: 'front',
      provider: 'deepseek',
      modelName: 'deepseek-chat',
      hasCredential: true,
      credentialId: 'credential-front',
    );
    await database.apiConfigBox.put(config.id, config);
    final character = _character('front', '前端', '前端工程师', config.id);
    await database.aiCharacterBox.put(character.id, character);
    final group = ChatGroup(
      id: 'blocked-group',
      name: '等待群',
      theme: '网页',
      aiCharacterIds: [character.id],
    );
    await database.chatGroupBox.put(group.id, group);
    await database.userProfileBox.put(
      'me',
      UserProfile(
        displayName: '小明',
        preferredAddress: '小明',
        avatar: '',
        bio: '',
      ),
    );
    final task = AgentTask(
      id: 'blocked-task',
      groupId: group.id,
      characterId: character.id,
      userRequest: '实现前端 HTML 页面并写入 desktop.html',
      assignedCharacterIds: [character.id],
      workModeTask: true,
    )..executionStateJson = WorkDiscussionState.mergeIntoExecutionState(
        '',
        WorkDiscussionState.initial(
          conversationId: group.id,
          executorId: character.id,
          candidateCharacterIds: [character.id],
          participantCharacterIds: [character.id],
          deliverableContract: const <String, dynamic>{
            'deliverableType': 'source',
            'format': 'html',
            'location': 'desktop.html',
            'contentScope': '实现页面',
            'explicitExecutorId': 'front',
            'revisionTarget': '',
            'requestRevision': 1,
          },
        ),
      );
    final runner = WorkDiscussionRunner(
      database: database,
      credentials: _Credentials(),
      completion: ({
        required character,
        required config,
        required apiKey,
        required provider,
        required conversationId,
        required messages,
        required timeout,
        cancelToken,
      }) async =>
          <String, dynamic>{
        'success': true,
        'message': jsonEncode(<String, dynamic>{
          'public_update': '看起来已经完全理解。',
          'understanding_percent': 100,
          'understanding_evidence': const ['目标已理解。'],
          'open_questions': const ['桌面文件名仍需用户确认。'],
          'blockers': const <String>[],
          'substantive_progress': true,
          'needs_user': true,
          'user_question': '请确认最终桌面文件名。',
        }),
      },
    );
    WorkDiscussionState? latest;
    await runner.runDiscussion(task, WorkTaskCancellation(), (state) async {
      latest = state;
      task.executionStateJson = WorkDiscussionState.mergeIntoExecutionState(
        task.executionStateJson,
        state,
      );
      return task;
    });
    expect(latest, isNotNull);
    expect(latest!.isExecutionReady, isFalse);
    expect(latest!.understandingPercent, lessThan(100));
    expect(latest!.phase, WorkDiscussionPhase.blocked);
    expect(
      database.messageBox.values.any(
        (message) =>
            message.content.contains('@小明') &&
            message.content.contains('最终桌面文件名'),
      ),
      isFalse,
    );
  });

  test('does not resolve a question introduced in the same turn', () async {
    final config = ApiConfig(
      id: 'cfg-conflict',
      name: 'conflict',
      provider: 'deepseek',
      modelName: 'deepseek-chat',
      hasCredential: true,
      credentialId: 'credential-conflict',
    );
    await database.apiConfigBox.put(config.id, config);
    final character = _character('conflict', '前端', '前端工程师', config.id);
    await database.aiCharacterBox.put(character.id, character);
    final group = ChatGroup(
      id: 'same-turn-conflict-group',
      name: '同轮冲突群',
      theme: '网页',
      aiCharacterIds: [character.id],
    );
    await database.chatGroupBox.put(group.id, group);
    final task = _task(
      group: group,
      request: '实现 HTML 页面',
      executorId: character.id,
      members: [character.id],
    );
    const question = '移动端验收范围仍需确认。';
    WorkDiscussionState? latest;
    final runner = WorkDiscussionRunner(
      database: database,
      credentials: _Credentials(),
      completion: ({
        required character,
        required config,
        required apiKey,
        required provider,
        required conversationId,
        required messages,
        required timeout,
        cancelToken,
      }) async =>
          _turn(
        update: '提出并声称解决同一个问题。',
        percent: 100,
        questions: const [question],
        resolvedQuestions: const [question],
      ),
    );
    await runner.runDiscussion(task, WorkTaskCancellation(), (state) async {
      latest = state;
      task.executionStateJson = WorkDiscussionState.mergeIntoExecutionState(
        task.executionStateJson,
        state,
      );
      return task;
    });
    expect(latest, isNotNull);
    expect(latest!.openQuestions, contains(question));
    expect(latest!.understandingPercent, lessThan(100));
    expect(latest!.isExecutionReady, isFalse);
  });

  test('does not let a discussion suggestion override the Word contract',
      () async {
    final config = ApiConfig(
      id: 'cfg-contract',
      name: 'contract',
      provider: 'deepseek',
      modelName: 'deepseek-chat',
      hasCredential: true,
      credentialId: 'credential-contract',
    );
    await database.apiConfigBox.put(config.id, config);
    final character = _character('contract', '产品', '产品经理', config.id);
    await database.aiCharacterBox.put(character.id, character);
    final group = ChatGroup(
      id: 'contract-group',
      name: '合同群',
      theme: '需求文档',
      aiCharacterIds: [character.id],
    );
    await database.chatGroupBox.put(group.id, group);
    final task = _task(
      group: group,
      request: '出具 Word 文档并保存到桌面',
      executorId: character.id,
      members: [character.id],
    );
    task.executionStateJson = WorkDiscussionState.mergeIntoExecutionState(
      task.executionStateJson,
      WorkDiscussionState.initial(
        conversationId: group.id,
        executorId: character.id,
        candidateCharacterIds: [character.id],
        participantCharacterIds: [character.id],
        deliverableContract: _contract(
          executorId: character.id,
          format: 'docx',
          location: 'desktop',
        ),
      ),
    );
    WorkDiscussionState? latest;
    final runner = WorkDiscussionRunner(
      database: database,
      credentials: _Credentials(),
      completion: ({
        required character,
        required config,
        required apiKey,
        required provider,
        required conversationId,
        required messages,
        required timeout,
        cancelToken,
      }) async =>
          _turn(
        update: '建议改用 Markdown 交付。',
        percent: 100,
        contract: const <String, dynamic>{
          'format': 'markdown',
          'location': 'notes.md',
          'explicitExecutorId': 'unqualified-other-role',
        },
      ),
    );
    await runner.runDiscussion(task, WorkTaskCancellation(), (state) async {
      latest = state;
      task.executionStateJson = WorkDiscussionState.mergeIntoExecutionState(
        task.executionStateJson,
        state,
      );
      return task;
    });
    expect(latest, isNotNull);
    expect(latest!.isExecutionReady, isTrue);
    expect(latest!.deliverableContract?['format'], 'docx');
    expect(latest!.deliverableContract?['location'], 'desktop');
  });

  test('executor assessment owns progress while member evidence is retained',
      () async {
    final config = ApiConfig(
      id: 'cfg-progress',
      name: 'progress',
      provider: 'deepseek',
      modelName: 'deepseek-chat',
      hasCredential: true,
      credentialId: 'credential-progress',
    );
    await database.apiConfigBox.put(config.id, config);
    final character = _character('progress', '执行人', '前端工程师', config.id);
    await database.aiCharacterBox.put(character.id, character);
    final group = ChatGroup(
      id: 'progress-group',
      name: '进度群',
      theme: '网页',
      aiCharacterIds: [character.id],
    );
    await database.chatGroupBox.put(group.id, group);
    final task = _task(
      group: group,
      request: '实现 HTML 页面',
      executorId: character.id,
      members: [character.id],
    );
    var summaryCount = 0;
    final updates = <WorkDiscussionState>[];
    final runner = WorkDiscussionRunner(
      database: database,
      credentials: _Credentials(),
      completion: ({
        required character,
        required config,
        required apiKey,
        required provider,
        required conversationId,
        required messages,
        required timeout,
        cancelToken,
      }) async {
        final isSummary =
            messages.first['content'].toString().contains('协调/执行人');
        if (isSummary) summaryCount++;
        return _turn(
          update: isSummary ? '汇总第$summaryCount轮' : '成员确认可行性。',
          percent: isSummary && summaryCount == 1 ? 40 : 100,
          evidence: isSummary
              ? const ['执行人摘要证据。']
              : const ['成员目标证据。', '成员方案证据。', '成员格式证据。'],
        );
      },
    );
    await runner.runDiscussion(task, WorkTaskCancellation(), (state) async {
      updates.add(state);
      task.executionStateJson = WorkDiscussionState.mergeIntoExecutionState(
        task.executionStateJson,
        state,
      );
      return task;
    });

    expect(updates.where((state) => state.round == 1).last.understandingPercent,
        40);
    final finalState = WorkDiscussionState.fromExecutionState(
      task.executionStateJson,
    )!;
    expect(finalState.isExecutionReady, isTrue);
    expect(finalState.understandingEvidence.length, greaterThanOrEqualTo(3));
  });

  test('member confidence never releases a low-confidence executor', () async {
    final config = ApiConfig(
      id: 'cfg-progress',
      name: 'progress',
      provider: 'deepseek',
      modelName: 'deepseek-chat',
      hasCredential: true,
      credentialId: 'credential-progress',
    );
    await database.apiConfigBox.put(config.id, config);
    final character = _character('progress', '执行人', '前端工程师', config.id);
    await database.aiCharacterBox.put(character.id, character);
    final group = ChatGroup(
      id: 'progress-group',
      name: '进度群',
      theme: '网页',
      aiCharacterIds: [character.id],
    );
    await database.chatGroupBox.put(group.id, group);
    final task = _task(
      group: group,
      request: '实现 HTML 页面',
      executorId: character.id,
      members: [character.id],
    );
    var summaryCount = 0;
    final updates = <WorkDiscussionState>[];
    final runner = WorkDiscussionRunner(
      database: database,
      credentials: _Credentials(),
      completion: ({
        required character,
        required config,
        required apiKey,
        required provider,
        required conversationId,
        required messages,
        required timeout,
        cancelToken,
      }) async {
        final isSummary =
            messages.first['content'].toString().contains('协调/执行人');
        if (isSummary) summaryCount++;
        return _turn(
          update: isSummary ? '汇总第$summaryCount轮' : '成员确认可行性。',
          percent: isSummary ? 20 : 100,
          evidence: isSummary
              ? const ['执行人摘要证据。']
              : const ['成员目标证据。', '成员方案证据。', '成员格式证据。'],
        );
      },
    );
    await runner.runDiscussion(task, WorkTaskCancellation(), (state) async {
      updates.add(state);
      task.executionStateJson = WorkDiscussionState.mergeIntoExecutionState(
        task.executionStateJson,
        state,
      );
      return task;
    });

    expect(updates.where((state) => state.round == 1).last.understandingPercent,
        20);
    final finalState = WorkDiscussionState.fromExecutionState(
      task.executionStateJson,
    )!;
    expect(finalState.isExecutionReady, isFalse);
    expect(finalState.understandingEvidence.length, greaterThanOrEqualTo(3));
  });

  test('publishes the latest executor assessment even when confidence falls',
      () async {
    final config = ApiConfig(
      id: 'cfg-monotonic-public-progress',
      name: 'monotonic-public-progress',
      provider: 'deepseek',
      modelName: 'deepseek-chat',
      hasCredential: true,
      credentialId: 'credential-monotonic-public-progress',
    );
    await database.apiConfigBox.put(config.id, config);
    final character = _character(
      'monotonic-progress',
      '执行人',
      '前端工程师',
      config.id,
    );
    await database.aiCharacterBox.put(character.id, character);
    final group = ChatGroup(
      id: 'monotonic-public-progress-group',
      name: '公开进度群',
      theme: '复杂网页架构',
      aiCharacterIds: [character.id],
    );
    await database.chatGroupBox.put(group.id, group);
    final task = _task(
      group: group,
      request: '复杂系统架构与跨模块集成，实现 HTML 页面',
      executorId: character.id,
      members: [character.id],
    );
    var summaryCount = 0;
    final runner = WorkDiscussionRunner(
      database: database,
      credentials: _Credentials(),
      completion: ({
        required character,
        required config,
        required apiKey,
        required provider,
        required conversationId,
        required messages,
        required timeout,
        cancelToken,
      }) async {
        final isSummary =
            messages.first['content'].toString().contains('协调/执行人');
        final percent = isSummary
            ? switch (++summaryCount) {
                1 => 80,
                2 => 20,
                _ => 100,
              }
            : 60;
        return _turn(
          update: isSummary ? '摘要$summaryCount' : '成员确认方案',
          percent: percent,
        );
      },
    );
    await runner.runDiscussion(task, WorkTaskCancellation(), (state) async {
      task.executionStateJson = WorkDiscussionState.mergeIntoExecutionState(
        task.executionStateJson,
        state,
      );
      return task;
    });

    final discussionMessages = database.messageBox.values
        .where((message) => message.groupId == group.id)
        .toList()
      ..sort((left, right) => left.timestamp.compareTo(right.timestamp));
    final percentages = discussionMessages
        .map(
            (message) => RegExp(r'\[理解进度 (\d+)%\]').firstMatch(message.content))
        .whereType<RegExpMatch>()
        .map((match) => int.parse(match.group(1)!))
        .toList(growable: false);
    expect(percentages, [80, 20, 100]);
  });

  test('gives the coordinator the latest replies in a large discussion',
      () async {
    final config = ApiConfig(
      id: 'cfg-large-discussion',
      name: 'large-discussion',
      provider: 'deepseek',
      modelName: 'deepseek-chat',
      hasCredential: true,
      credentialId: 'credential-large-discussion',
    );
    await database.apiConfigBox.put(config.id, config);
    final characters = [
      for (var index = 0; index < 17; index++)
        _character(
          'large-$index',
          '成员$index',
          '前端工程师',
          config.id,
        ),
    ];
    for (final character in characters) {
      await database.aiCharacterBox.put(character.id, character);
    }
    final group = ChatGroup(
      id: 'large-discussion-group',
      name: '大群讨论',
      theme: '网页',
      aiCharacterIds: characters.map((character) => character.id).toList(),
    );
    await database.chatGroupBox.put(group.id, group);
    final task = _task(
      group: group,
      request: '实现 HTML 页面',
      executorId: characters.first.id,
      members: characters.map((character) => character.id),
    );
    var callCount = 0;
    var summaryCount = 0;
    var secondSummarySawLatestReply = false;
    final runner = WorkDiscussionRunner(
      database: database,
      credentials: _Credentials(),
      completion: ({
        required character,
        required config,
        required apiKey,
        required provider,
        required conversationId,
        required messages,
        required timeout,
        cancelToken,
      }) async {
        callCount++;
        final isSummary =
            messages.first['content'].toString().contains('协调/执行人');
        if (isSummary) {
          summaryCount++;
          if (summaryCount == 2) {
            secondSummarySawLatestReply =
                messages.last['content'].toString().contains('当前轮 large-16-r2');
          }
        }
        final round = callCount <= characters.length + 1 ? 1 : 2;
        return _turn(
          update:
              isSummary ? '汇总第$summaryCount轮' : '当前轮 ${character.id}-r$round',
          percent: isSummary && summaryCount == 2 ? 100 : 50,
        );
      },
    );
    await runner.runDiscussion(task, WorkTaskCancellation(), (state) async {
      task.executionStateJson = WorkDiscussionState.mergeIntoExecutionState(
        task.executionStateJson,
        state,
      );
      return task;
    });

    expect(secondSummarySawLatestReply, isTrue);
    expect(callCount, 36);
    expect(
      WorkDiscussionState.fromExecutionState(task.executionStateJson)!
          .isExecutionReady,
      isTrue,
    );
  });

  test('targets the role named by a later unresolved question', () async {
    final configIds = ['product', 'front', 'test'];
    for (final id in configIds) {
      await database.apiConfigBox.put(
        'cfg-$id',
        ApiConfig(
          id: 'cfg-$id',
          name: id,
          provider: 'deepseek',
          modelName: 'deepseek-chat',
          hasCredential: true,
          credentialId: 'credential-$id',
        ),
      );
    }
    final characters = <AICharacter>[
      _character('product', '产品', '产品经理', 'cfg-product'),
      _character('front', '前端', '前端工程师', 'cfg-front'),
      _character('test', '测试', '测试工程师', 'cfg-test'),
    ];
    for (final character in characters) {
      await database.aiCharacterBox.put(character.id, character);
    }
    final group = ChatGroup(
      id: 'targeted-group',
      name: '定向讨论群',
      theme: '网页',
      aiCharacterIds: characters.map((item) => item.id).toList(),
    );
    await database.chatGroupBox.put(group.id, group);
    final task = _task(
      group: group,
      request: '实现 HTML 页面',
      executorId: 'front',
      members: characters.map((item) => item.id),
    );
    final calls = <String>[];
    final runner = WorkDiscussionRunner(
      database: database,
      credentials: _Credentials(),
      completion: ({
        required character,
        required config,
        required apiKey,
        required provider,
        required conversationId,
        required messages,
        required timeout,
        cancelToken,
      }) async {
        calls.add(character.id);
        final firstProductTurn = character.id == 'product' &&
            calls.where((id) => id == 'product').length == 1;
        return _turn(
          update: '${character.name}提供了公开意见。',
          percent: 40,
          questions: firstProductTurn ? const ['请前端确认移动端交互可行性。'] : const [],
        );
      },
    );
    await runner.runDiscussion(task, WorkTaskCancellation(), (state) async {
      task.executionStateJson = WorkDiscussionState.mergeIntoExecutionState(
        task.executionStateJson,
        state,
      );
      return task;
    });

    // Round one is product/front/test plus the front coordinator summary.
    // The next round should target front instead of repeating product/test.
    expect(calls.take(3), ['product', 'front', 'test']);
    expect(calls.length, greaterThanOrEqualTo(5));
    expect(calls.skip(4), everyElement('front'));
  });

  test('lets a later role response resolve an earlier open question', () async {
    final config = ApiConfig(
      id: 'cfg-front',
      name: 'front',
      provider: 'deepseek',
      modelName: 'deepseek-chat',
      hasCredential: true,
      credentialId: 'credential-front',
    );
    await database.apiConfigBox.put(config.id, config);
    final character = _character('front', '前端', '前端工程师', config.id);
    await database.aiCharacterBox.put(character.id, character);
    final group = ChatGroup(
      id: 'question-resolution-group',
      name: '问题闭环群',
      theme: '网页',
      aiCharacterIds: [character.id],
    );
    await database.chatGroupBox.put(group.id, group);
    final task = _task(
      group: group,
      request: '实现 HTML 页面',
      executorId: character.id,
      members: [character.id],
    );
    var callNumber = 0;
    const question = '请确认移动端交互范围。';
    final runner = WorkDiscussionRunner(
      database: database,
      credentials: _Credentials(),
      completion: ({
        required character,
        required config,
        required apiKey,
        required provider,
        required conversationId,
        required messages,
        required timeout,
        cancelToken,
      }) async {
        callNumber++;
        final summary = messages.first['content'].toString().contains('协调/执行人');
        final firstMemberTurn = !summary && callNumber == 1;
        final finalSummary = summary && callNumber == 4;
        return _turn(
          update: summary ? '已收集并取舍本轮意见。' : '已补充前端可行性意见。',
          percent: finalSummary ? 100 : 50,
          questions: firstMemberTurn ? [question] : const [],
          resolvedQuestions: summary && callNumber == 2 ? [question] : const [],
        );
      },
    );
    WorkDiscussionState? latest;
    await runner.runDiscussion(task, WorkTaskCancellation(), (state) async {
      latest = state;
      task.executionStateJson = WorkDiscussionState.mergeIntoExecutionState(
        task.executionStateJson,
        state,
      );
      return task;
    });
    expect(latest, isNotNull);
    expect(latest!.isExecutionReady, isTrue);
    expect(latest!.openQuestions, isEmpty);
    expect(latest!.round, 2);
  });

  test('preserves an incomplete route until discussion resolves it', () async {
    final config = ApiConfig(
      id: 'cfg-route-front',
      name: 'route-front',
      provider: 'deepseek',
      modelName: 'deepseek-chat',
      hasCredential: true,
      credentialId: 'credential-route-front',
    );
    await database.apiConfigBox.put(config.id, config);
    final character = _character(
      'route-front',
      '前端',
      '前端工程师',
      config.id,
    );
    await database.aiCharacterBox.put(character.id, character);
    final group = ChatGroup(
      id: 'route-pending-group',
      name: '路由待定群',
      theme: '网页',
      aiCharacterIds: [character.id],
    );
    await database.chatGroupBox.put(group.id, group);
    final task = _task(
      group: group,
      request: '实现 HTML 页面',
      executorId: character.id,
      members: [character.id],
    );
    task.executionStateJson = WorkDiscussionState.mergeIntoExecutionState(
      task.executionStateJson,
      WorkDiscussionState.initial(
        conversationId: group.id,
        executorId: character.id,
        candidateCharacterIds: [character.id],
        participantCharacterIds: [character.id],
        blockers: const ['routePending'],
        deliverableContract: _contract(executorId: character.id),
      ),
    );
    WorkDiscussionState? latest;
    final runner = WorkDiscussionRunner(
      database: database,
      credentials: _Credentials(),
      completion: ({
        required character,
        required config,
        required apiKey,
        required provider,
        required conversationId,
        required messages,
        required timeout,
        cancelToken,
      }) async =>
          _turn(
        update: '仍需确认路由前置条件。',
        percent: 100,
        resolvedBlockers: const ['routePending'],
      ),
    );
    await runner.runDiscussion(task, WorkTaskCancellation(), (state) async {
      latest = state;
      task.executionStateJson = WorkDiscussionState.mergeIntoExecutionState(
        task.executionStateJson,
        state,
      );
      return task;
    });
    expect(latest, isNotNull);
    expect(latest!.blockers, contains('routePending'));
    expect(latest!.phase, WorkDiscussionPhase.blocked);
  });

  test('clears a stale route blocker after a repaired group gains a candidate',
      () async {
    final group = ChatGroup(
      id: 'route-repair-group',
      name: '补角色路由群',
      theme: '网页',
      aiCharacterIds: const [],
    );
    await database.chatGroupBox.put(group.id, group);
    final task = AgentTask(
      id: 'route-repair-task',
      groupId: group.id,
      characterId: '',
      userRequest: '实现 HTML 页面',
      workModeTask: true,
    )..executionStateJson = WorkDiscussionState.mergeIntoExecutionState(
        '',
        WorkDiscussionState.initial(
          conversationId: group.id,
          candidateCharacterIds: const [],
          participantCharacterIds: const [],
          blockers: const ['routePending'],
          deliverableContract: const <String, dynamic>{
            'deliverableType': 'source',
            'format': 'html',
            'location': 'desktop.html',
            'contentScope': '实现 HTML 页面',
            'explicitExecutorId': null,
            'revisionTarget': '',
            'requestRevision': 1,
          },
        ),
      );

    WorkDiscussionState? firstBlocked;
    final runner = WorkDiscussionRunner(
      database: database,
      credentials: _Credentials(),
      completion: ({
        required character,
        required config,
        required apiKey,
        required provider,
        required conversationId,
        required messages,
        required timeout,
        cancelToken,
      }) async =>
          _turn(
        update: '${character.name}已确认方案。',
        percent: 100,
      ),
    );
    await runner.runDiscussion(task, WorkTaskCancellation(), (state) async {
      firstBlocked = state;
      task.executionStateJson = WorkDiscussionState.mergeIntoExecutionState(
        task.executionStateJson,
        state,
      );
      return task;
    });
    expect(firstBlocked, isNotNull);
    expect(firstBlocked!.blockers, contains('routePending'));
    expect(firstBlocked!.blockers, contains('routingUnavailable'));

    final config = ApiConfig(
      id: 'cfg-route-repair',
      name: 'route-repair',
      provider: 'deepseek',
      modelName: 'deepseek-chat',
      hasCredential: true,
      credentialId: 'credential-route-repair',
    );
    final character = _character(
      'route-repair-front',
      '补入前端',
      '前端工程师',
      config.id,
    );
    await database.apiConfigBox.put(config.id, config);
    await database.aiCharacterBox.put(character.id, character);
    group.aiCharacterIds = [character.id];
    await database.chatGroupBox.put(group.id, group);
    final repaired = firstBlocked!.copyWith(
      phase: WorkDiscussionPhase.awaitingExecutor,
      candidateCharacterIds: const [],
      clearExecutorId: true,
      blockers: const ['routePending'],
      openQuestions: const [],
    );
    task.executionStateJson = WorkDiscussionState.mergeIntoExecutionState(
      task.executionStateJson,
      repaired,
    );

    WorkDiscussionState? finalState;
    await runner.runDiscussion(task, WorkTaskCancellation(), (state) async {
      finalState = state;
      task.executionStateJson = WorkDiscussionState.mergeIntoExecutionState(
        task.executionStateJson,
        state,
      );
      return task;
    });

    expect(finalState, isNotNull);
    expect(finalState!.blockers, isNot(contains('routePending')));
    expect(finalState!.executorId, character.id);
    expect(finalState!.isExecutionReady, isTrue);
  });

  test('does not auto-elect a backup when the named executor is unavailable',
      () async {
    final config = ApiConfig(
      id: 'cfg-backup-executor',
      name: 'backup-executor',
      provider: 'deepseek',
      modelName: 'deepseek-chat',
      hasCredential: true,
      credentialId: 'credential-backup-executor',
    );
    await database.apiConfigBox.put(config.id, config);
    final backup = _character(
      'backup-front',
      '备用前端',
      '前端工程师',
      config.id,
    );
    await database.aiCharacterBox.put(backup.id, backup);
    final group = ChatGroup(
      id: 'explicit-unavailable-group',
      name: '指定执行人不可用群',
      theme: '网页',
      aiCharacterIds: [backup.id],
    );
    await database.chatGroupBox.put(group.id, group);
    final task = AgentTask(
      id: 'explicit-unavailable-task',
      groupId: group.id,
      characterId: 'named-front',
      userRequest: '实现前端 HTML 页面',
      assignedCharacterIds: const ['named-front', 'backup-front'],
      workModeTask: true,
    )..executionStateJson = WorkDiscussionState.mergeIntoExecutionState(
        '',
        WorkDiscussionState.initial(
          conversationId: group.id,
          executorId: 'named-front',
          candidateCharacterIds: const ['named-front', 'backup-front'],
          participantCharacterIds: const ['named-front', 'backup-front'],
          blockers: const ['executorUnavailable'],
          deliverableContract: _contract(executorId: 'named-front'),
        ),
      );

    var completionCalls = 0;
    WorkDiscussionState? latest;
    final runner = WorkDiscussionRunner(
      database: database,
      credentials: _Credentials(),
      completion: ({
        required character,
        required config,
        required apiKey,
        required provider,
        required conversationId,
        required messages,
        required timeout,
        cancelToken,
      }) async {
        completionCalls++;
        return _turn(update: '不应被调用', percent: 100);
      },
    );
    await runner.runDiscussion(task, WorkTaskCancellation(), (state) async {
      latest = state;
      task.executionStateJson = WorkDiscussionState.mergeIntoExecutionState(
        task.executionStateJson,
        state,
      );
      return task;
    });

    expect(completionCalls, 0);
    expect(latest, isNotNull);
    expect(latest!.phase, WorkDiscussionPhase.blocked);
    expect(latest!.executorId, 'named-front');
    expect(latest!.blockers, contains('executorUnavailable'));
  });

  test('does not let a summary clear an invalid structured member response',
      () async {
    final config = ApiConfig(
      id: 'cfg-invalid-structured',
      name: 'invalid-structured',
      provider: 'deepseek',
      modelName: 'deepseek-chat',
      hasCredential: true,
      credentialId: 'credential-invalid-structured',
    );
    await database.apiConfigBox.put(config.id, config);
    final character = _character(
      'invalid-structured-front',
      '前端',
      '前端工程师',
      config.id,
    );
    await database.aiCharacterBox.put(character.id, character);
    final group = ChatGroup(
      id: 'invalid-structured-group',
      name: '结构化回复异常群',
      theme: '网页',
      aiCharacterIds: [character.id],
    );
    await database.chatGroupBox.put(group.id, group);
    final task = _task(
      group: group,
      request: '实现 HTML 页面',
      executorId: character.id,
      members: [character.id],
    );
    var summaryCalls = 0;
    final runner = WorkDiscussionRunner(
      database: database,
      credentials: _Credentials(),
      completion: ({
        required character,
        required config,
        required apiKey,
        required provider,
        required conversationId,
        required messages,
        required timeout,
        cancelToken,
      }) async {
        final isSummary =
            messages.first['content'].toString().contains('协调/执行人');
        if (!isSummary) {
          // This is intentionally not a WorkDiscussionTurn. The runner must
          // keep the retry blocker until a real structured reply succeeds.
          return <String, dynamic>{
            'success': true,
            'message': '成员没有返回结构化 JSON',
          };
        }
        summaryCalls++;
        return _turn(
          update: '汇总并错误声称成员异常已经修复。',
          percent: 100,
          resolvedBlockers: [
            'structuredResponseInvalid:${character.id}',
          ],
        );
      },
    );
    WorkDiscussionState? latest;
    await runner.runDiscussion(task, WorkTaskCancellation(), (state) async {
      latest = state;
      task.executionStateJson = WorkDiscussionState.mergeIntoExecutionState(
        task.executionStateJson,
        state,
      );
      return task;
    });

    expect(summaryCalls, greaterThanOrEqualTo(1));
    expect(latest, isNotNull);
    expect(latest!.phase, WorkDiscussionPhase.blocked);
    expect(
      latest!.blockers,
      contains('structuredResponseInvalid:${character.id}'),
    );
    expect(latest!.isExecutionReady, isFalse);
  });

  test('reports provider HTTP failures without calling them malformed JSON',
      () async {
    final config = ApiConfig(
      id: 'cfg-http-402',
      name: 'http-402',
      provider: 'deepseek',
      modelName: 'deepseek-chat',
      hasCredential: true,
      credentialId: 'credential-http-402',
    );
    await database.apiConfigBox.put(config.id, config);
    final character = _character(
      'http-402-front',
      '前端',
      '前端工程师',
      config.id,
    );
    await database.aiCharacterBox.put(character.id, character);
    final group = ChatGroup(
      id: 'http-402-group',
      name: '模型可用性异常群',
      theme: '网页',
      aiCharacterIds: [character.id],
    );
    await database.chatGroupBox.put(group.id, group);
    final task = _task(
      group: group,
      request: '实现 HTML 页面',
      executorId: character.id,
      members: [character.id],
    );
    final requestOptions = RequestOptions(path: '/chat/completions');
    final runner = WorkDiscussionRunner(
      database: database,
      credentials: _Credentials(),
      completion: ({
        required character,
        required config,
        required apiKey,
        required provider,
        required conversationId,
        required messages,
        required timeout,
        cancelToken,
      }) async {
        throw DioException(
          requestOptions: requestOptions,
          response: Response<void>(
            requestOptions: requestOptions,
            statusCode: 402,
          ),
        );
      },
    );
    WorkDiscussionState? latest;
    await runner.runDiscussion(task, WorkTaskCancellation(), (state) async {
      latest = state;
      task.executionStateJson = WorkDiscussionState.mergeIntoExecutionState(
        task.executionStateJson,
        state,
      );
      return task;
    });

    expect(latest, isNotNull);
    expect(latest!.blockers, contains('modelRequestFailed:${character.id}'));
    expect(
      latest!.blockers,
      isNot(contains('structuredResponseInvalid:${character.id}')),
    );
    expect(
      latest!.participants.single.lastContribution,
      '模型请求失败（HTTP 402）',
    );
  });

  test('does not persist a plain multiline coordinator preview as state',
      () async {
    final config = ApiConfig(
      id: 'cfg-invalid-summary',
      name: 'invalid-summary',
      provider: 'deepseek',
      modelName: 'deepseek-chat',
      hasCredential: true,
      credentialId: 'credential-invalid-summary',
    );
    await database.apiConfigBox.put(config.id, config);
    final character = _character(
      'invalid-summary-front',
      '前端',
      '前端工程师',
      config.id,
    );
    await database.aiCharacterBox.put(character.id, character);
    final group = ChatGroup(
      id: 'invalid-summary-group',
      name: '汇总异常群',
      theme: '网页',
      aiCharacterIds: [character.id],
    );
    await database.chatGroupBox.put(group.id, group);
    final task = _task(
      group: group,
      request: '实现 HTML 页面',
      executorId: character.id,
      members: [character.id],
    );
    final runner = WorkDiscussionRunner(
      database: database,
      credentials: _Credentials(),
      completion: ({
        required character,
        required config,
        required apiKey,
        required provider,
        required conversationId,
        required messages,
        required timeout,
        cancelToken,
      }) async {
        final isSummary =
            messages.first['content'].toString().contains('协调/执行人');
        return isSummary
            ? <String, dynamic>{
                'success': true,
                'message': '第一行结论\n第二行仍未结构化',
              }
            : <String, dynamic>{
                'success': true,
                'message': '成员没有返回结构化 JSON',
              };
      },
    );
    WorkDiscussionState? latest;
    await runner.runDiscussion(task, WorkTaskCancellation(), (state) async {
      latest = state;
      task.executionStateJson = WorkDiscussionState.mergeIntoExecutionState(
        task.executionStateJson,
        state,
      );
      return task;
    });

    expect(latest, isNotNull);
    expect(latest!.phase, WorkDiscussionPhase.blocked);
    expect(latest!.blockers, contains('coordinatorResponseInvalid'));
    expect(latest!.decisionSummary, isEmpty);
    expect(latest!.isWithinBounds, isTrue);
  });

  test('stops after two rounds without substantive progress', () async {
    final config = ApiConfig(
      id: 'cfg-front',
      name: 'front',
      provider: 'deepseek',
      modelName: 'deepseek-chat',
      hasCredential: true,
      credentialId: 'credential-front',
    );
    await database.apiConfigBox.put(config.id, config);
    final character = _character('front', '前端', '前端工程师', config.id);
    await database.aiCharacterBox.put(character.id, character);
    final group = ChatGroup(
      id: 'stalled-group',
      name: '停滞群',
      theme: '网页',
      aiCharacterIds: [character.id],
    );
    await database.chatGroupBox.put(group.id, group);
    final task = _task(
      group: group,
      request: '实现 HTML 页面',
      executorId: character.id,
      members: [character.id],
    );
    WorkDiscussionState? latest;
    final runner = WorkDiscussionRunner(
      database: database,
      credentials: _Credentials(),
      completion: ({
        required character,
        required config,
        required apiKey,
        required provider,
        required conversationId,
        required messages,
        required timeout,
        cancelToken,
      }) async =>
          _turn(
        update: '',
        percent: 40,
        substantive: false,
      ),
    );
    await runner.runDiscussion(task, WorkTaskCancellation(), (state) async {
      latest = state;
      task.executionStateJson = WorkDiscussionState.mergeIntoExecutionState(
        task.executionStateJson,
        state,
      );
      return task;
    });
    expect(latest, isNotNull);
    expect(latest!.round, 2);
    expect(latest!.phase, WorkDiscussionPhase.blocked);
    expect(latest!.blockers, contains('discussionNotConverged'));
  });

  test('uses a longer bounded round budget for complex requests', () async {
    final config = ApiConfig(
      id: 'cfg-front',
      name: 'front',
      provider: 'deepseek',
      modelName: 'deepseek-chat',
      hasCredential: true,
      credentialId: 'credential-front',
    );
    await database.apiConfigBox.put(config.id, config);
    final character = _character('front', '前端', '前端工程师', config.id);
    await database.aiCharacterBox.put(character.id, character);

    Future<int> runRequest(String groupId, String request) async {
      final group = ChatGroup(
        id: groupId,
        name: groupId,
        theme: '网页',
        aiCharacterIds: [character.id],
      );
      await database.chatGroupBox.put(group.id, group);
      final task = _task(
        group: group,
        request: request,
        executorId: character.id,
        members: [character.id],
      );
      WorkDiscussionState? latest;
      var callNumber = 0;
      final runner = WorkDiscussionRunner(
        database: database,
        credentials: _Credentials(),
        completion: ({
          required character,
          required config,
          required apiKey,
          required provider,
          required conversationId,
          required messages,
          required timeout,
          cancelToken,
        }) async =>
            _turn(update: '新增第${++callNumber}条可验证结论。', percent: 50),
      );
      await runner.runDiscussion(task, WorkTaskCancellation(), (state) async {
        latest = state;
        task.executionStateJson = WorkDiscussionState.mergeIntoExecutionState(
          task.executionStateJson,
          state,
        );
        return task;
      });
      return latest!.round;
    }

    final simpleRounds = await runRequest('simple-round-group', '修复 HTML 页面');
    final complexRequest = List<String>.filled(90, '复杂系统架构与跨模块集成').join(' ');
    final complexRounds =
        await runRequest('complex-round-group', complexRequest);
    const explicitTwoRoundRequest = '复杂前端系统架构请完成两轮可验证讨论。';
    final explicitTwoRounds =
        await runRequest('explicit-two-round-group', explicitTwoRoundRequest);
    expect(simpleRounds, 2);
    expect(complexRounds, 6);
    expect(explicitTwoRounds, 2);
  });

  test('records a model timeout without fabricating a role message', () async {
    final config = ApiConfig(
      id: 'cfg-front',
      name: 'front',
      provider: 'deepseek',
      modelName: 'deepseek-chat',
      hasCredential: true,
      credentialId: 'credential-front',
    );
    await database.apiConfigBox.put(config.id, config);
    final character = _character('front', '前端', '前端工程师', config.id);
    await database.aiCharacterBox.put(character.id, character);
    final group = ChatGroup(
      id: 'timeout-group',
      name: '超时群',
      theme: '网页',
      aiCharacterIds: [character.id],
    );
    await database.chatGroupBox.put(group.id, group);
    final task = _task(
      group: group,
      request: '实现 HTML 页面',
      executorId: character.id,
      members: [character.id],
    );
    final runner = WorkDiscussionRunner(
      database: database,
      credentials: _Credentials(),
      roleTimeout: const Duration(milliseconds: 1),
      completion: ({
        required character,
        required config,
        required apiKey,
        required provider,
        required conversationId,
        required messages,
        required timeout,
        cancelToken,
      }) async {
        await Future<void>.delayed(const Duration(milliseconds: 30));
        return _turn(update: '迟到的回复', percent: 100);
      },
    );
    await runner.runDiscussion(task, WorkTaskCancellation(), (state) async {
      task.executionStateJson = WorkDiscussionState.mergeIntoExecutionState(
        task.executionStateJson,
        state,
      );
      return task;
    });
    final messages = database.messageBox.values
        .where((message) => message.groupId == group.id)
        .toList();
    expect(
        messages.any((message) => message.content.contains('模型请求超时')), isTrue);
    expect(
        messages.any((message) => message.senderId == character.id), isFalse);
    expect(
      messages
          .where((message) => message.content.contains('模型请求超时'))
          .every((message) => message.senderType == 'system'),
      isTrue,
    );
  });

  test('cancellation stops an in-flight discussion without a late update',
      () async {
    final config = ApiConfig(
      id: 'cfg-front',
      name: 'front',
      provider: 'deepseek',
      modelName: 'deepseek-chat',
      hasCredential: true,
      credentialId: 'credential-front',
    );
    await database.apiConfigBox.put(config.id, config);
    final character = _character('front', '前端', '前端工程师', config.id);
    await database.aiCharacterBox.put(character.id, character);
    final group = ChatGroup(
      id: 'cancel-group',
      name: '取消群',
      theme: '网页',
      aiCharacterIds: [character.id],
    );
    await database.chatGroupBox.put(group.id, group);
    final task = _task(
      group: group,
      request: '实现 HTML 页面',
      executorId: character.id,
      members: [character.id],
    );
    final started = Completer<void>();
    var updateCount = 0;
    final runner = WorkDiscussionRunner(
      database: database,
      credentials: _Credentials(),
      completion: ({
        required character,
        required config,
        required apiKey,
        required provider,
        required conversationId,
        required messages,
        required timeout,
        cancelToken,
      }) {
        started.complete();
        return cancelToken!.whenCancel.then<Map<String, dynamic>>((_) {
          throw DioException(
            requestOptions: RequestOptions(path: 'discussion'),
            type: DioExceptionType.cancel,
          );
        });
      },
    );
    final cancellation = WorkTaskCancellation();
    final run = runner.runDiscussion(task, cancellation, (state) async {
      updateCount++;
      task.executionStateJson = WorkDiscussionState.mergeIntoExecutionState(
        task.executionStateJson,
        state,
      );
      return task;
    });
    await started.future;
    cancellation.cancel();
    await run;
    expect(updateCount, 1); // only the initial discussion checkpoint landed
  });

  test('asks the same member again when the model returns an empty body',
      () async {
    final outcome = await _runSingleMemberFixture(
      database,
      characterId: 'empty-body-front',
      // Attempt one reproduces the real gateway reply: HTTP 200 with an empty
      // body, reported by ChatApiService as the stable `emptyResponse` code.
      memberResponse: (attempt) => attempt == 1
          ? <String, dynamic>{
              'success': false,
              'failureCode': 'emptyResponse',
              'message': '模型返回了空内容',
            }
          : _turn(update: '已补充前端可行性意见。', percent: 100),
    );

    // Round one spends exactly one repair call, round two speaks once.
    expect(outcome.memberPrompts.length, 3);
    expect(_isRepairPrompt(outcome.memberPrompts[1]), isTrue);
    expect(outcome.memberPrompts[1].length, outcome.memberPrompts[0].length + 1);
    final messages = database.messageBox.values
        .where((message) => message.groupId == 'empty-body-front-group')
        .toList();
    expect(
      messages.any((message) =>
          message.senderId == 'empty-body-front' &&
          message.content.contains('职责意见：')),
      isTrue,
    );
    expect(
      messages.any((message) => message.content.contains('暂不计入理解进度')),
      isFalse,
    );
    expect(outcome.state, isNotNull);
    expect(outcome.state!.phase, WorkDiscussionPhase.ready);
    expect(outcome.state!.understandingPercent, 100);
  });

  test('asks the same member again when a truncated reply loses its fields',
      () async {
    final outcome = await _runSingleMemberFixture(
      database,
      characterId: 'truncated-front',
      // Valid JSON that lost the protocol fields, which is what a reply cut
      // off in the middle of an array looks like after decoding.
      memberResponse: (attempt) => attempt == 1
          ? <String, dynamic>{
              'success': true,
              'message': jsonEncode(<String, dynamic>{
                'public_update': '已确认目标范围',
              }),
            }
          : _turn(update: '已补充前端可行性意见。', percent: 100),
    );

    expect(outcome.memberPrompts.length, 3);
    expect(_isRepairPrompt(outcome.memberPrompts[1]), isTrue);
    expect(outcome.state, isNotNull);
    expect(outcome.state!.phase, WorkDiscussionPhase.ready);
  });

  test('does not spend a repair call on a non-protocol member failure',
      () async {
    final outcome = await _runSingleMemberFixture(
      database,
      characterId: 'blocked-front',
      // A governance rejection is a real answer about this request, so
      // resending the same prompt cannot help and must not consume a call.
      memberResponse: (_) => <String, dynamic>{
        'success': false,
        'failureCode': 'governanceBlocked',
        'message': '请求输出上限超过模型上限',
      },
    );

    expect(outcome.memberPrompts.length, 2); // one attempt per round
    expect(
      outcome.memberPrompts.any(_isRepairPrompt),
      isFalse,
    );
    final messages = database.messageBox.values
        .where((message) => message.groupId == 'blocked-front-group')
        .toList();
    expect(
      messages.any((message) => message.content.contains('暂不计入理解进度')),
      isTrue,
    );
    expect(outcome.state, isNotNull);
    expect(outcome.state!.phase, WorkDiscussionPhase.blocked);
    expect(
      outcome.state!.blockers,
      contains('structuredResponseInvalid:blocked-front'),
    );
  });

  test('does not pin the discussion when a member is rate limited', () async {
    final outcome = await _runSingleMemberFixture(
      database,
      characterId: 'rate-limited-front',
      // HTTP 429 is a transport failure: it says nothing about this member's
      // opinion, so it must not become the model-proof
      // `structuredResponseInvalid:<id>` blocker. That blocker can never be
      // cleared, which used to freeze the group at 99% and make it re-ask the
      // same question every round.
      memberResponse: (_) => <String, dynamic>{
        'success': false,
        'statusCode': 429,
        'message': 'HTTP 429 请求失败',
      },
    );

    final messages = database.messageBox.values
        .where((message) => message.groupId == 'rate-limited-front-group')
        .toList();
    // The failure is still reported honestly to the user.
    expect(
      messages.any((message) => message.content.contains('暂不计入理解进度')),
      isTrue,
    );
    // A rate limit is not worth a repair resend, so no call is wasted on it.
    expect(outcome.memberPrompts.any(_isRepairPrompt), isFalse);
    expect(outcome.state, isNotNull);
    expect(
      outcome.state!.blockers,
      isNot(contains('structuredResponseInvalid:rate-limited-front')),
    );
    // The remaining members can still converge.
    expect(outcome.state!.phase, WorkDiscussionPhase.ready);
  });
}
