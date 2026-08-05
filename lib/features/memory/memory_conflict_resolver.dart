import 'dart:math';

import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/models/permanent_memory.dart';
import 'package:chat_group/core/models/user_profile.dart';

/// 冲突处理操作类型。
enum ConflictAction {
  create,
  duplicate,
  supplement,
  supersede,
  profileOverride,
}

/// 冲突处理结果。
class ConflictResult {
  final ConflictAction action;
  final List<String> supersededIds;

  const ConflictResult(this.action, [this.supersededIds = const []]);
}

/// Handles conflict detection and audit-safe invalidation for permanent memory.
class MemoryConflictResolver {
  final DatabaseService db;

  const MemoryConflictResolver(this.db);

  Future<ConflictResult> resolve({
    required String observerId,
    required MemoryKind kind,
    required String content,
    required List<String> subjectIds,
    required UserProfile? userProfile,
  }) async {
    final exactDuplicate = db.permanentMemoryBox.values.any(
      (memory) =>
          memory.observerCharacterId == observerId &&
          memory.kind == kind &&
          memory.status == MemoryStatus.active &&
          memory.content == content &&
          _listsOverlap(memory.subjectIds, subjectIds),
    );
    if (exactDuplicate) return const ConflictResult(ConflictAction.duplicate);

    if (_conflictsWithProfile(content, subjectIds, userProfile: userProfile)) {
      final toInvalidate = db.permanentMemoryBox.values
          .where(
            (memory) =>
                memory.observerCharacterId == observerId &&
                memory.status == MemoryStatus.active &&
                memory.kind == kind &&
                !memory.pinned &&
                _listsOverlap(memory.subjectIds, subjectIds) &&
                _conflictsWithProfile(
                  memory.content,
                  memory.subjectIds,
                  userProfile: userProfile,
                ),
          )
          .map((memory) => memory.id)
          .toList();
      return ConflictResult(ConflictAction.profileOverride, toInvalidate);
    }

    final supersededIds = <String>[];
    for (final memory in db.permanentMemoryBox.values) {
      if (memory.observerCharacterId != observerId ||
          memory.status != MemoryStatus.active ||
          memory.kind != kind ||
          memory.pinned ||
          !_listsOverlap(memory.subjectIds, subjectIds)) {
        continue;
      }
      if (_isSuperseding(memory.content, content)) supersededIds.add(memory.id);
    }
    if (supersededIds.isNotEmpty) {
      return ConflictResult(ConflictAction.supersede, supersededIds);
    }

    final isSupplement = db.permanentMemoryBox.values.any(
      (memory) =>
          memory.observerCharacterId == observerId &&
          memory.status == MemoryStatus.active &&
          memory.kind == kind &&
          _listsOverlap(memory.subjectIds, subjectIds) &&
          _isRelatedContent(memory.content, content) &&
          memory.content != content,
    );
    if (isSupplement) return const ConflictResult(ConflictAction.supplement);

    return const ConflictResult(ConflictAction.create);
  }

  bool _listsOverlap(List<String> a, List<String> b) =>
      (a.isEmpty && b.isEmpty) ||
      (a.isNotEmpty && b.isNotEmpty && a.any(b.contains));

  bool _isSuperseding(String oldContent, String newContent) {
    final newLower = newContent.toLowerCase();
    final oldLower = oldContent.toLowerCase();
    final negationPattern = RegExp(r'不是|不|错误|更正|修正|实际上|其实是');
    if (negationPattern.hasMatch(newLower) &&
        oldLower.length >= 2 &&
        newLower.contains(oldLower.substring(0, min(oldLower.length, 4)))) {
      return true;
    }
    return newContent.length > oldContent.length * 1.5 &&
        oldLower.split(' ').any(newLower.contains);
  }

  bool _isRelatedContent(String a, String b) {
    final overlap =
        _tokenize(a.toLowerCase()).intersection(_tokenize(b.toLowerCase()));
    return overlap.length >= 2;
  }

  Set<String> _tokenize(String text) {
    final result = <String>{};
    final segments = text.split(RegExp(r'\s+|[，。！？、,.!?；;：:""「」『』【】\s]'));
    for (final segment in segments) {
      if (segment.length < 2) continue;
      if (segment.length == 2) {
        result.add(segment);
      } else {
        for (var i = 0; i < segment.length - 1; i++) {
          result.add(segment.substring(i, i + 2));
        }
      }
    }
    return result;
  }

  bool _conflictsWithProfile(
    String content,
    List<String> subjectIds, {
    required UserProfile? userProfile,
  }) {
    if (!subjectIds.contains('user') || userProfile == null) return false;
    final lower = content.toLowerCase();

    if (userProfile.displayName.isNotEmpty) {
      final namePatterns = [
        RegExp(r'名字叫(.+?)(?:，|。|$|的)'),
        RegExp(r'叫(.+?)(?:，|。|$|的)'),
        RegExp(r'姓名[是为](.+?)(?:，|。|$|的)'),
      ];
      for (final pattern in namePatterns) {
        final match = pattern.firstMatch(lower);
        final rememberedName = match?.group(1)?.trim() ?? '';
        if (rememberedName.isNotEmpty &&
            !lower.contains(userProfile.displayName.toLowerCase()) &&
            rememberedName != userProfile.displayName.toLowerCase()) {
          return true;
        }
      }
    }

    if (userProfile.age != null) {
      final ageMatch = RegExp(r'(\d+)\s*岁').firstMatch(lower);
      final rememberedAge = int.tryParse(ageMatch?.group(1) ?? '');
      if (rememberedAge != null && rememberedAge != userProfile.age) {
        return true;
      }
    }

    for (final background in userProfile.importantBackground) {
      final value = background.toLowerCase();
      if (lower.contains('不是$value') ||
          lower.contains('不是 $value') ||
          lower.contains('不对$value') ||
          lower.contains('错误$value')) {
        return true;
      }
    }
    return false;
  }
}
