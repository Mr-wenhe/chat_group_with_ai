import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/chat_group.dart';
import 'package:lpinyin/lpinyin.dart';

class PinnedOrdering {
  static List<AICharacter> sortCharacters(
    Iterable<AICharacter> characters, {
    required Set<String> pinnedIds,
  }) {
    final sorted = characters.toList();
    sorted.sort((a, b) {
      final pinCompare = _comparePinned(a.id, b.id, pinnedIds);
      if (pinCompare != 0) return pinCompare;
      final nameCompare = _characterSortKey(a.name).compareTo(
        _characterSortKey(b.name),
      );
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

  static String _characterSortKey(String name) {
    final normalized = name.trim().toLowerCase();
    if (normalized.isEmpty) return normalized;
    try {
      return PinyinHelper.getPinyinE(
        normalized,
        separator: '',
        format: PinyinFormat.WITHOUT_TONE,
      ).toLowerCase();
    } on PinyinException {
      return normalized;
    }
  }
}
