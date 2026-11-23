import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:html/parser.dart' as html;
import 'model_client.dart';

bool publicIpv4(String value) {
  final ip = InternetAddress.tryParse(value);
  if (ip == null || ip.type != InternetAddressType.IPv4) return false;
  final b = ip.rawAddress;
  return !(b[0] == 0 ||
      b[0] == 10 ||
      b[0] == 127 ||
      b[0] >= 224 ||
      b[0] == 169 && b[1] == 254 ||
      b[0] == 172 && b[1] >= 16 && b[1] <= 31 ||
      b[0] == 192 && (b[1] == 168 || b[1] == 0 || b[1] == 2 || b[1] == 88) ||
      b[0] == 100 && b[1] >= 64 && b[1] <= 127 ||
      b[0] == 198 && (b[1] == 18 || b[1] == 19 || b[1] == 51) ||
      b[0] == 203 && b[1] == 0);
}

Uri publicUrl(String value) {
  final uri = Uri.parse(value);
  final host = uri.host.toLowerCase();
  if (uri.scheme != 'https' ||
      host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasPort && uri.port != 443 ||
      !host.contains('.') ||
      host.endsWith('.local') ||
      host.endsWith('.internal') ||
      host.endsWith('.localhost') ||
      InternetAddress.tryParse(host) != null ||
      RegExp(r'^(?:[0-9.]+|0x[0-9a-f.]+)$', caseSensitive: false)
          .hasMatch(host) ||
      uri.queryParameters.keys.any((k) => RegExp(
              r'^(?:api[-_]?key|token|access_token|password|secret)$',
              caseSensitive: false)
          .hasMatch(k))) {
    throw StateError('只允许不含凭据的公网 HTTPS 页面。');
  }
  return uri.removeFragment();
}

class WebResponse {
  WebResponse(this.url, this.bytes, this.contentType);
  final Uri url;
  final Uint8List bytes;
  final String contentType;
  String get text => utf8.decode(bytes, allowMalformed: true);
}

class PublicWeb {
  PublicWeb(this.control, this.event);
  final RunControl control;
  final void Function(String, Map<String, dynamic>) event;
  final _addresses = <String, String>{};

  Future<String> _address(String host) async {
    if (_addresses.containsKey(host)) return _addresses[host]!;
    final system =
        await InternetAddress.lookup(host).timeout(const Duration(seconds: 8));
    final ips = system.map((a) => a.address).toList();
    if (ips.isNotEmpty && ips.every(publicIpv4)) {
      return _addresses[host] = ips.first;
    }
    // Demo-only: resolve through a fixed HTTPS DNS service instead of allowing
    // Fake-IP/private targets. Production gateway integration remains separate.
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    control.clients.add(client);
    try {
      final req = await client.getUrl(Uri.https('dns.google', '/resolve',
          {'name': host, 'type': 'A', 'edns_client_subnet': '0.0.0.0/0'}));
      req.followRedirects = false;
      final response = await req.close();
      if (response.statusCode != 200) throw StateError('公网 DNS 查询失败。');
      final bytes = <int>[];
      await for (final chunk in response) {
        control.check();
        bytes.addAll(chunk);
        if (bytes.length > 65536) throw StateError('DNS 响应过大。');
      }
      final json = jsonDecode(utf8.decode(bytes)) as Map;
      final records = (json['Answer'] as List? ?? [])
          .whereType<Map>()
          .where((r) => r['type'] == 1)
          .map((r) => '${r['data']}')
          .toList();
      if (json['Status'] != 0 ||
          records.isEmpty ||
          !records.every(publicIpv4)) {
        throw StateError('没有通过公网校验的 DNS 地址。');
      }
      event('network', {'host': host, 'mode': 'HTTPS DNS → 公网地址固定连接'});
      return _addresses[host] = records.first;
    } finally {
      control.clients.remove(client);
      client.close(force: true);
    }
  }

  Future<WebResponse> get(String value,
      {int maxBytes = 2 * 1024 * 1024}) async {
    return _get(value, maxBytes).timeout(const Duration(seconds: 25),
        onTimeout: () {
      control.cancel();
      throw StateError('公网请求超过 Demo 的 25 秒时限。');
    });
  }

  Future<WebResponse> _get(String value, int maxBytes) async {
    var url = publicUrl(value);
    for (var redirects = 0; redirects <= 4; redirects++) {
      control.check();
      final address = await _address(url.host);
      control.check();
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 8);
      client.findProxy = (_) => 'DIRECT';
      client.connectionFactory = (uri, host, port) async {
        final task = await Socket.startConnect(address, 443);
        Socket? pending;
        final secure = task.socket.then((socket) async {
          pending = socket;
          control.check();
          final tls = await SecureSocket.secure(socket, host: uri.host);
          pending = tls;
          return tls;
        });
        return ConnectionTask.fromSocket(secure, () {
          task.cancel();
          pending?.destroy();
        });
      };
      control.clients.add(client);
      try {
        final req = await client.getUrl(url);
        req.followRedirects = false;
        req.headers.set('User-Agent', 'chat_group/1.1.0 (keyless-search)');
        final response = await req.close();
        if ([301, 302, 303, 307, 308].contains(response.statusCode)) {
          final location = response.headers.value('location');
          if (location == null) throw StateError('重定向缺少目标地址。');
          url = publicUrl(url.resolve(location).toString());
          continue;
        }
        if (response.statusCode != 200) {
          throw StateError('网页 HTTP ${response.statusCode}：${url.host}');
        }
        if (response.contentLength > maxBytes) {
          throw StateError('文件超过 Demo 大小上限。');
        }
        final bytes = BytesBuilder(copy: false);
        await for (final chunk in response) {
          control.check();
          bytes.add(chunk);
          if (bytes.length > maxBytes) throw StateError('文件超过 Demo 大小上限。');
        }
        return WebResponse(url, bytes.takeBytes(),
            response.headers.contentType?.mimeType ?? '');
      } finally {
        control.clients.remove(client);
        client.close(force: true);
      }
    }
    throw StateError('网页重定向次数过多。');
  }

  Future<List<Map<String, String>>> search(String query) async {
    if (query.trim().isEmpty || query.length > 400) {
      throw StateError('搜索词应为 1–400 字符。');
    }
    final failures = <String>[];
    for (final bing in [false, true]) {
      final url = bing
          ? Uri.https('www.bing.com', '/search', {'q': query})
          : Uri.https('html.duckduckgo.com', '/html/', {'q': query});
      try {
        final response = await get(url.toString(), maxBytes: 512 * 1024);
        if (response.text.contains('anomaly.js') ||
            response.text.contains('challenge-form')) {
          throw StateError('搜索来源要求验证码。');
        }
        final results = parseSearch(response.text, bing: bing);
        if (results.isEmpty) throw StateError('没有解析到搜索结果。');
        event('search', {
          'provider': bing ? 'Bing HTML' : 'DuckDuckGo HTML',
          'query': query,
          'results': results,
          'searchKeyUsed': false
        });
        return results;
      } catch (e) {
        control.check();
        failures.add('$e');
        event('source_failed', {
          'provider': bing ? 'Bing HTML' : 'DuckDuckGo HTML',
          'error': '$e'
        });
      }
    }
    throw StateError('两个免 Key 来源均失败：${failures.join('；')}');
  }

  static List<Map<String, String>> parseSearch(String body,
      {bool bing = false}) {
    final doc = html.parse(body);
    final nodes = bing
        ? doc.querySelectorAll('li.b_algo')
        : doc.querySelectorAll('.result');
    final result = <Map<String, String>>[];
    final seen = <String>{};
    for (final node in nodes) {
      final anchor = node.querySelector(bing ? 'h2 a' : 'a.result__a');
      var link = anchor?.attributes['href'];
      if (anchor == null || link == null) continue;
      if (link.startsWith('//')) link = 'https:$link';
      var uri = Uri.tryParse(link);
      if (uri == null) continue;
      if (uri.queryParameters['uddg'] != null) {
        uri = Uri.tryParse(uri.queryParameters['uddg']!);
      }
      if (uri?.host.endsWith('bing.com') == true && uri?.path == '/ck/a') {
        var encoded = uri?.queryParameters['u'] ?? '';
        if (encoded.startsWith('a1')) {
          try {
            uri = Uri.tryParse(utf8.decode(
                base64Url.decode(base64Url.normalize(encoded.substring(2)))));
          } catch (_) {
            continue;
          }
        }
      }
      if (uri == null) continue;
      try {
        uri = publicUrl(uri.toString());
      } catch (_) {
        continue;
      }
      if (!seen.add(uri.toString())) continue;
      final snippet = node
              .querySelector(bing ? '.b_caption p' : '.result__snippet')
              ?.text ??
          '';
      result.add({
        'source_id': 's${result.length + 1}',
        'title': anchor.text.trim(),
        'url': uri.toString(),
        'snippet': snippet.trim()
      });
      if (result.length == 5) break;
    }
    return result;
  }

  Future<Map<String, dynamic>> read(Map<String, String> source) async {
    var url = publicUrl(source['url']!);
    final raw = githubRaw(url);
    if (raw != null) url = raw;
    final response = await get(url.toString());
    if (!response.contentType.contains('text') &&
        !response.contentType.contains('html') &&
        !response.contentType.contains('json') &&
        !response.contentType.contains('xml')) {
      throw StateError('此 Demo 阅读器仅支持 HTML / Markdown / 文本。');
    }
    final doc = html.parse(response.text);
    final links = <Map<String, String>>[];
    final seen = <String>{};
    void offer(Uri uri, String title) {
      try {
        uri = publicUrl(uri.toString());
      } catch (_) {
        return;
      }
      uri = githubRaw(uri) ?? uri;
      if (!seen.add(uri.toString()) || links.length >= 20) return;
      links.add({
        'link_id': 'l${links.length + 1}',
        'title': title,
        'url': uri.toString()
      });
    }

    final isHtml = response.contentType.contains('html');
    if (!isHtml) offer(response.url, source['title']!);
    for (final anchor in doc.querySelectorAll('a[href]')) {
      final href = anchor.attributes['href']!;
      final uri = response.url.resolve(href);
      if (RegExp(r'\.(md|txt|pdf|csv|json|zip|docx|xlsx)$',
              caseSensitive: false)
          .hasMatch(uri.path)) {
        offer(uri, anchor.text.trim());
      }
    }
    if (links.isEmpty) offer(response.url, '保存当前网页 HTML');
    doc
        .querySelectorAll(
            'script,style,noscript,nav,footer,header,svg,iframe,form')
        .forEach((e) => e.remove());
    final text = isHtml
        ? (doc.body?.text ?? '').replaceAll(RegExp(r'\s+'), ' ').trim()
        : response.text;
    if (text.isEmpty) throw StateError('网页没有可读取正文。');
    return {
      'source_id': source['source_id'],
      'url': response.url.toString(),
      'title': doc.querySelector('title')?.text ?? source['title'],
      'body': text.substring(0, text.length > 12000 ? 12000 : text.length),
      'bodyChars': text.length,
      'truncated': text.length > 12000,
      'downloadLinks': links
    };
  }
}

Uri? githubRaw(Uri uri) {
  final parts = uri.pathSegments;
  if (uri.host == 'github.com' && parts.length >= 5 && parts[2] == 'blob') {
    return Uri.https('raw.githubusercontent.com',
        '/${parts[0]}/${parts[1]}/${parts.sublist(3).join('/')}');
  }
  return null;
}
