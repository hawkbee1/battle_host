import 'package:battle_backend/battle_backend.dart';
import 'package:battle_host/battle_host.dart';
import 'package:hawkbee_schema/hawkbee_schema.dart';
import 'package:test/test.dart';

import '../../helpers/fixtures.dart';
import 'battle_placement_test.dart';

void main() {
  group(HostService, () {
    late MemoryRows rows;
    late MemorySnapshotStore snapshots;
    late SimulationHost host;
    late HostService service;

    setUp(() async {
      rows = await warRows();
      snapshots = MemorySnapshotStore();
      host = hostOn(snapshots: snapshots);
      service = HostService(
        host: host,
        placement: BattlePlacement(
          rows: rows,
          host: host,
          hostId: 'host-1',
          mapIds: const {'valley'},
          reporter: RecordingErrorReporter(),
        ),
        poll: const Duration(seconds: 3),
      );
    });

    test('P-02 prepares the searches of its maps, then runs the battles '
        'placed on it', () async {
      await service.start();

      // The map was loaded once, prepared, and its battle runs on it.
      expect((host.maps.source as MemoryMapSource).reads, {'valley': 1});
      expect(host['b-1']!.map, same(host.maps.load('valley')));
    });

    test('stack decision 1 advances every second and looks for battles '
        'every poll', () async {
      await rows.put(
        AppwriteIds.battlesTableId,
        'b-1',
        BattleRow.fromData(
          'b-1',
          (await rows.get(AppwriteIds.battlesTableId, 'b-1'))!,
        ).copyWith(status: BattleStatus.planned).toData(),
      );
      await service.start();
      await rows.put(
        AppwriteIds.battlesTableId,
        'b-1',
        BattleRow.fromData(
          'b-1',
          (await rows.get(AppwriteIds.battlesTableId, 'b-1'))!,
        ).copyWith(status: BattleStatus.running).toData(),
      );

      await service.tick();
      await service.tick();
      expect(host['b-1'], isNull);
      await service.tick();
      expect(host['b-1'], isNotNull);

      (host.clock as ManualClock).advance(const Duration(seconds: 5));
      await service.tick();
      expect(host['b-1']!.time, const Duration(seconds: 5));
    });

    test('stack decision 2 snapshots every battle when it stops', () async {
      await service.start();
      (host.clock as ManualClock).advance(const Duration(minutes: 1));

      await service.stop();

      final snapshot = (await snapshots.latest('b-1'))!;
      expect(snapshot.time, const Duration(minutes: 1));
    });
  });
}
