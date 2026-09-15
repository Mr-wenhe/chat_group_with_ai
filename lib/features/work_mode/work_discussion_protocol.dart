import 'dart:convert';

import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/features/work_mode/work_public_update_stream.dart';

/// Public fields accepted from one discussion turn. Private reasoning and
/// tool-shaped fields are intentionally absent from this value object.
class WorkDiscussionTurn {
  final bool valid;
  final String failureReason;
  final String publicUpdate;
  final int understandingPercent;
  final List<String> understandingEvidence;
  final List<String> openQuestions;
  final List<String> resolvedQuestions;
  final List<String> blockers;
  final List<String> resolvedBlockers;
  final String? recommendedExecutorId;
  final Map<String, dynamic>? contractPatch;
  final bool substantiveProgress;
  final bool needsUser;
  final String userQuestion;

  const WorkDiscussionTurn.invalid({
    this.failureReason = '结构化回复无效',
    this.publicUpdate = '',
    this.understandingPercent = 0,
    this.understandingEvidence = const [],
    this.openQuestions = const [],
    this.resolvedQuestions = const [],
    this.blockers = const ['structuredResponseInvalid'],
    this.resolvedBlockers = const [],
    this.recommendedExecutorId,
    this.contractPatch,
    this.substantiveProgress = false,
    this.needsUser = false,
    this.userQuestion = '',
  }) : valid = false;

  const WorkDiscussionTurn({
    this.failureReason = '',
    required this.publicUpdate,
    required this.understandingPercent,
    required this.understandingEvidence,
    required this.openQuestions,
    required this.resolvedQuestions,
    required this.blockers,
    required this.resolvedBlockers,
    required this.recommendedExecutorId,
    required this.contractPatch,
    required this.substantiveProgress,
    required this.needsUser,
    required this.userQuestion,
  }) : valid = true;

  factory WorkDiscussionTurn.fromResponse(Map<String, dynamic> response) {
    if (response['success'] == false) {
      final message = _safeText(response['message']);
      return WorkDiscussionTurn.invalid(
        failureReason: message.isEmpty ? '模型调用失败' : message,
      );
    }
    final raw = _responseText(response);
    if (raw == null || raw.trim().isEmpty) {
      return const WorkDiscussionTurn.invalid();
    }
    final decoded = _decodeObject(raw);
    if (decoded == null) {
      // A plain answer is shown only as a safe diagnostic. It never counts as
      // structured progress and therefore can never open the execution gate.
      return WorkDiscussionTurn.invalid(
        failureReason: '模型返回了非结构化公开内容',
        publicUpdate: WorkPublicUpdateStream.sanitize(raw),
      );
    }

    final percent = _integer(
      decoded['understanding_percent'] ?? decoded['understandingPercent'],
    );
    if (percent == null) return const WorkDiscussionTurn.invalid();
    final evidence = _strings(
      decoded['understanding_evidence'] ?? decoded['understandingEvidence'],
      maximum: 512,
    );
    final questions = _strings(
      decoded['open_questions'] ?? decoded['openQuestions'],
      maximum: 256,
    );
    final resolvedQuestions = _optionalStrings(
      decoded['resolved_questions'] ?? decoded['resolvedQuestions'],
      maximum: 256,
    );
    final blockers = _strings(decoded['blockers'], maximum: 256);
    final resolvedBlockers = _optionalStrings(
      decoded['resolved_blockers'] ?? decoded['resolvedBlockers'],
      maximum: 256,
    );
    if (evidence == null ||
        questions == null ||
        resolvedQuestions == null ||
        blockers == null ||
        resolvedBlockers == null) {
      return const WorkDiscussionTurn.invalid();
    }
    final publicUpdate = _safeText(
      decoded['public_update'] ?? decoded['publicUpdate'],
    );
    if (publicUpdate.isEmpty) {
      return const WorkDiscussionTurn.invalid(
        failureReason: '模型没有提供公开职责意见',
      );
    }
    final userQuestion = _safeText(
      decoded['user_question'] ?? decoded['userQuestion'],
      maximum: 256,
    );
    final recommended = _optionalId(
      decoded['recommend_executor_id'] ?? decoded['recommendExecutorId'],
    );
    final patch = _contractPatch(decoded['contract']);
    final needsUser = decoded['needs_user'] == true ||
        decoded['needsUser'] == true ||
        userQuestion.isNotEmpty;
    if (needsUser && userQuestion.isEmpty) {
      return const WorkDiscussionTurn.invalid(
        failureReason: '模型标记需要用户信息，但没有提供可发送的问题',
      );
    }
    final substantive = decoded['substantive_progress'] == true ||
        decoded['substantiveProgress'] == true ||
        (publicUpdate.isNotEmpty &&
            (evidence.isNotEmpty || questions.isNotEmpty || percent > 0));
    return WorkDiscussionTurn(
      publicUpdate: publicUpdate,
      understandingPercent: percent,
      understandingEvidence: evidence,
      openQuestions: questions,
      resolvedQuestions: resolvedQuestions,
      blockers: blockers,
      resolvedBlockers: resolvedBlockers,
      recommendedExecutorId: recommended,
      contractPatch: patch,
      substantiveProgress: substantive,
      needsUser: needsUser,
      userQuestion: userQuestion,
    );
  }

  static String? _responseText(Map<String, dynamic> response) {
    final content = response['content'];
    if (content is String && content.trim().isNotEmpty) return content;
    final message = response['message'];
    if (message is String && message.trim().isNotEmpty) return message;
    // The gateway's compatibility rule allows this field only after the
    // standard content fields are empty. It is parsed as protocol data, never
    // displayed as private reasoning.
    final reasoning = response['reasoning_content'];
    return reasoning is String && reasoning.trim().isNotEmpty
        ? reasoning
        : null;
  }

  static Map<String, dynamic>? _decodeObject(String raw) {
    var source = raw.trim();
    if (source.startsWith('```')) {
      source = source.replaceFirst(RegExp(r'^```(?:json)?\s*'), '');
      source = source.replaceFirst(RegExp(r'\s*```$'), '');
    }
    final candidates = <String>[source];
    final embedded = _embeddedObject(source);
    if (embedded != null && embedded != source) candidates.add(embedded);
    for (final candidate in candidates) {
      try {
        final decoded = jsonDecode(candidate);
        if (decoded is Map<String, dynamic>) return decoded;
        if (decoded is Map) return Map<String, dynamic>.from(decoded);
      } on Object {
        // Some OpenAI-compatible gateways prepend a short explanation even
        // when the actual protocol body is valid JSON. Try only the first
        // balanced object; never interpret arbitrary prose as fields.
      }
    }
    return null;
  }

  /// Finds one complete top-level JSON object inside a bounded text reply.
  /// This is deliberately a parser fallback, not a free-form field extractor:
  /// the object still goes through every required-field and range check above.
  static String? _embeddedObject(String source) {
    final start = source.indexOf('{');
    if (start < 0) return null;
    var depth = 0;
    var quoted = false;
    var escaped = false;
    for (var index = start; index < source.length; index++) {
      final character = source[index];
      if (quoted) {
        if (escaped) {
          escaped = false;
        } else if (character == '\\') {
          escaped = true;
        } else if (character == '"') {
          quoted = false;
        }
        continue;
      }
      if (character == '"') {
        quoted = true;
      } else if (character == '{') {
        depth++;
      } else if (character == '}') {
        depth--;
        if (depth == 0) return source.substring(start, index + 1);
        if (depth < 0) return null;
      }
    }
    return null;
  }

  static int? _integer(Object? value) {
    if (value is! num || !value.isFinite || value != value.truncate()) {
      return null;
    }
    final integer = value.toInt();
    return integer < 0 || integer > 100 ? null : integer;
  }

  static List<String>? _strings(Object? value, {required int maximum}) {
    if (value is! List || value.length > 64) return null;
    final result = <String>[];
    for (final item in value) {
      if (item is! String) return null;
      final safe = _safeText(item, maximum: maximum);
      if (safe.isNotEmpty) {
        result.add(safe.substring(0, safe.length.clamp(0, maximum).toInt()));
      }
    }
    return result.toSet().take(32).toList(growable: false);
  }

  static List<String>? _optionalStrings(Object? value, {required int maximum}) {
    if (value == null) return const <String>[];
    return _strings(value, maximum: maximum);
  }

  static String _safeText(Object? value, {int maximum = 1024}) {
    if (value is! String) return '';
    final safe = WorkPublicUpdateStream.sanitize(value)
        .replaceAll(RegExp(r'[\u0000-\u001f\u007f]'), ' ')
        .trim();
    return safe.substring(0, safe.length.clamp(0, maximum).toInt());
  }

  static String? _optionalId(Object? value) {
    if (value is! String) return null;
    final trimmed = value.trim();
    if (trimmed.isEmpty ||
        trimmed.length > 128 ||
        trimmed.contains(RegExp(r'[\u0000-\u001f\u007f]'))) {
      return null;
    }
    return trimmed;
  }

  static Map<String, dynamic>? _contractPatch(Object? value) {
    if (value is! Map) return null;
    final output = <String, dynamic>{};
    for (final key in const [
      'deliverableType',
      'format',
      'location',
      'contentScope',
      'explicitExecutorId',
      'revisionTarget',
      'requestRevision',
    ]) {
      final item = value[key];
      if (key == 'requestRevision') {
        if (item is num && item.isFinite && item == item.truncate()) {
          output[key] = item.toInt();
        }
        continue;
      }
      if (item is String) {
        final safe = key == 'contentScope'
            ? _safeText(item)
            : item.replaceAll(RegExp(r'[\u0000-\u001f\u007f]'), ' ').trim();
        if (safe.isNotEmpty || key == 'revisionTarget') output[key] = safe;
      }
    }
    return output.isEmpty ? null : output;
  }
}

String discussionRoleLabel(AICharacter character) {
  final role = character.role.trim();
  return role.isEmpty ? character.name : '${character.name}（$role）';
}

String boundedDiscussionText(String value, {int maximum = 800}) {
  final safe = WorkPublicUpdateStream.sanitize(value);
  if (safe.length <= maximum) return safe;
  return '${safe.substring(0, maximum - 1)}…';
}
