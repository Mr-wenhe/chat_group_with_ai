import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/character_memory.dart';

class HumanizedMemoryService {
  static CharacterMemory memoryForCharacter({
    required String groupId,
    required AICharacter character,
    required List<CharacterMemory> existing,
  }) {
    for (final memory in existing) {
      if (memory.groupId == groupId && memory.characterId == character.id) {
        return memory;
      }
    }

    final legacy = character.memorySummary.trim();
    return CharacterMemory(
      groupId: groupId,
      characterId: character.id,
      personaGrowth: legacy.isEmpty ? const [] : [legacy],
    );
  }
}
