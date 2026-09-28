import 'dart:convert';
import 'dart:typed_data';

import 'package:chat_group/core/images/image_generation_service.dart';
import 'package:chat_group/core/images/image_provider_presets.dart';
import 'package:chat_group/core/images/image_service_config.dart';
import 'package:chat_group/features/settings/widgets/image_generation_preview_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/async_pump.dart';

/// 真正的 1×1 透明 PNG。必须是**可解码**字节：[Image.memory] 会走
/// `instantiateImageCodecWithSize`，喂截断头会抛 `Invalid image data`
/// 并把整个用例判失败（像素内容本身并不校验）。
final Uint8List _pngBytes = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8'
  'z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);

const _draft = ImageServiceConfig(
  baseUrl: 'https://open.bigmodel.cn/api/paas/v4',
  model: 'cogview-4-flash',
  size: '512x512',
  quality: '',
  apiKeyBound: true,
);

void main() {
  testWidgets('生成时传入的是表单草稿配置与固定预览 prompt', (tester) async {
    ImageServiceConfig? received;
    String? receivedPrompt;
    var readCount = 0;

    await tester.pumpWidget(MaterialApp(
      home: ImageGenerationPreviewCard(
        draft: _draft,
        apiKeyBound: true,
        readApiKey: () async {
          readCount++;
          return 'sk-bound';
        },
        generate: (config, prompt) async {
          received = config;
          receivedPrompt = prompt;
          return _pngBytes;
        },
      ),
    ));

    await tester.tap(find.byKey(const ValueKey('image-preview-generate')));
    await pumpUntilReady(tester, () => received != null);

    // 草稿值原样进生图调用：用户改完模型名不必先保存才能验证。
    expect(received!.baseUrl, _draft.baseUrl);
    expect(received!.model, _draft.model);
    expect(received!.size, _draft.size);
    expect(receivedPrompt, kImagePreviewPrompt);
    expect(readCount, 1, reason: '凭据只读一次，不做写入/回读/删除');
  });

  testWidgets('未绑定 Key 时按钮禁用，不会发起生成', (tester) async {
    var generateCalls = 0;

    await tester.pumpWidget(MaterialApp(
      home: ImageGenerationPreviewCard(
        draft: _draft,
        apiKeyBound: false,
        readApiKey: () async {
          fail('未绑定 Key 不应读取凭据');
        },
        generate: (config, prompt) async {
          generateCalls++;
          return _pngBytes;
        },
      ),
    ));

    final button = tester.widget<FilledButton>(
      find.byKey(const ValueKey('image-preview-generate')),
    );
    expect(button.onPressed, isNull);
    expect(generateCalls, 0);
  });

  testWidgets('地址或模型为空时按钮禁用', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: ImageGenerationPreviewCard(
        draft: _draft.copyWith(baseUrl: '   ', model: ''),
        apiKeyBound: true,
        readApiKey: () async => 'sk-bound',
        generate: (config, prompt) async => _pngBytes,
      ),
    ));

    final button = tester.widget<FilledButton>(
      find.byKey(const ValueKey('image-preview-generate')),
    );
    expect(button.onPressed, isNull);
  });

  testWidgets('读不到已绑定 Key 时就地报错，不发起生成', (tester) async {
    var generateCalls = 0;

    await tester.pumpWidget(MaterialApp(
      home: ImageGenerationPreviewCard(
        draft: _draft,
        apiKeyBound: true,
        readApiKey: () async => null,
        generate: (config, prompt) async {
          generateCalls++;
          return _pngBytes;
        },
      ),
    ));

    await tester.tap(find.byKey(const ValueKey('image-preview-generate')));
    await pumpUntilReady(
      tester,
      () => find.byKey(const ValueKey('image-preview-error')).evaluate().isNotEmpty,
    );

    expect(find.textContaining('未找到已绑定的 API Key'), findsOneWidget);
    expect(generateCalls, 0);
  });

  testWidgets('业务失败展示中文原因', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: ImageGenerationPreviewCard(
        draft: _draft,
        apiKeyBound: true,
        readApiKey: () async => 'sk-bound',
        generate: (config, prompt) async =>
            throw const ImageGenerationException('图像服务 API Key 无效或已过期'),
      ),
    ));

    await tester.tap(find.byKey(const ValueKey('image-preview-generate')));
    await pumpUntilReady(
      tester,
      () => find.byKey(const ValueKey('image-preview-error')).evaluate().isNotEmpty,
    );

    expect(find.textContaining('API Key 无效'), findsOneWidget);
  });

  testWidgets('成功后展示图片并提示可放大', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: ImageGenerationPreviewCard(
        draft: _draft,
        apiKeyBound: true,
        readApiKey: () async => 'sk-bound',
        generate: (config, prompt) async => _pngBytes,
      ),
    ));

    await tester.tap(find.byKey(const ValueKey('image-preview-generate')));
    await pumpUntilReady(
      tester,
      () => find.textContaining('点击左侧图片可放大查看').evaluate().isNotEmpty,
    );

    expect(find.byType(Image), findsOneWidget);
    expect(find.byKey(const ValueKey('image-preview-error')), findsNothing);
  });
}
