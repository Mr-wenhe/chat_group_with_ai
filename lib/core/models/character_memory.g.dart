// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'character_memory.dart';

// **************************************************************************
// TypeAdapterGenerator
// **************************************************************************

class CharacterMemoryAdapter extends TypeAdapter<CharacterMemory> {
  @override
  final int typeId = 5;

  @override
  CharacterMemory read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return CharacterMemory(
      id: fields[0] as String?,
      groupId: fields[1] as String,
      characterId: fields[2] as String,
      facts: (fields[3] as List?)?.cast<String>(),
      relationshipNotes: (fields[4] as List?)?.cast<String>(),
      personaGrowth: (fields[5] as List?)?.cast<String>(),
      lastUpdatedAt: fields[6] as DateTime?,
      createdAt: fields[7] as DateTime?,
    );
  }

  @override
  void write(BinaryWriter writer, CharacterMemory obj) {
    writer
      ..writeByte(8)
      ..writeByte(0)
      ..write(obj.id)
      ..writeByte(1)
      ..write(obj.groupId)
      ..writeByte(2)
      ..write(obj.characterId)
      ..writeByte(3)
      ..write(obj.facts)
      ..writeByte(4)
      ..write(obj.relationshipNotes)
      ..writeByte(5)
      ..write(obj.personaGrowth)
      ..writeByte(6)
      ..write(obj.lastUpdatedAt)
      ..writeByte(7)
      ..write(obj.createdAt);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CharacterMemoryAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
