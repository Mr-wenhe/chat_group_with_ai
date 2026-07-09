import 'dart:convert';

import 'package:chat_group/core/models/tool_permission.dart';

class GeneratedSkillDraft {
  final String name;
  final String domain;
  final String description;
  final List<String> instructions;
  final List<ToolPermission> permissions;

  const GeneratedSkillDraft({
    required this.name,
    required this.domain,
    required this.description,
    required this.instructions,
    required this.permissions,
  });
}

class SkillGenerationService {
  static GeneratedSkillDraft? parseDraft(String content) {
    final match =
        RegExp(r'```skill_json\s*([\s\S]*?)\s*```').firstMatch(content);
    if (match == null) return null;
    try {
      final decoded = jsonDecode(match.group(1)!);
      if (decoded is! Map<String, dynamic>) return null;
      final instructions = decoded['instructions'];
      final permissions = decoded['permissions'];
      if (instructions is! List || permissions is! List) return null;
      return GeneratedSkillDraft(
        name: decoded['name'] as String? ?? '',
        domain: decoded['domain'] as String? ?? 'general',
        description: decoded['description'] as String? ?? '',
        instructions: instructions.whereType<String>().toList(),
        permissions: permissions
            .whereType<String>()
            .map(_permissionFromName)
            .whereType<ToolPermission>()
            .toList(),
      );
    } on FormatException {
      return null;
    }
  }

  static ToolPermission? _permissionFromName(String name) {
    for (final permission in ToolPermission.values) {
      if (permission.name == name) return permission;
    }
    return null;
  }
}
