import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

/// Debug-only, privacy-preserving diagnostics for the Web Search pipeline.
///
/// Query text and credentials are intentionally never written to the log.
/// A short digest lets developers correlate one request across stages without
/// making the log itself an additional data sink.
class SearchFlowLogger {
  const SearchFlowLogger._();

  static void event(
    String name, {
    String? query,
    Map<String, Object?> fields = const <String, Object?>{},
  }) {
    if (kReleaseMode) return;
    final payload = <String, Object?>{
      ...fields,
      if (query != null) ...queryMeta(query),
    };
    debugPrint('[WebSearch][$name] ${jsonEncode(payload)}');
  }

  static Map<String, Object?> queryMeta(String query) => <String, Object?>{
        'queryLength': query.length,
        'queryHash': sha256
            .convert(utf8.encode(query))
            .toString()
            .substring(0, 12),
      };
}
