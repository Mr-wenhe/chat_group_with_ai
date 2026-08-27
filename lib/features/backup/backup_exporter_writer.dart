part of 'backup_exporter.dart';

/// Writes generated JSON through the same byte boundary used by the importer.
/// Failing before the file is complete prevents a locally-created backup from
/// becoming larger than the format can later restore.
class _BoundedJsonFileWriter {
  final IOSink _sink;
  final String _path;
  var _bytes = 0;

  _BoundedJsonFileWriter(this._sink, this._path);

  void writeText(String text) {
    final encoded = utf8.encode(text);
    final next = _bytes + encoded.length;
    if (next > StagedBackupData.maxJsonFileBytes) {
      throw BackupException('备份数据文件过大：$_path');
    }
    _sink.add(encoded);
    _bytes = next;
  }

  void writeJsonLine(Map<String, dynamic> record) {
    final encoded = utf8.encode(jsonEncode(record));
    if (encoded.length > StagedBackupData.maxJsonLineBytes) {
      throw BackupException('备份记录行过长：$_path');
    }
    final next = _bytes + encoded.length + 1;
    if (next > StagedBackupData.maxJsonFileBytes) {
      throw BackupException('备份数据文件过大：$_path');
    }
    _sink
      ..add(encoded)
      ..add(const [0x0a]);
    _bytes = next;
  }
}

String _safeExtension(String name) {
  final base = _basename(name);
  final dot = base.lastIndexOf('.');
  if (dot <= 0 || base.length - dot > 12) return '';
  final extension = base.substring(dot).toLowerCase();
  return RegExp(r'^\.[a-z0-9]+$').hasMatch(extension) ? extension : '';
}

String _basename(String path) => path.replaceAll('\\', '/').split('/').last;
