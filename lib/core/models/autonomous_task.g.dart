// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'autonomous_task.dart';

// **************************************************************************
// TypeAdapterGenerator
// **************************************************************************

class AutonomousTaskAdapter extends TypeAdapter<AutonomousTask> {
  @override
  final int typeId = 17;

  @override
  AutonomousTask read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return AutonomousTask(
      id: fields[0] as String?,
      conversationId: fields[1] as String,
      conversationType: fields[2] as String,
      userGoal: fields[3] as String,
      taskType: fields[4] as String,
      workDirPath: fields[5] as String,
      targetProjectPath: fields[6] as String?,
      status: fields[7] as AutonomousTaskStatus,
      phase: fields[8] as AutonomousTaskPhase,
      participantCharacterIds: (fields[9] as List?)?.cast<String>(),
      plannerCharacterId: fields[10] as String?,
      executorCharacterId: fields[11] as String?,
      verifierCharacterId: fields[12] as String?,
      repeatedBlockCount: fields[13] as int,
      lastBlockSignature: fields[14] as String,
      resultSummary: fields[15] as String,
      createdAt: fields[16] as DateTime?,
      updatedAt: fields[17] as DateTime?,
    );
  }

  @override
  void write(BinaryWriter writer, AutonomousTask obj) {
    writer
      ..writeByte(18)
      ..writeByte(0)
      ..write(obj.id)
      ..writeByte(1)
      ..write(obj.conversationId)
      ..writeByte(2)
      ..write(obj.conversationType)
      ..writeByte(3)
      ..write(obj.userGoal)
      ..writeByte(4)
      ..write(obj.taskType)
      ..writeByte(5)
      ..write(obj.workDirPath)
      ..writeByte(6)
      ..write(obj.targetProjectPath)
      ..writeByte(7)
      ..write(obj.status)
      ..writeByte(8)
      ..write(obj.phase)
      ..writeByte(9)
      ..write(obj.participantCharacterIds)
      ..writeByte(10)
      ..write(obj.plannerCharacterId)
      ..writeByte(11)
      ..write(obj.executorCharacterId)
      ..writeByte(12)
      ..write(obj.verifierCharacterId)
      ..writeByte(13)
      ..write(obj.repeatedBlockCount)
      ..writeByte(14)
      ..write(obj.lastBlockSignature)
      ..writeByte(15)
      ..write(obj.resultSummary)
      ..writeByte(16)
      ..write(obj.createdAt)
      ..writeByte(17)
      ..write(obj.updatedAt);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AutonomousTaskAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}

class AutonomousTaskStepAdapter extends TypeAdapter<AutonomousTaskStep> {
  @override
  final int typeId = 18;

  @override
  AutonomousTaskStep read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return AutonomousTaskStep(
      id: fields[0] as String?,
      taskId: fields[1] as String,
      characterId: fields[2] as String,
      role: fields[3] as String,
      action: fields[4] as String,
      toolName: fields[5] as String,
      inputSummary: fields[6] as String,
      outputSummary: fields[7] as String,
      changedPaths: (fields[8] as List?)?.cast<String>(),
      artifactPaths: (fields[9] as List?)?.cast<String>(),
      commandExitCode: fields[10] as int?,
      createdAt: fields[11] as DateTime?,
    );
  }

  @override
  void write(BinaryWriter writer, AutonomousTaskStep obj) {
    writer
      ..writeByte(12)
      ..writeByte(0)
      ..write(obj.id)
      ..writeByte(1)
      ..write(obj.taskId)
      ..writeByte(2)
      ..write(obj.characterId)
      ..writeByte(3)
      ..write(obj.role)
      ..writeByte(4)
      ..write(obj.action)
      ..writeByte(5)
      ..write(obj.toolName)
      ..writeByte(6)
      ..write(obj.inputSummary)
      ..writeByte(7)
      ..write(obj.outputSummary)
      ..writeByte(8)
      ..write(obj.changedPaths)
      ..writeByte(9)
      ..write(obj.artifactPaths)
      ..writeByte(10)
      ..write(obj.commandExitCode)
      ..writeByte(11)
      ..write(obj.createdAt);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AutonomousTaskStepAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}

class AutonomousTaskStatusAdapter extends TypeAdapter<AutonomousTaskStatus> {
  @override
  final int typeId = 14;

  @override
  AutonomousTaskStatus read(BinaryReader reader) {
    switch (reader.readByte()) {
      case 0:
        return AutonomousTaskStatus.planning;
      case 1:
        return AutonomousTaskStatus.running;
      case 2:
        return AutonomousTaskStatus.verifying;
      case 3:
        return AutonomousTaskStatus.fixing;
      case 4:
        return AutonomousTaskStatus.productReview;
      case 5:
        return AutonomousTaskStatus.completed;
      case 6:
        return AutonomousTaskStatus.blocked;
      case 7:
        return AutonomousTaskStatus.paused;
      case 8:
        return AutonomousTaskStatus.cancelled;
      case 9:
        return AutonomousTaskStatus.failed;
      default:
        return AutonomousTaskStatus.planning;
    }
  }

  @override
  void write(BinaryWriter writer, AutonomousTaskStatus obj) {
    switch (obj) {
      case AutonomousTaskStatus.planning:
        writer.writeByte(0);
        break;
      case AutonomousTaskStatus.running:
        writer.writeByte(1);
        break;
      case AutonomousTaskStatus.verifying:
        writer.writeByte(2);
        break;
      case AutonomousTaskStatus.fixing:
        writer.writeByte(3);
        break;
      case AutonomousTaskStatus.productReview:
        writer.writeByte(4);
        break;
      case AutonomousTaskStatus.completed:
        writer.writeByte(5);
        break;
      case AutonomousTaskStatus.blocked:
        writer.writeByte(6);
        break;
      case AutonomousTaskStatus.paused:
        writer.writeByte(7);
        break;
      case AutonomousTaskStatus.cancelled:
        writer.writeByte(8);
        break;
      case AutonomousTaskStatus.failed:
        writer.writeByte(9);
        break;
    }
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AutonomousTaskStatusAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}

class AutonomousTaskPhaseAdapter extends TypeAdapter<AutonomousTaskPhase> {
  @override
  final int typeId = 15;

  @override
  AutonomousTaskPhase read(BinaryReader reader) {
    switch (reader.readByte()) {
      case 0:
        return AutonomousTaskPhase.intake;
      case 1:
        return AutonomousTaskPhase.requirements;
      case 2:
        return AutonomousTaskPhase.execution;
      case 3:
        return AutonomousTaskPhase.verification;
      case 4:
        return AutonomousTaskPhase.bugfix;
      case 5:
        return AutonomousTaskPhase.productConfirmation;
      case 6:
        return AutonomousTaskPhase.handoff;
      default:
        return AutonomousTaskPhase.intake;
    }
  }

  @override
  void write(BinaryWriter writer, AutonomousTaskPhase obj) {
    switch (obj) {
      case AutonomousTaskPhase.intake:
        writer.writeByte(0);
        break;
      case AutonomousTaskPhase.requirements:
        writer.writeByte(1);
        break;
      case AutonomousTaskPhase.execution:
        writer.writeByte(2);
        break;
      case AutonomousTaskPhase.verification:
        writer.writeByte(3);
        break;
      case AutonomousTaskPhase.bugfix:
        writer.writeByte(4);
        break;
      case AutonomousTaskPhase.productConfirmation:
        writer.writeByte(5);
        break;
      case AutonomousTaskPhase.handoff:
        writer.writeByte(6);
        break;
    }
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AutonomousTaskPhaseAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
