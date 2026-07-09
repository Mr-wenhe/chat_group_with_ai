// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'evidence_memory.dart';

// **************************************************************************
// TypeAdapterGenerator
// **************************************************************************

class EvidenceMemoryAdapter extends TypeAdapter<EvidenceMemory> {
  @override
  final int typeId = 20;

  @override
  EvidenceMemory read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return EvidenceMemory(
      id: fields[0] as String?,
      subjectCharacterId: fields[1] as String,
      targetId: fields[2] as String,
      targetType: fields[3] as String,
      type: fields[4] as EvidenceMemoryType,
      content: fields[5] as String,
      evidenceConversationId: fields[6] as String,
      evidenceMessageId: fields[7] as String?,
      evidenceTaskId: fields[8] as String?,
      evidenceTaskStepId: fields[9] as String?,
      evidenceSnippet: fields[10] as String,
      occurredAt: fields[11] as DateTime?,
      createdAt: fields[12] as DateTime?,
      updatedAt: fields[13] as DateTime?,
      confidence: fields[14] as double,
      deleted: fields[15] as bool,
      userCorrected: fields[16] as bool,
    );
  }

  @override
  void write(BinaryWriter writer, EvidenceMemory obj) {
    writer
      ..writeByte(17)
      ..writeByte(0)
      ..write(obj.id)
      ..writeByte(1)
      ..write(obj.subjectCharacterId)
      ..writeByte(2)
      ..write(obj.targetId)
      ..writeByte(3)
      ..write(obj.targetType)
      ..writeByte(4)
      ..write(obj.type)
      ..writeByte(5)
      ..write(obj.content)
      ..writeByte(6)
      ..write(obj.evidenceConversationId)
      ..writeByte(7)
      ..write(obj.evidenceMessageId)
      ..writeByte(8)
      ..write(obj.evidenceTaskId)
      ..writeByte(9)
      ..write(obj.evidenceTaskStepId)
      ..writeByte(10)
      ..write(obj.evidenceSnippet)
      ..writeByte(11)
      ..write(obj.occurredAt)
      ..writeByte(12)
      ..write(obj.createdAt)
      ..writeByte(13)
      ..write(obj.updatedAt)
      ..writeByte(14)
      ..write(obj.confidence)
      ..writeByte(15)
      ..write(obj.deleted)
      ..writeByte(16)
      ..write(obj.userCorrected);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is EvidenceMemoryAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}

class EvidenceMemoryTypeAdapter extends TypeAdapter<EvidenceMemoryType> {
  @override
  final int typeId = 19;

  @override
  EvidenceMemoryType read(BinaryReader reader) {
    switch (reader.readByte()) {
      case 0:
        return EvidenceMemoryType.selfFact;
      case 1:
        return EvidenceMemoryType.userFact;
      case 2:
        return EvidenceMemoryType.relationship;
      case 3:
        return EvidenceMemoryType.taskFact;
      case 4:
        return EvidenceMemoryType.correction;
      default:
        return EvidenceMemoryType.selfFact;
    }
  }

  @override
  void write(BinaryWriter writer, EvidenceMemoryType obj) {
    switch (obj) {
      case EvidenceMemoryType.selfFact:
        writer.writeByte(0);
        break;
      case EvidenceMemoryType.userFact:
        writer.writeByte(1);
        break;
      case EvidenceMemoryType.relationship:
        writer.writeByte(2);
        break;
      case EvidenceMemoryType.taskFact:
        writer.writeByte(3);
        break;
      case EvidenceMemoryType.correction:
        writer.writeByte(4);
        break;
    }
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is EvidenceMemoryTypeAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
