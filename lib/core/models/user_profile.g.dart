// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'user_profile.dart';

// **************************************************************************
// TypeAdapterGenerator
// **************************************************************************

class UserProfileAdapter extends TypeAdapter<UserProfile> {
  @override
  final int typeId = 22;

  @override
  UserProfile read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return UserProfile(
      id: fields[0] as String?,
      displayName: fields[1] as String,
      preferredAddress: fields[2] as String,
      avatar: fields[3] as String,
      pronouns: fields[4] as String,
      age: fields[5] as int?,
      bio: fields[6] as String,
      personality: (fields[7] as List?)?.cast<String>(),
      interests: (fields[8] as List?)?.cast<String>(),
      importantBackground: (fields[9] as List?)?.cast<String>(),
      updatedAt: fields[10] as DateTime?,
      createdAt: fields[11] as DateTime?,
      gender: fields[12] as CharacterGender?,
      ipImageRelPath: fields[13] == null ? '' : fields[13] as String,
      avatarFromIpImage: fields[14] == null ? false : fields[14] as bool,
      ipImageStyle: fields[15] == null ? '' : fields[15] as String,
      apiConfigId: fields[16] == null ? '' : fields[16] as String,
    );
  }

  @override
  void write(BinaryWriter writer, UserProfile obj) {
    writer
      ..writeByte(17)
      ..writeByte(0)
      ..write(obj.id)
      ..writeByte(1)
      ..write(obj.displayName)
      ..writeByte(2)
      ..write(obj.preferredAddress)
      ..writeByte(3)
      ..write(obj.avatar)
      ..writeByte(4)
      ..write(obj.pronouns)
      ..writeByte(5)
      ..write(obj.age)
      ..writeByte(6)
      ..write(obj.bio)
      ..writeByte(7)
      ..write(obj.personality)
      ..writeByte(8)
      ..write(obj.interests)
      ..writeByte(9)
      ..write(obj.importantBackground)
      ..writeByte(10)
      ..write(obj.updatedAt)
      ..writeByte(11)
      ..write(obj.createdAt)
      ..writeByte(12)
      ..write(obj.gender)
      ..writeByte(13)
      ..write(obj.ipImageRelPath)
      ..writeByte(14)
      ..write(obj.avatarFromIpImage)
      ..writeByte(15)
      ..write(obj.ipImageStyle)
      ..writeByte(16)
      ..write(obj.apiConfigId);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is UserProfileAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
