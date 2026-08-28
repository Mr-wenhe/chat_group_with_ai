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
      currentStep: fields[9] == null ? 0 : fields[9] as int,
      completedOperations:
          fields[10] == null ? [] : (fields[10] as List?)?.cast<String>(),
      pendingToolRequestJson: fields[11] == null ? '' : fields[11] as String,
      updatedAt: fields[12] as DateTime?,
      lastError: fields[13] == null ? '' : fields[13] as String,
      workModeTask: fields[14] == null ? false : fields[14] as bool,
      queuedUserRequests:
          fields[15] == null ? [] : (fields[15] as List?)?.cast<String>(),
      contextSummary: fields[16] == null ? '' : fields[16] as String,
      assignedCharacterIds:
          fields[17] == null ? [] : (fields[17] as List?)?.cast<String>(),
      startedAt: fields[18] as DateTime?,
      actionCount: fields[19] == null ? 0 : fields[19] as int,
      softLimitReached: fields[20] == null ? false : fields[20] as bool,
      resumeRequired: fields[21] == null ? false : fields[21] as bool,
      executionStateJson: fields[22] == null ? '' : fields[22] as String,
      lastArtifactPaths:
          fields[23] == null ? [] : (fields[23] as List?)?.cast<String>(),
      actionLimit: fields[24] == null ? 100 : fields[24] as int,
      softTimeLimitMinutes: fields[25] == null ? 60 : fields[25] as int,
      eventLogIncomplete: fields[26] == null ? false : fields[26] as bool,
    );
  }

  @override
  void write(BinaryWriter writer, AgentTask obj) {
    writer
      ..writeByte(27)
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
      ..write(obj.createdAt)
      ..writeByte(9)
      ..write(obj.currentStep)
      ..writeByte(10)
      ..write(obj.completedOperations)
      ..writeByte(11)
      ..write(obj.pendingToolRequestJson)
      ..writeByte(12)
      ..write(obj.updatedAt)
      ..writeByte(13)
      ..write(obj.lastError)
      ..writeByte(14)
      ..write(obj.workModeTask)
      ..writeByte(15)
      ..write(obj.queuedUserRequests)
      ..writeByte(16)
      ..write(obj.contextSummary)
      ..writeByte(17)
      ..write(obj.assignedCharacterIds)
      ..writeByte(18)
      ..write(obj.startedAt)
      ..writeByte(19)
      ..write(obj.actionCount)
      ..writeByte(20)
      ..write(obj.softLimitReached)
      ..writeByte(21)
      ..write(obj.resumeRequired)
      ..writeByte(22)
      ..write(obj.executionStateJson)
      ..writeByte(23)
      ..write(obj.lastArtifactPaths)
      ..writeByte(24)
      ..write(obj.actionLimit)
      ..writeByte(25)
      ..write(obj.softTimeLimitMinutes)
      ..writeByte(26)
      ..write(obj.eventLogIncomplete);
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
      case 6:
        return AgentTaskStatus.partiallyCompleted;
      case 7:
        return AgentTaskStatus.queued;
      case 8:
        return AgentTaskStatus.paused;
      case 9:
        return AgentTaskStatus.interrupted;
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
      case AgentTaskStatus.partiallyCompleted:
        writer.writeByte(6);
        break;
      case AgentTaskStatus.queued:
        writer.writeByte(7);
        break;
      case AgentTaskStatus.paused:
        writer.writeByte(8);
        break;
      case AgentTaskStatus.interrupted:
        writer.writeByte(9);
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
