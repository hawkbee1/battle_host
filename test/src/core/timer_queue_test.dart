import 'package:battle_host/battle_host.dart';
import 'package:test/test.dart';

List<(Duration, T)> _drain<T>(TimerQueue<T> queue, Duration now) => [
  for (var due = queue.popDue(now); due != null; due = queue.popDue(now)) due,
];

void main() {
  group(TimerQueue, () {
    test(
      'stack decision 1 gives timers from seconds to days in time order',
      () {
        final queue = TimerQueue<String>()
          ..schedule(const Duration(days: 1), 'lock ends')
          ..schedule(const Duration(seconds: 3), 'reload done')
          ..schedule(const Duration(hours: 6), 'recall done')
          ..schedule(const Duration(minutes: 30), 'capture done')
          ..schedule(const Duration(days: 1), 'hold ends');
        const order = [
          'reload done',
          'capture done',
          'recall done',
          'lock ends',
          'hold ends',
        ];

        expect(queue.length, equals(5));
        expect(queue.nextAt, equals(const Duration(seconds: 3)));
        expect(queue.pending.map((timer) => timer.$2), equals(order));
        expect(
          _drain(queue, const Duration(days: 2)).map((timer) => timer.$2),
          equals(order),
        );
        expect(queue.isEmpty, isTrue);
        expect(queue.nextAt, isNull);
      },
    );

    test('gives nothing before its time', () {
      final queue = TimerQueue<int>()..schedule(const Duration(hours: 1), 1);

      expect(queue.popDue(const Duration(minutes: 59)), isNull);
      expect(
        queue.popDue(const Duration(hours: 1)),
        equals((const Duration(hours: 1), 1)),
      );
    });

    test('keeps the scheduling order of timers due together', () {
      final queue = TimerQueue<int>();
      for (var i = 0; i < 200; i++) {
        queue.schedule(Duration(seconds: (i * 7919) % 13), i);
      }
      final expected =
          [
            for (var i = 0; i < 200; i++)
              (Duration(seconds: (i * 7919) % 13), i),
          ]..sort((a, b) {
            final byTime = a.$1.compareTo(b.$1);
            return byTime != 0 ? byTime : a.$2.compareTo(b.$2);
          });

      expect(queue.pending, equals(expected));
      expect(_drain(queue, const Duration(minutes: 1)), equals(expected));
    });
  });
}
