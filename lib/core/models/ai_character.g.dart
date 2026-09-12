// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'ai_character.dart';

// **************************************************************************
// TypeAdapterGenerator
// **************************************************************************

class AICharacterAdapter extends TypeAdapter<AICharacter> {
  @override
  final int typeId = 0;

  @override
  AICharacter read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return AICharacter(
      id: fields[0] as String?,
      name: fields[1] as String,
      avatar: fields[2] as String,
      age: fields[3] as int,
      role: fields[4] as String,
      personalityTags: (fields[5] as List).cast<String>(),
      systemPrompt: fields[6] as String,
      memorySummary: fields[7] as String,
      apiKey: fields[8] as String,
      apiProvider: fields[9] as String,
      modelName: fields[10] as String?,
      customBaseUrl: fields[11] as String,
      hourlyReplyLimit: fields[12] as int,
      hourlyReplyCount: fields[13] as int,
      lastReplyTimestamp: fields[14] as DateTime?,
      isActive: fields[15] as bool,
      createdAt: fields[16] as DateTime?,
      apiConfigId: fields[17] as String?,
      agenticEnabled: fields[18] == null ? true : fields[18] as bool,
      skillIds: fields[19] == null ? [] : (fields[19] as List?)?.cast<String>(),
      toolPermissions: fields[20] == null
          ? [ToolPermission.skillCreate, ToolPermission.skillDownload]
          : (fields[20] as List?)?.cast<ToolPermission>(),
      gender: fields[21] == null
          ? CharacterGender.female
          : fields[21] as CharacterGender,
      hasKnownGender: fields[22] == null ? false : fields[22] as bool,
      voiceId: fields[23] == null ? '' : fields[23] as String,
      webSearchEnabled: fields[24] == null ? false : fields[24] as bool,
      proactiveChatEnabled: fields[25] == null ? true : fields[25] as bool,
    );
  }

  @override
  void write(BinaryWriter writer, AICharacter obj) {
    writer
      ..writeByte(26)
      ..writeByte(0)
      ..write(obj.id)
      ..writeByte(1)
      ..write(obj.name)
      ..writeByte(2)
      ..write(obj.avatar)
      ..writeByte(3)
      ..write(obj.age)
      ..writeByte(4)
      ..write(obj.role)
      ..writeByte(5)
      ..write(obj.personalityTags)
      ..writeByte(6)
      ..write(obj.systemPrompt)
      ..writeByte(7)
      ..write(obj.memorySummary)
      ..writeByte(8)
      ..write(obj.apiKey)
      ..writeByte(9)
      ..write(obj.apiProvider)
      ..writeByte(10)
      ..write(obj.modelName)
      ..writeByte(11)
      ..write(obj.customBaseUrl)
      ..writeByte(12)
      ..write(obj.hourlyReplyLimit)
      ..writeByte(13)
      ..write(obj.hourlyReplyCount)
      ..writeByte(14)
      ..write(obj.lastReplyTimestamp)
      ..writeByte(15)
      ..write(obj.isActive)
      ..writeByte(16)
      ..write(obj.createdAt)
      ..writeByte(17)
      ..write(obj.apiConfigId)
      ..writeByte(18)
      ..write(obj.agenticEnabled)
      ..writeByte(19)
      ..write(obj.skillIds)
      ..writeByte(20)
      ..write(obj.toolPermissions)
      ..writeByte(21)
      ..write(obj.gender)
      ..writeByte(22)
      ..write(obj.hasKnownGender)
      ..writeByte(23)
      ..write(obj.voiceId)
      ..writeByte(24)
      ..write(obj.webSearchEnabled)
      ..writeByte(25)
      ..write(obj.proactiveChatEnabled);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AICharacterAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}

class CharacterGenderAdapter extends TypeAdapter<CharacterGender> {
  @override
  final int typeId = 24;

  @override
  CharacterGender read(BinaryReader reader) {
    switch (reader.readByte()) {
      case 0:
        return CharacterGender.male;
      case 1:
        return CharacterGender.female;
      default:
        return CharacterGender.male;
    }
  }

  @override
  void write(BinaryWriter writer, CharacterGender obj) {
    switch (obj) {
      case CharacterGender.male:
        writer.writeByte(0);
        break;
      case CharacterGender.female:
        writer.writeByte(1);
        break;
    }
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CharacterGenderAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
