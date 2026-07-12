import 'package:chat_group/features/settings/ai_processing_directory_policy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('web directory label does not invoke native filesystem loader',
      () async {
    var invoked = false;

    final label = await resolveAiProcessingDirectoryLabel(
      isWeb: true,
      nativePathLoader: () async {
        invoked = true;
        throw StateError('native filesystem must not be read on web');
      },
    );

    expect(invoked, isFalse);
    expect(label, 'Web 端使用浏览器存储，不提供本地工作目录');
  });

  test('native directory label uses the configured path', () async {
    final label = await resolveAiProcessingDirectoryLabel(
      isWeb: false,
      nativePathLoader: () async => '/tmp/agentic_output',
    );

    expect(label, '/tmp/agentic_output');
  });
}
