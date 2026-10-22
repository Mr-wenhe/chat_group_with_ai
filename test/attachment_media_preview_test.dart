import 'dart:io';
import 'dart:typed_data';

import 'package:chat_group/features/document/attachment_media_preview.dart';
import 'package:chat_group/features/document/offline_preview_html.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html;

void main() {
  test('MOV and audio remain local playable media inside the sandbox', () {
    for (final audio in [false, true]) {
      final source = attachmentMediaHtml(Uint8List.fromList([1, 2, 3]),
          name: audio ? 'sample.mp3' : 'sample.MOV', audio: audio);
      final document = html.parse(source);
      final media = document.querySelector(audio ? 'audio' : 'video')!;
      expect(media.attributes, contains('controls'));
      expect(media.attributes, contains('playsinline'));
      expect(media.attributes['src'],
          'data:${audio ? 'audio/mpeg' : 'video/quicktime'};base64,AQID');
      final frame = html
          .parse(offlinePreviewHtml(source, mediaPlayback: true))
          .querySelector('iframe')!;
      expect(frame.attributes['sandbox'], 'allow-scripts');
      expect(frame.attributes['srcdoc'], source);
      expect(frame.attributes['allow'], startsWith('autoplay;'));
      expect(offlinePreviewHtml(source), isNot(contains('autoplay;')));
    }
  });

  testWidgets('visible Flutter controls dispatch every playback action',
      (tester) async {
    final commands = <AttachmentMediaCommand>[];
    await tester.pumpWidget(MaterialApp(
        home:
            Scaffold(body: AttachmentMediaControls(onCommand: commands.add))));
    for (final label in [
      '播放',
      '暂停',
      '后退 10 秒',
      '前进 10 秒',
      '从头播放',
      '静音 / 恢复声音'
    ]) {
      await tester.tap(find.text(label));
    }
    expect(commands, AttachmentMediaCommand.values);
    expect(tester.takeException(), isNull);
  });

  test('media commands enforce sender, seek bounds and report play failures',
      () async {
    final page = html.parse(
        attachmentMediaHtml(Uint8List(0), name: 'sample.mov', audio: false));
    final script = page.querySelector('script')!.text;
    final result = await Process.run('node', [
      '-e',
      '''
const assert = require('node:assert/strict');
let handler;
const parent = {};
const player = {currentTime: 3, duration: 12, muted: false,
  play: async () => { player.played = true; },
  pause: () => { player.paused = true; }};
const message = {textContent: ''};
const document = {querySelector: (tag) => tag === '#error' ? message : player};
const window = {addEventListener: (_, callback) => handler = callback};
$script
(async () => {
  const send = data => handler({source: parent, data});
  await handler({source: {}, data: 'play'});
  assert.equal(player.played, undefined);
  await send('play'); assert.equal(player.played, true);
  await send('pause'); assert.equal(player.paused, true);
  await send('rewind'); assert.equal(player.currentTime, 0);
  await send('forward'); assert.equal(player.currentTime, 10);
  await send('forward'); assert.equal(player.currentTime, 12);
  await send('restart'); assert.equal(player.currentTime, 0);
  player.duration = NaN;
  await send('forward'); assert.equal(player.currentTime, 0);
  await send('mute'); assert.equal(player.muted, true);
  await send('mute'); assert.equal(player.muted, false);
  player.play = async () => { throw Error('unsupported'); };
  await send('play'); assert.match(message.textContent, /系统应用/);
  message.textContent = '';
  player.onerror(); assert.match(message.textContent, /编码/);
})().catch(error => { console.error(error); process.exitCode = 1; });
'''
    ]);
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
  }, timeout: const Timeout(Duration(seconds: 30)));
}
