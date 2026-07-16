import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('work mode caps generation limits to the selected model capability', () {
    final source = File(
      'lib/features/chat_group/chat_room_page.dart',
    ).readAsStringSync();
    final start = source.indexOf('AgentRuntime _agentRuntimeFor');
    final end = source.indexOf(
        'Future<Map<String, dynamic>> _saveGeneratedSkillFromArgs', start);
    expect(start, isNonNegative);
    expect(end, greaterThan(start));

    final runtimeFactory = source.substring(start, end);
    expect(
        runtimeFactory, contains('final capability = _aiGateway.capability'));
    expect(
      runtimeFactory,
      contains(
          'min(AgentRuntime.preferredMaxOutputTokens, capability.maxOutput)'),
    );
    expect(runtimeFactory, contains('maxTokens: agentMaxTokens'));
    expect(runtimeFactory, contains('maxTokens: summaryMaxTokens'));
  });
}
