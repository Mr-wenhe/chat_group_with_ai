// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'work_mode_workspace.dart';

// **************************************************************************
// TypeAdapterGenerator
// **************************************************************************

class WorkModeWorkspaceAdapter extends TypeAdapter<WorkModeWorkspace> {
  @override
  final int typeId = 16;

  @override
  WorkModeWorkspace read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return WorkModeWorkspace(
      id: fields[0] as String?,
      conversationId: fields[1] as String,
      conversationType: fields[2] as String,
      workDirPath: fields[3] as String,
      updatedAt: fields[4] as DateTime?,
    );
  }

  @override
  void write(BinaryWriter writer, WorkModeWorkspace obj) {
    writer
      ..writeByte(5)
      ..writeByte(0)
      ..write(obj.id)
      ..writeByte(1)
      ..write(obj.conversationId)
      ..writeByte(2)
      ..write(obj.conversationType)
      ..writeByte(3)
      ..write(obj.workDirPath)
      ..writeByte(4)
      ..write(obj.updatedAt);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is WorkModeWorkspaceAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
