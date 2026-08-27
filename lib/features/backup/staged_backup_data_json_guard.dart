part of 'staged_backup_data.dart';

class _BackupJsonContainer {
  final int opening;
  int arrayItems = 0;
  int mapEntries = 0;
  bool expectingValue = true;
  bool expectingKey = true;

  _BackupJsonContainer(this.opening);
}

/// Lightweight structural guard that runs before [jsonDecode].
///
/// Dart's standard decoder materializes the entire tree, so record and shape
/// limits must be checked while scanning the bounded text first. Syntax is
/// still validated by [jsonDecode] after this guard passes.
class _BackupJsonGuard {
  final String text;
  final String path;
  final int? maxArrayItems;
  final int? maxMapEntries;
  final List<_BackupJsonContainer> _containers = [];
  var _inString = false;
  var _escaped = false;
  var _stringCharacters = 0;

  _BackupJsonGuard({
    required this.text,
    required this.path,
    required this.maxArrayItems,
    required this.maxMapEntries,
  });

  void validate() {
    for (var index = 0; index < text.length; index++) {
      final codeUnit = text.codeUnitAt(index);
      if (_inString) {
        _consumeStringCharacter(codeUnit);
        continue;
      }

      if (codeUnit == 0x22) {
        _startString();
      } else if (codeUnit == 0x7b || codeUnit == 0x5b) {
        _startValueIfNeeded();
        if (_containers.length >= StagedBackupData.maxJsonDepth) {
          throw BackupException('备份 JSON 结构过深：$path');
        }
        _containers.add(_BackupJsonContainer(codeUnit));
      } else if (codeUnit == 0x7d || codeUnit == 0x5d) {
        _closeContainer(codeUnit);
      } else if (codeUnit == 0x2c) {
        _markNextValueOrKey();
      } else if (_containers.isNotEmpty &&
          _containers.last.opening == 0x5b &&
          _containers.last.expectingValue &&
          !_isWhitespace(codeUnit) &&
          codeUnit != 0x5d) {
        // First character of a primitive array item (true/false/null/number).
        _markArrayItem();
      }
    }
    if (_inString || _containers.isNotEmpty) {
      throw BackupException('备份 JSON 结构无效：$path');
    }
  }

  void _consumeStringCharacter(int codeUnit) {
    if (_escaped) {
      _escaped = false;
      return;
    }
    if (codeUnit == 0x5c) {
      _escaped = true;
      return;
    }
    if (codeUnit == 0x22) {
      _inString = false;
      return;
    }
    if (++_stringCharacters > StagedBackupData.maxJsonStringCharacters) {
      throw BackupException('备份 JSON 字符串过长：$path');
    }
  }

  void _startString() {
    if (_containers.isNotEmpty) {
      final container = _containers.last;
      if (container.opening == 0x5b && container.expectingValue) {
        _markArrayItem();
      } else if (container.opening == 0x7b && container.expectingKey) {
        _markMapEntry();
      }
    }
    _inString = true;
    _escaped = false;
    _stringCharacters = 0;
  }

  void _startValueIfNeeded() {
    if (_containers.isEmpty) return;
    final container = _containers.last;
    if (container.opening == 0x5b && container.expectingValue) {
      _markArrayItem();
    }
  }

  void _closeContainer(int closing) {
    if (_containers.isEmpty) {
      throw BackupException('备份 JSON 结构无效：$path');
    }
    final expected = closing == 0x7d ? 0x7b : 0x5b;
    if (_containers.last.opening != expected) {
      throw BackupException('备份 JSON 结构无效：$path');
    }
    _containers.removeLast();
  }

  void _markNextValueOrKey() {
    if (_containers.isEmpty) return;
    final container = _containers.last;
    if (container.opening == 0x5b) {
      container.expectingValue = true;
    } else {
      container.expectingKey = true;
    }
  }

  void _markArrayItem() {
    final container = _containers.last;
    container.expectingValue = false;
    final count = ++container.arrayItems;
    if (maxArrayItems != null && count > maxArrayItems!) {
      throw BackupException('备份记录数量超出限制：$path');
    }
  }

  void _markMapEntry() {
    final container = _containers.last;
    container.expectingKey = false;
    final count = ++container.mapEntries;
    if (maxMapEntries != null && count > maxMapEntries!) {
      throw BackupException('备份设置项数量超出限制：$path');
    }
  }

  static bool _isWhitespace(int codeUnit) =>
      codeUnit == 0x20 ||
      codeUnit == 0x09 ||
      codeUnit == 0x0a ||
      codeUnit == 0x0d;
}

/// Splits a top-level JSON array into individual object texts while reading
/// the file in chunks. The standard JSON decoder is still used for each object
/// after it is bounded, but the complete array and its duplicate object tree
/// never have to coexist in memory.
class _BackupJsonArrayStreamParser {
  final String path;
  final int maxRecords;
  final StringBuffer _record = StringBuffer();
  var _started = false;
  var _closed = false;
  var _insideRecord = false;
  var _expectValue = true;
  var _afterComma = false;
  var _sawRecord = false;
  var _depth = 0;
  var _inString = false;
  var _escaped = false;
  var _recordCount = 0;

  _BackupJsonArrayStreamParser({required this.path, required this.maxRecords});

  Iterable<String> add(String chunk) sync* {
    for (var index = 0; index < chunk.length; index++) {
      final codeUnit = chunk.codeUnitAt(index);
      final character = String.fromCharCode(codeUnit);

      if (!_started) {
        if (_isWhitespace(codeUnit)) continue;
        if (codeUnit != 0x5b) {
          throw BackupException('备份数据文件格式无效：$path');
        }
        _started = true;
        continue;
      }
      if (_closed) {
        if (!_isWhitespace(codeUnit)) {
          throw BackupException('备份数据文件格式无效：$path');
        }
        continue;
      }
      if (!_insideRecord) {
        if (_isWhitespace(codeUnit)) continue;
        if (_expectValue) {
          if (codeUnit == 0x5d && !_sawRecord && !_afterComma) {
            _closed = true;
            continue;
          }
          if (codeUnit != 0x7b) {
            throw BackupException('备份数据文件格式无效：$path');
          }
          _insideRecord = true;
          _record.clear();
          _depth = 0;
          _inString = false;
          _escaped = false;
          _afterComma = false;
        } else {
          if (codeUnit == 0x2c) {
            _expectValue = true;
            _afterComma = true;
            continue;
          }
          if (codeUnit == 0x5d) {
            _closed = true;
            continue;
          }
          throw BackupException('备份数据文件格式无效：$path');
        }
      }

      _record.write(character);
      if (_inString) {
        if (_escaped) {
          _escaped = false;
        } else if (codeUnit == 0x5c) {
          _escaped = true;
        } else if (codeUnit == 0x22) {
          _inString = false;
        }
        continue;
      }
      if (codeUnit == 0x22) {
        _inString = true;
      } else if (codeUnit == 0x7b || codeUnit == 0x5b) {
        _depth++;
        if (_depth > StagedBackupData.maxJsonDepth) {
          throw BackupException('备份 JSON 结构过深：$path');
        }
      } else if (codeUnit == 0x7d || codeUnit == 0x5d) {
        _depth--;
        if (_depth < 0) {
          throw BackupException('备份数据文件格式无效：$path');
        }
        if (_depth == 0) {
          if (codeUnit != 0x7d || _inString) {
            throw BackupException('备份数据文件格式无效：$path');
          }
          _insideRecord = false;
          _expectValue = false;
          _sawRecord = true;
          _recordCount++;
          if (_recordCount > maxRecords) {
            throw BackupException('备份记录数量超出限制：$path');
          }
          yield _record.toString();
        }
      }
    }
  }

  Iterable<String> finish() sync* {
    if (!_started || !_closed || _insideRecord || _inString) {
      throw BackupException('备份数据文件格式无效：$path');
    }
  }

  static bool _isWhitespace(int codeUnit) =>
      codeUnit == 0x20 ||
      codeUnit == 0x09 ||
      codeUnit == 0x0a ||
      codeUnit == 0x0d;
}
