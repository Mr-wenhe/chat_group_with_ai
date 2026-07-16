import 'package:chat_group/features/chat_group/conversation_controller.dart';
import 'package:chat_group/features/chat_group/models/chat_room_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('normal, auto, work and approval runs are mutually exclusive', () {
    final controller = ConversationController(idFactory: () => 'run-1');

    expect(controller.beginNormal()?.type, ConversationRunType.normal);
    expect(controller.beginAuto(), isNull);
    expect(controller.beginWork(), isNull);
    expect(controller.state.phase, ConversationPhase.normalGenerating);

    controller.complete();
    expect(controller.beginWork()?.type, ConversationRunType.work);
    expect(controller.waitForApproval(), isTrue);
    expect(controller.state.phase, ConversationPhase.waitingForApproval);
    expect(controller.beginAuto(), isNull);
  });

  test('messages queued during a run survive stop and are drained in order',
      () {
    final controller = ConversationController();
    controller.beginNormal();
    controller.enqueue(PendingUserMessage('first', const ['a']));
    controller.enqueue(PendingUserMessage('second', const ['b']));

    expect(controller.state.queuedUserMessageCount, 2);
    expect(controller.requestStop(), isTrue);
    expect(controller.state.phase, ConversationPhase.stopping);
    controller.complete();
    expect(controller.state.phase, ConversationPhase.userMessageQueued);
    expect(controller.takeNext()!.text, 'first');
    expect(controller.takeNext()!.text, 'second');
    expect(controller.state.phase, ConversationPhase.idle);
  });

  test('failed and disposed conversations reject new runs', () {
    final controller = ConversationController();
    controller.beginAuto();
    controller.fail('network');
    expect(controller.state.phase, ConversationPhase.failed);
    expect(controller.state.error, 'network');

    expect(controller.beginNormal(), isNotNull);
    controller.dispose();
    expect(controller.state.phase, ConversationPhase.disposed);
    expect(controller.beginWork(), isNull);
  });
}
