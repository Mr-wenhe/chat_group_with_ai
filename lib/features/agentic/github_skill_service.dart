import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/features/web_search/application/search_provider_route.dart';
import 'package:chat_group/features/web_search/application/search_runtime_provider_factory.dart';
import 'package:chat_group/features/web_search/data/search_credential_resolver.dart';
import 'package:chat_group/features/web_search/data/search_settings_store.dart';
import 'package:chat_group/features/web_search/models/search_models.dart';
import 'package:chat_group/features/web_search/models/search_provider_config.dart';
import 'package:chat_group/features/web_search/providers/search_provider.dart';
import 'package:chat_group/features/web_search/providers/search_provider_http_support.dart';
import 'package:chat_group/features/web_search/security/search_endpoint_dns_guard.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

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
  final SearchProviderConfigStore settings;
  final Dio Function() dioFactory;

  GitHubSkillService({
    required this.database,
    SearchProviderConfigStore? settings,
    Dio Function()? dioFactory,
  })  : settings = settings ?? SearchProviderConfigStore(db: database),
        dioFactory = dioFactory ?? _defaultDio;

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
    final request = SearchRequest(
      requestId: const Uuid().v4(),
      rootRequestId: const Uuid().v4(),
      turnId: const Uuid().v4(),
      query: 'site:github.com "$normalized" (SKILL.md OR skills)',
      category: SearchCategory.software,
      maxResults: 8,
    );
    if (request.isSensitive) {
      throw const GitHubSkillServiceException(
        'sensitiveQuery',
        '搜索词包含敏感内容，已阻止发送到搜索服务。',
      );
    }
    final route = _gatewaySearchRoute();
    if (route == null) {
      throw const GitHubSkillServiceException(
        'gatewayUnavailable',
        '没有可用的生产搜索 Gateway，无法发现 GitHub 技能。',
      );
    }
    final SearchProviderResponse response;
    try {
      response = await route.provider.search(
        request,
        credential: route.credential,
        cancelToken: cancelToken,
      );
    } on DioException catch (error) {
      if (CancelToken.isCancel(error)) rethrow;
      throw const GitHubSkillServiceException(
        'searchFailed',
        '生产搜索 Gateway 暂时不可用。',
      );
    } on Object {
      throw const GitHubSkillServiceException(
        'searchFailed',
        '生产搜索 Gateway 暂时不可用。',
      );
    }
    if (response.failure != null) {
      throw GitHubSkillServiceException(
        response.failure!.type.name,
        response.failure!.safeMessage,
      );
    }
    final results = <Map<String, String>>[];
    for (final item in response.items) {
      final candidate = _candidateFromUrl(item.url);
      if (candidate == null) continue;
      results.add({
        ...candidate,
        'title': item.title,
        'summary': item.snippet,
      });
      if (results.length == 5) break;
    }
    if (results.isEmpty) {
      throw const GitHubSkillServiceException(
        'noSkillResults',
        '搜索结果中没有可解析的 GitHub 技能目录。',
      );
    }
    return List.unmodifiable(results);
  }

  Future<SkillResourcePack> importPublicSkill({
    required String owner,
    required String repo,
    required String path,
    required String ref,
    CancelToken? cancelToken,
  }) async {
    _validateImportFields(owner: owner, repo: repo, path: path, ref: ref);
    if (kIsWeb || settings.isWebUnsupported) {
      throw const GitHubSkillServiceException(
        'unsupportedPlatform',
        '当前平台不支持通过受控 Gateway 导入技能。',
      );
    }
    final route = _configuredGateway();
    if (route == null) {
      throw const GitHubSkillServiceException(
        'gatewayUnavailable',
        '没有可用的生产搜索 Gateway，无法导入 GitHub 技能。',
      );
    }
    final current = settings.findById(route.id);
    if (current == null ||
        current.provider != SearchProviderKind.gateway ||
        !current.enabled ||
        current.requiresAttention) {
      throw const GitHubSkillServiceException(
        'gatewayUnavailable',
        '已配置的 Gateway 当前不可用。',
      );
    }
    final resolver = SearchCredentialResolver(
      credentials: settings.credentials,
      isRelease: settings.isRelease,
    );
    final resolved = await resolver.resolveResult(current);
    if (current.credentialRequired && !resolved.isAvailable) {
      await settings.setRequiresAttention(current.id, true);
      throw const GitHubSkillServiceException(
        'authorizationRequired',
        'Gateway 凭据不可用，请在搜索设置中重新连接。',
      );
    }
    if (settings.isRelease &&
        (!resolved.isAvailable || resolved.value?.trim().isNotEmpty != true)) {
      throw const GitHubSkillServiceException(
        'authorizationRequired',
        'Release 版本需要已配置的 Gateway 凭据。',
      );
    }
    final endpoint = resolveSearchProviderEndpoint(
      current.baseUrl,
      githubSkillImportPath,
      isRelease: settings.isRelease,
      allowLocalDevelopmentGateway: settings.allowLocalDevelopmentGateway,
    );
    final dio = dioFactory();
    try {
      await prepareSearchEndpointConnection(
        dio,
        endpoint,
        isRelease: settings.isRelease,
      );
      final response = await dio.postUri<dynamic>(
        endpoint,
        data: {'owner': owner, 'repo': repo, 'path': path, 'ref': ref},
        options: Options(
          headers: {
            'Content-Type': 'application/json',
            'X-Request-Id': const Uuid().v4(),
            if (resolved.isAvailable && resolved.value?.isNotEmpty == true)
              'Authorization': 'Bearer ${resolved.value}',
          },
          responseType: ResponseType.json,
          validateStatus: (_) => true,
        ),
        cancelToken: cancelToken,
      );
      if (response.statusCode == 401 || response.statusCode == 403) {
        await settings.setRequiresAttention(current.id, true);
      }
      if (response.statusCode != 200) {
        throw GitHubSkillServiceException(
          _safeGatewayCode(response.data),
          _safeGatewayMessage(response.statusCode),
        );
      }
      final pack = _parseGatewayResponse(response.data);
      if (RegExp(r'^[0-9a-f]{40}$', caseSensitive: false).hasMatch(ref) &&
          pack.commit.toLowerCase() != ref.toLowerCase()) {
        throw const GitHubSkillServiceException(
          'commitConflict',
          'Gateway 返回的提交与指定 SHA 不一致，已拒绝保存。',
        );
      }
      return pack;
    } on GitHubSkillServiceException {
      rethrow;
    } on DioException catch (error) {
      if (CancelToken.isCancel(error)) rethrow;
      throw const GitHubSkillServiceException(
        'gatewayUnavailable',
        'GitHub 技能 Gateway 请求失败。',
      );
    } on FormatException {
      throw const GitHubSkillServiceException(
        'invalidSkillPack',
        'Gateway 返回的技能包结构或摘要校验失败。',
      );
    } on Object {
      throw const GitHubSkillServiceException(
        'gatewayUnavailable',
        'GitHub 技能 Gateway 请求失败。',
      );
    } finally {
      dio.close(force: true);
    }
  }

  SearchProviderRoute? _gatewaySearchRoute() {
    final routes = SearchRuntimeProviderFactory(store: settings).buildRoutes();
    final matches = routes
        .where((route) =>
            route.kind == SearchProviderKind.gateway &&
            route.enabled &&
            !route.isFallback)
        .toList();
    if (matches.isEmpty) return null;
    final primary = matches.where((route) => route.isPrimary).toList();
    return primary.isNotEmpty ? primary.first : matches.first;
  }

  SearchProviderConfig? _configuredGateway() {
    final matches = settings.configs
        .where((config) =>
            config.provider == SearchProviderKind.gateway &&
            config.enabled &&
            !config.requiresAttention)
        .toList();
    if (matches.isEmpty) return null;
    final primary = matches.where((config) => config.isDefault).toList();
    return primary.isNotEmpty ? primary.first : matches.first;
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

  static SkillResourcePack _parseGatewayResponse(Object? raw) {
    if (raw is! Map ||
        raw.keys.any((key) => key != 'request_id' && key != 'pack') ||
        raw.length != 2 ||
        raw['request_id'] is! String) {
      throw const FormatException('Gateway 响应字段无效。');
    }
    return SkillResourcePack.fromGatewayJson(raw['pack']);
  }

  static String _safeGatewayCode(Object? raw) {
    if (raw is Map && raw['error'] is Map) {
      final code = (raw['error'] as Map)['code'];
      if (code is String && RegExp(r'^[A-Z0-9_]{1,64}$').hasMatch(code)) {
        return code;
      }
    }
    return 'gatewayError';
  }

  static String _safeGatewayMessage(int? status) => switch (status) {
        401 || 403 => 'Gateway 拒绝了当前请求，请检查搜索设置。',
        404 => '指定的公开 GitHub 资源不存在。',
        413 => '技能导入请求超过大小限制。',
        422 => 'GitHub 技能包不完整或包含不支持的资源。',
        429 || 402 => 'Gateway 当前限流或额度不足。',
        _ => 'GitHub 技能 Gateway 暂时不可用。',
      };

  static Dio _defaultDio() => configureSearchProviderDio(
        Dio(BaseOptions(
          connectTimeout: const Duration(seconds: 15),
          sendTimeout: const Duration(seconds: 15),
          receiveTimeout: const Duration(seconds: 30),
          followRedirects: false,
          maxRedirects: 0,
        )),
      );
}
