import 'package:chat_group/features/work_mode/work_artifact_delivery_guard.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('source creation without a real artifact fails explicitly', () {
    const request = '请生成一个可运行的 Python 脚本 script.py';

    expect(
      WorkArtifactDeliveryGuard.requiresSourceArtifact(request),
      isTrue,
    );
    expect(
      WorkArtifactDeliveryGuard.failureFor(
        request: request,
        hasReadableArtifact: false,
      ),
      WorkArtifactDeliveryGuard.missingArtifactMessage,
    );
  });

  test('source review without a write request is not treated as delivery', () {
    const request = '请分析并解释现有 Python 脚本的错误';

    expect(
      WorkArtifactDeliveryGuard.requiresSourceArtifact(request),
      isFalse,
    );
    expect(
      WorkArtifactDeliveryGuard.failureFor(
        request: request,
        hasReadableArtifact: false,
      ),
      isNull,
    );
  });

  test('a readable source artifact allows completion', () {
    const request = '请把这个 TypeScript 文件修复并保存';

    expect(
      WorkArtifactDeliveryGuard.failureFor(
        request: request,
        hasReadableArtifact: true,
      ),
      isNull,
    );
  });
}
