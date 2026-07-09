// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'autonomous_conversation_config.dart';

// **************************************************************************
// TypeAdapterGenerator
// **************************************************************************

class AutonomousConversationConfigAdapter
    extends TypeAdapter<AutonomousConversationConfig> {
  @override
  final int typeId = 16;

  @override
  AutonomousConversationConfig read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return AutonomousConversationConfig(
      id: fields[0] as String?,
      conversationId: fields[1] as String,
      conversationType: fields[2] as String,
      enabled: fields[3] as bool,
      workDirPath: fields[4] as String,
      authorizedProjectPath: fields[5] as String?,
      sourceWriteAuthorized: fields[6] as bool,
      authorizedAt: fields[7] as DateTime?,
      updatedAt: fields[8] as DateTime?,
    );
  }

  @override
  void write(BinaryWriter writer, AutonomousConversationConfig obj) {
    writer
      ..writeByte(9)
      ..writeByte(0)
      ..write(obj.id)
      ..writeByte(1)
      ..write(obj.conversationId)
      ..writeByte(2)
      ..write(obj.conversationType)
      ..writeByte(3)
      ..write(obj.enabled)
      ..writeByte(4)
      ..write(obj.workDirPath)
      ..writeByte(5)
      ..write(obj.authorizedProjectPath)
      ..writeByte(6)
      ..write(obj.sourceWriteAuthorized)
      ..writeByte(7)
      ..write(obj.authorizedAt)
      ..writeByte(8)
      ..write(obj.updatedAt);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AutonomousConversationConfigAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
