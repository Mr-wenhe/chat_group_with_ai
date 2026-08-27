// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'message.dart';

// **************************************************************************
// TypeAdapterGenerator
// **************************************************************************

class MessageAdapter extends TypeAdapter<Message> {
  @override
  final int typeId = 2;

  @override
  Message read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return Message(
      id: fields[0] as String?,
      groupId: fields[1] as String,
      senderId: fields[2] as String,
      senderType: fields[3] as String,
      content: fields[4] as String,
      timestamp: fields[5] as DateTime?,
      replyToMessageId: fields[6] as String?,
      isMention: fields[7] as bool,
      mentionedAiIds: (fields[8] as List?)?.cast<String>(),
      media: (fields[9] as List?)?.cast<MediaAttachment>(),
      visibleToCharacterIds:
          fields[10] == null ? [] : (fields[10] as List?)?.cast<String>(),
      webSearchSnapshot: (fields[11] as Map?)?.cast<dynamic, dynamic>(),
    );
  }

  @override
  void write(BinaryWriter writer, Message obj) {
    writer
      ..writeByte(12)
      ..writeByte(0)
      ..write(obj.id)
      ..writeByte(1)
      ..write(obj.groupId)
      ..writeByte(2)
      ..write(obj.senderId)
      ..writeByte(3)
      ..write(obj.senderType)
      ..writeByte(4)
      ..write(obj.content)
      ..writeByte(5)
      ..write(obj.timestamp)
      ..writeByte(6)
      ..write(obj.replyToMessageId)
      ..writeByte(7)
      ..write(obj.isMention)
      ..writeByte(8)
      ..write(obj.mentionedAiIds)
      ..writeByte(9)
      ..write(obj.media)
      ..writeByte(10)
      ..write(obj.visibleToCharacterIds)
      ..writeByte(11)
      ..write(obj.webSearchSnapshot);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is MessageAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
