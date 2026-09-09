// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'api_config.dart';

// **************************************************************************
// TypeAdapterGenerator
// **************************************************************************

class ApiConfigAdapter extends TypeAdapter<ApiConfig> {
  @override
  final int typeId = 4;

  @override
  ApiConfig read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return ApiConfig(
      id: fields[0] as String?,
      name: fields[1] == null ? '' : fields[1] as String,
      provider: fields[2] == null ? '' : fields[2] as String,
      modelName: fields[3] == null ? '' : fields[3] as String?,
      customBaseUrl: fields[5] == null ? '' : fields[5] as String,
      createdAt: fields[6] as DateTime?,
      credentialId: fields[7] == null ? '' : fields[7] as String,
      hasCredential: fields[8] == null ? false : fields[8] as bool,
      apiProtocol:
          fields[9] == null ? 'openAiChatCompletions' : fields[9] as String,
    ).._legacyApiKey = fields[4] == null ? '' : fields[4] as String?;
  }

  @override
  void write(BinaryWriter writer, ApiConfig obj) {
    writer
      ..writeByte(10)
      ..writeByte(0)
      ..write(obj.id)
      ..writeByte(1)
      ..write(obj.name)
      ..writeByte(2)
      ..write(obj.provider)
      ..writeByte(3)
      ..write(obj.modelName)
      ..writeByte(4)
      ..write(obj._legacyApiKey)
      ..writeByte(5)
      ..write(obj.customBaseUrl)
      ..writeByte(6)
      ..write(obj.createdAt)
      ..writeByte(7)
      ..write(obj.credentialId)
      ..writeByte(8)
      ..write(obj.hasCredential)
      ..writeByte(9)
      ..write(obj.apiProtocol);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ApiConfigAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
