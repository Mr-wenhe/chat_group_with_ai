/// Restores a scroll position while a lazily laid out sliver discovers its
/// children over multiple frames.
class MemoryScrollRestorer {
  // This is only a safety valve. Completion is driven by the sliver reporting
  // an extent that can contain the requested offset; the frame budget prevents
  // a broken/empty scroll view from keeping a route alive forever.
  static const defaultMaxFrames = 240;

  const MemoryScrollRestorer._();

  static Future<void> restore({
    required double offset,
    required bool Function() isMounted,
    required bool Function() hasClients,
    required double Function() maxScrollExtent,
    required double Function() pixels,
    required void Function(double value) jumpTo,
    required Future<void> Function() endOfFrame,
    required void Function() scheduleFrame,
    int maxFrames = defaultMaxFrames,
  }) async {
    if (maxFrames <= 0) return;
    final requestedOffset =
        offset.isFinite ? offset.clamp(0.0, double.infinity) : 0.0;
    for (var frame = 0; frame < maxFrames; frame++) {
      // endOfFrame only observes a frame; it does not guarantee that another
      // layout pass will be produced after we jump to a lazy sliver's edge.
      scheduleFrame();
      await endOfFrame();
      if (!isMounted() || !hasClients()) return;

      final extent = maxScrollExtent();
      final target = requestedOffset.clamp(0.0, extent).toDouble();
      final reachedTarget = extent >= requestedOffset;
      final reachedBudget = frame == maxFrames - 1;
      if (reachedTarget || reachedBudget) {
        jumpTo(target);
        return;
      }

      // Jumping to the currently known end forces a lazy sliver to lay out
      // more children on the next frame. If the previous restore already
      // landed exactly on a short edge, a same-value jump is a no-op in
      // ScrollPosition and the sliver may never discover the remaining rows.
      // Move to the opposite edge first so the next end jump is a genuine
      // scroll transition even when the known extent has not changed yet.
      if (extent > 0) {
        jumpTo(pixels() >= extent ? 0.0 : extent);
      }
    }
  }
}
