import 'package:chat_group/core/models/ai_character.dart';

/// Durable progress for the one-shot legacy gender migration.
class CharacterGenderMigrationState {
  final Set<String> candidateIds;
  final Set<String> completedIds;
  final Map<String, CharacterGender> decisions;

  CharacterGenderMigrationState({
    required Set<String> candidateIds,
    Set<String>? completedIds,
    Map<String, CharacterGender>? decisions,
  })  : candidateIds = {...candidateIds},
        completedIds = {...?completedIds},
        decisions = {...?decisions};

  factory CharacterGenderMigrationState.fromMap(Map<dynamic, dynamic> map) {
    final state = tryFromMap(map);
    if (state == null) {
      throw const FormatException('Invalid character gender migration state');
    }
    return state;
  }

  /// Returns null instead of accepting partial state that could skip a
  /// character forever.
  static CharacterGenderMigrationState? tryFromMap(
    Map<dynamic, dynamic> map,
  ) {
    final candidateIds = _stringSet(map['candidateIds']);
    final completedIds = _stringSet(map['completedIds']);
    final decisions = _genderMap(map['decisions']);
    if (candidateIds == null ||
        candidateIds.isEmpty ||
        completedIds == null ||
        decisions == null) {
      return null;
    }
    if (!completedIds.every(candidateIds.contains) ||
        !decisions.keys.every(candidateIds.contains) ||
        completedIds.any(decisions.containsKey)) {
      return null;
    }
    return CharacterGenderMigrationState(
      candidateIds: candidateIds,
      completedIds: completedIds,
      decisions: decisions,
    );
  }

  static Map<String, CharacterGender>? _genderMap(Object? value) {
    if (value is! Map) return null;
    final decisions = <String, CharacterGender>{};
    for (final entry in value.entries) {
      if (entry.key is! String || (entry.key as String).isEmpty) {
        return null;
      }
      final gender = _genderFromStateValue(entry.value);
      if (gender == null) return null;
      decisions[entry.key as String] = gender;
    }
    return decisions;
  }

  Map<String, dynamic> toMap() => {
        'candidateIds': candidateIds.toList()..sort(),
        'completedIds': completedIds.toList()..sort(),
        'decisions': {
          for (final entry in decisions.entries) entry.key: entry.value.name,
        },
      };

  static Set<String>? _stringSet(Object? value) {
    if (value is! Iterable) return null;
    final values = <String>{};
    for (final item in value) {
      if (item is! String || item.isEmpty) return null;
      values.add(item);
    }
    return values;
  }

  static CharacterGender? _genderFromStateValue(Object? value) {
    return switch (value?.toString()) {
      'male' || '男' => CharacterGender.male,
      'female' || '女' => CharacterGender.female,
      _ => null,
    };
  }
}
