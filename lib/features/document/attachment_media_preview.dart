import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

/// Only app-generated media pages accept these commands; document HTML does not.
enum AttachmentMediaCommand { play, pause, rewind, forward, restart, mute }

/// Flutter receives clicks even when the embedded desktop WebView does not.
class AttachmentMediaControls extends StatelessWidget {
  const AttachmentMediaControls({super.key, required this.onCommand});
  final ValueChanged<AttachmentMediaCommand> onCommand;

  @override
  Widget build(BuildContext context) => Wrap(
        alignment: WrapAlignment.center,
        children: [
          for (final item in const [
            (AttachmentMediaCommand.play, Icons.play_arrow, '播放'),
            (AttachmentMediaCommand.pause, Icons.pause, '暂停'),
            (AttachmentMediaCommand.rewind, Icons.replay_10, '后退 10 秒'),
            (AttachmentMediaCommand.forward, Icons.forward_10, '前进 10 秒'),
            (AttachmentMediaCommand.restart, Icons.restart_alt, '从头播放'),
            (AttachmentMediaCommand.mute, Icons.volume_off, '静音 / 恢复声音'),
          ])
            TextButton.icon(
              onPressed: () => onCommand(item.$1),
              icon: Icon(item.$2),
              label: Text(item.$3),
            ),
        ],
      );
}

/// Data URLs keep the existing offline sandbox and avoid granting file access.
String attachmentMediaHtml(Uint8List bytes,
    {required String name, required bool audio}) {
  final tag = audio ? 'audio' : 'video';
  final mime = const {
        '.mp3': 'audio/mpeg',
        '.wav': 'audio/wav',
        '.m4a': 'audio/mp4',
        '.aac': 'audio/aac',
        '.ogg': 'audio/ogg',
        '.flac': 'audio/flac',
        '.opus': 'audio/ogg',
        '.aiff': 'audio/aiff',
        '.mp4': 'video/mp4',
        '.m4v': 'video/mp4',
        '.mov': 'video/quicktime',
        '.webm': 'video/webm',
        '.avi': 'video/x-msvideo',
        '.mkv': 'video/x-matroska',
        '.wmv': 'video/x-ms-wmv',
      }[p.extension(name).toLowerCase()] ??
      (audio ? 'audio/mp4' : 'video/mp4');
  return '''
<style>body{margin:0;background:#171717;color:white;display:flex;align-items:center;justify-content:center;flex-direction:column;height:100vh}
video,audio{max-width:100%;max-height:90vh}#error:empty{display:none}</style>
<$tag controls playsinline preload="metadata" src="data:$mime;base64,${base64Encode(bytes)}"></$tag>
<p id="error" role="alert"></p>
<script>
const media = document.querySelector('$tag');
const error = document.querySelector('#error');
media.onerror = () => error.textContent = '系统不支持此音视频编码，请用系统应用打开。';
window.addEventListener('message', async (event) => {
  if (event.source !== parent) return;
  try {
    switch (event.data) {
      case 'play': await media.play(); break;
      case 'pause': media.pause(); break;
      case 'restart': media.currentTime = 0; await media.play(); break;
      case 'rewind': media.currentTime = Math.max(0, media.currentTime - 10); break;
      case 'forward':
        if (Number.isFinite(media.duration))
          media.currentTime = Math.min(media.duration, media.currentTime + 10);
        break;
      case 'mute': media.muted = !media.muted; break;
      default: return;
    }
  } catch (_) {
    error.textContent = '无法播放此音视频，请用系统应用打开。';
  }
});
</script>''';
}
