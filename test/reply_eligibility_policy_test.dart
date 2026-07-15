import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/api_config.dart';
import 'package:chat_group/features/chat_group/reply_eligibility_policy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final now = DateTime(2026, 7, 13, 12);

  AICharacter character({
    bool active = true,
    int count = 0,
    int limit = 10,
    DateTime? lastReply,
  }) {
    return AICharacter(
      id: 'character',
      name: 'Tester',
      avatar: 'T',
      age: 30,
      role: 'tester',
      personalityTags: const [],
      systemPrompt: '',
      apiKey: '',
      apiProvider: 'deepseek',
      apiConfigId: 'shared-config',
      isActive: active,
      hourlyReplyCount: count,
      hourlyReplyLimit: limit,
      lastReplyTimestamp: lastReply,
    );
  }

  ApiConfig config({String apiKey = 'secret'}) => ApiConfig(
        id: 'shared-config',
        name: 'shared',
        provider: 'deepseek',
        apiKey: apiKey,
        credentialId: 'credential.api-config.shared-config',
        hasCredential: apiKey.isNotEmpty,
      );

  test('uses resolved shared ApiConfig instead of legacy character key', () {
    final policy = ReplyEligibilityPolicy(
      resolveApiConfig: (_) => config(),
      now: () => now,
    );

    expect(policy.isEligible(character()), isTrue);
  });

  test('reports inactive, missing config, and hourly limit distinctly', () {
    final configured = ReplyEligibilityPolicy(
      resolveApiConfig: (_) => config(),
      now: () => now,
    );
    final missing = ReplyEligibilityPolicy(
      resolveApiConfig: (_) => null,
      now: () => now,
    );

    expect(
      configured.blockReasonFor(character(active: false)),
      ReplyBlockReason.inactive,
    );
    expect(
      missing.blockReasonFor(character()),
      ReplyBlockReason.noApiConfig,
    );
    expect(
      configured.blockReasonFor(
        character(
            count: 10, lastReply: now.subtract(const Duration(minutes: 5))),
      ),
      ReplyBlockReason.hourlyLimit,
    );
  });

  test('resets usage after an hour and increments within the same hour', () {
    final policy = ReplyEligibilityPolicy(
      resolveApiConfig: (_) => config(),
      now: () => now,
    );
    final stale = character(
      count: 9,
      lastReply: now.subtract(const Duration(hours: 2)),
    );
    final recent = character(
      count: 4,
      lastReply: now.subtract(const Duration(minutes: 5)),
    );

    policy.recordReplyUsage(stale);
    policy.recordReplyUsage(recent);

    expect(stale.hourlyReplyCount, 1);
    expect(recent.hourlyReplyCount, 5);
    expect(stale.lastReplyTimestamp, now);
    expect(recent.lastReplyTimestamp, now);
  });
}
