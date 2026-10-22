import 'work_contract_change.dart';
import 'dart:convert';

import 'package:chat_group/core/models/agent_task.dart';
import 'package:chat_group/features/work_mode/work_discussion_state.dart';
import 'package:chat_group/features/work_mode/work_collaboration_state.dart';
import 'package:crypto/crypto.dart';

/// A confirmation gate stored in the existing task checkpoint.
///
/// It carries only the request version and a digest. The request itself remains
/// in the existing task/discussion record, so a confirmation can never silently
/// authorize a different revision.
class WorkTaskRequirementsConfirmation {
  static const String metadataKey = 'requirementsConfirmation';
  static const String blockerId = 'requirementsConfirmation';
  static const _flightRules =
      '四人同机轮流，每人 4 架棋子；掷出 6 起飞，掷出 6 可再掷一次；落在对手非安全格时撞子回基地；到达终点需点数精确；任一方 4 架棋子全部到终点即获胜，可重新开始。';
  static final RegExp _explicitFlightRules = RegExp(
    r'[0-9一二两三四五六七八九十]+(?:人|名玩家|位玩家)|单人|双人|多人|'
    r'起飞|掷|骰|撞子|安全格|回基地|终点|胜|重新开始|重开',
  );

  /// 卡中被接受的默认玩法也是需求，不能只留在消息正文里。
  static void acceptCurrentRequest(AgentTask task) {
    if (!isCurrent(task)) throw StateError('需求确认卡已过期。');
    final shell =
        WorkDiscussionState.fromExecutionState(task.executionStateJson)!;
    final state = shell.collaboration;
    if (state != null &&
        RegExp(r'飞行棋|飞机棋').hasMatch(state.scope) &&
        !_explicitFlightRules.hasMatch(state.scope) &&
        !state.scope.contains(_flightRules)) {
      final next = WorkCollaborationState.tryParse(state.toJson()
        ..['scope'] = '${state.scope}\n用户确认卡中接受的玩法：$_flightRules'
        ..['revision'] = state.revision + 1);
      if (next == null) throw StateError('确认内容无法保存，未开始执行。');
      task.executionStateJson = WorkDiscussionState.mergeIntoExecutionState(
        task.executionStateJson,
        shell.copyWith(collaboration: next),
        expectedCollaborationRevision: state.revision,
      );
    }
    clear(task);
  }

  static void requireForCurrentRequest(AgentTask task) {
    final metadata = _decodeForWrite(task.executionStateJson);
    final discussion = WorkDiscussionState.decodeExecutionState(
      task.executionStateJson,
    );
    if (!discussion.isValid || discussion.state == null) {
      throw StateError('缺少有效的群聊需求检查点，不能要求确认。');
    }
    final state = discussion.state!;
    final scope = WorkDiscussionState.currentRequestScope(task).trim();
    if (scope.isEmpty) throw StateError('需求内容为空，不能要求确认。');
    metadata[metadataKey] = <String, dynamic>{
      'schemaVersion': 1,
      'requestRevision': state.requestRevision,
      'scopeDigest': _digest(scope),
      'contractDigest':
          _digest(jsonEncode(state.deliverableContract ?? const {})),
    };
    task.executionStateJson = jsonEncode(metadata);
  }

  static bool hasMarker(String executionStateJson) =>
      _decode(executionStateJson).containsKey(metadataKey);

  static bool isCurrent(AgentTask task) {
    final raw = _decode(task.executionStateJson)[metadataKey];
    final discussion = WorkDiscussionState.decodeExecutionState(
      task.executionStateJson,
    );
    if (raw is! Map || !discussion.isValid || discussion.state == null) {
      return false;
    }
    final revision = raw['requestRevision'];
    final scopeDigest = raw['scopeDigest'];
    final contractDigest = raw['contractDigest'];
    final scope = WorkDiscussionState.currentRequestScope(task).trim();
    return raw['schemaVersion'] == 1 &&
        revision is int &&
        revision == discussion.state!.requestRevision &&
        scopeDigest is String &&
        scope.isNotEmpty &&
        scopeDigest == _digest(scope) &&
        contractDigest is String &&
        contractDigest == _contractDigest(task);
  }

  /// Only a text acknowledgement may confirm the already displayed request.
  static bool acceptsMessage(AgentTask task, String text,
          {bool hasAttachments = false}) =>
      !hasAttachments &&
      isCurrent(task) &&
      RegExp(r'^(我)?(确认|接受|同意)(?:(当前|本版|这版)?需求)?[。！!\s]*$')
          .hasMatch(text.trim());

  static int versionFor(AgentTask task) {
    final raw = _decode(task.executionStateJson)[metadataKey];
    if (raw is! Map || !isCurrent(task)) return 0;
    final revision = raw['requestRevision'] as int;
    return _versionDigest(<String>[
      task.id,
      blockerId,
      revision.toString(),
      raw['scopeDigest'] as String,
      raw['contractDigest'] as String,
      task.characterId,
      ...task.assignedCharacterIds,
    ]);
  }

  static void clear(AgentTask task) {
    final metadata = _decode(task.executionStateJson)..remove(metadataKey);
    task.executionStateJson = metadata.isEmpty ? '' : jsonEncode(metadata);
  }

  /// Builds the concise card shown before group discussion. It uses only the
  /// current user request and routed contract; unconfirmed implementation
  /// details are explicitly presented as suggestions.
  static String cardFor(
    AgentTask task, {
    required String executorName,
  }) {
    final state = WorkDiscussionState.fromExecutionState(
      task.executionStateJson,
    );
    final contract = state?.deliverableContract ?? const <String, dynamic>{};
    final scope = WorkDiscussionState.currentRequestScope(task).trim();
    final revision = state?.requestRevision ?? 1;
    final flightGame = RegExp(r'飞行棋|飞机棋').hasMatch(scope);
    final explicitFlightRules = _explicitFlightRules.hasMatch(scope);
    final purpose = flightGame ? '制作可实际游玩的单文件 HTML 飞行棋。' : _summaryLine(scope);
    final location = _contractText(contract['location']);
    final format = _contractText(contract['format']);
    final deliverable = _deliverable(scope, contract);
    final assigned = executorName.trim().isNotEmpty
        ? executorName.trim()
        : '群内成员讨论并核实合适的执行人';
    final ruleSuggestion = flightGame && explicitFlightRules
        ? '玩法要求：按你原话中已明确的规则执行；未写明的细节由成员提出建议并标明。'
        : flightGame
            ? '玩法建议：$_flightRules'
            : '默认假设：严格按你写明的范围执行；没有写明的细节由成员提出合理建议并标明。';
    final flightGameVerification = flightGame
        ? '交付与测试：CSS 和 JavaScript 内嵌于同一 HTML，无需安装、构建或联网，双击即可打开。非制作人测试成员实际运行当前候选，记录版本摘要、测试项目、预期、实际和执行记录；失败时列出本轮全部缺陷，由程序媛返工生成新候选后再独立复测。'
        : '';
    final openQuestions = flightGame && explicitFlightRules
        ? '仍需你决定：没有写明的玩法细节由团队提出默认建议并标明。'
        : flightGame
            ? '仍需你决定：暂无硬性问题；上面的玩法是待你确认的默认建议。'
            : '仍需你决定：${_openQuestion(scope)}';
    final flightAcceptance = explicitFlightRules
        ? '按你明确写出的玩家人数与玩法规则实现；以群内测试成员实际操作当前候选为准。'
        : '四人轮流、掷骰、起飞与移动、撞子回基地、胜负判定、重新开始；以群内测试成员实际操作当前候选为准。';
    return '🟡【待你确认】需求版本 $revision\n'
        '要完成什么：$purpose\n'
        '负责人：$assigned；其他成员参与讨论收敛，并由独立测试成员实际验证。\n'
        '保存位置与交付：${location.isEmpty ? '讨论中明确' : location}；$deliverable'
        '${format.isEmpty ? '' : '（格式：$format）'}\n'
        '核心功能与验收：${flightGame ? flightAcceptance : _acceptanceSummary(scope)}\n'
        '$ruleSuggestion\n'
        '${flightGame ? '$flightGameVerification\n' : ''}'
        '$openQuestions\n'
        '你可以在群里补充或纠正；卡片会按新需求版本更新。确认前不会开始群讨论、制作或写入产物。';
  }

  static String _summaryLine(String scope) {
    final first = scope
        .split(RegExp(r'[\n。！？!?]'))
        .map((part) => part.trim())
        .firstWhere((part) => part.isNotEmpty, orElse: () => scope);
    return first.length <= 220 ? first : '${first.substring(0, 219)}…';
  }

  static String _deliverable(String scope, Map<String, dynamic> contract) {
    final files = RegExp(
            r'(?<![\w/.-])[^\s，,；;。]+\.(?:html|htm|md|txt|json|pdf|docx|xlsx|pptx)',
            caseSensitive: false)
        .allMatches(scope)
        .map((match) => match.group(0)!)
        .toSet();
    final contractFiles = contract['files'];
    if (contractFiles is List) {
      files.addAll(contractFiles.whereType<String>());
    }
    if (files.isNotEmpty) return '交付文件：${files.join('、')}';
    final nestedHtmlPath = _nestedHtmlOutputPath(scope, contract);
    if (nestedHtmlPath != null) return '交付文件：$nestedHtmlPath';
    return '交付文件：${contract['revisionTarget'] is String && (contract['revisionTarget'] as String).trim().isNotEmpty ? contract['revisionTarget'] : '方案中明确'}';
  }

  /// The named file from a nested-folder request is part of the confirmed
  /// deliverable, even when the model later proposes a different filename.
  static String? requiredNestedHtmlOutputPath(AgentTask task) {
    final state = WorkDiscussionState.fromExecutionState(
      task.executionStateJson,
    );
    return _nestedHtmlOutputPath(
      WorkDiscussionState.currentRequestScope(task).trim(),
      state?.deliverableContract ?? const <String, dynamic>{},
    );
  }

  static String? _nestedHtmlOutputPath(
    String scope,
    Map<String, dynamic> contract,
  ) {
    final nestedHtml = RegExp(
      r'(?:创建|新建)一个([^，,；;。/\\\s]+)的目录\s*[,，;；]?\s*'
      r'里面放着一份([^，,；;。/\\\s]+?)的\s*html\b',
      caseSensitive: false,
    ).firstMatch(scope);
    if (nestedHtml == null) return null;
    final folder = nestedHtml.group(1)!.trim();
    final name = nestedHtml.group(2)!.trim();
    final root = _contractText(contract['location'])
        .replaceAll('\\', '/')
        .replaceFirst(RegExp(r'/+$'), '');
    final directory = root.isEmpty || root.toLowerCase() == 'desktop'
        ? folder
        : root.endsWith('/$folder')
            ? root
            : '$root/$folder';
    return rewrittenWorkArtifactPath(scope, '$directory/$name.html');
  }

  static String _acceptanceSummary(String scope) {
    final clauses = scope
        .split(RegExp(r'[\n；;。]'))
        .map((part) => part.trim())
        .where((part) => part.length >= 4)
        .take(4)
        .toList(growable: false);
    return clauses.isEmpty ? '以本需求和确认后的方案逐项验收。' : clauses.join('；');
  }

  static String _openQuestion(String scope) {
    if (scope.contains('仍需我决定') || scope.contains('请我决定')) {
      return '按卡片所列的问题补充后再确认。';
    }
    return '暂无必须你补充的内容；未写明的实现取舍由团队提出默认建议。';
  }

  static String _contractText(Object? value) =>
      value is String && value != 'unspecified' ? value.trim() : '';

  static String _digest(String value) =>
      sha256.convert(utf8.encode(value)).toString();

  static String _contractDigest(AgentTask task) {
    final state = WorkDiscussionState.fromExecutionState(
      task.executionStateJson,
    );
    return _digest(jsonEncode(state?.deliverableContract ?? const {}));
  }

  static int _versionDigest(Iterable<String> values) {
    final digest =
        sha256.convert(utf8.encode(values.join('\u001f'))).toString();
    final value = int.tryParse(digest.substring(0, 8), radix: 16) ?? 1;
    return value == 0 ? 1 : value;
  }

  static Map<String, dynamic> _decode(String raw) {
    if (raw.trim().isEmpty) return <String, dynamic>{};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map || decoded.keys.any((key) => key is! String)) {
        return <String, dynamic>{};
      }
      return Map<String, dynamic>.from(decoded);
    } on Object {
      return <String, dynamic>{};
    }
  }

  static Map<String, dynamic> _decodeForWrite(String raw) {
    if (raw.trim().isEmpty) return <String, dynamic>{};
    final decoded = jsonDecode(raw);
    if (decoded is! Map || decoded.keys.any((key) => key is! String)) {
      throw StateError('现有任务检查点格式无效，已保留原内容。');
    }
    return Map<String, dynamic>.from(decoded);
  }
}
