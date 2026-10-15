import 'dart:convert';

import 'agent_decision.dart';

/// A member's opinion is not a runtime receipt or an acceptance override.
Map<String, dynamic>? parseWorkUsageFeedback(AgentFinishCompletion completion,
    {required List<String> acceptanceIds,
    bool requireDocumentEvidence = false,
    bool requireDocumentPages = false}) {
  try {
    if (completion.evidence.length != 1) return null;
    final feedback = Map<String, dynamic>.from(
        jsonDecode(completion.evidence.single) as Map);
    const baseKeys = {'method', 'result', 'acceptanceIds', 'report', 'defects'};
    final keys = {
      ...baseKeys,
      if (requireDocumentEvidence) 'documentEvidence',
    };
    bool text(Object? value) =>
        value is String &&
        value.trim().isNotEmpty &&
        value.length <= 4096 &&
        !value.contains(
            RegExp(r'[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]'));
    final ids = feedback['acceptanceIds'];
    final defects = feedback['defects'];
    if (feedback.length != keys.length ||
        !feedback.keys.every(keys.contains) ||
        !text(feedback['method']) ||
        !text(feedback['report']) ||
        !{'passed', 'failed', 'blocked'}.contains(feedback['result']) ||
        ids is! List ||
        ids.isEmpty ||
        ids.toSet().length != ids.length ||
        ids.length != acceptanceIds.length ||
        !ids.every(acceptanceIds.contains) ||
        defects is! List ||
        defects.length > 64) {
      return null;
    }
    const baseDefectKeys = {
      'acceptanceId',
      'reproduction',
      'expected',
      'actual',
      'retestCondition'
    };
    bool validLocation(Object? value) {
      if (value is! Map ||
          value.isEmpty ||
          value.length > 6 ||
          !value.keys.every((key) => const {
                'fileName',
                'paragraph',
                'lineStart',
                'lineEnd',
                'page',
                'sheet'
              }.contains(key)) ||
          !text(value['fileName'])) {
        return false;
      }
      for (final key in const ['paragraph', 'lineStart', 'lineEnd', 'page']) {
        if (value.containsKey(key) &&
            (value[key] is! int || (value[key] as int) < 1)) {
          return false;
        }
      }
      return !value.containsKey('sheet') || text(value['sheet']);
    }

    final evidence = feedback['documentEvidence'];
    final requiresLocations =
        requireDocumentEvidence && feedback['result'] != 'blocked';
    final requiresPages =
        requireDocumentPages && feedback['result'] != 'blocked';
    if (requireDocumentEvidence &&
        (evidence is! Map ||
            evidence.length != 2 ||
            !evidence.keys
                .every(const {'pageNumbers', 'sourceLocations'}.contains) ||
            evidence['pageNumbers'] is! List ||
            (requiresPages && (evidence['pageNumbers'] as List).isEmpty) ||
            (evidence['pageNumbers'] as List).length > 80 ||
            (evidence['pageNumbers'] as List)
                .any((page) => page is! int || page < 1 || page > 80) ||
            (evidence['pageNumbers'] as List).toSet().length !=
                (evidence['pageNumbers'] as List).length ||
            evidence['sourceLocations'] is! List ||
            (requiresLocations &&
                (evidence['sourceLocations'] as List).isEmpty) ||
            (evidence['sourceLocations'] as List).length > 256 ||
            (evidence['sourceLocations'] as List)
                .any((item) => !validLocation(item)))) {
      return null;
    }
    final defectKeys = {
      ...baseDefectKeys,
      if (requireDocumentEvidence) 'sourceLocation',
    };
    if (defects.any((d) =>
            d is! Map ||
            d.length != defectKeys.length ||
            !d.keys.every(defectKeys.contains) ||
            !ids.contains(d['acceptanceId']) ||
            d.entries.any((entry) => entry.key == 'sourceLocation'
                ? !validLocation(entry.value)
                : !text(entry.value))) ||
        feedback['result'] == 'failed' && defects.isEmpty ||
        feedback['result'] != 'failed' && defects.isNotEmpty) {
      return null;
    }
    return Map.unmodifiable({
      ...feedback,
      'acceptanceIds': List.unmodifiable(ids),
      if (requireDocumentEvidence)
        'documentEvidence': Map<String, dynamic>.unmodifiable({
          'pageNumbers': List<int>.unmodifiable(
              (evidence!['pageNumbers'] as List).cast<int>()),
          'sourceLocations': List<Map<String, dynamic>>.unmodifiable(
              (evidence['sourceLocations'] as List).map((location) =>
                  Map<String, dynamic>.unmodifiable(
                      Map<String, dynamic>.from(location as Map)))),
        }),
      'defects': List.unmodifiable(defects.map((d) =>
          Map<String, dynamic>.unmodifiable(
              Map<String, dynamic>.from(d as Map)))),
    });
  } on Object {
    return null;
  }
}
