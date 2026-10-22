import 'work_collaboration_state.dart';
import 'dart:convert';
import 'package:chat_group/features/agentic/tool_request.dart';
import 'agent_decision.dart';
import 'work_artifact_count.dart';
import 'work_discussion_v2_protocol_text.dart';
import 'work_discussion_v2_stage.dart';
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

  /// Repair one schema field without letting the repair rewrite other facts.
  static Map<String, dynamic>? proposalFieldRepair(String text, String error) {
    final field = const ['workItems', 'acceptances', 'usageAssignments']
        .where((field) =>
            error.startsWith('proposal.$field ') ||
            error.startsWith('proposal.$field['))
        .firstOrNull;
    if (field == null) return null;
    try {
      final original = _decodeResponseObject(text);
      if (original is! Map || original['proposal'] is! Map) return null;
      return {'field': field, 'original': original};
    } on Object {
      return null;
    }
  }

  static String mergeProposalFieldRepair(
      Map<String, dynamic> repair, String response) {
    final field = repair['field'] as String;
    final replacement = _decodeResponseObject(response);
    if (replacement is! Map ||
        replacement.length != 1 ||
        !replacement.containsKey(field)) {
      throw const FormatException('字段修复只能返回指定字段');
    }
    final original = Map<String, dynamic>.from(repair['original'] as Map);
    return jsonEncode({
      ...original,
      'proposal': {...original['proposal'] as Map, field: replacement[field]}
    });
  }

  /// Accept a single protocol object after a preface of at most 256 characters.
  /// The object still goes through the exact same schema validation below, and
  /// any non-whitespace text after it remains invalid.
  static Object? _decodeResponseObject(String raw) {
    if (raw.trimLeft().startsWith('{')) return _decodeObjectText(raw);

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
        final decoded = _decodeObjectText(raw.substring(start, end + 1));
        if (decoded is Map) return decoded;
      } on FormatException {
        // A brace in the preface may not begin the protocol object. Keep
        // looking for the one complete, trailing JSON object.
      }
    }

    // Preserve the parser's normal syntax diagnostic for malformed output.
    return _decodeObjectText(raw);
  }

  /// Decode JSON text, repairing stray unescaped quotes inside string values.
  ///
  /// 模型偶尔会在字符串值里写半角 `"`（例如引用用户原话），使 JSON 在服务端
  /// 边界就语法错误。严格解码失败时只转义这些游离引号再重试一次；若仍失败就
  /// 抛出原始 `FormatException`，让调用方保留既有的“畸形响应”诊断。
  static Object? _decodeObjectText(String text) {
    try {
      return jsonDecode(text);
    } on FormatException {
      final repaired = _escapeStrayQuotes(text);
      if (repaired == null) rethrow;
      return jsonDecode(repaired);
    }
  }

  /// 转义“落在字符串值内部、却不闭合字符串”的引号。
  ///
  /// 合法 JSON 里字符串的闭合引号后面（跳过空白）只可能是 `, : } ]`；否则该引号
  /// 属于正文，应转义。没有可修复内容时返回 `null`，让调用方沿用严格解码的报错。
  static String? _escapeStrayQuotes(String raw) {
    final out = StringBuffer();
    var inString = false;
    var escaped = false;
    var changed = false;
    for (var i = 0; i < raw.length; i++) {
      final ch = raw[i];
      if (!inString) {
        if (ch == '"') inString = true;
        out.write(ch);
        continue;
      }
      if (escaped) {
        escaped = false;
        out.write(ch);
        continue;
      }
      if (ch == r'\') {
        escaped = true;
        out.write(ch);
        continue;
      }
      if (ch != '"') {
        out.write(ch);
        continue;
      }
      if (_quoteClosesString(raw, i)) {
        inString = false;
        out.write(ch);
      } else {
        out.write(r'\"');
        changed = true;
      }
    }
    return changed ? out.toString() : null;
  }

  /// 引号 [index] 是否闭合当前字符串：其后第一个非空白字符须为 `, : } ]`。
  static bool _quoteClosesString(String raw, int index) {
    for (var j = index + 1; j < raw.length; j++) {
      final unit = raw.codeUnitAt(j);
      if (unit == 0x20 || unit == 0x09 || unit == 0x0a || unit == 0x0d) {
        continue;
      }
      return unit == 0x2c || unit == 0x3a || unit == 0x7d || unit == 0x5d;
    }
    return true;
  }

  /// 按阶段取协议尾部：认可合同只在认可轮出现。
  ///
  /// 其余两个阶段不可能被采纳认可（方案/提案/候选都还没就位，闸门会拒），把它的
  /// 结构说明发过去只是让成员对着无关字段反复自检。
  static String _tailFor(WorkDiscussionStage stage,
          {required bool autonomous}) =>
      _tail(
          includeApproval: stage == WorkDiscussionStage.reviewApproval,
          autonomous: autonomous);

  static String _tail(
          {required bool includeApproval, required bool autonomous}) =>
      WorkDiscussionProtocolText.proposalTail +
      (includeApproval ? WorkDiscussionProtocolText.approvalTail : '') +
      (autonomous ? WorkDiscussionProtocolText.autonomyRules : '') +
      WorkDiscussionProtocolText.tailCommon(autonomous: autonomous);

  /// 协议总则加材料要求：首轮请求与协议修复器共用同一份。
  static String _withContractRules(String userRequest,
          {required bool autonomous}) =>
      WorkDiscussionProtocolText.headFor(autonomous: autonomous) +
      (requestsSingleArtifact(userRequest)
          ? WorkDiscussionProtocolText.singleArtifactRule
          : WorkDiscussionProtocolText.materialsRule);

  /// 按用户原话取协议文本。
  ///
  /// [userRequest] 必须是**冻结**的需求范围（运行时用
  /// `WorkDiscussionState.currentRequestScope(task)`），不能是 `task.userRequest`：
  /// 那个字段会被跟进推广覆盖，而产出阶段的合同闸门按同一份范围判定要不要材料
  /// 工作项，两边读不同的源就会在一次跟进后各说各话。
  ///
  /// [stage] 决定要不要带上认可合同：本轮不可能被采纳的 action 不该占额度，也不该
  /// 让成员对着与它无关的字段反复自检。提案合同不参与裁剪，理由见
  /// [WorkDiscussionProtocolText.proposalTail]。
  ///
  /// 运行时一律走这里，不要直接用 `WorkDiscussionProtocolText` 里的常量拼默认版：
  /// 用户只点名一个交付文件时不强制材料工作项，否则那三份文档会把一个"生成
  /// 一份 HTML"的请求放大成五份产物（2026-10-10 现场）。
  static String protocolFor(
    String userRequest, {
    required WorkDiscussionStage stage,
    bool autonomous = false,
  }) =>
      _withContractRules(userRequest, autonomous: autonomous) +
      _tailFor(stage, autonomous: autonomous);

  /// 协议修复器用的全量协议：修复器要把任意原始响应转成合法 JSON。
  ///
  /// 原始响应可能包含任何 action，按阶段裁剪它会让"模型写坏了 JSON"这件事更难
  /// 救回来，所以这里刻意不带 stage 参数。
  static String repairProtocolFor(String userRequest,
          {bool autonomous = false}) =>
      _withContractRules(userRequest, autonomous: autonomous) +
      _tail(includeApproval: true, autonomous: autonomous);

  static WorkDiscussionV2Turn? parse(Map<String, dynamic> response,
      {void Function(String)? onInvalid, bool autonomous = false}) {
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
      const issueKeys = {
        'id',
        'kind',
        'target',
        'problem',
        'evidenceRef',
        'retestCondition'
      };
      for (var index = 0; index < issues.length; index++) {
        final item = issues[index];
        if (!_keys(item, issueKeys)) {
          final missing =
              issueKeys.where((key) => !item.containsKey(key)).join('、');
          final unexpected = item.keys
              .where((key) => !issueKeys.contains(key))
              .map((key) =>
                  RegExp(r'^[A-Za-z][A-Za-z0-9_]{0,63}$').hasMatch(key)
                      ? key
                      : 'unknown')
              .join('、');
          return invalid(
              'issues[$index] 必须且只能包含 id、kind、target、problem、evidenceRef、retestCondition；'
              '缺少字段：${missing.isEmpty ? '无' : missing}；多余字段：${unexpected.isEmpty ? '无' : unexpected}');
        }
        if (!{'defect', 'idea', 'decision'}.contains(item['kind'])) {
          return invalid('issues[$index].kind 必须为 defect、idea 或 decision');
        }
        for (final field in const [
          'id',
          'target',
          'problem',
          'retestCondition'
        ]) {
          final value = item[field];
          if (value is! String || value.trim().isEmpty || !_text(value, 4096)) {
            return invalid('issues[$index].$field 必须是非空、无控制字符且不超过 4096 字符的字符串');
          }
        }
        if (!_text(item['evidenceRef'], 128)) {
          return invalid('issues[$index].evidenceRef 必须是不超过 128 字符且无控制字符的字符串');
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
      var proposal = optional('proposal');
      final approval = optional('approval');
      final decision = optional('decision');
      if (proposal != null &&
          (!_keys(proposal, {
                'scope',
                'plan',
                'artifactContract',
                'workItems',
                'acceptances',
                if (proposal.containsKey('usageAssignments')) 'usageAssignments'
              }) ||
              !_nonempty(proposal['scope']) ||
              !_nonempty(proposal['plan']) ||
              proposal['artifactContract'] is! Map ||
              _records(proposal['workItems']) == null ||
              _records(proposal['acceptances']) == null)) {
        return invalid(
            'proposal 须仅包含 scope/plan/artifactContract/workItems/acceptances 五个基础字段；自主策略下还必须且只可增加 usageAssignments。scope、plan 非空且最多 4096 字符');
      }
      if (proposal != null &&
          (autonomous || proposal.containsKey('usageAssignments'))) {
        final assignments = _records(proposal['usageAssignments']);
        if (assignments == null || assignments.isEmpty) {
          return invalid('proposal.usageAssignments 必须是非空逐成员场景数组，自主方案不得省略');
        }
        for (var index = 0; index < assignments.length; index++) {
          final error = WorkCollaborationAutonomy.proposalAssignmentError(
              assignments[index]);
          if (error != null) {
            return invalid('proposal.usageAssignments[$index].$error');
          }
        }
      }
      if (proposal != null && proposal['artifactContract'] is Map) {
        final contract = Map<String, dynamic>.from(
          proposal['artifactContract'] as Map,
        );
        if (contract.containsKey('verificationCommands') &&
            contract['verificationCommands'] != null) {
          final normalized = normalizeVerificationCommands(
            contract['verificationCommands'],
          );
          if (normalized == null) {
            return invalid(
              'artifactContract.verificationCommands 必须是 1–64 条 command.run 命令；每条可用 JSON 字符串或仅含 executable 与 arguments 的对象表达，字段和类型必须精确匹配，且规范化后不超过 1024 字符。拒绝额外字段、控制字符和超长参数。',
            );
          }
          // JSON object member order and insignificant whitespace do not alter
          // a command. Store the one canonical representation used by the
          // approved command baseline, preserving executable and argument
          // strings exactly.
          contract['verificationCommands'] = normalized;
          proposal = <String, dynamic>{
            ...proposal,
            'artifactContract': contract,
          };
        }
      }
      if (proposal != null &&
          !isValidArtifactContractFields(
              Map<String, dynamic>.from(proposal['artifactContract'] as Map))) {
        return invalid(
            'proposal.artifactContract 只能包含 type、format、location、revisionTarget、files、verificationCommands、nativeBundle；type/format 最多 128 字符，location/revisionTarget 最多 512 字符。若提供 nativeBundle，必须含 schemaVersion:1、相对路径 appPath（.app）和 archivePath（.zip），且 type 为 software、files 只能包含 archivePath');
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
            'proposal.acceptances 每项只能包含 id、method、requiredCapability；id 和 requiredCapability 最多 128 字符，method 必须非空且最多 128 字符，长验收条件应拆分为多项');
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
              !{'question', 'choice', 'dispute', 'ruling'}
                  .contains(decision['kind']) ||
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
  static List<String>? normalizeVerificationCommands(Object? value) {
    if (value is! List || value.isEmpty || value.length > 64) return null;
    final normalized = <String>[];
    for (final item in value) {
      try {
        final Object? decoded;
        if (item is String) {
          if (!_text(item, 1024)) return null;
          decoded = jsonDecode(item);
        } else if (item is Map) {
          decoded = Map<String, dynamic>.from(item);
        } else {
          return null;
        }
        if (decoded is! Map ||
            decoded.length != 2 ||
            !decoded.containsKey('executable') ||
            !decoded.containsKey('arguments') ||
            decoded['executable'] is! String ||
            (decoded['executable'] as String).trim().isEmpty ||
            (decoded['executable'] as String)
                .contains(RegExp(r'[\u0000-\u001f\u007f]')) ||
            decoded['arguments'] is! List ||
            (decoded['arguments'] as List).length > 64 ||
            !(decoded['arguments'] as List).every(
              (argument) =>
                  argument is String &&
                  !argument.contains(RegExp(r'[\u0000-\u001f\u007f]')),
            )) {
          return null;
        }
        final canonical = jsonEncode(<String, dynamic>{
          'executable': decoded['executable'],
          'arguments': decoded['arguments'],
        });
        if (canonical.length > 1024) return null;
        normalized.add(canonical);
      } on Object {
        return null;
      }
    }
    return normalized;
  }

  static bool isValidVerificationCommands(Map<String, dynamic> contract) {
    if (!contract.containsKey('verificationCommands')) return true;
    final commands = contract['verificationCommands'];
    if (commands == null) return true;
    return normalizeVerificationCommands(commands) != null;
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
      'verificationCommands',
      'nativeBundle'
    };
    return contract.keys.every(allowed.contains) &&
        _text(contract['type'], 128) &&
        _text(contract['format'], 128) &&
        _text(contract['location'], 512) &&
        _text(contract['revisionTarget'], 512) &&
        _validNativeBundleContract(contract);
  }

  static bool _validNativeBundleContract(Map<String, dynamic> contract) {
    final value = contract['nativeBundle'];
    if (value == null) return true;
    if (value is! Map ||
        value.length != 3 ||
        value.keys.any((key) =>
            key is! String ||
            !const {'schemaVersion', 'appPath', 'archivePath'}.contains(key)) ||
        value['schemaVersion'] != 1 ||
        !_relativeMacBundlePath(value['appPath'], '.app') ||
        !_relativeMacBundlePath(value['archivePath'], '.zip') ||
        contract['type'] != 'software' ||
        contract['files'] is! List ||
        (contract['files'] as List).length != 1 ||
        (contract['files'] as List).single != value['archivePath']) {
      return false;
    }
    return true;
  }

  static bool _relativeMacBundlePath(Object? value, String suffix) =>
      value is String &&
      value.length <= 255 &&
      value.endsWith(suffix) &&
      !value.startsWith('/') &&
      !value.contains('\\') &&
      !value.contains('\u0000') &&
      value
          .split('/')
          .every((part) => part.isNotEmpty && part != '.' && part != '..');

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
