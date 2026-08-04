// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'relationship_state.dart';

// **************************************************************************
// TypeAdapterGenerator
// **************************************************************************

class RelationshipStateAdapter extends TypeAdapter<RelationshipState> {
  @override
  final int typeId = 8;

  @override
  RelationshipState read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return RelationshipState(
      id: fields[0] as String?,
      groupId: fields[1] as String,
      sourceCharacterId: fields[2] as String,
      targetId: fields[3] as String,
      targetType: fields[4] == null
          ? RelationshipTargetType.ai
          : fields[4] as RelationshipTargetType,
      affinity: fields[5] == null ? 0 : fields[5] as int,
      trust: fields[6] == null ? 0 : fields[6] as int,
      friction: fields[7] == null ? 0 : fields[7] as int,
      familiarity: fields[8] == null ? 0 : fields[8] as int,
      recentMood: fields[9] == null
          ? RelationshipMood.neutral
          : fields[9] as RelationshipMood,
      notes: fields[10] == null ? '' : fields[10] as String,
      lastInteractionAt: fields[11] as DateTime?,
      createdAt: fields[12] as DateTime?,
      stage: fields[13] == null
          ? RelationshipStage.stranger
          : fields[13] as RelationshipStage,
      revision: fields[14] == null ? 0 : fields[14] as int,
      lastEventId: fields[15] as String?,
      updatedAt: fields[16] as DateTime?,
    );
  }

  @override
  void write(BinaryWriter writer, RelationshipState obj) {
    writer
      ..writeByte(17)
      ..writeByte(0)
      ..write(obj.id)
      ..writeByte(1)
      ..write(obj.groupId)
      ..writeByte(2)
      ..write(obj.sourceCharacterId)
      ..writeByte(3)
      ..write(obj.targetId)
      ..writeByte(4)
      ..write(obj.targetType)
      ..writeByte(5)
      ..write(obj.affinity)
      ..writeByte(6)
      ..write(obj.trust)
      ..writeByte(7)
      ..write(obj.friction)
      ..writeByte(8)
      ..write(obj.familiarity)
      ..writeByte(9)
      ..write(obj.recentMood)
      ..writeByte(10)
      ..write(obj.notes)
      ..writeByte(11)
      ..write(obj.lastInteractionAt)
      ..writeByte(12)
      ..write(obj.createdAt)
      ..writeByte(13)
      ..write(obj.stage)
      ..writeByte(14)
      ..write(obj.revision)
      ..writeByte(15)
      ..write(obj.lastEventId)
      ..writeByte(16)
      ..write(obj.updatedAt);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is RelationshipStateAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}

class RelationshipTargetTypeAdapter
    extends TypeAdapter<RelationshipTargetType> {
  @override
  final int typeId = 6;

  @override
  RelationshipTargetType read(BinaryReader reader) {
    switch (reader.readByte()) {
      case 0:
        return RelationshipTargetType.ai;
      case 1:
        return RelationshipTargetType.user;
      default:
        return RelationshipTargetType.ai;
    }
  }

  @override
  void write(BinaryWriter writer, RelationshipTargetType obj) {
    switch (obj) {
      case RelationshipTargetType.ai:
        writer.writeByte(0);
        break;
      case RelationshipTargetType.user:
        writer.writeByte(1);
        break;
    }
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is RelationshipTargetTypeAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}

class RelationshipMoodAdapter extends TypeAdapter<RelationshipMood> {
  @override
  final int typeId = 7;

  @override
  RelationshipMood read(BinaryReader reader) {
    switch (reader.readByte()) {
      case 0:
        return RelationshipMood.neutral;
      case 1:
        return RelationshipMood.warm;
      case 2:
        return RelationshipMood.annoyed;
      case 3:
        return RelationshipMood.awkward;
      case 4:
        return RelationshipMood.protective;
      case 5:
        return RelationshipMood.cold;
      default:
        return RelationshipMood.neutral;
    }
  }

  @override
  void write(BinaryWriter writer, RelationshipMood obj) {
    switch (obj) {
      case RelationshipMood.neutral:
        writer.writeByte(0);
        break;
      case RelationshipMood.warm:
        writer.writeByte(1);
        break;
      case RelationshipMood.annoyed:
        writer.writeByte(2);
        break;
      case RelationshipMood.awkward:
        writer.writeByte(3);
        break;
      case RelationshipMood.protective:
        writer.writeByte(4);
        break;
      case RelationshipMood.cold:
        writer.writeByte(5);
        break;
    }
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is RelationshipMoodAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}

class RelationshipStageAdapter extends TypeAdapter<RelationshipStage> {
  @override
  final int typeId = 23;

  @override
  RelationshipStage read(BinaryReader reader) {
    switch (reader.readByte()) {
      case 0:
        return RelationshipStage.stranger;
      case 1:
        return RelationshipStage.acquaintance;
      case 2:
        return RelationshipStage.friend;
      case 3:
        return RelationshipStage.closeFriend;
      case 4:
        return RelationshipStage.romantic;
      case 5:
        return RelationshipStage.strained;
      case 6:
        return RelationshipStage.hostile;
      default:
        return RelationshipStage.stranger;
    }
  }

  @override
  void write(BinaryWriter writer, RelationshipStage obj) {
    switch (obj) {
      case RelationshipStage.stranger:
        writer.writeByte(0);
        break;
      case RelationshipStage.acquaintance:
        writer.writeByte(1);
        break;
      case RelationshipStage.friend:
        writer.writeByte(2);
        break;
      case RelationshipStage.closeFriend:
        writer.writeByte(3);
        break;
      case RelationshipStage.romantic:
        writer.writeByte(4);
        break;
      case RelationshipStage.strained:
        writer.writeByte(5);
        break;
      case RelationshipStage.hostile:
        writer.writeByte(6);
        break;
    }
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is RelationshipStageAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
