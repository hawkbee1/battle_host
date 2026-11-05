import 'package:battle_host/battle_host.dart';
import 'package:battle_pathfinding/battle_pathfinding.dart';
import 'package:battle_protocol/battle_protocol.dart';
import 'package:battle_rules/battle_rules.dart';

import 'fixtures.dart';
import 'orders.dart';

/// The wall time every scripted battle starts at.
final scriptStart = DateTime.utc(2026, 11, 5, 8);

/// A host running the battle of [ordersSetup] by the [script], on the
/// stores it is given.
final class ScriptedHost {
  /// A host on [clock] with these stores.
  new({
    required this.clock,
    required this.wal,
    required this.logs,
    required this.snapshots,
  }) {
    host = SimulationHost(
      clock: clock,
      maps: MapLibrary(
        source: MemoryMapSource({'valley': valley}),
        terrain: planData.terrain,
      ),
      definitions: planData,
      reporter: reporter,
      wal: wal,
      logs: logs,
      snapshots: snapshots,
      rateLimit: RateLimit(perSecond: 1000, burst: 1000),
    );
  }

  /// A host on stores of its own, in memory.
  factory alone() => ScriptedHost(
    clock: ManualClock(scriptStart),
    wal: MemoryWriteAheadLog(),
    logs: MemoryLogSink(),
    snapshots: MemorySnapshotStore(),
  );

  final ManualClock clock;
  final WriteAheadLog wal;
  final LogSink logs;
  final SnapshotStore snapshots;
  final reporter = RecordingErrorReporter();
  late final SimulationHost host;

  /// The unit `s-2` bought, once bought.
  String get recruit => battle.state.units.keys.firstWhere(
    (id) => id.startsWith('unit-'),
    orElse: () => 'none',
  );

  /// The battle.
  Battle get battle => host['b-1']!;

  /// Starts the battle, deploys its units and sets it up by hand, logs
  /// `a-1` in, and keeps a snapshot of it there.
  Future<void> begin() async {
    host.start(ordersSetup());
    deploy(battle);
    battle.change(
      (state) => state
          .withUnit(
            state.units['soldier-1']!.copyWith(
              health: const Health(current: 40, max: 100),
            ),
          )
          .withUnit(
            state.units['jeep-1']!.copyWith(
              cell: const CellRef(2, 2),
              health: Health(
                current: 90,
                max: state.units['jeep-1']!.health.max,
              ),
            ),
          )
          .withRelic(
            const RelicState(
              id: 'relic-2',
              cell: CellRef(3, 0),
              owner: 'team-1',
            ),
          )
          .withSection(
            state.sections['s-1']!.withWeapons(
              const StoredWeapons(['machine_gun']),
            ),
          )
          .withSection(state.sections['s-2']!.withWallet(money: 1000)),
    );
    send(const EnterBattle(), origin: Origin.server);
    host.snapshot('b-1');
    await host.settle();
  }

  /// Sends [order] from [section] of [account], signed in as [origin].
  HandledOrder send(
    Order order, {
    String section = 's-1',
    String account = 'a-1',
    Origin origin = Origin.player,
  }) => host.submit(
    'b-1',
    Command(
      sender: Sender(accountId: account, sectionId: section),
      sentAt: battle.time,
      order: order,
    ),
    origin: origin,
  );

  /// Sends [order] from `s-2`, signed in as [origin].
  HandledOrder sendTwo(Order order, {Origin origin = Origin.player}) =>
      send(order, section: 's-2', account: 'a-2', origin: origin);

  /// Moves the clock by [step] and brings the host there.
  void wait(Duration step) {
    clock.advance(step);
    host.advance();
  }

  /// The position of the centre of [cell].
  Position at(CellRef cell) => centreOf(battle, cell);
}

/// The scripted battle: every M4 order, a purchase, a section that stores
/// and recalls itself and is locked for a day, over more than a day. Each
/// step is an order or a wait; the waits upload batches and take
/// snapshots.
final List<void Function(ScriptedHost)> script = [
  (s) => s.send(Move(unitId: 'soldier-1', to: s.at(const CellRef(1, 1)))),
  (s) => s.send(const Fire(unitId: 'commander-1', targetId: 'soldier-2')),
  (s) => s.send(
    FireAtPosition(unitId: 'artillery-1', target: s.at(const CellRef(6, 2))),
  ),
  (s) => s.send(
    FireAimed(
      unitId: 'jeep-1',
      aim: Direction.of(1, 0, 0),
      fireTime: s.battle.time,
    ),
  ),
  (s) => s.send(const Reload(unitId: 'jeep-1')),
  (s) => s.wait(const Duration(seconds: 12)),
  (s) => s.send(const UnloadWeapon(unitId: 'artillery-1')),
  (s) => s.send(const TakeOff(unitId: 'helicopter-1')),
  (s) => s.send(const Embark(unitId: 'medic-1', transportId: 'truck-1')),
  (s) => s.send(
    const Build(unitId: 'engineer-1', structure: 'wall', cells: [Cell(3, 4)]),
  ),
  (s) => s.send(const Observe(unitId: 'scout-1')),
  (s) => s.send(const Capture(unitId: 'commander-1', relicId: 'relic-1')),
  (s) => s.send(const Push(unitId: 'radio-1', relicId: 'relic-2')),
  (s) => s.send(
    const Push(
      unitId: 'scout-1',
      relicId: 'relic-2',
      path: [Cell(3, 0), Cell(4, 0)],
    ),
  ),
  (s) => s.send(MoveHq(to: s.at(const CellRef(1, 0)))),
  (s) => s.wait(const Duration(seconds: 30)),
  (s) => s.send(const Disembark(unitId: 'medic-1')),
  (s) => s.send(const Heal(unitId: 'medic-1', targetId: 'soldier-1')),
  (s) => s.send(const Land(unitId: 'helicopter-1')),
  (s) => s.wait(const Duration(minutes: 1)),
  (s) => s.send(const Resume(unitId: 'scout-1', workId: 'wall@(3, 4)')),
  (s) => s.send(const PickUpWeapon(unitId: 'soldier-1', droppedId: 'nothing')),
  (s) => s.send(Move(unitId: 'soldier-1', to: s.at(const CellRef(0, 1)))),
  (s) => s.wait(const Duration(minutes: 6)),
  (s) => s.send(Move(unitId: 'engineer-1', to: s.at(const CellRef(2, 2)))),
  (s) => s.send(const Repair(unitId: 'engineer-1', targetId: 'jeep-1')),
  (s) => s.send(const SwapWeapon(unitId: 'soldier-1', weapon: 'machine_gun')),
  (s) => s.send(const Fire(unitId: 'commander-1', targetId: 'soldier-2')),
  (s) => s.wait(const Duration(hours: 3)),
  (s) => s.sendTwo(const BuyUnit(unitType: 'soldier')),
  (s) => s.sendTwo(
    FireAimed(
      unitId: s.recruit,
      aim: Direction.of(-1, 0, 0),
      fireTime: s.battle.time,
    ),
  ),
  (s) => s.sendTwo(Move(unitId: 'commander-2', to: s.at(const CellRef(11, 1)))),
  (s) => s.sendTwo(
    Move(unitId: 'soldier-3', to: s.at(const CellRef(11, 0))),
    origin: Origin.ai,
  ),
  (s) => s.wait(const Duration(minutes: 5)),
  (s) => s.sendTwo(const Store(unitId: 'commander-2')),
  (s) => s.sendTwo(const Store(unitId: 'soldier-3')),
  (s) => s.sendTwo(Store(unitId: s.recruit)),
  (s) => s.sendTwo(const Recall(unitId: 'soldier-2')),
  (s) => s.wait(const Duration(seconds: 10)),
  (s) => s.wait(const Duration(hours: 31)),
  (s) => s.sendTwo(const Deploy(unitId: 'commander-2')),
  (s) => s.wait(const Duration(minutes: 5)),
];
