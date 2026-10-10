import 'dart:convert';
import 'package:chat_group/features/agentic/tool_request.dart';
import 'agent_decision.dart';
import 'work_public_update_stream.dart';
import 'work_tool_registry.dart';

/// Public expression and machine state are validated separately. Old replies,
/// previews, coordinator signatures and percentages cannot produce a v2 turn.
class WorkDiscussionV2Turn {
  final String action;

  /// 气泡正文：脱敏后按 [WorkPublicUpdateStream.bubbleTargetCharacters] 截断。
  final String publicUpdate;

  /// 脱敏后的完整正文；没有截断时与 [publicUpdate] 相同。
  ///
  /// 气泡有长度上限，但成员真正说过的话不能因此消失：被截断时调用方把这一份
  /// 转存成详情附件。
  final String publicUpdateFull;
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
      this.publicUpdateFull,
      this.issueId,
      this.nextMemberId,
      this.issues,
      this.resolutions,
      this.proposal,
      this.approval,
      this.decision,
      this.tool);

  /// 用重写后的公开正文替换原正文，其余字段原样保留。
  ///
  /// 只换正文，不重发整个 JSON：重写请求只被要求改善文风，若让它重出方案，它
  /// 就能顺手改掉 [approval] / [proposal]，等于借"改文风"篡改成员立场。
  /// [sanitizedFull] 与 [publicUpdateFull] 同口径，是已脱敏的完整正文。
  WorkDiscussionV2Turn withPublicUpdate(String sanitizedFull) =>
      WorkDiscussionV2Turn._(
          action,
          _bubbleText(sanitizedFull),
          sanitizedFull,
          issueId,
          nextMemberId,
          issues,
          resolutions,
          proposal,
          approval,
          decision,
          tool);

  /// 气泡正文：按 [WorkPublicUpdateStream.bubbleTargetCharacters] 截断。
  ///
  /// 首解析与重写共用同一处，否则两条路会各自漂移出一个长度。
  static String _bubbleText(String sanitized) =>
      WorkPublicUpdateStream.boundText(sanitized,
          maximum: WorkPublicUpdateStream.bubbleTargetCharacters,
          explicitNotice: true);

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

  /// Accept a single protocol object after a preface of at most 256 characters.
  /// The object still goes through the exact same schema validation below, and
  /// any non-whitespace text after it remains invalid.
  static Object? _decodeResponseObject(String raw) {
    if (raw.trimLeft().startsWith('{')) return jsonDecode(raw);

    // Bound candidate starts so malformed output cannot cause quadratic scans.
    const maxPrefaceCharacters = 256;
    for (var start = 0;
        start < raw.length && start <= maxPrefaceCharacters;
        start++) {
      if (raw.codeUnitAt(start) != 0x7b) continue; // {
      var depth = 0;
      var inString = false;
      var escaped = false;
      var end = -1;
      for (var index = start; index < raw.length; index++) {
        final unit = raw.codeUnitAt(index);
        if (inString) {
          if (escaped) {
            escaped = false;
          } else if (unit == 0x5c) {
            escaped = true;
          } else if (unit == 0x22) {
            inString = false;
          }
          continue;
        }
        if (unit == 0x22) {
          inString = true;
        } else if (unit == 0x7b) {
          depth++;
        } else if (unit == 0x7d) {
          depth--;
          if (depth == 0) {
            end = index;
            break;
          }
        }
      }
      if (end < 0 || raw.substring(end + 1).trim().isNotEmpty) continue;
      try {
        final decoded = jsonDecode(raw.substring(start, end + 1));
        if (decoded is Map) return decoded;
      } on FormatException {
        // A brace in the preface may not begin the protocol object. Keep
        // looking for the one complete, trailing JSON object.
      }
    }

    // Preserve the parser's normal syntax diagnostic for malformed output.
    return jsonDecode(raw);
  }

  static const protocol = '''只返回严格 JSON object，不输出 Markdown 或私有推理。
全部顶层字段必须出现：schemaVersion:2、action、public_update、issue_id、next_member_id、issues、resolutions、proposal、approval、decision、tool。无内容字段用空字符串、空数组或 null。
完整顶层结构示例（内容需按你的真实判断填写）：{"schemaVersion":2,"action":"respond","public_update":"本轮公开意见","issue_id":"","next_member_id":"","issues":[],"resolutions":[],"proposal":null,"approval":null,"decision":null,"tool":null}。不增加其他顶层字段，不把公开说明放在 JSON 外。
action: respond/investigate/propose/approve/decide/silent。respond 与 silent 时 proposal/approval/decision/tool 全部为 null；propose 只填 proposal，approve 只填 approval（包括本人不认可 approved:false），decide 只填 decision，investigate 只填 tool，其余三个为 null。public_update 是自然公开回应，不展示合同 JSON，不写理解百分比，不出现版本整数、approved:true|false、阶段名或 proposal 摘要等协议标识，不出现 artifactContract、requiredCapability、V-08 这类内部标识符，也不排 ①②③④ 式清单——那些值只填进对应字段，缺陷与补丁要求写进 issues 或详情，气泡只给你的判断和依据。公开气泡目标是 ${WorkPublicUpdateStream.bubbleTargetCharacters} 字以内（一到三个短句），按目标写而不是写到它的边上；超出部分会被截断并标注，完整正文转存为详情附件，所以只写当前结论、依据或异议，明细交给 issues 与详情。
本轮只推进上下文 turnFocus 指明的一项工作，不在一次回应中模拟整场会议、完整开发和未来验收。它是注意力提示，不是批准或工具授权；真实缺陷与分歧必须继续记录。outputGuidance 指定正文优先的建议预算，不保证服务端预留；先保证完整最终 JSON，不反复推演同一方案。
recentDiscussion 与 recentChatMessages 是有界聊天预览，可能截断，不能据此判定方案内容缺失；审查完整提案使用 collaboration 中的权威方案与关联问题。准备提交的命令必须写入完整 proposal.artifactContract.verificationCommands，不能只口头列在 public_update 中让其他成员从预览猜测。effectiveTools 表示角色与任务允许的权限，不保证工具已注册、依赖已安装或讨论阶段允许执行；browserContext 权限不能证明浏览器运行时可用，commandRun 权限不能证明 jsdom 已安装。
issues 是本轮全部新问题，每项 {id,kind:"defect|idea|decision",target,problem,evidenceRef,retestCondition}。问题、依据、解决条件必须具体；evidenceRef 引用当前真实证据或你的响应，不伪造代码读取。
新问题仅依据本轮本人意见时，issues.evidenceRef 填空字符串，运行时收到真实回应后才绑定响应 ID；不能填 self、current-response、userRequest 等占位符或自造引用。引用旧工具或用户答复时逐字复制 evidence 中真实键或 collaboration.decisions.responseRef。resolutions 必须引用已有真实证据，不引用尚未取得 ID 的当前回应。
resolutions 是 {id,resolution,evidenceRef} 数组，只引用真实工具/成员回应/用户答复，不因模型自称完成删除问题。
调查：action=investigate，issue_id 指向已有 open 问题，tool={name,arguments}。只允许 workspace.list/read/search/document；调查结果回台账后再讨论，禁止 command.run、写文件、安装、写探针或浏览器。工具能力与权限以运行时为准。
proposal={scope,plan,artifactContract:{type,format,location,revisionTarget,files:[相对路径字符串]},workItems:[{id,ownerId,dependencies,kind:"material|produce"}],acceptances:[{id,method,requiredCapability}]}。workItems 只允许 id/ownerId/dependencies/kind 四个字段，kind 可省略或为 material/produce；acceptances 只允许 id/method/requiredCapability 三个字段。不要把执行状态、说明文字或额外字段放进这些对象，运行时会生成状态字段。files 必须是相对路径字符串数组，不是对象数组。只协调成员可建立/修改当前方案，不默许原型；制作和测试工作项这里只规划，不声称已经执行。仅要求软件需求文档时不得扩展交付成软件。工作项、验收的 requestRevision 必须匹配当前需求；用户裁决/补充后旧版工作项必须由协调成员重新形成 proposal，不能只重新签字。
形成原范围方案时，proposal.scope 必须逐字复制 collaboration.scope（包含用户补充、禁止事项及原语言），不能翻译、摘要或重述；自然语言整理写在 plan 和 public_update。只有关联既有 open idea 的完整范围提案才能改变 scope 或既有验收，仍需逐人确认，不能用“意思相同”绕过。
proposal.artifactContract 从 collaboration.artifactContract 完整复制并保留全部现有字段，不只复制上方示例字段。非空且已明确的字段值必须保持原样（尤其 location 的绝对路径、format、revisionTarget）；不能换成 basename、相对路径或中文描述。只有尚未明确的空值、unspecified、generic 可以补齐；files 使用相对路径清单不意味着可以改写 location。
软件实现方案必须有 kind=material 的需求/技术/测试材料工作项以及 kind=produce 的实现工作项，完整的 artifactContract.files 实现文件清单和 verificationCommands 独立测试命令计划。只写“前端制作、测试验收”两行不足以启动软件制作；冻结候选后独立验证由运行时安排，讨论中不自称测试已通过。工具不足应明确提出能力问题，不虚构测试命令或批准收据。
verificationCommands 必须放在 proposal.artifactContract 内，不能成为 proposal 的第六个字段。它必须是非空字符串数组；每项都是 command.run 的紧凑 JSON 参数字符串，只能包含 executable 与 arguments，键顺序固定为 executable、arguments，例如元素文本为 {"executable":"node","arguments":["verify.js"]}。不得把元素写成对象，不得在命令字符串内添加编号或环境字段；V-01 等用例编号、每条命令的运行环境及其映射写在 plan 中。每条字符串不超过 1024 字符。proposal 本身只包含 scope、plan、artifactContract、workItems、acceptances。
已有方案非空时，补充原来没有的 verificationCommands 也属于验收修改；必须先登记 kind=idea 的问题，完整 proposal 用 issue_id 关联它，再由全员确认后采纳。可在同轮 issues 登记该提案问题并提交关联 proposal，但不能自称已被认可。既有 acceptances 的 id、method、requiredCapability 必须逐字保留；更新需求版本不意味着允许改写验收口径。任何新增或修改同样要关联提案。
新增范围作为 kind=idea 的问题，全体成员对该提案明确认可后再更新范围、计划和验收；有分歧用 decide 交用户。保留用户原始范围和所有禁止事项，不能扩大工具授权。
approval={kind:"plan|idea|delivery",subjectId,approved:true|false,requestRevision,teamRevision,verificationRevision}。delivery 必须另带 iterationId 和 artifactDigest，逐人审阅当前候选与真实验证报告。只代表自己，对当前完整方案或指定提案逐人确认；沉默、百分比、总结不是认可，不能返回他人签字。
approval 结构必须逐字包含 kind、subjectId、approved、requestRevision、teamRevision、verificationRevision 六个字段；版本必须是 JSON 整数而非字符串。plan 的 subjectId=taskId；idea 的 subjectId=对应问题 id；delivery 另加 iterationId 与 artifactDigest，且 subjectId=iterationId=当前候选 id、摘要原样复制当前候选。例：{"kind":"idea","subjectId":"ISS-VC-01","approved":true,"requestRevision":2,"teamRevision":1,"verificationRevision":3}。示例中的 ID 与版本仅说明类型和结构，必须替换为当前上下文的真实值，不能照抄。只代表自己，对当前完整方案或指定提案逐人确认；沉默、百分比、总结不是认可，不能返回他人签字。
decision={kind:"question|choice|dispute",targetId,reason,evidence,impact,options:[{id,label,impact}]}，用户偏好、未知规则与真实分歧走用户决策；不要把普通实现取舍推给用户。
next_member_id 可请求当前团队具体成员回应当前问题，不能用它调入群外成员。没有新增信息且无必要答复可以 silent。''';

  static WorkDiscussionV2Turn? parse(Map<String, dynamic> response,
      {void Function(String)? onInvalid}) {
    WorkDiscussionV2Turn? invalid(String reason) {
      onInvalid?.call(reason);
      return null;
    }

    if (response['success'] == false) return null;
    try {
      final raw = response['message'] ?? response['content'];
      if (raw is! String || raw.length > 48 * 1024) {
        return invalid('正文必须是字符串且不超过 48Ki 字符');
      }
      final decoded = _decodeResponseObject(raw);
      if (decoded is! Map) return invalid('顶层必须为 JSON object');
      final m = Map<String, dynamic>.from(decoded);
      if (m.length != fields.length ||
          !m.keys.every(fields.contains) ||
          m['schemaVersion'] != 2 ||
          !actions.contains(m['action']) ||
          !_text(m['public_update'], 12000) ||
          !_text(m['issue_id'], 128) ||
          !_text(m['next_member_id'], 128)) {
        return invalid('顶层必填字段、类型或长度不符合协议');
      }
      final issues = _records(m['issues']);
      final resolutions = _records(m['resolutions']);
      if (issues == null || resolutions == null) {
        return invalid('issues/resolutions 必须为对象数组，每项最多 64 条');
      }
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
          return invalid(
              'issues 项必须仅包含六个协议字段，非空文本最多 4096 字符，evidenceRef 最多 128 字符');
        }
      }
      for (final item in resolutions) {
        if (!_keys(item, {'id', 'resolution', 'evidenceRef'}) ||
            !item.values.every(_nonempty)) {
          return invalid('resolutions 项字段或非空文本长度不符合协议');
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
        return invalid(
            'proposal 仅包含 scope/plan/artifactContract/workItems/acceptances；scope、plan 非空且最多 4096 字符');
      }
      if (proposal != null &&
          !isValidArtifactContractFields(
              Map<String, dynamic>.from(proposal['artifactContract'] as Map))) {
        return invalid(
            'proposal.artifactContract 只能包含 type、format、location、revisionTarget、files、verificationCommands，合同文本长度须符合字段边界');
      }
      if (proposal != null &&
          !isValidVerificationCommands(
              Map<String, dynamic>.from(proposal['artifactContract'] as Map))) {
        return invalid(
            'artifactContract.verificationCommands 必须是 1–64 条紧凑 command.run JSON 字符串；每条仅含 executable 与 arguments，且不超过 1024 字符');
      }
      if (proposal != null &&
          !isValidArtifactFiles(
              Map<String, dynamic>.from(proposal['artifactContract'] as Map))) {
        return invalid('artifactContract.files 必须是非空相对路径字符串数组，每条不超过 128 字符');
      }
      if (proposal != null &&
          !_validProposalRecords(
              proposal['workItems'], {'id', 'ownerId', 'dependencies', 'kind'},
              requiredKeys: {'id', 'ownerId', 'dependencies'}, valid: (item) {
            final dependencies = item['dependencies'];
            return _text(item['id'], 128) &&
                _text(item['ownerId'], 128) &&
                (item['kind'] == null ||
                    {'material', 'produce'}.contains(item['kind'])) &&
                dependencies is List &&
                dependencies.length <= 64 &&
                dependencies.every((id) => _text(id, 128));
          })) {
        return invalid(
            'proposal.workItems 只能包含 id、ownerId、dependencies、kind；依赖必须是 ID 字符串数组');
      }
      if (proposal != null &&
          !_validProposalRecords(
              proposal['acceptances'], {'id', 'method', 'requiredCapability'},
              requiredKeys: {'id', 'method', 'requiredCapability'},
              valid: (item) =>
                  _text(item['id'], 128) &&
                  _nonempty(item['method']) &&
                  (item['method'] as String).length <= 128 &&
                  _text(item['requiredCapability'], 128))) {
        return invalid(
            'proposal.acceptances 只能包含 id、method、requiredCapability，且均须为有效文本');
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
        final missingRevisions = [
          for (final key in const [
            'requestRevision',
            'teamRevision',
            'verificationRevision'
          ])
            if (approval[key] is! int) key
        ];
        return invalid(
            'approval 必须只含当前 kind 对应字段；kind/subjectId/approved 必须有效。revision 字段必须是 JSON 整数：${missingRevisions.join(', ')}');
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
        return invalid('decision 字段、非空文本或 options 数组不符合协议');
      }
      AgentToolCall? tool;
      if (m['tool'] != null) {
        final t = Map<String, dynamic>.from(m['tool'] as Map);
        final name = AgentToolName.fromWire(t['name']);
        if (!_keys(t, {'name', 'arguments'}) ||
            name == null ||
            t['arguments'] is! Map) {
          return invalid('tool 必须只包含有效 name 和 arguments 对象');
        }
        final arguments = Map<String, dynamic>.from(t['arguments'] as Map);
        if (!WorkToolSchema.isJsonValue(arguments)) {
          return invalid('tool.arguments 含非 JSON 值');
        }
        tool = AgentToolCall(name: name, arguments: arguments);
      }
      final action = m['action'] as String;
      if ((action == 'investigate') != (tool != null) ||
          (action == 'propose') != (proposal != null) ||
          (action == 'approve') != (approval != null) ||
          (action == 'decide') != (decision != null) ||
          action != 'silent' && (m['public_update'] as String).trim().isEmpty) {
        return invalid(
            'action 与非空 proposal/approval/decision/tool 必须一一对应，非 silent 必须有公开回应');
      }
      final sanitizedUpdate =
          WorkPublicUpdateStream.sanitize(m['public_update'] as String);
      return WorkDiscussionV2Turn._(
          action,
          _bubbleText(sanitizedUpdate),
          sanitizedUpdate,
          m['issue_id'] as String,
          m['next_member_id'] as String,
          issues,
          resolutions,
          proposal,
          approval,
          decision,
          tool);
    } on FormatException catch (error) {
      return invalid('JSON 语法错误，字符偏移 ${error.offset ?? -1}');
    } on Object {
      return invalid('协议字段类型无法解析');
    }
  }

  static bool _text(Object? v, int max) =>
      v is String &&
      v.length <= max &&
      !v.contains(RegExp(r'[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]'));
  static bool isValidVerificationCommands(Map<String, dynamic> contract) {
    if (!contract.containsKey('verificationCommands')) return true;
    final commands = contract['verificationCommands'];
    if (commands == null) return true;
    if (commands is! List ||
        commands.isEmpty ||
        commands.length > 64 ||
        !commands.every((command) => _validVerificationCommand(command))) {
      return false;
    }
    return true;
  }

  static bool _validVerificationCommand(Object? value) {
    if (!_text(value, 1024)) return false;
    try {
      final decoded = jsonDecode(value as String);
      if (decoded is! Map ||
          decoded.length != 2 ||
          decoded.keys.toList().join(',') != 'executable,arguments' ||
          decoded['executable'] is! String ||
          (decoded['executable'] as String).trim().isEmpty ||
          decoded['arguments'] is! List ||
          !(decoded['arguments'] as List)
              .every((argument) => argument is String)) {
        return false;
      }
      // Runtime allowlisting compares this exact canonical serialization.
      return jsonEncode(decoded) == value;
    } on Object {
      return false;
    }
  }

  static bool isValidArtifactFiles(Map<String, dynamic> contract) {
    if (!contract.containsKey('files') || contract['files'] == null) {
      return true;
    }
    final files = contract['files'];
    return files is List &&
        files.isNotEmpty &&
        files.length <= 64 &&
        files.every((file) => _text(file, 128));
  }

  static bool isValidArtifactContractFields(Map<String, dynamic> contract) {
    const allowed = {
      'type',
      'format',
      'location',
      'revisionTarget',
      'files',
      'verificationCommands'
    };
    return contract.keys.every(allowed.contains) &&
        _text(contract['type'], 128) &&
        _text(contract['format'], 128) &&
        _text(contract['location'], 512) &&
        _text(contract['revisionTarget'], 512);
  }

  static bool _validProposalRecords(Object? value, Set<String> allowedKeys,
      {required Set<String> requiredKeys,
      required bool Function(Map<String, dynamic>) valid}) {
    if (value is! List || value.length > 64) return false;
    try {
      return value.every((raw) {
        final item = Map<String, dynamic>.from(raw as Map);
        return item.keys.every(allowedKeys.contains) &&
            requiredKeys.every(item.containsKey) &&
            valid(item);
      });
    } on Object {
      return false;
    }
  }

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
