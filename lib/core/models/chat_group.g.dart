// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'chat_group.dart';

// **************************************************************************
// TypeAdapterGenerator
// **************************************************************************

class ChatGroupAdapter extends TypeAdapter<ChatGroup> {
  @override
  final int typeId = 1;

  @override
  ChatGroup read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return ChatGroup(
      id: fields[0] as String?,
      name: fields[1] as String,
      theme: fields[2] as String,
      description: fields[3] as String,
      aiCharacterIds: (fields[4] as List).cast<String>(),
      createdAt: fields[5] as DateTime?,
      ownerName: fields[6] as String?,
      announcement: fields[7] as String?,
      replyIntervalSeconds: fields[8] as int?,
      hostUserId: fields[9] as String?,
      roomId: fields[10] as String?,
      inviteCode: fields[11] as String?,
      humanMemberNames: fields[12] == null
          ? {}
          : (fields[12] as Map?)?.cast<String, String>(),
    );
  }

  @override
  void write(BinaryWriter writer, ChatGroup obj) {
    writer
      ..writeByte(13)
      ..writeByte(0)
      ..write(obj.id)
      ..writeByte(1)
      ..write(obj.name)
      ..writeByte(2)
      ..write(obj.theme)
      ..writeByte(3)
      ..write(obj.description)
      ..writeByte(4)
      ..write(obj.aiCharacterIds)
      ..writeByte(5)
      ..write(obj.createdAt)
      ..writeByte(6)
      ..write(obj.ownerName)
      ..writeByte(7)
      ..write(obj.announcement)
      ..writeByte(8)
      ..write(obj.replyIntervalSeconds)
      ..writeByte(9)
      ..write(obj.hostUserId)
      ..writeByte(10)
      ..write(obj.roomId)
      ..writeByte(11)
      ..write(obj.inviteCode)
      ..writeByte(12)
      ..write(obj.humanMemberNames);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ChatGroupAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
