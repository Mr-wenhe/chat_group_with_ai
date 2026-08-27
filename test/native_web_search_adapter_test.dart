import 'package:chat_group/core/models/api_provider.dart';
import 'package:chat_group/features/ai_governance/model_capability_registry.dart';
import 'package:chat_group/features/web_search/application/search_provider_chain.dart';
import 'package:chat_group/features/web_search/application/search_provider_route.dart';
import 'package:chat_group/features/web_search/application/search_retry_policy.dart';
import 'package:chat_group/features/web_search/models/search_failure.dart';
import 'package:chat_group/features/web_search/models/search_models.dart';
import 'package:chat_group/features/web_search/providers/native_web_search_adapter.dart';
import 'package:chat_group/features/web_search/providers/search_provider.dart';
import 'package:chat_group/features/web_search/providers/search_provider_http_support.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

part 'native_web_search_adapter_test_helpers_01.dart';
part 'native_web_search_adapter_test_part_01.dart';

void main() {
  _registerNativeWebSearchAdapterTestPart1();
}
