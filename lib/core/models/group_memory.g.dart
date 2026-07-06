// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'group_memory.dart';

// **************************************************************************
// TypeAdapterGenerator
// **************************************************************************

class GroupMemoryAdapter extends TypeAdapter<GroupMemory> {
  @override
  final int typeId = 3;

  @override
  GroupMemory read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return GroupMemory(
      groupId: fields[0] as String,
      topicSummary: fields[1] as String,
      lastSummaryAt: fields[2] as DateTime?,
    );
  }

  @override
  void write(BinaryWriter writer, GroupMemory obj) {
    writer
      ..writeByte(3)
      ..writeByte(0)
      ..write(obj.groupId)
      ..writeByte(1)
      ..write(obj.topicSummary)
      ..writeByte(2)
      ..write(obj.lastSummaryAt);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is GroupMemoryAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
