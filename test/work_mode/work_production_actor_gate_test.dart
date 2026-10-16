import 'dart:io';

import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/models/agent_task.dart';
import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/api_config.dart';
import 'package:chat_group/core/models/chat_group.dart';
import 'package:chat_group/core/models/tool_permission.dart';
import 'package:chat_group/core/storage/api_credential_resolver.dart';
import 'package:chat_group/features/work_mode/default_work_task_runner.dart';
import 'package:chat_group/features/work_mode/work_collaboration_state.dart';
import 'package:chat_group/features/work_mode/work_discussion_state.dart';
import 'package:chat_group/features/work_mode/work_folder_grant_service.dart';
import 'package:chat_group/features/work_mode/work_mode_workspace_service.dart';
import 'package:chat_group/features/work_mode/work_task_event_store.dart';
import 'package:chat_group/features/work_mode/workspace_file_service.dart';
import 'package:chat_group/features/work_mode/workspace_mutation_service.dart';
import 'package:chat_group/features/work_mode/workspace_path_policy.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/lifecycle_hive.dart';

class _Credentials implements ApiCredentialResolver {
  @override
  Future<String?> resolve(ApiConfig config) async => 'test-key';
}

void main() {
  late Directory dir;
  late Directory project;
  late DatabaseService db;
  late WorkTaskEventStore events;
  late DefaultWorkTaskRunner runner;
  late AgentTask task;

  setUp(() async {
    dir = await openLifecycleHive();
    db = DatabaseService();
    events = WorkTaskEventStore(
        appSupportDirectory: Directory('${dir.path}/support'));
    project = await Directory('${dir.path}/project').create();
    final grants = WorkFolderGrantService(
        box: db.appSettingsBox,
        directoryValidator: (_) async => true,
        writeDirectoryValidator: (_) async => true,
        isWindows: false);
    await grants.authorizeDirectory(project.path, consent: (_) async => true);
    final policy = WorkspacePathPolicy(grantService: grants);
    runner = DefaultWorkTaskRunner(
      database: db,
      eventStore: events,
      credentials: _Credentials(),
      workspaceService: WorkModeWorkspaceService(db: db, grantService: grants),
      folderGrantService: grants,
      workspaceFileService: WorkspaceFileService(pathPolicy: policy),
      mutationService: WorkspaceMutationService(pathPolicy: policy),
    );
  });

  tearDown(() async {
    await events.close();
    await closeLifecycleHive(dir, db);
  });

  Future<void> putCharacter(String id, String role,
      {required String configId}) async {
    await db.aiCharacterBox.put(
        id,
        AICharacter(
            id: id,
            name: id,
            avatar: 'W',
            age: 30,
            role: role,
            personalityTags: const [],
            systemPrompt: '我是$id，按自己的责任工作。',
            apiKey: '',
            apiProvider: 'deepseek',
            modelName: 'deepseek-chat',
            apiConfigId: configId,
            toolPermissions: const [ToolPermission.workspaceRead]));
  }

  /// 一条已通过方案认可、停在制作阶段的任务：所有 `productionReady` 子门禁都满足。
  Future<void> seedProductionReadyTask() async {
    for (final id in ['maker', 'tester']) {
      await db.apiConfigBox.put(
          'config-$id',
          ApiConfig(
              id: 'config-$id',
              name: id,
              provider: 'deepseek',
              modelName: 'deepseek-chat',
              hasCredential: true,
              credentialId: 'credential-$id'));
      await putCharacter(id, id == 'maker' ? '软件开发工程师' : '测试工程师',
          configId: 'config-$id');
    }
    const groupId = 'prod-group';
    await db.chatGroupBox.put(
        groupId,
        ChatGroup(
            id: groupId,
            name: '生产讨论',
            theme: '软件开发',
            aiCharacterIds: const ['maker', 'tester']));
    task = AgentTask(
        id: 'prod-task',
        groupId: groupId,
        characterId: 'maker',
        userRequest: '生成一份报告',
        workModeTask: true,
        requestedPermissions: const [ToolPermission.workspaceRead]);
    final legacy = WorkDiscussionState.initial(
        conversationId: groupId,
        deliverableContract: const {
          'deliverableType': 'document',
          'format': 'txt',
          'location': 'report.txt',
          'contentScope': '生成一份报告',
          'revisionTarget': '',
          'requestRevision': 1
        });
    final workspace = await runner.workspaceService.loadOrCreate(
        conversationId: groupId,
        isDirectChat: false,
        preferredRootPath: project.path);
    final base = WorkDiscussionState.fromLegacyTask(task, legacy,
        projectScopeId: workspace.projectScopeId!);
    final raw = base.collaboration!.toJson()
      ..['scope'] = '生成一份报告'
      ..['plan'] = '制作后交给测试逐人验收。'
      ..['phase'] = 'producing'
      ..['coordinatorId'] = 'maker'
      ..['artifactContract'] = {
        'type': 'document',
        'format': 'txt',
        'location': 'report.txt',
        'revisionTarget': ''
      }
      ..['team'] = [
        for (final id in ['maker', 'tester'])
          {
            'memberId': id,
            'role': id == 'maker' ? 'development' : 'testing',
            'qualificationRef': 'skill-$id',
            'qualified': true,
            'available': true,
          }
      ]
      ..['acceptances'] = [
        {
          'id': 'qa',
          'method': '读取报告并核对结论',
          'requiredCapability': 'workspaceRead',
          'status': 'pending',
          'evidenceRef': '',
          'requestRevision': 1,
          'verificationRevision': 1
        }
      ]
      ..['approvals'] = [
        for (final id in ['maker', 'tester'])
          {
            'eventId': 'plan-$id',
            'memberId': id,
            'kind': 'plan',
            'subjectId': task.id,
            'requestRevision': 1,
            'teamRevision': base.collaboration!.teamRevision,
            'iterationId': '',
            'artifactDigest': '',
            'verificationRevision': 1,
            'approved': true,
            'evidenceRef': 'message-plan-$id',
            'source': 'memberModel'
          }
      ]
      ..['workItems'] = [
        {
          'id': 'build',
          'kind': 'produce',
          'ownerId': 'maker',
          'status': 'pending',
          'dependencies': <String>[],
          'requestRevision': 1
        }
      ];
    final collaboration = WorkCollaborationState.tryParse(raw);
    expect(collaboration, isNotNull, reason: '夹具本身必须先是合法的 v2 协作状态');
    expect(collaboration!.productionReady, isTrue,
        reason: '夹具必须真的停在制作阶段，否则这条用例测不到执行期门禁');
    task.executionStateJson = WorkDiscussionState.mergeIntoExecutionState(
        '', base.copyWith(collaboration: collaboration));
    await db.agentTaskBox.put(task.id, task);
  }

  List<Map<String, dynamic>> pendingDecisions() =>
      WorkDiscussionState.fromExecutionState(task.executionStateJson)!
          .collaboration!
          .decisions
          .where((d) => d['status'] == 'pending')
          .map(Map<String, dynamic>.from)
          .toList();

  test('执行期成员没绑定模型时如实报出成因，不并进笼统文案', () async {
    await seedProductionReadyTask();
    // 现场那种形态：责任成员没有绑定任何模型配置。
    final maker = db.aiCharacterBox.get('maker')!;
    maker.apiConfigId = '';
    maker.apiKey = '';
    await db.aiCharacterBox.put('maker', maker);

    expect(await runner.prepareCollaborationWork(task), isFalse);

    final pending = pendingDecisions();
    expect(pending, hasLength(1));
    expect(pending.single['reason'], contains('尚未配置可用模型'),
        reason: '执行期同样只有写明成因，用户才知道该恢复配置还是换人');
    expect(pending.single['reason'], isNot(contains('当前责任成员失效或模型凭据不可用')));
  });

  test('执行期成员已离群时按授权归因，不牵连模型凭据', () async {
    await seedProductionReadyTask();
    final group = db.chatGroupBox.get(task.groupId)!;
    await db.chatGroupBox.put(
        group.id,
        ChatGroup(
            id: group.id,
            name: group.name,
            theme: group.theme,
            aiCharacterIds: const ['tester']));

    expect(await runner.prepareCollaborationWork(task), isFalse);

    final pending = pendingDecisions();
    expect(pending, hasLength(1));
    expect(pending.single['reason'], contains('未获任务加入确认'));
    expect(pending.single['reason'], isNot(contains('模型凭据不可用')));
  });

  test('执行人不在本次任务的团队里时按团队归因，不牵连模型配置', () async {
    await seedProductionReadyTask();
    // 制作工作项仍指向 maker，团队里已经没有它——检查点来自旧团队、或成员被改派。
    // 执行期过去在这里用 `team.singleWhere` 取责任，会直接抛 StateError；改成如实
    // 归因后还必须**先**判团队：这个成员同时也没绑模型，先报配置会把用户送去修一个
    // 与结论无关的东西。
    final decoded =
        WorkDiscussionState.fromExecutionState(task.executionStateJson)!;
    task.executionStateJson = WorkDiscussionState.mergeIntoExecutionState(
        '',
        decoded.copyWith(
            collaboration: WorkCollaborationState.tryParse(
                decoded.collaboration!.toJson()
                  ..['team'] = [
                    {
                      'memberId': 'tester',
                      'role': 'testing',
                      'qualificationRef': 'skill-tester',
                      'qualified': true,
                      'available': true,
                    }
                  ]
                  ..['coordinatorId'] = 'tester')));
    final maker = db.aiCharacterBox.get('maker')!;
    maker.apiConfigId = '';
    maker.apiKey = '';
    await db.aiCharacterBox.put('maker', maker);
    expect(
        WorkDiscussionState.fromExecutionState(task.executionStateJson)!
            .collaboration!
            .productionReady,
        isTrue,
        reason: '夹具必须仍然停在制作阶段，否则这条用例测不到执行期门禁');

    expect(await runner.prepareCollaborationWork(task), isFalse);

    final pending = pendingDecisions();
    expect(pending, hasLength(1));
    expect(pending.single['reason'], contains('成员已不在本次任务的团队里'));
    expect(pending.single['reason'], isNot(contains('尚未配置可用模型')));
  });
}
