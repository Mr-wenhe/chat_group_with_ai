import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/chat_group.dart';

class PinnedOrdering {
  static List<AICharacter> sortCharacters(
    Iterable<AICharacter> characters, {
    required Set<String> pinnedIds,
  }) {
    final sorted = characters.toList();
    sorted.sort((a, b) {
      final pinCompare = _comparePinned(a.id, b.id, pinnedIds);
      if (pinCompare != 0) return pinCompare;
      final nameCompare = a.name.compareTo(b.name);
      if (nameCompare != 0) return nameCompare;
      return a.createdAt.compareTo(b.createdAt);
    });
    return sorted;
  }

  static List<ChatGroup> sortGroups(
    Iterable<ChatGroup> groups, {
    required Set<String> pinnedIds,
  }) {
    final sorted = groups.toList();
    sorted.sort((a, b) {
      final pinCompare = _comparePinned(a.id, b.id, pinnedIds);
      if (pinCompare != 0) return pinCompare;
      return a.createdAt.compareTo(b.createdAt);
    });
    return sorted;
  }

  static int _comparePinned(String aId, String bId, Set<String> pinnedIds) {
    final aPinned = pinnedIds.contains(aId);
    final bPinned = pinnedIds.contains(bId);
    if (aPinned == bPinned) return 0;
    return aPinned ? -1 : 1;
  }
}
