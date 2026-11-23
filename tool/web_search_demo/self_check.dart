import 'dart:convert';
import 'dart:io';
import 'model_client.dart';
import 'public_web.dart';

void rejects(void Function() action) {
  var rejected = false;
  try {
    action();
  } catch (_) {
    rejected = true;
  }
  assert(rejected);
}

void main() {
  for (final ip in [
    '127.0.0.1',
    '10.1.1.1',
    '169.254.169.254',
    '172.16.0.1',
    '192.168.1.1',
    '100.64.0.1',
    '198.18.0.114',
    '224.0.0.1',
    '::1'
  ]) {
    assert(!publicIpv4(ip), ip);
  }
  assert(publicIpv4('8.8.8.8'));
  for (final url in [
    'http://example.com',
    'https://127.0.0.1',
    'https://example.local',
    'https://user:secret@example.com',
    'https://example.com:8443',
    'https://example.com/?api_key=secret'
  ]) {
    rejects(() => publicUrl(url));
  }
  assert(publicUrl('https://example.com/a#fragment').toString() ==
      'https://example.com/a');
  const target = 'https://github.com/flutter/flutter/blob/main/README.md';
  final wrapped = Uri.https('duckduckgo.com', '/l/', {'uddg': target});
  final results = PublicWeb.parseSearch('''
<div class="result"><a class="result__a" href="$wrapped">Flutter</a>
<span class="result__snippet">Official README</span></div>
<div class="result"><a class="result__a" href="$target">Duplicate</a></div>
<div class="result"><a class="result__a" href="https://127.0.0.1">Blocked</a></div>
''');
  assert(results.length == 1 && results.single['url'] == target);
  final encoded = base64Url.encode(utf8.encode(target));
  final bing = PublicWeb.parseSearch('''
<li class="b_algo"><h2><a href="https://www.bing.com/ck/a?u=a1$encoded">Flutter</a></h2></li>
''', bing: true);
  assert(bing.single['url'] == target);
  assert(githubRaw(Uri.parse(target)).toString() ==
      'https://raw.githubusercontent.com/flutter/flutter/main/README.md');
  assert(
      parseDecision('```json\n{"source_id":"s1"}\n```')['source_id'] == 's1');
  rejects(() => parseDecision('No actual decision'));
  assert(!redact('Key: demo-secret', 'demo-secret').contains('demo-secret'));
  final control = RunControl()..cancel();
  rejects(control.check);
  stdout.writeln(
      'PASS: public URL/IP boundary, real-result parsing, JSON, redaction, cancellation');
}
