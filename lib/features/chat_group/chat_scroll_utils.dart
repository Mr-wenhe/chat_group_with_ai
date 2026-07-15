import 'package:flutter/widgets.dart';

/// Waits for ListView's estimated extent to settle after asynchronously loading
/// variable-height history, then positions it at the latest message.
void scrollToBottomAfterInitialLayout(ScrollController controller) {
  WidgetsBinding.instance.addPostFrameCallback((_) {
    _jumpToBottom(controller);
    WidgetsBinding.instance
        .addPostFrameCallback((_) => _jumpToBottom(controller));
  });
}

void _jumpToBottom(ScrollController controller) {
  if (controller.hasClients) {
    controller.jumpTo(controller.position.maxScrollExtent);
  }
}
