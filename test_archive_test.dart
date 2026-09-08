// ignore_for_file: avoid_print

import 'package:archive/archive.dart';

void main() {
  final archive = Archive()
    ..addFile(ArchiveFile.string('../outside.txt', 'escape'));
  final bytes = ZipEncoder().encodeBytes(archive);
  final decoded = ZipDecoder().decodeBytes(bytes);
  for (final entry in decoded) {
    print('Entry name bytes: ${entry.name.codeUnits}');
    print('Entry name: "${entry.name}"');
    print('Entry name split: ${entry.name.split("/")}');
    print('Entry name contains "..": ${entry.name.contains("..")}');
    print('Entry isSymbolicLink: ${entry.isSymbolicLink}');
    print('---');
  }
}
