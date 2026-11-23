import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/features/web_search/desktop/desktop_web_service.dart';
import 'package:chat_group/features/web_search/desktop/web_worker_client.dart';
import 'package:dio/dio.dart';
import 'skill_resource_pack.dart';

const String githubSkillImportPath = '/v1/github/skills/import';

class GitHubSkillServiceException implements Exception {
  final String code;
  final String message;

  const GitHubSkillServiceException(this.code, this.message);

  @override
  String toString() => message;
}

class GitHubSkillService {
  final DatabaseService database;
  final WebWorkerClient Function() workerFactory;

  GitHubSkillService(
      {required this.database, WebWorkerClient Function()? workerFactory})
      : workerFactory = workerFactory ?? WebWorkerClient.bundled;

  Future<T> _usingWorker<T>(CancelToken? cancelToken,
      Future<T> Function(WebWorkerClient worker) operation) async {
    if (cancelToken?.isCancelled == true) throw cancelToken!.cancelError!;
    final worker = workerFactory();
    var finished = false;
    if (cancelToken != null) {
      unawaited(cancelToken.whenCancel.then((_) {
        if (!finished) worker.close();
      }));
    }
    try {
      final value = await operation(worker);
      if (cancelToken?.isCancelled == true) throw cancelToken!.cancelError!;
      return value;
    } on Object {
      if (cancelToken?.isCancelled == true) throw cancelToken!.cancelError!;
      rethrow;
    } finally {
      finished = true;
      worker.close();
    }
  }

  Future<List<Map<String, String>>> discover(
    String query, {
    CancelToken? cancelToken,
  }) async {
    final normalized = query.trim();
    if (normalized.isEmpty || normalized.length > 200) {
      throw const GitHubSkillServiceException(
        'invalidQuery',
        '搜索词为空或超出限制。',
      );
    }
    return _usingWorker(cancelToken, (worker) async {
      final results = <Map<String, String>>[];
      final items = await DesktopWebService(worker).search(
          'site:github.com "$normalized" (SKILL.md OR skills)',
          cancellation: cancelToken?.whenCancel.then<void>((_) {}));
      for (final item in items) {
        final candidate = _candidateFromUrl(Uri.parse(item['url']!));
        if (candidate != null) {
          results.add({
            ...candidate,
            'title': item['title']!,
            'summary': item['snippet']!
          });
        }
        if (results.length == 5) break;
      }
      if (results.isEmpty) {
        throw const GitHubSkillServiceException(
          'noSkillResults',
          '搜索结果中没有可解析的 GitHub 技能目录。',
        );
      }
      return List.unmodifiable(results);
    });
  }

  Future<SkillResourcePack> importPublicSkill({
    required String owner,
    required String repo,
    required String path,
    required String ref,
    CancelToken? cancelToken,
  }) async {
    _validateImportFields(owner: owner, repo: repo, path: path, ref: ref);
    return _usingWorker(cancelToken, (worker) async {
      final bytes = BytesBuilder(copy: false);
      var completed = false;
      await for (final frame in worker.request({
        'operation': 'github.import',
        'arguments': {'owner': owner, 'repo': repo, 'path': path, 'ref': ref}
      })) {
        if (cancelToken?.isCancelled == true) throw cancelToken!.cancelError!;
        if (frame['status'] == 'error') {
          throw const GitHubSkillServiceException(
              'importFailed', '公开 GitHub 技能导入失败。');
        }
        if (frame['status'] == 'chunk') {
          bytes.add(base64Decode(frame['data'] as String));
          if (bytes.length > 4 * 1024 * 1024) {
            throw const FormatException('技能包超过上限。');
          }
        }
        if (frame['status'] == 'done') {
          if (frame['byteLength'] != bytes.length) {
            throw const FormatException('技能包不完整。');
          }
          completed = true;
        }
      }
      if (!completed) throw const FormatException('技能导入提前结束。');
      final pack = SkillResourcePack.fromGatewayJson(
          jsonDecode(utf8.decode(bytes.takeBytes())));
      if (RegExp(r'^[0-9a-f]{40}$', caseSensitive: false).hasMatch(ref) &&
          pack.commit.toLowerCase() != ref.toLowerCase()) {
        throw const GitHubSkillServiceException(
            'commitConflict', '返回的提交与指定 SHA 不一致。');
      }
      return pack;
    });
  }

  static Map<String, String>? _candidateFromUrl(Uri url) {
    if (url.scheme != 'https' ||
        url.host.toLowerCase() != 'github.com' ||
        url.userInfo.isNotEmpty ||
        url.hasQuery ||
        url.hasFragment) {
      return null;
    }
    final segments = url.pathSegments.where((item) => item.isNotEmpty).toList();
    if (segments.length < 5 ||
        (segments[2] != 'tree' && segments[2] != 'blob')) {
      return null;
    }
    final owner = segments[0];
    final repo = segments[1].replaceFirst(RegExp(r'\.git$'), '');
    final ref = segments[3];
    var path = segments.skip(4).join('/');
    if (path.endsWith('/SKILL.md')) path = path.substring(0, path.length - 9);
    if (path.isEmpty ||
        !_safeSearchSegment(owner) ||
        !_safeSearchSegment(repo) ||
        !RegExp(r'^[A-Za-z0-9._/-]{1,128}$').hasMatch(ref) ||
        ref.startsWith('/') ||
        ref.endsWith('/') ||
        path
            .split('/')
            .any((part) => part.isEmpty || part == '.' || part == '..')) {
      return null;
    }
    return {'owner': owner, 'repo': repo, 'path': path, 'ref': ref};
  }

  static bool _safeSearchSegment(String value) =>
      RegExp(r'^[A-Za-z0-9][A-Za-z0-9_.-]{0,99}$').hasMatch(value) &&
      value != '.' &&
      value != '..';

  static void _validateImportFields({
    required String owner,
    required String repo,
    required String path,
    required String ref,
  }) {
    if (!_safeSearchSegment(owner) ||
        !_safeSearchSegment(repo) ||
        path.isEmpty ||
        path.length > 500 ||
        path.startsWith('/') ||
        path.contains('\\') ||
        path.contains('%') ||
        !RegExp(r'^[A-Za-z0-9._/-]{1,500}$').hasMatch(path) ||
        path
            .split('/')
            .any((part) => part.isEmpty || part == '.' || part == '..') ||
        !RegExp(r'^[A-Za-z0-9._/-]{1,128}$').hasMatch(ref) ||
        ref.startsWith('/') ||
        ref.endsWith('/') ||
        ref
            .split('/')
            .any((part) => part.isEmpty || part == '.' || part == '..')) {
      throw const GitHubSkillServiceException(
        'invalidImportRequest',
        'GitHub owner、repo、path 或 ref 格式无效。',
      );
    }
  }
}
