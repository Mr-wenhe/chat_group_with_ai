import 'package:flutter/foundation.dart';

import 'search_secret_scanner.dart';

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
    const scanner = SearchSecretScanner();
    if (uri.userInfo.isNotEmpty ||
        scanner.containsSensitiveData(uri.host) ||
        scanner.containsSensitiveData(uri.path)) {
      return '';
    }
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
    if (host.contains('%') || host.contains('\\')) {
      return const SearchEndpointValidationResult.invalid(
        SearchEndpointValidationFailure.malformed,
        'Base URL Host 格式无效',
      );
    }
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

  /// Shared host safety check for both configured endpoints and untrusted
  /// result links. DNS resolution remains the responsibility of the network
  /// boundary, but literal/local destinations must never pass validation.
  static bool isPrivateOrLocalHost(String host) {
    final normalized = host.toLowerCase().replaceAll(RegExp(r'\.$'), '');
    // Zone identifiers and backslashes are not part of a public DNS host.
    // Reject them before IPv6 parsing so an encoded link-local address such as
    // `[fe80::1%25en0]` cannot be treated as an unknown public hostname.
    if (normalized.contains('%') || normalized.contains('\\')) return true;
    return _isLocalHost(normalized);
  }

  /// Applies the same private-range policy to addresses returned by DNS.
  /// An empty answer is not a valid public endpoint.
  static bool areResolvedAddressesPublic(Iterable<String> addresses) {
    var found = false;
    for (final address in addresses) {
      found = true;
      final normalized = address.toLowerCase().trim();
      // Scoped IPv6 answers (for example `fe80::1%en0`) and escaped forms
      // are interface-local, not public routable destinations. Reject them
      // before the generic parser so a zone identifier cannot turn a
      // link-local answer into an apparently unknown hostname.
      if (normalized.contains('%') || normalized.contains('\\')) return false;
      if (_isLocalHost(normalized)) return false;
    }
    return found;
  }

  static bool _containsCredentialQuery(Uri uri) {
    const scanner = SearchSecretScanner();
    for (final key in uri.queryParameters.keys) {
      if (scanner.isSensitiveParameter(key)) return true;
    }
    for (final value in uri.queryParameters.values) {
      if (scanner.containsSensitiveData(value)) return true;
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
        host == 'metadata.google.internal' ||
        host == 'metadata' ||
        host == 'instance-data' ||
        host == 'host.docker.internal' ||
        host.endsWith('.nip.io') ||
        host.endsWith('.xip.io') ||
        host.endsWith('.sslip.io') ||
        host == 'localtest.me') {
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
          (first == 192 && second == 0) ||
          (first == 192 && second == 2) ||
          (first == 192 && second == 88) ||
          (first == 100 && second >= 64 && second <= 127) ||
          (first == 198 && (second == 18 || second == 19)) ||
          (first == 198 && second == 51) ||
          (first == 203 && second == 0) ||
          first >= 224;
    }
    // Reject alternate numeric IPv4 spellings (single-integer, shorthand,
    // hexadecimal, or octal-like forms) instead of letting the HTTP stack
    // reinterpret them as a private address after validation.
    if (RegExp(r'^[0-9.]+$').hasMatch(host) ||
        RegExp(
          r'^(?:0x[0-9a-f]+|[0-9]+)(?:\.(?:0x[0-9a-f]+|[0-9]+)){1,3}$',
          caseSensitive: false,
        ).hasMatch(host) ||
        RegExp(r'^0x[0-9a-f]+$', caseSensitive: false).hasMatch(host)) {
      return true;
    }
    return _isLocalIpv6(host);
  }

  static bool _isLocalIpv6(String rawHost) {
    final groups = _parseIpv6(rawHost.replaceAll('[', '').replaceAll(']', ''));
    if (groups == null) return false;
    final first = groups.first;
    final isUnspecified = groups.every((group) => group == 0);
    final isLoopback = isUnspecified ||
        (groups.take(7).every((group) => group == 0) && groups.last == 1);
    if (isLoopback) return true;
    if ((first & 0xfe00) == 0xfc00 || // fc00::/7 unique-local
        (first & 0xffc0) == 0xfe80 || // fe80::/10 link-local
        (first & 0xff00) == 0xff00) {
      // ff00::/8 multicast
      return true;
    }
    final isMapped =
        groups.take(5).every((group) => group == 0) && groups[5] == 0xffff;
    if (!isMapped) return false;
    return _isLocalHost(
      '${groups[6] >> 8}.${groups[6] & 255}.'
      '${groups[7] >> 8}.${groups[7] & 255}',
    );
  }

  static List<int>? _parseIpv6(String value) {
    if (value.isEmpty || value.indexOf('::') != value.lastIndexOf('::')) {
      return null;
    }
    final hasCompression = value.contains('::');
    final halves = value.split('::');
    final left = _parseIpv6Half(halves.first, allowIpv4Tail: !hasCompression);
    final right = halves.length == 2
        ? _parseIpv6Half(halves.last, allowIpv4Tail: true)
        : const <int>[];
    if (left == null || right == null) return null;
    if (!hasCompression) {
      return left.length == 8 ? left : null;
    }
    final missing = 8 - left.length - right.length;
    if (missing <= 0) return null;
    return [...left, ...List<int>.filled(missing, 0), ...right];
  }

  static List<int>? _parseIpv6Half(
    String half, {
    required bool allowIpv4Tail,
  }) {
    if (half.isEmpty) return const <int>[];
    final parts = half.split(':');
    final groups = <int>[];
    for (var index = 0; index < parts.length; index++) {
      final part = parts[index];
      if (part.contains('.')) {
        if (!allowIpv4Tail || index != parts.length - 1) return null;
        final ipv4 = _parseIpv4(part);
        if (ipv4 == null) return null;
        groups.add((ipv4[0] << 8) | ipv4[1]);
        groups.add((ipv4[2] << 8) | ipv4[3]);
        continue;
      }
      if (part.isEmpty || part.length > 4) return null;
      final value = int.tryParse(part, radix: 16);
      if (value == null) return null;
      groups.add(value);
    }
    return groups;
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
