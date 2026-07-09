// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'character_skill.dart';

// **************************************************************************
// TypeAdapterGenerator
// **************************************************************************

class CharacterSkillAdapter extends TypeAdapter<CharacterSkill> {
  @override
  final int typeId = 11;

  @override
  CharacterSkill read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return CharacterSkill(
      id: fields[0] as String?,
      characterId: fields[1] as String,
      name: fields[2] as String,
      domain: fields[3] as String,
      description: fields[4] as String,
      instructions: (fields[5] as List).cast<String>(),
      requiredPermissions: (fields[6] as List).cast<ToolPermission>(),
      createdAt: fields[7] as DateTime?,
      updatedAt: fields[8] as DateTime?,
    );
  }

  @override
  void write(BinaryWriter writer, CharacterSkill obj) {
    writer
      ..writeByte(9)
      ..writeByte(0)
      ..write(obj.id)
      ..writeByte(1)
      ..write(obj.characterId)
      ..writeByte(2)
      ..write(obj.name)
      ..writeByte(3)
      ..write(obj.domain)
      ..writeByte(4)
      ..write(obj.description)
      ..writeByte(5)
      ..write(obj.instructions)
      ..writeByte(6)
      ..write(obj.requiredPermissions)
      ..writeByte(7)
      ..write(obj.createdAt)
      ..writeByte(8)
      ..write(obj.updatedAt);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CharacterSkillAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
