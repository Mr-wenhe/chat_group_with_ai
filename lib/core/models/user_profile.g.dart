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
    );
  }

  @override
  void write(BinaryWriter writer, UserProfile obj) {
    writer
      ..writeByte(12)
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
      ..write(obj.createdAt);
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
