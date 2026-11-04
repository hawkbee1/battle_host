/// {@template timer_queue}
/// The timers of a battle in time order, from seconds to days (stack
/// decision 1): recalls, locks, captures, the victory hold. The next due
/// timer comes out in O(log n), and nothing is spent on time where no timer
/// is due. Timers due at the same time come out in the order they were
/// scheduled, so a replay fires them in the same order.
/// {@endtemplate}
final class TimerQueue<T> {
  /// {@macro timer_queue}
  new();

  final _heap = <(Duration, int, T)>[];
  var _scheduled = 0;

  /// Whether no timer is waiting.
  bool get isEmpty => _heap.isEmpty;

  /// The timers waiting.
  int get length => _heap.length;

  /// When the next timer is due; null when none waits.
  Duration? get nextAt => _heap.isEmpty ? null : _heap.first.$1;

  /// The waiting timers in the order they fire.
  List<(Duration, T)> get pending =>
      ([..._heap]..sort(_compare)).map((e) => (e.$1, e.$3)).toList();

  /// Schedules [timer] at the battle time [at].
  void schedule(Duration at, T timer) {
    _heap.add((at, _scheduled++, timer));
    var index = _heap.length - 1;
    while (index > 0) {
      final parent = (index - 1) ~/ 2;
      if (_compare(_heap[parent], _heap[index]) <= 0) break;
      _swap(parent, index);
      index = parent;
    }
  }

  /// Removes and returns the next timer due at [now] or before; null when
  /// none is due.
  (Duration, T)? popDue(Duration now) {
    if (_heap.isEmpty || _heap.first.$1 > now) return null;
    final (at, _, timer) = _heap.first;
    final last = _heap.removeLast();
    if (_heap.isNotEmpty) {
      _heap[0] = last;
      var index = 0;
      while (true) {
        final left = 2 * index + 1;
        final right = left + 1;
        var smallest = index;
        if (left < _heap.length && _compare(_heap[left], _heap[smallest]) < 0) {
          smallest = left;
        }
        if (right < _heap.length &&
            _compare(_heap[right], _heap[smallest]) < 0) {
          smallest = right;
        }
        if (smallest == index) break;
        _swap(index, smallest);
        index = smallest;
      }
    }
    return (at, timer);
  }

  static int _compare<T>((Duration, int, T) a, (Duration, int, T) b) {
    final byTime = a.$1.compareTo(b.$1);
    return byTime != 0 ? byTime : a.$2.compareTo(b.$2);
  }

  void _swap(int a, int b) {
    final item = _heap[a];
    _heap[a] = _heap[b];
    _heap[b] = item;
  }
}
