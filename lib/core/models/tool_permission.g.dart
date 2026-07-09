// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'tool_permission.dart';

// **************************************************************************
// TypeAdapterGenerator
// **************************************************************************

class ToolPermissionAdapter extends TypeAdapter<ToolPermission> {
  @override
  final int typeId = 10;

  @override
  ToolPermission read(BinaryReader reader) {
    switch (reader.readByte()) {
      case 0:
        return ToolPermission.workspaceRead;
      case 1:
        return ToolPermission.workspacePatch;
      case 2:
        return ToolPermission.commandRun;
      case 3:
        return ToolPermission.browserContext;
      case 4:
        return ToolPermission.skillCreate;
      case 5:
        return ToolPermission.skillDownload;
      default:
        return ToolPermission.workspaceRead;
    }
  }

  @override
  void write(BinaryWriter writer, ToolPermission obj) {
    switch (obj) {
      case ToolPermission.workspaceRead:
        writer.writeByte(0);
        break;
      case ToolPermission.workspacePatch:
        writer.writeByte(1);
        break;
      case ToolPermission.commandRun:
        writer.writeByte(2);
        break;
      case ToolPermission.browserContext:
        writer.writeByte(3);
        break;
      case ToolPermission.skillCreate:
        writer.writeByte(4);
        break;
      case ToolPermission.skillDownload:
        writer.writeByte(5);
        break;
    }
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ToolPermissionAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
