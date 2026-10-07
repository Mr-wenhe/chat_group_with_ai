import 'dart:convert';
import 'package:chat_group/features/agentic/tool_request.dart';
import 'agent_decision.dart';
import 'work_public_update_stream.dart';
import 'work_tool_registry.dart';

/// Public expression and machine state are validated separately. Old replies,
/// previews, coordinator signatures and percentages cannot produce a v2 turn.
class WorkDiscussionV2Turn {
  final String action;
  final String publicUpdate;
  final String issueId;
  final String nextMemberId;
  final List<Map<String, dynamic>> issues;
  final List<Map<String, dynamic>> resolutions;
  final Map<String, dynamic>? proposal;
  final Map<String, dynamic>? approval;
  final Map<String, dynamic>? decision;
  final AgentToolCall? tool;
  const WorkDiscussionV2Turn._(
      this.action,
      this.publicUpdate,
      this.issueId,
      this.nextMemberId,
      this.issues,
      this.resolutions,
      this.proposal,
      this.approval,
      this.decision,
      this.tool);

  static const actions = {
    'respond',
    'investigate',
    'propose',
    'approve',
    'decide',
    'silent'
  };
  static const fields = {
    'schemaVersion',
    'action',
    'public_update',
    'issue_id',
    'next_member_id',
    'issues',
    'resolutions',
    'proposal',
    'approval',
    'decision',
    'tool'
  };
  static const protocol = '''只返回严格 JSON object，不输出 Markdown 或私有推理。
全部顶层字段必须出现：schemaVersion:2、action、public_update、issue_id、next_member_id、issues、resolutions、proposal、approval、decision、tool。无内容字段用空字符串、空数组或 null。
action: respond/investigate/propose/approve/decide/silent。public_update 是自然公开回应，不展示合同 JSON，不写理解百分比。
issues 是本轮全部新问题，每项 {id,kind:"defect|idea|decision",target,problem,evidenceRef,retestCondition}。问题、依据、解决条件必须具体；evidenceRef 引用当前真实证据或你的响应，不伪造代码读取。
resolutions 是 {id,resolution,evidenceRef} 数组，只引用真实工具/成员回应/用户答复，不因模型自称完成删除问题。
调查：action=investigate，issue_id 指向已有 open 问题，tool={name,arguments}。只允许 workspace.list/read/search/document；调查结果回台账后再讨论，禁止 command.run、写文件、安装、写探针或浏览器。工具能力与权限以运行时为准。
proposal={scope,plan,artifactContract:{type,format,location,revisionTarget,files:[完整合同相对文件路径]},workItems:[{id,ownerId,dependencies,kind:"material|produce"}],acceptances:[{id,method,requiredCapability}]}。只协调成员可建立/修改当前方案，不默许原型；制作和测试工作项这里只规划，不声称已经执行。仅要求软件需求文档时不得扩展交付成软件。工作项、验收的 requestRevision 必须匹配当前需求；用户裁决/补充后旧版工作项必须由协调成员重新形成 proposal，不能只重新签字。
新增范围作为 kind=idea 的问题，全体成员对该提案明确认可后再更新范围、计划和验收；有分歧用 decide 交用户。保留用户原始范围和所有禁止事项，不能扩大工具授权。
approval={kind:"plan|idea|delivery",subjectId,approved:true|false,requestRevision,teamRevision,verificationRevision}。delivery 必须另带 iterationId 和 artifactDigest，逐人审阅当前候选与真实验证报告。只代表自己，对当前完整方案或指定提案逐人确认；沉默、百分比、总结不是认可，不能返回他人签字。
decision={kind:"question|choice|dispute",targetId,reason,evidence,impact,options:[{id,label,impact}]}，用户偏好、未知规则与真实分歧走用户决策；不要把普通实现取舍推给用户。
next_member_id 可请求当前团队具体成员回应当前问题，不能用它调入群外成员。没有新增信息且无必要答复可以 silent。''';

  static WorkDiscussionV2Turn? parse(Map<String, dynamic> response) {
    if (response['success'] == false) return null;
    try {
      final raw = response['message'] ?? response['content'];
      if (raw is! String || raw.length > 48 * 1024) return null;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final m = Map<String, dynamic>.from(decoded);
      if (m.length != fields.length ||
          !m.keys.every(fields.contains) ||
          m['schemaVersion'] != 2 ||
          !actions.contains(m['action']) ||
          !_text(m['public_update'], 12000) ||
          !_text(m['issue_id'], 128) ||
          !_text(m['next_member_id'], 128)) {
        return null;
      }
      final issues = _records(m['issues']);
      final resolutions = _records(m['resolutions']);
      if (issues == null || resolutions == null) return null;
      for (final item in issues) {
        if (!_keys(item, {
              'id',
              'kind',
              'target',
              'problem',
              'evidenceRef',
              'retestCondition'
            }) ||
            !{'defect', 'idea', 'decision'}.contains(item['kind']) ||
            !['id', 'target', 'problem', 'retestCondition']
                .every((k) => _nonempty(item[k])) ||
            !_text(item['evidenceRef'], 128)) {
          return null;
        }
      }
      for (final item in resolutions) {
        if (!_keys(item, {'id', 'resolution', 'evidenceRef'}) ||
            !item.values.every(_nonempty)) {
          return null;
        }
      }
      Map<String, dynamic>? optional(String key) =>
          m[key] == null ? null : Map<String, dynamic>.from(m[key] as Map);
      final proposal = optional('proposal');
      final approval = optional('approval');
      final decision = optional('decision');
      if (proposal != null &&
          (!_keys(proposal, {
                'scope',
                'plan',
                'artifactContract',
                'workItems',
                'acceptances'
              }) ||
              !_nonempty(proposal['scope']) ||
              !_nonempty(proposal['plan']) ||
              proposal['artifactContract'] is! Map ||
              _records(proposal['workItems']) == null ||
              _records(proposal['acceptances']) == null)) {
        return null;
      }
      if (approval != null &&
          (!_keys(approval, {
                if (approval['kind'] == 'delivery') 'iterationId',
                if (approval['kind'] == 'delivery') 'artifactDigest',
                'kind',
                'subjectId',
                'approved',
                'requestRevision',
                'teamRevision',
                'verificationRevision'
              }) ||
              !{'plan', 'idea', 'delivery'}.contains(approval['kind']) ||
              approval['approved'] is! bool ||
              !_nonempty(approval['subjectId']) ||
              !['requestRevision', 'teamRevision', 'verificationRevision']
                  .every((k) => approval[k] is int))) {
        return null;
      }
      if (decision != null &&
          (!_keys(decision, {
                'kind',
                'targetId',
                'reason',
                'evidence',
                'impact',
                'options'
              }) ||
              !{'question', 'choice', 'dispute'}.contains(decision['kind']) ||
              !['reason', 'evidence', 'impact']
                  .every((k) => _nonempty(decision[k])) ||
              !_text(decision['targetId'], 128) ||
              _records(decision['options']) == null)) {
        return null;
      }
      AgentToolCall? tool;
      if (m['tool'] != null) {
        final t = Map<String, dynamic>.from(m['tool'] as Map);
        final name = AgentToolName.fromWire(t['name']);
        if (!_keys(t, {'name', 'arguments'}) ||
            name == null ||
            t['arguments'] is! Map) {
          return null;
        }
        final arguments = Map<String, dynamic>.from(t['arguments'] as Map);
        if (!WorkToolSchema.isJsonValue(arguments)) return null;
        tool = AgentToolCall(name: name, arguments: arguments);
      }
      final action = m['action'] as String;
      if ((action == 'investigate') != (tool != null) ||
          (action == 'propose') != (proposal != null) ||
          (action == 'approve') != (approval != null) ||
          (action == 'decide') != (decision != null) ||
          action != 'silent' && (m['public_update'] as String).trim().isEmpty) {
        return null;
      }
      return WorkDiscussionV2Turn._(
          action,
          WorkPublicUpdateStream.sanitize(m['public_update'] as String),
          m['issue_id'] as String,
          m['next_member_id'] as String,
          issues,
          resolutions,
          proposal,
          approval,
          decision,
          tool);
    } on Object {
      return null;
    }
  }

  static bool _text(Object? v, int max) =>
      v is String &&
      v.length <= max &&
      !v.contains(RegExp(r'[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]'));
  static bool _nonempty(Object? v) =>
      _text(v, 4096) && (v as String).trim().isNotEmpty;
  static bool _keys(Map<String, dynamic> m, Set<String> keys) =>
      m.length == keys.length && m.keys.every(keys.contains);
  static List<Map<String, dynamic>>? _records(Object? v) {
    if (v is! List || v.length > 64) return null;
    try {
      return v.map((e) => Map<String, dynamic>.from(e as Map)).toList();
    } on Object {
      return null;
    }
  }
}
