import 'dart:convert';

import 'package:chat_group/features/work_mode/agent_decision.dart';
import 'package:chat_group/features/work_mode/work_change_plan.dart';
import 'package:crypto/crypto.dart';

/// Names the capability represented by an approval checkpoint. A mutation
/// approval must never authorize a sensitive read, and vice versa.
abstract final class WorkApprovalCapability {
  static const mutation = 'mutation';
  static const sensitiveRead = 'sensitiveRead';
}

/// Produces stable, non-reversible operation identities for durable approval
/// checkpoints. Payloads such as file content are hashed and never persisted.
abstract final class WorkApprovalFingerprint {
  static String mutation({
    required AgentToolCall call,
    WorkChangePlan? plan,
  }) {
    return _digest({
      'capability': WorkApprovalCapability.mutation,
      'tool': call.name.wireName,
      'arguments': _canonical(call.arguments),
      if (plan != null) 'plan': _canonical(plan.toJson()),
    });
  }

  static String sensitiveRead({
    required String operation,
    required String path,
    int startByte = 0,
    int? byteLength,
    String? query,
    bool recursive = false,
    bool caseSensitive = true,
  }) {
    return _digest({
      'capability': WorkApprovalCapability.sensitiveRead,
      'operation': operation,
      'path': path,
      if (operation == 'search') ...{
        'query': query ?? '',
        'recursive': recursive,
        'caseSensitive': caseSensitive,
      } else ...{
        'startByte': startByte,
        'byteLength': byteLength,
      },
    });
  }

  static String _digest(Map<String, dynamic> payload) =>
      sha256.convert(utf8.encode(jsonEncode(_canonical(payload)))).toString();

  static Object? _canonical(Object? value, [String? key]) {
    if (value is String && _isSensitiveKey(key)) {
      return 'sha256:${sha256.convert(utf8.encode(value))}';
    }
    if (value is Map) {
      final entries = value.entries.toList()
        ..sort((left, right) =>
            left.key.toString().compareTo(right.key.toString()));
      return <String, Object?>{
        for (final entry in entries)
          entry.key.toString(): _canonical(entry.value, entry.key.toString()),
      };
    }
    if (value is Iterable) {
      return value.map((item) => _canonical(item)).toList(growable: false);
    }
    return value;
  }

  static bool _isSensitiveKey(String? key) {
    if (key == null) return false;
    final normalized = key.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
    return const {
      'content',
      'contents',
      'replacement',
      'expectedfragment',
      'script',
      'command',
      'description',
      'instructions',
      'body',
      'prompt',
      'token',
      'secret',
      'apikey',
      'authorization',
      'password',
    }.contains(normalized);
  }
}
