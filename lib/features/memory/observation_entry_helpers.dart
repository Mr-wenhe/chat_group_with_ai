part of 'observation_entry.dart';

extension _ObservationEntryHelpers on ObservationEntry {
  ApiConfig? _resolveConfig(AICharacter character) {
    if (character.apiConfigId.isEmpty) return null;
    return db.apiConfigBox.get(character.apiConfigId);
  }

  String _explicitMemoryId({
    required String observerId,
    required String conversationId,
    required String messageId,
  }) =>
      'explicit:$observerId:$conversationId:$messageId';

  MemoryKind? _parseKind(Object? raw) {
    if (raw is! String) return null;
    switch (raw) {
      case 'fact':
        return MemoryKind.fact;
      case 'preference':
        return MemoryKind.preference;
      case 'commitment':
        return MemoryKind.commitment;
      case 'sharedExperience':
        return MemoryKind.sharedExperience;
      case 'relationshipNote':
        return MemoryKind.relationshipNote;
      case 'personaGrowth':
        return MemoryKind.personaGrowth;
      case 'explicitInstruction':
        return MemoryKind.explicitInstruction;
      default:
        return null;
    }
  }

  List<String>? _parseSubjectIds(Object? raw, List<String> visibleIds) {
    if (raw is! List) return null;
    final result = <String>[];
    for (final item in raw) {
      if (item is! String) return null;
      final id = item.trim();
      if (id.isEmpty) return null;
      if (id == 'user') {
        if (!result.contains('user')) result.add('user');
      } else if (visibleIds.contains(id)) {
        if (!result.contains(id)) result.add(id);
      } else {
        return null;
      }
    }
    return result;
  }

  MemoryOriginType _originTypeForConversation(String conversationId) {
    if (DirectChatSession.isDirectConversationId(conversationId)) {
      return MemoryOriginType.direct;
    }
    return MemoryOriginType.group;
  }
}
