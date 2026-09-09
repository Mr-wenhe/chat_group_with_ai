import 'dart:async';
import 'dart:convert';

import 'package:chat_group/core/models/api_provider.dart';
import 'package:chat_group/core/models/api_protocol.dart';
import 'package:chat_group/core/streaming/chat_stream_event.dart';
import 'package:chat_group/features/ai_governance/ai_governance_models.dart';
import 'package:chat_group/features/ai_governance/ai_request_gateway.dart';
import 'package:chat_group/features/web_search/application/search_coordinator.dart';
import 'package:chat_group/features/web_search/models/search_failure.dart';
import 'package:chat_group/features/web_search/models/search_models.dart';
import 'package:chat_group/features/web_search/providers/search_provider.dart';
import 'package:chat_group/services/chat_api_service.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/memory_governance_store.dart';

part 'search_stage06_test_helpers_01.dart';
part 'search_stage06_test_part_01.dart';
part 'search_stage06_test_part_02.dart';

/// Advances only when a test simulates user consent, avoiding wall-clock
/// scheduling noise in deadline-bound coordinator tests.
class _FakeClock {
  DateTime value = DateTime.utc(2026, 8, 23, 12);

  DateTime call() => value;

  void advance(Duration duration) => value = value.add(duration);
}

void main() {
  _registerSearchStage06TestPart1();
  _registerSearchStage06TestPart2();
}
