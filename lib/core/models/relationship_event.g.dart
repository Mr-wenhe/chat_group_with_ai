// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'relationship_event.dart';

// **************************************************************************
// TypeAdapterGenerator
// **************************************************************************

class RelationshipEventAdapter extends TypeAdapter<RelationshipEvent> {
  @override
  final int typeId = 21;

  @override
  RelationshipEvent read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return RelationshipEvent(
      id: fields[0] as String?,
      sourceCharacterId: fields[1] as String,
      targetType: fields[2] as RelationshipTargetType,
      targetId: fields[3] as String,
      reason: fields[4] as String,
      affinityBefore: fields[5] as int,
      affinityAfter: fields[6] as int,
      trustBefore: fields[7] as int,
      trustAfter: fields[8] as int,
      frictionBefore: fields[9] as int,
      frictionAfter: fields[10] as int,
      familiarityBefore: fields[11] as int,
      familiarityAfter: fields[12] as int,
      moodBefore: fields[13] as RelationshipMood,
      moodAfter: fields[14] as RelationshipMood,
      stageBefore: fields[15] as RelationshipStage,
      stageAfter: fields[16] as RelationshipStage,
      originConversationId: fields[17] as String?,
      originNameSnapshot: fields[18] as String,
      sourceMessageIds: (fields[19] as List?)?.cast<String>(),
      revision: fields[20] as int,
      occurredAt: fields[21] as DateTime?,
      confidence: fields[22] as double,
      createdBy: fields[23] as RelationshipEventCreator,
      createdAt: fields[24] as DateTime?,
    );
  }

  @override
  void write(BinaryWriter writer, RelationshipEvent obj) {
    writer
      ..writeByte(25)
      ..writeByte(0)
      ..write(obj.id)
      ..writeByte(1)
      ..write(obj.sourceCharacterId)
      ..writeByte(2)
      ..write(obj.targetType)
      ..writeByte(3)
      ..write(obj.targetId)
      ..writeByte(4)
      ..write(obj.reason)
      ..writeByte(5)
      ..write(obj.affinityBefore)
      ..writeByte(6)
      ..write(obj.affinityAfter)
      ..writeByte(7)
      ..write(obj.trustBefore)
      ..writeByte(8)
      ..write(obj.trustAfter)
      ..writeByte(9)
      ..write(obj.frictionBefore)
      ..writeByte(10)
      ..write(obj.frictionAfter)
      ..writeByte(11)
      ..write(obj.familiarityBefore)
      ..writeByte(12)
      ..write(obj.familiarityAfter)
      ..writeByte(13)
      ..write(obj.moodBefore)
      ..writeByte(14)
      ..write(obj.moodAfter)
      ..writeByte(15)
      ..write(obj.stageBefore)
      ..writeByte(16)
      ..write(obj.stageAfter)
      ..writeByte(17)
      ..write(obj.originConversationId)
      ..writeByte(18)
      ..write(obj.originNameSnapshot)
      ..writeByte(19)
      ..write(obj.sourceMessageIds)
      ..writeByte(20)
      ..write(obj.revision)
      ..writeByte(21)
      ..write(obj.occurredAt)
      ..writeByte(22)
      ..write(obj.confidence)
      ..writeByte(23)
      ..write(obj.createdBy)
      ..writeByte(24)
      ..write(obj.createdAt);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is RelationshipEventAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}

class RelationshipEventCreatorAdapter
    extends TypeAdapter<RelationshipEventCreator> {
  @override
  final int typeId = 20;

  @override
  RelationshipEventCreator read(BinaryReader reader) {
    switch (reader.readByte()) {
      case 0:
        return RelationshipEventCreator.automatic;
      case 1:
        return RelationshipEventCreator.manual;
      case 2:
        return RelationshipEventCreator.legacyMigration;
      default:
        return RelationshipEventCreator.automatic;
    }
  }

  @override
  void write(BinaryWriter writer, RelationshipEventCreator obj) {
    switch (obj) {
      case RelationshipEventCreator.automatic:
        writer.writeByte(0);
        break;
      case RelationshipEventCreator.manual:
        writer.writeByte(1);
        break;
      case RelationshipEventCreator.legacyMigration:
        writer.writeByte(2);
        break;
    }
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is RelationshipEventCreatorAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
