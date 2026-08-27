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

  test('a queued message can be returned to the head when dispatch fails', () {
    final controller = ConversationController();
    final first = PendingUserMessage('first', const ['a']);
    final second = PendingUserMessage('second', const ['b']);
    controller.enqueue(first);
    controller.enqueue(second);

    final taken = controller.takeNext();
    expect(taken, same(first));
    controller.requeueFirst(taken!);

    expect(controller.state.queuedUserMessageCount, 2);
    expect(controller.takeNext(), same(first));
    expect(controller.takeNext(), same(second));
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

  test('normal run guard releases the controller exactly once', () {
    final controller = ConversationController();
    final guard = controller.beginNormalGuard();

    expect(guard, isNotNull);
    expect(controller.isBusy, isTrue);

    guard!.finish();
    guard.finish();

    expect(controller.isBusy, isFalse);
    expect(controller.state.phase, ConversationPhase.idle);
  });

  test('automatic run guard releases the controller exactly once', () {
    final controller = ConversationController();
    final guard = controller.beginAutoGuard();

    expect(guard, isNotNull);
    expect(controller.state.phase, ConversationPhase.autoGenerating);

    guard!.finish();
    guard.finish();

    expect(controller.isBusy, isFalse);
    expect(controller.state.phase, ConversationPhase.idle);
  });

  test('an old guard cannot complete a newer run', () {
    var nextId = 0;
    final controller = ConversationController(
      idFactory: () => 'run-${nextId++}',
    );
    final first = controller.beginNormalGuard()!;
    first.finish();
    final second = controller.beginNormalGuard()!;

    first.finish();

    expect(controller.isBusy, isTrue);
    second.finish();
    expect(controller.isBusy, isFalse);
  });
}
