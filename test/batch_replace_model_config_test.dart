import 'dart:async';
import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/api_config.dart';
import 'package:chat_group/features/ai_character/batch_replace_model_config.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class SlowCharacter extends AICharacter {
  SlowCharacter(this.saved)
      : super(
            id: 'character',
            name: 'Review',
            avatar: 'R',
            age: 20,
            role: 'tester',
            personalityTags: [],
            systemPrompt: '',
            apiKey: '',
            apiProvider: 'custom',
            apiConfigId: 'source');
  final Completer<void> saved;
  @override
  Future<void> save() => saved.future;
}

void main() {
  testWidgets('batch replacement does not access disposed caller context',
      (tester) async {
    final saved = Completer<void>();
    Object? failure;
    Future<int>? running;
    await tester.pumpWidget(MaterialApp(
        home: Builder(
            builder: (context) => Scaffold(
                body: TextButton(
                    onPressed: () {
                      running = batchReplaceCharacterModelConfig(
                          context: context,
                          characters: [SlowCharacter(saved)],
                          apiConfigs: [
                            ApiConfig(
                                id: 'source',
                                name: 'Source',
                                provider: 'custom'),
                            ApiConfig(
                                id: 'target',
                                name: 'Target',
                                provider: 'custom')
                          ],
                          subjectLabel: '角色');
                      running!.then((_) {}, onError: (Object error) {
                        failure = error;
                      });
                    },
                    child: const Text('Open'))))));
    await tester.runAsync(() async {
      await tester.tap(find.text('Open'));
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.runAsync(() async {
      await tester.tap(find.text('替换 1 个角色'));
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() async {
      saved.complete();
      try {
        await running;
      } catch (_) {}
    });
    expect(failure, isNull);
  });
}
