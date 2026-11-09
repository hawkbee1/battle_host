import 'package:battle_host/battle_host.dart';
import 'package:battle_protocol/battle_protocol.dart';
import 'package:test/test.dart';

void main() {
  group(RequestMemory, () {
    final start = DateTime.utc(2026, 11, 8);
    const accepted = CommandAccepted(requestId: 1, seq: 7);

    test('gives an answer back by battle, account and request ID', () {
      final memory = RequestMemory()
        ..remember(('b-1', 'a-1', 1), accepted, start);

      expect(memory.recall(('b-1', 'a-1', 1), start), equals(accepted));
      expect(memory.recall(('b-1', 'a-2', 1), start), isNull);
      expect(memory.recall(('b-2', 'a-1', 1), start), isNull);
      expect(memory.recall(('b-1', 'a-1', 2), start), isNull);
    });

    test('keeps an answer for 15 minutes after it was given', () {
      final memory = RequestMemory()
        ..remember(('b-1', 'a-1', 1), accepted, start)
        ..remember(
          ('b-1', 'a-1', 2),
          const CommandRefused(requestId: 2, reason: 'not_enough_ap'),
          start.add(const Duration(minutes: 10)),
        );
      const almost = Duration(minutes: 14, seconds: 59);

      expect(memory.recall(('b-1', 'a-1', 1), start.add(almost)), accepted);
      expect(
        memory.recall((
          'b-1',
          'a-1',
          1,
        ), start.add(const Duration(minutes: 15))),
        isNull,
      );
      expect(memory.length, equals(1));
      expect(
        memory.recall((
          'b-1',
          'a-1',
          2,
        ), start.add(const Duration(minutes: 25))),
        isNull,
      );
      expect(memory.length, isZero);
    });
  });
}
