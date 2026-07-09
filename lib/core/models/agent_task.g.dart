// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'agent_task.dart';

// **************************************************************************
// TypeAdapterGenerator
// **************************************************************************

class AgentTaskAdapter extends TypeAdapter<AgentTask> {
  @override
  final int typeId = 13;

  @override
  AgentTask read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return AgentTask(
      id: fields[0] as String?,
      groupId: fields[1] as String,
      characterId: fields[2] as String,
      userRequest: fields[3] as String,
      status: fields[4] as AgentTaskStatus,
      requestedPermissions: (fields[5] as List?)?.cast<ToolPermission>(),
      plan: fields[6] as String,
      resultSummary: fields[7] as String,
      createdAt: fields[8] as DateTime?,
    );
  }

  @override
  void write(BinaryWriter writer, AgentTask obj) {
    writer
      ..writeByte(9)
      ..writeByte(0)
      ..write(obj.id)
      ..writeByte(1)
      ..write(obj.groupId)
      ..writeByte(2)
      ..write(obj.characterId)
      ..writeByte(3)
      ..write(obj.userRequest)
      ..writeByte(4)
      ..write(obj.status)
      ..writeByte(5)
      ..write(obj.requestedPermissions)
      ..writeByte(6)
      ..write(obj.plan)
      ..writeByte(7)
      ..write(obj.resultSummary)
      ..writeByte(8)
      ..write(obj.createdAt);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AgentTaskAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}

class AgentTaskStatusAdapter extends TypeAdapter<AgentTaskStatus> {
  @override
  final int typeId = 12;

  @override
  AgentTaskStatus read(BinaryReader reader) {
    switch (reader.readByte()) {
      case 0:
        return AgentTaskStatus.planning;
      case 1:
        return AgentTaskStatus.waitingForApproval;
      case 2:
        return AgentTaskStatus.runningTool;
      case 3:
        return AgentTaskStatus.completed;
      case 4:
        return AgentTaskStatus.failed;
      case 5:
        return AgentTaskStatus.cancelled;
      default:
        return AgentTaskStatus.planning;
    }
  }

  @override
  void write(BinaryWriter writer, AgentTaskStatus obj) {
    switch (obj) {
      case AgentTaskStatus.planning:
        writer.writeByte(0);
        break;
      case AgentTaskStatus.waitingForApproval:
        writer.writeByte(1);
        break;
      case AgentTaskStatus.runningTool:
        writer.writeByte(2);
        break;
      case AgentTaskStatus.completed:
        writer.writeByte(3);
        break;
      case AgentTaskStatus.failed:
        writer.writeByte(4);
        break;
      case AgentTaskStatus.cancelled:
        writer.writeByte(5);
        break;
    }
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AgentTaskStatusAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
