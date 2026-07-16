import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('connection test never persists a newly entered API key', () async {
    final source = await File(
      'lib/features/settings/api_config_form_page.dart',
    ).readAsString();

    expect(source, isNot(contains('_credentials.save(probe.id')));
  });
}
