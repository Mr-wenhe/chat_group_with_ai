// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'media_attachment.dart';

// **************************************************************************
// TypeAdapterGenerator
// **************************************************************************

class MediaAttachmentAdapter extends TypeAdapter<MediaAttachment> {
  @override
  final int typeId = 9;

  @override
  MediaAttachment read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return MediaAttachment(
      id: fields[0] as String?,
      type: fields[1] as String,
      localPath: fields[2] as String,
      fileName: fields[3] as String?,
      fileSize: fields[4] as int?,
      mimeType: fields[5] as String?,
      durationMs: fields[6] as int?,
    );
  }

  @override
  void write(BinaryWriter writer, MediaAttachment obj) {
    writer
      ..writeByte(7)
      ..writeByte(0)
      ..write(obj.id)
      ..writeByte(1)
      ..write(obj.type)
      ..writeByte(2)
      ..write(obj.localPath)
      ..writeByte(3)
      ..write(obj.fileName)
      ..writeByte(4)
      ..write(obj.fileSize)
      ..writeByte(5)
      ..write(obj.mimeType)
      ..writeByte(6)
      ..write(obj.durationMs);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is MediaAttachmentAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
