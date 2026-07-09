import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/models/ai_character.dart';
import '../../../providers/providers.dart';

final aiCharactersProvider =
    StateNotifierProvider<AICharactersNotifier, List<AICharacter>>((ref) {
  return AICharactersNotifier(ref.read(databaseServiceProvider));
});

class AICharactersNotifier extends StateNotifier<List<AICharacter>> {
  final DatabaseService _db;

  AICharactersNotifier(this._db) : super([]) {
    _loadCharacters();
  }

  void _loadCharacters() {
    state = _db.aiCharacterBox.values.toList()
      ..sort((a, b) => a.name.compareTo(b.name));
  }

  Future<void> addCharacter(AICharacter character) async {
    await _db.aiCharacterBox.put(character.id, character);
    _loadCharacters();
  }

  Future<void> updateCharacter(AICharacter character) async {
    await _db.aiCharacterBox.put(character.id, character);
    _loadCharacters();
  }

  Future<void> deleteCharacter(String id) async {
    await _db.aiCharacterBox.delete(id);
    _loadCharacters();
  }

  AICharacter? getCharacterById(String id) {
    try {
      return _db.aiCharacterBox.get(id);
    } catch (e) {
      return null;
    }
  }
}
