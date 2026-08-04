// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'permanent_memory.dart';

// **************************************************************************
// TypeAdapterGenerator
// **************************************************************************

class PermanentMemoryAdapter extends TypeAdapter<PermanentMemory> {
  @override
  final int typeId = 19;

  @override
  PermanentMemory read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return PermanentMemory(
      id: fields[0] as String?,
      observerCharacterId: fields[1] as String,
      kind: fields[2] as MemoryKind,
      content: fields[3] as String,
      subjectIds: (fields[4] as List?)?.cast<String>(),
      status: fields[5] as MemoryStatus,
      importance: fields[6] as int,
      confidence: fields[7] as double,
      explicitlyRequested: fields[8] as bool,
      pinned: fields[9] as bool,
      supersedesIds: (fields[10] as List?)?.cast<String>(),
      originType: fields[11] as MemoryOriginType,
      originConversationId: fields[12] as String?,
      originNameSnapshot: fields[13] as String,
      sourceMessageIds: (fields[14] as List?)?.cast<String>(),
      participantIds: (fields[15] as List?)?.cast<String>(),
      occurredAt: fields[16] as DateTime?,
      createdAt: fields[17] as DateTime?,
      updatedAt: fields[18] as DateTime?,
    );
  }

  @override
  void write(BinaryWriter writer, PermanentMemory obj) {
    writer
      ..writeByte(19)
      ..writeByte(0)
      ..write(obj.id)
      ..writeByte(1)
      ..write(obj.observerCharacterId)
      ..writeByte(2)
      ..write(obj.kind)
      ..writeByte(3)
      ..write(obj.content)
      ..writeByte(4)
      ..write(obj.subjectIds)
      ..writeByte(5)
      ..write(obj.status)
      ..writeByte(6)
      ..write(obj.importance)
      ..writeByte(7)
      ..write(obj.confidence)
      ..writeByte(8)
      ..write(obj.explicitlyRequested)
      ..writeByte(9)
      ..write(obj.pinned)
      ..writeByte(10)
      ..write(obj.supersedesIds)
      ..writeByte(11)
      ..write(obj.originType)
      ..writeByte(12)
      ..write(obj.originConversationId)
      ..writeByte(13)
      ..write(obj.originNameSnapshot)
      ..writeByte(14)
      ..write(obj.sourceMessageIds)
      ..writeByte(15)
      ..write(obj.participantIds)
      ..writeByte(16)
      ..write(obj.occurredAt)
      ..writeByte(17)
      ..write(obj.createdAt)
      ..writeByte(18)
      ..write(obj.updatedAt);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PermanentMemoryAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}

class MemoryKindAdapter extends TypeAdapter<MemoryKind> {
  @override
  final int typeId = 14;

  @override
  MemoryKind read(BinaryReader reader) {
    switch (reader.readByte()) {
      case 0:
        return MemoryKind.fact;
      case 1:
        return MemoryKind.preference;
      case 2:
        return MemoryKind.commitment;
      case 3:
        return MemoryKind.sharedExperience;
      case 4:
        return MemoryKind.relationshipNote;
      case 5:
        return MemoryKind.personaGrowth;
      case 6:
        return MemoryKind.explicitInstruction;
      default:
        return MemoryKind.fact;
    }
  }

  @override
  void write(BinaryWriter writer, MemoryKind obj) {
    switch (obj) {
      case MemoryKind.fact:
        writer.writeByte(0);
        break;
      case MemoryKind.preference:
        writer.writeByte(1);
        break;
      case MemoryKind.commitment:
        writer.writeByte(2);
        break;
      case MemoryKind.sharedExperience:
        writer.writeByte(3);
        break;
      case MemoryKind.relationshipNote:
        writer.writeByte(4);
        break;
      case MemoryKind.personaGrowth:
        writer.writeByte(5);
        break;
      case MemoryKind.explicitInstruction:
        writer.writeByte(6);
        break;
    }
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is MemoryKindAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}

class MemoryOriginTypeAdapter extends TypeAdapter<MemoryOriginType> {
  @override
  final int typeId = 15;

  @override
  MemoryOriginType read(BinaryReader reader) {
    switch (reader.readByte()) {
      case 0:
        return MemoryOriginType.group;
      case 1:
        return MemoryOriginType.direct;
      case 2:
        return MemoryOriginType.manual;
      case 3:
        return MemoryOriginType.legacyMigration;
      default:
        return MemoryOriginType.group;
    }
  }

  @override
  void write(BinaryWriter writer, MemoryOriginType obj) {
    switch (obj) {
      case MemoryOriginType.group:
        writer.writeByte(0);
        break;
      case MemoryOriginType.direct:
        writer.writeByte(1);
        break;
      case MemoryOriginType.manual:
        writer.writeByte(2);
        break;
      case MemoryOriginType.legacyMigration:
        writer.writeByte(3);
        break;
    }
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is MemoryOriginTypeAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}

class MemoryStatusAdapter extends TypeAdapter<MemoryStatus> {
  @override
  final int typeId = 18;

  @override
  MemoryStatus read(BinaryReader reader) {
    switch (reader.readByte()) {
      case 0:
        return MemoryStatus.active;
      case 1:
        return MemoryStatus.superseded;
      case 2:
        return MemoryStatus.invalidated;
      default:
        return MemoryStatus.active;
    }
  }

  @override
  void write(BinaryWriter writer, MemoryStatus obj) {
    switch (obj) {
      case MemoryStatus.active:
        writer.writeByte(0);
        break;
      case MemoryStatus.superseded:
        writer.writeByte(1);
        break;
      case MemoryStatus.invalidated:
        writer.writeByte(2);
        break;
    }
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is MemoryStatusAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
