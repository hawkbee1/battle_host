import 'package:battle_host/src/core/battle.dart';
import 'package:battle_protocol/battle_protocol.dart';

/// Replays on [battle], restored at the log position [from], the [entries]
/// of its log that follow (stack decisions 1 and 2): each command again at
/// its time with its sequence number, and the battle's own entries made
/// again by its timers. The battle then stands at the time of the last
/// entry, as the logged battle did.
///
/// Throws a [StateError] naming the log position of the first entry that
/// does not come out as logged: the battle is then not the logged one.
void replay(Battle battle, List<LogEntry> entries, {required int from}) {
  final made = <LogEntry>[];
  Never diverged(int index) => throw StateError(
    'the replay of ${battle.id} diverges from its log at position '
    '${from + index}',
  );
  final listener = battle.onEvents;
  battle.onEvents = (at, events) => made.add(LogEntry(at: at, events: events));
  try {
    var checked = 0;
    for (var index = 0; index < entries.length; index++) {
      // An entry the timers already made again was checked with them.
      if (index < made.length) continue;
      final entry = entries[index];
      battle.advanceTo(entry.at);
      if (made.length == index) {
        final command = entry.command ?? diverged(index);
        if (battle.takeSeq() != command.seq) diverged(index);
        made.add(
          LogEntry(
            at: entry.at,
            command: command,
            events: battle.orders.handle(command).events,
          ),
        );
      }
      for (; checked < made.length; checked++) {
        if (made[checked] != entries.elementAtOrNull(checked)) {
          diverged(checked);
        }
      }
    }
  } finally {
    battle.onEvents = listener;
  }
}
