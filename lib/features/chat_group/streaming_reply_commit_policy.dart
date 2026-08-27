/// Returns whether a completed stream must be discarded instead of committed.
///
/// A stream can finish after the user presses stop or after the room leaves
/// the active route. Those results are not valid replies, even if the
/// provider delivered a partial token before cancellation completed.
bool shouldDiscardStreamingReply({
  required bool stopped,
  required bool pageActive,
  required bool conversationStopping,
}) {
  return stopped || !pageActive || conversationStopping;
}

/// Work-mode transitions invalidate an automatic stream only when one is
/// actually active. A running scheduler by itself must not arm a latch that
/// could discard the next, unrelated reply.
bool shouldArmDiscardOnWorkModeToggle({
  required bool schedulerRunning,
  required bool streamActive,
}) {
  return schedulerRunning && streamActive;
}
