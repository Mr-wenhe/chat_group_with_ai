import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'model_client.dart';
import 'public_web.dart';

String nonce() => List.generate(20, (_) => Random.secure().nextInt(256))
    .map((n) => n.toRadixString(16).padLeft(2, '0'))
    .join();

Future<void> main(List<String> args) async {
  final models = await SavedModels.load();
  final output = args.isEmpty
      ? await Directory.systemTemp.createTemp('banban-web-demo-')
      : await Directory(args.single).create(recursive: true);
  final page = File.fromUri(Platform.script.resolve('index.html'));
  final token = nonce();
  final downloads = <String, File>{};
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final origin = 'http://127.0.0.1:${server.port}';
  RunControl? active;
  stdout.writeln('DEMO_URL=$origin');
  stdout.writeln('OUTPUT_DIR=${output.path}');
  ProcessSignal.sigint.watch().listen((_) async {
    active?.cancel();
    await server.close(force: true);
    exit(0);
  });
  await for (final request in server) {
    unawaited(() async {
      final response = request.response;
      var streaming = false;
      response.headers.set('Cache-Control', 'no-store');
      response.headers.set('X-Content-Type-Options', 'nosniff');
      response.headers.set('Referrer-Policy', 'no-referrer');
      try {
        if (request.method == 'GET' && request.uri.path == '/') {
          response.headers.contentType = ContentType.html;
          response.headers.set('Content-Security-Policy',
              "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; frame-ancestors 'none'");
          response.write(
              (await page.readAsString()).replaceAll('__DEMO_TOKEN__', token));
        } else if (request.method == 'GET' &&
            request.uri.path == '/api/configs') {
          response.headers.contentType = ContentType.json;
          response.write(
              jsonEncode(models.configs.map((c) => c.publicInfo).toList()));
        } else if (request.method == 'GET' && request.uri.path == '/api/file') {
          final file = downloads[request.uri.queryParameters['id']];
          if (file == null) {
            response.statusCode = 404;
          } else {
            response.headers.contentType = ContentType.binary;
            response.headers.set('Content-Disposition',
                'attachment; filename="${file.uri.pathSegments.last}"');
            await response.addStream(file.openRead());
          }
        } else if (request.method == 'POST' &&
            ['/api/run', '/api/stop'].contains(request.uri.path)) {
          if (request.headers.value('x-demo-token') != token ||
              request.headers.value('origin') != origin) {
            response.statusCode = 403;
          } else if (request.uri.path == '/api/stop') {
            active?.cancel();
            response.write('stopped');
          } else if (active != null) {
            response.statusCode = 409;
            response.write('已有 Demo 正在运行。');
          } else {
            final body = <int>[];
            await for (final chunk in request) {
              body.addAll(chunk);
              if (body.length > 16384) throw StateError('输入过长。');
            }
            final input = jsonDecode(utf8.decode(body)) as Map;
            final task = input['task'] as String;
            if (task.trim().isEmpty || task.length > 1600) {
              throw StateError('任务须为 1–1600 字符。');
            }
            final config =
                models.configs.singleWhere((c) => c.name == input['config']);
            final control = RunControl();
            active = control;
            response.headers
                .set('Content-Type', 'text/event-stream; charset=utf-8');
            response.headers.set('X-Accel-Buffering', 'no');
            streaming = true;
            var delivery = Future<void>.value();
            var connected = true;
            try {
              await runDemo(models, config, task, output, downloads, control,
                  (event) {
                delivery = delivery.then((_) async {
                  if (!connected) return;
                  response.write('data: ${jsonEncode(event)}\n\n');
                  await response.flush();
                }).catchError((_) {
                  connected = false;
                  control.cancel();
                });
              });
              await delivery;
            } finally {
              control.cancel();
              active = null;
            }
          }
        } else {
          response.statusCode = 404;
        }
      } catch (_) {
        // Never return credential-store errors or unfiltered model bodies.
        if (!streaming) {
          response.statusCode = 400;
          response.write('Demo 请求失败，请查看步骤状态。');
        }
      } finally {
        await response.close().catchError((_) {});
      }
    }());
  }
}

Future<void> runDemo(
    SavedModels models,
    DemoConfig config,
    String task,
    Directory output,
    Map<String, File> downloads,
    RunControl control,
    void Function(Map<String, dynamic>) emit) async {
  final runId = nonce();
  final directory = await Directory('${output.path}/$runId').create();
  final events = <Map<String, dynamic>>[];
  var secret = '';
  DemoModelClient? model;
  void event(String kind, Map<String, dynamic> data) {
    final safe = jsonDecode(redact(
        jsonEncode({
          'kind': kind,
          'time': DateTime.now().toUtc().toIso8601String(),
          ...data
        }),
        secret)) as Map<String, dynamic>;
    events.add(safe);
    emit(safe);
  }

  final web = PublicWeb(control, event);
  try {
    secret = await models.keyFor(config);
    model = DemoModelClient(config, secret, control);
    event('start', {
      'config': config.publicInfo,
      'task': task,
      'message': '仅使用现有聊天 Key；搜索与网页请求不带 Key。'
    });
    event('working', {'step': '模型生成查询'});
    final queryDecision = await model.decide(
        task, '输出 {"query":"搜索词"}。优先搜索能直接找到相关公开文本文件的官方来源；搜索词最多 200 字符。', {});
    final query = queryDecision['query'];
    if (query is! String) throw StateError('模型没有提供搜索词。');
    if (query.contains(secret) ||
        RegExp(r'\bsk-[A-Za-z0-9._-]+').hasMatch(query)) {
      throw StateError('搜索词包含疑似密钥，已阻止外发。');
    }
    event('decision', {
      'step': 'search',
      'instruction': {'query': query}
    });
    final sources = await web.search(query);
    event('working', {'step': '模型选择阅读来源'});
    final readDecision = await model.decide(task,
        '选择一个最相关的官方来源。只输出 {"source_id":"s1"}，禁止编造 id。', {'sources': sources});
    final source =
        sources.singleWhere((s) => s['source_id'] == readDecision['source_id']);
    event('decision', {'step': 'read', 'instruction': readDecision});
    final page = await web.read(source);
    event('read', page);
    event('working', {'step': '模型选择下载文件'});
    final selection = await model.decide(
        task,
        '从 downloadLinks 选择最符合原任务的小型文件，输出 {"link_id":"l1","filename":"README.md"}。'
        '只有网页 HTML 可下载时使用 .html 扩展名，必须如实保存，禁止冒充其他格式。',
        page);
    final links = (page['downloadLinks'] as List).cast<Map<String, String>>();
    final link = links.singleWhere((l) => l['link_id'] == selection['link_id']);
    final filename = selection['filename'];
    if (filename is! String ||
        filename.length > 100 ||
        !RegExp(r'^[A-Za-z0-9][A-Za-z0-9_.-]*$').hasMatch(filename) ||
        filename.contains('..')) {
      throw StateError('模型提供的文件名不安全。');
    }
    event('decision',
        {'step': 'download', 'instruction': selection, 'url': link['url']});
    final fileResponse = await web.get(link['url']!, maxBytes: 8 * 1024 * 1024);
    control.check();
    if (fileResponse.bytes.isEmpty) throw StateError('下载内容为空。');
    if (fileResponse.contentType.contains('html') &&
        !filename.endsWith('.html')) {
      throw StateError('服务器返回 HTML，不能保存成其他文件格式。');
    }
    if (utf8
        .decode(fileResponse.bytes, allowMalformed: true)
        .contains(secret)) {
      throw StateError('下载内容包含当前聊天 Key，已阻止写入。');
    }
    final file = File('${directory.path}/$filename');
    final staging = File('${file.path}.part');
    await staging.writeAsBytes(fileResponse.bytes, flush: true);
    control.check();
    await staging.rename(file.path);
    final fileId = nonce();
    downloads[fileId] = file;
    final receipt = {
      'url': fileResponse.url.toString(),
      'file': filename,
      'path': file.path,
      'bytes': fileResponse.bytes.length,
      'sha256': sha256.convert(fileResponse.bytes).toString(),
      'downloadId': fileId
    };
    event('download', receipt);
    event('working', {'step': '模型根据真实收据汇报'});
    final summary = await model.decide(
        task,
        '依据实测证据输出 {"answer":"中文简短结论"}，'
        '指出来源及下载文件，不能把 Demo 成功说成伴伴正式版已接入。',
        {
          'source': source,
          'pageExcerpt': '${page['body']}'.substring(
              0,
              '${page['body']}'.length > 1800
                  ? 1800
                  : '${page['body']}'.length),
          'downloadReceipt': receipt
        });
    event('complete', {
      'answer': summary['answer'],
      'reportedUsage': model.usages,
      'reportPath': '${directory.path}/report.json'
    });
  } catch (error) {
    event('failed', {
      'error': '$error',
      'reportedUsage': model?.usages ?? [],
      'reportPath': '${directory.path}/report.json'
    });
  } finally {
    await File('${directory.path}/report.json').writeAsString(
        const JsonEncoder.withIndent('  ')
            .convert({'demoOnly': true, 'events': events}));
  }
}
