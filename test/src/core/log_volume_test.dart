import 'package:battle_host/battle_host.dart';
import 'package:battle_protocol/battle_protocol.dart';
import 'package:test/test.dart';

import '../../helpers/scripted_battle.dart';

void main() {
  test('P-03 the scripted battle logs under 100 bytes an entry, the budget '
      'of 0.4 MB a day at 4,000 entries, in one upload at most per 10-second '
      'interval with entries', () async {
    final run = ScriptedHost.alone();
    await run.begin();
    for (final step in script) {
      step(run);
      await run.host.settle();
    }
    run.wait(const Duration(seconds: 10));
    await run.host.settle();

    final entries = run.wal.read('b-1').entries;
    const codec = BinaryProtocolCodec();
    final bytes = codec.encodeLog(entries).length - codec.logHeader().length;
    final batches = (run.logs as MemoryLogSink).batchesOf('b-1');
    final intervals = {for (final entry in entries) entry.at.inSeconds ~/ 10};

    expect(bytes / entries.length, lessThan(100));
    expect(batches.length, lessThanOrEqualTo(intervals.length));
    expect(await run.logs.read('b-1'), equals(entries));
    for (final batch in batches) {
      expect(encodeBatch(batch.entries).length, lessThan(1024));
    }
  });
}
