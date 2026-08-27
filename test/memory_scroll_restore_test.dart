import 'package:chat_group/features/memory/memory_scroll_restore.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('waits for a delayed extent instead of settling on a short plateau',
      () async {
    const targetOffset = 2776.0;
    final extents = <double>[216, 216, targetOffset];
    final jumps = <double>[];
    var frame = 0;
    var pixels = 0.0;

    await MemoryScrollRestorer.restore(
      offset: targetOffset,
      maxFrames: extents.length,
      isMounted: () => true,
      hasClients: () => true,
      maxScrollExtent: () => extents[frame],
      pixels: () => pixels,
      jumpTo: (value) {
        pixels = value;
        jumps.add(value);
      },
      scheduleFrame: () {},
      endOfFrame: () async {
        if (frame < extents.length - 1) frame++;
      },
    );

    expect(jumps, contains(216));
    expect(jumps.last, targetOffset);
  });

  test('nudges a stable short edge so lazy layout can discover more rows',
      () async {
    const targetOffset = 2776.0;
    final jumps = <double>[];
    var extent = 216.0;
    var pixels = extent;
    var observedJumps = 0;

    await MemoryScrollRestorer.restore(
      offset: targetOffset,
      maxFrames: 8,
      isMounted: () => true,
      hasClients: () => true,
      maxScrollExtent: () => extent,
      pixels: () => pixels,
      jumpTo: (value) {
        pixels = value;
        jumps.add(value);
      },
      scheduleFrame: () {},
      endOfFrame: () async {
        if (jumps.length > observedJumps) {
          observedJumps = jumps.length;
          // A real sliver lays out additional children after a non-noop edge
          // jump. Keep the transition explicit in this deterministic model.
          extent = targetOffset;
        }
      },
    );

    expect(jumps, contains(0));
    expect(jumps.last, targetOffset);
  });
}
