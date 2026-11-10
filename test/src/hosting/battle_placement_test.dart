import 'dart:io';

import 'package:battle_backend/battle_backend.dart';
import 'package:battle_host/battle_host.dart';
import 'package:battle_protocol/battle_protocol.dart';
import 'package:battle_rules/battle_rules.dart';
import 'package:hawkbee_schema/hawkbee_schema.dart';
import 'package:test/test.dart';

import '../../helpers/fixtures.dart';

const String _battles = AppwriteIds.battlesTableId;

/// A war `w-1` with a running battle `b-1` on the valley: `s-1` (team-1,
/// chief of `g-1`, a commander with a tree and a machine gun, spare
/// weapons) and `s-2` (team-2, a commander).
Future<MemoryRows> warRows({
  String mapId = 'valley',
  String? host,
  Map<String, int> tree = const {'hp': 2},
  Map<String, Object?> settings = const {},
}) async {
  final rows = MemoryRows();
  await rows.put(
    AppwriteIds.warsTableId,
    'w-1',
    const WarRow(id: 'w-1', minStartingMoney: 500).toData(),
  );
  await rows.put(
    AppwriteIds.sectionsTableId,
    's-1',
    SectionRow(
      id: 's-1',
      warId: 'w-1',
      accountId: 'a-1',
      guildId: 'g-1',
      kept: KeptSection(
        money: 700,
        xp: 40,
        weapons: const ['anti_tank'],
        units: [
          KeptUnit(
            id: 'c-1',
            type: 'commander',
            xpEarned: 12,
            xpUnspent: 3,
            tree: tree,
            weapon: 'machine_gun',
          ),
        ],
      ),
    ).toData(),
  );
  await rows.put(
    AppwriteIds.sectionsTableId,
    's-2',
    const SectionRow(
      id: 's-2',
      warId: 'w-1',
      accountId: 'a-2',
      kept: KeptSection(
        money: 100,
        xp: 0,
        units: [KeptUnit(id: 'c-2', type: 'commander')],
      ),
    ).toData(),
  );
  await rows.put(
    AppwriteIds.guildsTableId,
    'g-1',
    const GuildRow(id: 'g-1', warId: 'w-1', roles: {'s-1': 'chief'}).toData(),
  );
  await rows.put(
    _battles,
    'b-1',
    BattleRow(
      id: 'b-1',
      warId: 'w-1',
      mapId: mapId,
      seed: 3,
      settings: settings,
      status: BattleStatus.running,
      host: host,
      teams: const {
        'team-1': ['s-1'],
        'team-2': ['s-2'],
      },
    ).toData(),
  );
  return rows;
}

/// Rows where another host always wins the claim of a battle.
final class _LosingRows implements Rows {
  new(this.inner);

  final MemoryRows inner;

  @override
  Future<void> put(String table, String id, RowData data) => inner.put(
    table,
    id,
    table == _battles && data['host'] != null
        ? {...data, 'host': 'host-2'}
        : data,
  );

  @override
  Future<RowData?> get(String table, String id) => inner.get(table, id);

  @override
  Future<List<Row>> find(String table, Map<String, Object> equal) =>
      inner.find(table, equal);

  @override
  Future<void> delete(String table, String id) => inner.delete(table, id);
}

SimulationHost hostOn({
  MemorySnapshotStore? snapshots,
  MemoryLogSink? logs,
  MemoryWriteAheadLog? wal,
}) => SimulationHost(
  clock: ManualClock(DateTime.utc(2026, 11, 6)),
  maps: MapLibrary(
    source: MemoryMapSource({'valley': valley}),
    terrain: planData.terrain,
  ),
  definitions: planData,
  reporter: RecordingErrorReporter(),
  snapshots: snapshots,
  logs: logs,
  wal: wal,
);

void main() {
  late RecordingErrorReporter reporter;

  setUp(() => reporter = RecordingErrorReporter());

  BattlePlacement placementOf(
    Rows rows,
    SimulationHost host, {
    String hostId = 'host-1',
  }) => BattlePlacement(
    rows: rows,
    host: host,
    hostId: hostId,
    mapIds: const {'valley'},
    address: 'http://$hostId:8080',
    reporter: reporter,
  );

  Future<HostRow?> hostRow(Rows rows, String hostId) async =>
      switch (await rows.get(AppwriteIds.hostsTableId, hostId)) {
        final data? => HostRow.fromData(data),
        null => null,
      };

  /// Writes the `hosts` row of [hostId], last seen at [seenAt].
  Future<void> seen(Rows rows, String hostId, DateTime seenAt) => rows.put(
    AppwriteIds.hostsTableId,
    hostId,
    HostRow(address: 'http://$hostId:8080', seenAt: seenAt).toData(),
  );

  Future<BattleRow> battleRow(Rows rows) async =>
      BattleRow.fromData('b-1', (await rows.get(_battles, 'b-1'))!);

  group(BattlePlacement, () {
    test('stack decision 1 claims a running battle of its map, records '
        'where it runs and starts it from its rows', () async {
      final rows = await warRows();
      final host = hostOn();

      expect(await placementOf(rows, host).sync(), ['b-1']);

      expect((await battleRow(rows)).host, 'host-1');
      final state = host['b-1']!.state;
      expect(host['b-1']!.random.seed, 3);
      expect(host['b-1']!.minStartingMoney, 500);
      final s1 = state.sections['s-1']!;
      expect(
        (s1.team, s1.accountId, s1.money, s1.xp),
        ('team-1', 'a-1', 700, 40.0),
      );
      expect((s1.guildId, s1.guildChief), ('g-1', true));
      expect(s1.storedWeapons.weapons, ['anti_tank']);
      expect(state.sections['s-2']!.guildChief, isFalse);
      final c1 = state.units['c-1']!;
      expect(c1.tree.steps, {EvolvableStat.hp: 2});
      expect((c1.xp.earned, c1.xp.unspent), (12.0, 3.0));
      expect(c1.weapon.weapon!.id, 'machine_gun');
    });

    test('stack decision 1 runs a battle placed on it, and leaves the '
        'battles of other live hosts, other maps and other statuses', () async {
      final mine = await warRows(host: 'host-1');
      final theirs = await warRows(host: 'host-2');
      await seen(theirs, 'host-2', DateTime.utc(2026, 11, 6));
      final elsewhere = await warRows(mapId: 'saint_lo');
      final planned = await warRows();
      await planned.put(
        _battles,
        'b-1',
        (await battleRow(planned))
            .copyWith(status: BattleStatus.planned)
            .toData(),
      );

      final host = hostOn();
      final placement = placementOf(mine, host);
      expect(await placement.sync(), ['b-1']);
      expect(await placement.sync(), isEmpty);
      for (final rows in [theirs, elsewhere, planned]) {
        expect(await placementOf(rows, hostOn()).sync(), isEmpty);
      }
      expect((await battleRow(theirs)).host, 'host-2');
    });

    test('stack decision 1 lets a battle go when another host won its '
        'claim', () async {
      final losing = _LosingRows(await warRows());
      final host = hostOn();

      expect(await placementOf(losing, host).sync(), isEmpty);
      expect(host['b-1'], isNull);
    });

    test('stack decision 2 recovers a battle that has a snapshot', () async {
      final rows = await warRows();
      final snapshots = MemorySnapshotStore();
      final logs = MemoryLogSink();
      final wal = MemoryWriteAheadLog();
      final first = hostOn(snapshots: snapshots, logs: logs, wal: wal);
      await placementOf(rows, first).sync();
      await first.settle();
      final second = hostOn(snapshots: snapshots, logs: logs, wal: wal);

      expect(await placementOf(rows, second).sync(), ['b-1']);

      expect(second['b-1']!.state.units.keys, first['b-1']!.state.units.keys);
    });

    test('COMBAT-02 decision 238 plays a battle with the settings its row '
        'overrides, and the plan for the rest', () async {
      final rows = await warRows(
        settings: {
          'ap': {'recovery_delay_s': 1},
          'test_units': true,
        },
      );
      final host = hostOn();

      await placementOf(rows, host).sync();

      final battle = host['b-1']!;
      expect(battle.settings.ap.recoveryDelayS, 1);
      expect(battle.settings.testUnits, isTrue);
      expect(battle.settings.ap.max, planData.battle.ap.max);
      expect(battle.state.units['c-1']!.pool.recoveryDelayS, 1);
      expect(battle.state.teams['team-1']!.hq.pool.recoveryDelayS, 1);
    });

    test('COMBAT-02 a battle recovered from its snapshot keeps its own '
        'settings', () async {
      final rows = await warRows(
        settings: {
          'ap': {'recovery_delay_s': 1},
          'test_units': true,
        },
      );
      final snapshots = MemorySnapshotStore();
      final logs = MemoryLogSink();
      final wal = MemoryWriteAheadLog();
      final first = hostOn(snapshots: snapshots, logs: logs, wal: wal);
      await placementOf(rows, first).sync();
      await first.settle();
      final second = hostOn(snapshots: snapshots, logs: logs, wal: wal);

      expect(await placementOf(rows, second).sync(), ['b-1']);

      final battle = second['b-1']!;
      expect(battle.settings.ap.recoveryDelayS, 1);
      expect(battle.settings.testUnits, isTrue);
      expect(battle.state.units['c-1']!.pool.recoveryDelayS, 1);
    });

    test(
      'reports a battle whose row holds settings the plan refuses',
      () async {
        final rows = await warRows(
          settings: {
            'ap': {'recovery_delay_s': 0},
          },
        );

        expect(await placementOf(rows, hostOn()).sync(), isEmpty);
        expect(reporter.reports.single.$1, isA<GameDataException>());
        expect(reporter.reports.single.$2, 'b-1');
      },
    );

    test('reports a battle that fails to start and tries again', () async {
      final rows = await warRows(tree: const {'wings': 1});
      final host = hostOn();
      final placement = placementOf(rows, host);

      expect(await placement.sync(), isEmpty);
      expect(reporter.reports.single.$1, isA<FormatException>());
      expect(reporter.reports.single.$2, 'b-1');

      final fixed = await warRows();
      await rows.put(
        AppwriteIds.sectionsTableId,
        's-1',
        (await fixed.get(AppwriteIds.sectionsTableId, 's-1'))!,
      );
      expect(await placement.sync(), ['b-1']);

      final missing = await warRows();
      await missing.delete(AppwriteIds.sectionsTableId, 's-2');
      expect(await placementOf(missing, hostOn()).sync(), isEmpty);
      expect(reporter.reports.last.$1, isA<StateError>());
    });

    test('SOC-17 writes the result of a battle once it has ended, which '
        'end_battle reads', () async {
      final rows = await warRows();
      final host = hostOn();
      final placement = placementOf(rows, host);
      await placement.sync();
      expect(await placement.report(), isEmpty);

      host['b-1']!.change(
        (state) => state
            .withUnit(
              state.units['c-1']!.copyWith(
                xp: const UnitXp(earned: 20, unspent: 11),
              ),
            )
            .withSection(state.sections['s-1']!.withWallet(xp: 42))
            .withVictory(
              VictoryState(
                relicOwners: state.victory!.relicOwners,
                teams: state.victory!.teams,
                winner: const BattleWon(
                  team: 'team-1',
                  kind: VictoryKind.lastHq,
                ),
              ),
            ),
      );

      expect(await placement.report(), ['b-1']);
      expect(await placement.report(), isEmpty);
      final row = await battleRow(rows);
      expect(
        (row.status, row.winner, row.host),
        (BattleStatus.ended, 'team-1', 'host-1'),
      );
      final result = row.result!;
      expect(result.winner, 'team-1');
      // 2 section XP is the 20 % share of 10 XP its units earned (UNIT-14).
      expect(result.earned['s-1'], closeTo(10, 1e-9));
      expect(result.earned['s-2'], 0);
      final s1 = result.sections['s-1']!;
      expect((s1.money, s1.xp), (700, 42.0));
      expect(s1.weapons, ['anti_tank']);
      final c1 = s1.units.single;
      expect(c1.toJson(), {
        'id': 'c-1',
        'type': 'commander',
        'xp_earned': 20.0,
        'xp_unspent': 11.0,
        'tree': {'hp': 2},
        'weapon': 'machine_gun',
      });
      expect(result.sections['s-2']!.units.single.weapon, isNull);
    });

    test('does not report a battle whose row is gone', () async {
      final rows = await warRows();
      final host = hostOn();
      final placement = placementOf(rows, host);
      await placement.sync();
      host['b-1']!.change(
        (state) => state.withVictory(
          VictoryState(
            relicOwners: state.victory!.relicOwners,
            teams: state.victory!.teams,
            winner: const BattleWon(team: 'team-2', kind: VictoryKind.lastHq),
          ),
        ),
      );
      await rows.delete(_battles, 'b-1');

      expect(await placement.report(), isEmpty);
    });
  });

  group('M6 Issue 6 where a battle runs', () {
    final now = DateTime.utc(2026, 11, 6);

    test('writes its public address and the time at each sync', () async {
      final rows = await warRows();
      final host = hostOn();
      final placement = placementOf(rows, host);

      await placement.sync();
      expect(
        (await hostRow(rows, 'host-1'))!.toData(),
        HostRow(address: 'http://host-1:8080', seenAt: now).toData(),
      );

      (host.clock as ManualClock).advance(const Duration(seconds: 10));
      await placement.sync();
      expect(
        (await hostRow(rows, 'host-1'))!.seenAt,
        now.add(const Duration(seconds: 10)),
      );
    });

    test('takes over the battle of a host not seen for its lease, or with '
        'no row, from the uploads', () async {
      for (final last in [now.subtract(const Duration(minutes: 1)), null]) {
        final rows = await warRows();
        final snapshots = MemorySnapshotStore();
        final logs = MemoryLogSink();
        final gone = hostOn(snapshots: snapshots, logs: logs);
        await placementOf(rows, gone, hostId: 'host-2').sync();
        await gone.settle();
        if (last == null) {
          await rows.delete(AppwriteIds.hostsTableId, 'host-2');
        } else {
          await seen(rows, 'host-2', last);
        }
        final next = hostOn(snapshots: snapshots, logs: logs);

        expect(await placementOf(rows, next).sync(), ['b-1']);

        expect((await battleRow(rows)).host, 'host-1');
        expect(next['b-1']!.state.units.keys, gone['b-1']!.state.units.keys);
      }
    });

    test('leaves the battle of a host seen within its lease', () async {
      final rows = await warRows(host: 'host-2');
      await seen(rows, 'host-2', now.subtract(const Duration(seconds: 59)));

      expect(await placementOf(rows, hostOn()).sync(), isEmpty);
      expect((await battleRow(rows)).host, 'host-2');
    });

    test('discards its own write-ahead log of a battle it claims: another '
        'host may have run it since', () async {
      final rows = await warRows();
      final wal = MemoryWriteAheadLog();
      final stale = hostOn(wal: wal);
      await placementOf(rows, stale).sync();
      expect(wal.read('b-1').entries, isNotEmpty);
      await rows.put(
        _battles,
        'b-1',
        (await battleRow(rows)).copyWith(host: () => null).toData(),
      );
      final again = hostOn(wal: wal);

      // A start at position 0 over the stale log would be refused.
      expect(await placementOf(rows, again).sync(), ['b-1']);
      expect(reporter.reports, isEmpty);
    });

    test('stops running a battle that moved to another host, and claims it '
        'again once free', () async {
      final rows = await warRows();
      final host = hostOn();
      final placement = placementOf(rows, host);
      await placement.sync();
      await seen(rows, 'host-2', now);
      await rows.put(
        _battles,
        'b-1',
        (await battleRow(rows)).copyWith(host: () => 'host-2').toData(),
      );

      expect(await placement.sync(), isEmpty);
      expect(host['b-1'], isNull);
      expect(host.failed, isEmpty);
      expect(
        () => host.subscribe('b-1', 's-1', _Silent()),
        throwsArgumentError,
      );

      await rows.put(
        _battles,
        'b-1',
        (await battleRow(rows)).copyWith(host: () => null).toData(),
      );
      expect(await placement.sync(), ['b-1']);
    });

    test('lets go of its battles all uploaded when it leaves, and of its '
        'row', () async {
      final rows = await warRows();
      final host = hostOn();
      final placement = placementOf(rows, host);
      await placement.sync();

      // Its first snapshot is not uploaded yet.
      await placement.leave();
      expect((await battleRow(rows)).host, 'host-1');
      expect(host['b-1'], isNotNull);
      expect(await hostRow(rows, 'host-1'), isNull);

      await host.settle();
      await placement.leave();
      expect((await battleRow(rows)).host, isNull);
      expect(host['b-1'], isNull);
    });

    test('keeps the battles it runs whose row names another host or is '
        'gone when it leaves', () async {
      final rows = await warRows();
      final host = hostOn();
      final placement = placementOf(rows, host);
      await placement.sync();
      await host.settle();
      await rows.put(
        _battles,
        'b-1',
        (await battleRow(rows)).copyWith(host: () => 'host-2').toData(),
      );

      await placement.leave();
      expect((await battleRow(rows)).host, 'host-2');

      await rows.delete(_battles, 'b-1');
      await placement.leave();
      expect(await rows.get(_battles, 'b-1'), isNull);
      expect(host['b-1'], isNotNull);
    });
  });

  group('resultOf', () {
    test('SOC-47 counts all the section XP of a battle with no setup as '
        'earned in it, and none with no section share', () async {
      final rows = await warRows();
      final host = hostOn();
      await placementOf(rows, host).sync();
      final battle = host['b-1']!
        ..change(
          (state) => state.withVictory(
            VictoryState(
              relicOwners: state.victory!.relicOwners,
              teams: state.victory!.teams,
              winner: const BattleWon(team: 'team-2', kind: VictoryKind.lastHq),
            ),
          ),
        );

      final result = resultOf(battle, null);

      expect(result.winner, 'team-2');
      expect(result.earned['s-1'], closeTo(200, 1e-9));
      expect(result.earned['s-2'], 0);

      final units = File('$planPath/data/units.yaml').readAsStringSync();
      final withoutShare = GameData.parse(
        units: units.replaceFirst(
          'section_xp_share: 0.2',
          'section_xp_share: 0',
        ),
        combat: File('$planPath/data/combat.yaml').readAsStringSync(),
        terrain: File('$planPath/data/terrain.yaml').readAsStringSync(),
        battle: File('$planPath/data/battle.yaml').readAsStringSync(),
        economy: File('$planPath/milestones/economy.yaml').readAsStringSync(),
        medals: File('$planPath/data/medals.yaml').readAsStringSync(),
      );
      expect(withoutShare.units.progression.sectionXpShare, 0);
      final shareless = Battle.restore(
        battle.save(),
        map: battle.map,
        definitions: withoutShare,
      );
      expect(resultOf(shareless, null).earned, {'s-1': 0.0, 's-2': 0.0});
    });
  });
}

final class _Silent implements SectionSubscriber {
  @override
  void send(HostMessage message) {}
}
