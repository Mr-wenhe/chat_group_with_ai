import 'package:flutter/foundation.dart';

enum SearchEndpointValidationFailure {
  empty,
  malformed,
  dangerousScheme,
  httpsRequired,
  missingHost,
  userInfoNotAllowed,
  queryCredentialNotAllowed,
  privateAddress,
}

class SearchEndpointValidationResult {
  final Uri? uri;
  final SearchEndpointValidationFailure? failure;
  final String message;

  const SearchEndpointValidationResult.valid(this.uri)
      : failure = null,
        message = '';

  const SearchEndpointValidationResult.invalid(this.failure, this.message)
      : uri = null;

  bool get isValid => failure == null && uri != null;
}

/// Validates user-supplied provider endpoints before they can be persisted or
/// used for an outbound request.
class SearchEndpointValidator {
  /// Returns a backup-safe representation of a persisted endpoint.
  ///
  /// Backups may contain legacy or hand-edited settings that never passed the
  /// current validator. Query strings, fragments, and user-info are therefore
  /// removed instead of trusting the stored value to be secret-free.
  static String sanitizeForBackup(String raw) {
    final uri = Uri.tryParse(raw.trim());
    if (uri == null || uri.host.trim().isEmpty) {
      return '';
    }
    final scheme = uri.scheme.toLowerCase();
    if (scheme != 'http' && scheme != 'https') return '';
    return Uri(
      scheme: scheme,
      host: uri.host,
      port: uri.hasPort ? uri.port : null,
      path: uri.path,
    ).toString();
  }

  static SearchEndpointValidationResult validate(
    String raw, {
    bool? isRelease,
    bool? releaseMode,
    bool allowLocalDevelopmentGateway = false,
  }) {
    final release = releaseMode ?? isRelease ?? kReleaseMode;
    final value = raw.trim();
    if (value.isEmpty) {
      return const SearchEndpointValidationResult.invalid(
        SearchEndpointValidationFailure.empty,
        'Base URL 不能为空',
      );
    }

    final uri = Uri.tryParse(value);
    if (uri == null || !uri.isAbsolute) {
      return const SearchEndpointValidationResult.invalid(
        SearchEndpointValidationFailure.malformed,
        'Base URL 必须是绝对 URL',
      );
    }
    final scheme = uri.scheme.toLowerCase();
    if (scheme != 'http' && scheme != 'https') {
      return const SearchEndpointValidationResult.invalid(
        SearchEndpointValidationFailure.dangerousScheme,
        'Base URL 只允许 http 或 https',
      );
    }
    if (release && scheme != 'https') {
      return const SearchEndpointValidationResult.invalid(
        SearchEndpointValidationFailure.httpsRequired,
        'Release 必须使用 HTTPS',
      );
    }
    if (uri.host.trim().isEmpty) {
      return const SearchEndpointValidationResult.invalid(
        SearchEndpointValidationFailure.missingHost,
        'Base URL 必须包含 Host',
      );
    }
    if (uri.userInfo.isNotEmpty) {
      return const SearchEndpointValidationResult.invalid(
        SearchEndpointValidationFailure.userInfoNotAllowed,
        'Base URL 不得包含用户名或密码',
      );
    }
    if (_containsCredentialQuery(uri)) {
      return const SearchEndpointValidationResult.invalid(
        SearchEndpointValidationFailure.queryCredentialNotAllowed,
        'Base URL 查询参数不得携带凭据',
      );
    }

    final host = uri.host.toLowerCase().replaceAll(RegExp(r'\.$'), '');
    final local = _isLocalHost(host);
    if (local && !(allowLocalDevelopmentGateway && !release)) {
      return const SearchEndpointValidationResult.invalid(
        SearchEndpointValidationFailure.privateAddress,
        'Base URL 不得指向本机或私网地址',
      );
    }
    return SearchEndpointValidationResult.valid(uri);
  }

  static Uri requireValid(
    String raw, {
    bool? isRelease,
    bool? releaseMode,
    bool allowLocalDevelopmentGateway = false,
  }) {
    final result = validate(
      raw,
      isRelease: isRelease,
      releaseMode: releaseMode,
      allowLocalDevelopmentGateway: allowLocalDevelopmentGateway,
    );
    if (!result.isValid) {
      throw ArgumentError.value(raw, 'baseUrl', result.message);
    }
    return result.uri!;
  }

  static String? errorFor(
    String raw, {
    bool? isRelease,
    bool? releaseMode,
    bool allowLocalDevelopmentGateway = false,
  }) {
    final result = validate(
      raw,
      isRelease: isRelease,
      releaseMode: releaseMode,
      allowLocalDevelopmentGateway: allowLocalDevelopmentGateway,
    );
    return result.isValid ? null : result.message;
  }

  static bool isValid(
    String raw, {
    bool? isRelease,
    bool? releaseMode,
    bool allowLocalDevelopmentGateway = false,
  }) =>
      validate(
        raw,
        isRelease: isRelease,
        releaseMode: releaseMode,
        allowLocalDevelopmentGateway: allowLocalDevelopmentGateway,
      ).isValid;

  static bool _containsCredentialQuery(Uri uri) {
    for (final key in uri.queryParameters.keys) {
      final normalized = key.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
      if (normalized.contains('key') ||
          normalized.contains('token') ||
          normalized.contains('secret') ||
          normalized.contains('password') ||
          normalized.contains('authorization') ||
          normalized.contains('credential')) {
        return true;
      }
    }
    return false;
  }

  static bool _isLocalHost(String host) {
    if (host == 'localhost' ||
        host == 'localhost.localdomain' ||
        host == 'ip6-localhost' ||
        host.endsWith('.localhost') ||
        host.endsWith('.local') ||
        host.endsWith('.internal') ||
        host == 'metadata.google.internal') {
      return true;
    }
    final ipv4 = _parseIpv4(host);
    if (ipv4 != null) {
      final first = ipv4[0];
      final second = ipv4[1];
      return first == 0 ||
          first == 10 ||
          first == 127 ||
          (first == 169 && second == 254) ||
          (first == 172 && second >= 16 && second <= 31) ||
          (first == 192 && second == 168) ||
          (first == 100 && second >= 64 && second <= 127) ||
          (first == 198 && (second == 18 || second == 19)) ||
          first >= 224;
    }
    // Reject alternate numeric IPv4 spellings (single-integer, shorthand,
    // hexadecimal, or octal-like forms) instead of letting the HTTP stack
    // reinterpret them as a private address after validation.
    if (RegExp(r'^[0-9.]+$').hasMatch(host) ||
        RegExp(r'^0x[0-9a-f]+$', caseSensitive: false).hasMatch(host)) {
      return true;
    }
    final ipv6 = host.replaceAll('[', '').replaceAll(']', '');
    if (ipv6 == '::' || ipv6 == '0:0:0:0:0:0:0:1' || ipv6 == '::1') {
      return true;
    }
    if (ipv6.startsWith('fc') ||
        ipv6.startsWith('fd') ||
        ipv6.startsWith('fe8') ||
        ipv6.startsWith('fe9') ||
        ipv6.startsWith('fea') ||
        ipv6.startsWith('feb')) {
      return true;
    }
    final mapped =
        RegExp(r'::ffff:(\d+\.\d+\.\d+\.\d+)$').firstMatch(ipv6)?.group(1);
    return mapped != null && _isLocalHost(mapped);
  }

  static List<int>? _parseIpv4(String host) {
    final parts = host.split('.');
    if (parts.length != 4) return null;
    final values = <int>[];
    for (final part in parts) {
      if (part.length > 1 && part.startsWith('0')) return null;
      final value = int.tryParse(part);
      if (value == null || value < 0 || value > 255) return null;
      values.add(value);
    }
    return values;
  }
}
