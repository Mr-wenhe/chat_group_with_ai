/// Limits durable model-progress events to a small, predictable rate.
///
/// Streaming callbacks can arrive once per token. Persisting every callback
/// grows the task event queue faster than the filesystem can flush it and can
/// prevent the work loop from reaching the next decision. The first non-empty
/// update is emitted immediately; later updates are sampled by [interval].
class WorkModelProgressThrottle {
  static const Duration defaultInterval = Duration(milliseconds: 250);

  final Duration interval;
  DateTime? _lastPublishedAt;

  WorkModelProgressThrottle({this.interval = defaultInterval});

  bool shouldPublish({
    required int streamedCharacters,
    required DateTime now,
  }) {
    if (streamedCharacters <= 0) return false;
    final previous = _lastPublishedAt;
    if (previous != null && now.difference(previous) < interval) {
      return false;
    }
    _lastPublishedAt = now;
    return true;
  }
}
