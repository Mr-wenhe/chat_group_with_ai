import 'package:chat_group/core/models/api_config.dart';
import 'package:chat_group/core/storage/api_credential_resolver.dart';
import 'package:chat_group/features/settings/providers/api_config_providers.dart';
import 'package:chat_group/services/chat_api_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'doudizhu_hard_engine.dart';
import 'doudizhu_ai_player.dart';

final doudizhuChatApiServiceProvider =
    Provider<ChatApiService>((ref) => ChatApiService());

final doudizhuCredentialResolverProvider =
    Provider<ApiCredentialResolver>((ref) => SecureApiCredentialResolver());

final doudizhuHardMoveEngineProvider =
    Provider<DoudizhuHardMoveSelector>((ref) => const DoudizhuHardEngine());

/// AI 两次出牌之间的间隔。调快让对局更流畅，动画已与此时长解耦。
final doudizhuMoveSpacingProvider = Provider<Duration>(
  (ref) => const Duration(milliseconds: 240),
);

/// 叫分结束、换阶段等过渡的停顿时长。
final doudizhuTransitionSpacingProvider = Provider<Duration>(
  (ref) => const Duration(milliseconds: 420),
);

final doudizhuSeedProvider = Provider<int?>((ref) => null);

final doudizhuApiConfigsProvider = Provider<List<ApiConfig>>(
  (ref) => ref.watch(apiConfigsProvider),
);
