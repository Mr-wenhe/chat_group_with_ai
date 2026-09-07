import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:chat_group/features/ai_governance/search_audit_entry.dart';
import 'package:chat_group/features/web_search/application/search_context_formatter.dart';
import 'package:chat_group/features/web_search/application/search_failure_mapper.dart';
import 'package:chat_group/features/ai_governance/search_failure_classifier.dart';
import 'package:chat_group/features/web_search/application/search_run_state.dart';
import 'package:chat_group/features/web_search/application/search_turn_cache.dart';
import 'package:chat_group/features/web_search/models/search_failure.dart';
import 'package:chat_group/features/web_search/models/search_models.dart';
import 'package:chat_group/features/web_search/security/search_endpoint_validator.dart';
import 'package:chat_group/features/web_search/security/search_endpoint_dns_guard.dart';
import 'package:chat_group/features/web_search/security/search_query_sanitizer.dart';
import 'package:chat_group/features/web_search/security/search_secret_scanner.dart';
import 'package:chat_group/features/web_search/providers/search_provider_http_support.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

part 'search_stage08_security_test_part_01.dart';
part 'search_stage08_security_test_part_02.dart';

void main() {
  _registerSearchStage08SecurityTestPart1();
  _registerSearchStage08SecurityTestPart2();
}
