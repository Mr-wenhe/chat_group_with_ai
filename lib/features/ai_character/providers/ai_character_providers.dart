import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/database/data_lifecycle_models.dart';
import 'package:chat_group/core/database/data_lifecycle_service.dart';
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
    final savedCharacter = _db.aiCharacterBox.get(character.id);
    _validateNewCharacterGender(character, savedCharacter);
    if (savedCharacter != null) {
      character = character.withGender(
        savedCharacter.gender,
        hasKnownGender: savedCharacter.hasKnownGender,
      );
    }
    await _db.aiCharacterBox.put(character.id, character);
    _loadCharacters();
  }

  Future<void> updateCharacter(AICharacter character) async {
    final savedCharacter = _db.aiCharacterBox.get(character.id);
    _validateNewCharacterGender(character, savedCharacter);
    if (savedCharacter != null) {
      character = character.withGender(
        savedCharacter.gender,
        hasKnownGender: savedCharacter.hasKnownGender,
      );
    }
    await _db.aiCharacterBox.put(character.id, character);
    _loadCharacters();
  }

  void _validateNewCharacterGender(
    AICharacter character,
    AICharacter? savedCharacter,
  ) {
    if (savedCharacter == null && !character.hasKnownGender) {
      throw ArgumentError('新建角色必须选择性别');
    }
  }

  Future<DataLifecycleResult> deleteCharacter(
    String id, {
    required CharacterDeletionPolicy policy,
  }) async {
    final result = await DataLifecycleService(db: _db).deleteCharacter(
      id,
      policy: policy,
    );
    _loadCharacters();
    return result;
  }

  AICharacter? getCharacterById(String id) {
    try {
      return _db.aiCharacterBox.get(id);
    } catch (e) {
      return null;
    }
  }
}
