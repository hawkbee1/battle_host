/// {@template rate_limit}
/// A token bucket per sender (AI-03): each sender may send [burst] orders
/// at once, then [perSecond] a second. The same limit holds for players
/// and AI agents. The values are the host's, not rules (stack decision 3,
/// M6 Issue 5): a section can spend its whole AP at once, so the burst
/// holds a whole section's machine-gun fire (16 units of 30 AP firing
/// 1-AP shots is 480 orders, P-02), and the steady rate is a busy
/// player's (first-person moves at 5 a second, with orders between them).
/// A flood past that is refused.
/// {@endtemplate}
final class RateLimit {
  /// {@macro rate_limit}
  new({this.perSecond = 10, this.burst = 500});

  /// Orders a second, in the long run.
  final double perSecond;

  /// Orders at once.
  final double burst;

  final _buckets = <String, (double, DateTime)>{};

  /// Whether [sender] may send one more order at [now]; takes it if so.
  bool take(String sender, DateTime now) {
    final (tokens, at) = _buckets[sender] ?? (burst, now);
    final elapsed = now.difference(at).inMicroseconds / 1e6;
    final available = (tokens + elapsed * perSecond).clamp(0, burst);
    if (available < 1) {
      _buckets[sender] = (available.toDouble(), now);
      return false;
    }
    _buckets[sender] = (available - 1, now);
    return true;
  }
}
