import 'dart:convert';
import 'dart:io';
import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/models/agent_task.dart';
import 'package:chat_group/features/work_mode/work_collaboration_state.dart';
import 'package:chat_group/features/work_mode/work_discussion_state.dart';

WorkCollaborationState candidateTestState(
    {String type = 'document', String format = 'txt'}) {
  final json = WorkCollaborationState.fromLegacy(
      taskId: 'task-a',
      conversationId: 'group-a',
      projectScopeId: 'scope-a',
      requestRevision: 1,
      requestMessageId: 'request-a',
      scope: '生成候选文件',
      artifactContract: {
        'type': type,
        'format': format,
        'location': 'unspecified',
        'revisionTarget': '',
      }).toJson()
    ..['plan'] = '制作、验证、审查'
    ..['phase'] = 'producing'
    ..['coordinatorId'] = 'a'
    ..['artifactContract'] = {
      'type': type,
      'format': format,
      'location': '.',
      'revisionTarget': ''
    }
    ..['team'] = [
      for (final member in ['a', 'b'])
        {
          'memberId': member,
          'role': member == 'a' ? 'developer' : 'tester',
          'qualificationRef': 'skill-$member',
          'qualified': true,
          'available': true,
        }
    ]
    ..['acceptances'] = [
      {
        'id': 'qa',
        'method': 'run',
        'requiredCapability': 'command',
        'status': 'pending',
        'evidenceRef': '',
        'requestRevision': 1,
        'verificationRevision': 1
      }
    ]
    ..['approvals'] = [
      for (final member in ['a', 'b'])
        candidateTestApproval(member, 'plan', 'task-a')
    ];
  return WorkCollaborationState.tryParse(json)!;
}

Map<String, dynamic> candidateTestApproval(
        String member, String kind, String subject,
        {String iteration = '', String digest = '', int verification = 1}) =>
    {
      'eventId': '$kind-$member-$verification',
      'memberId': member,
      'kind': kind,
      'subjectId': subject,
      'requestRevision': 1,
      'teamRevision': 1,
      'iterationId': iteration,
      'artifactDigest': digest,
      'verificationRevision': verification,
      'approved': true,
      'evidenceRef': 'message-$kind-$member',
      'source': 'memberModel',
    };

AgentTask candidateTestTask(WorkCollaborationState state) => AgentTask(
    id: state.taskId,
    groupId: state.conversationId,
    characterId: 'a',
    userRequest: '生成 ${state.artifactContract['format']} 文件',
    workModeTask: true,
    executionStateJson: jsonEncode({
      'discussionState':
          WorkDiscussionState.initial(conversationId: state.conversationId)
              .copyWith(
                  schemaVersion: 2,
                  phase: WorkDiscussionPhase.ready,
                  collaboration: state)
              .toJson()
    }));

class CandidateTestDatabase extends DatabaseService {
  final Directory root;
  CandidateTestDatabase(this.root);
  @override
  Future<Directory> get mediaDir async =>
      Directory('${root.path}/media').create(recursive: true);
  @override
  Future<Directory> get aiProcessingDir async =>
      Directory('${root.path}/processing').create(recursive: true);
}
