import 'package:chat_group/core/models/api_config.dart';
import 'package:chat_group/core/storage/api_credential_resolver.dart';
import 'package:chat_group/features/settings/providers/api_config_providers.dart';
import 'package:chat_group/services/chat_api_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'othello_hard_engine.dart';

final othelloChatApiServiceProvider =
    Provider<ChatApiService>((ref) => ChatApiService());

final othelloCredentialResolverProvider =
    Provider<ApiCredentialResolver>((ref) => SecureApiCredentialResolver());

final othelloHardMoveEngineProvider =
    Provider<OthelloMoveEngine>((ref) => const OthelloHardEngine());

final othelloMoveSpacingProvider = Provider<Duration>(
  (ref) => const Duration(milliseconds: 350),
);

final othelloApiConfigsProvider = Provider<List<ApiConfig>>(
  (ref) => ref.watch(apiConfigsProvider),
);
