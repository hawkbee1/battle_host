import 'dart:convert';

import 'package:battle_host/battle_host.dart';
import 'package:battle_pathfinding/battle_pathfinding.dart';
import 'package:battle_protocol/battle_protocol.dart';
import 'package:battle_rules/battle_rules.dart';
import 'package:test/test.dart';

import 'fixtures.dart';

/// Two teams on the valley. Team 1 (`s-1` of `a-1`, 1000 w€) has one unit
/// of most types; team 2 (`s-2` of `a-2`, no money) has a commander and two
/// soldiers.
/// `soldier-4`, `soldier-5` and the guild camp `camp-1` stay in storage.
/// The server runs `s-2` when [serverManaged] (AI-06); [accountTwo] holds
/// `s-2`.
BattleSetup ordersSetup({
  int seed = 11,
  bool serverManaged = false,
  String accountTwo = 'a-2',
}) => BattleSetup(
  battleId: 'b-1',
  mapId: 'valley',
  seed: seed,
  settings: planData.battle,
  teams: [
    const TeamSetup(
      id: 'team-1',
      sections: [
        SectionSetup(
          id: 's-1',
          accountId: 'a-1',
          money: 1000,
          units: [
            UnitSetup(id: 'commander-1', type: 'commander'),
            UnitSetup(id: 'soldier-1', type: 'soldier'),
            UnitSetup(id: 'medic-1', type: 'medic'),
            UnitSetup(id: 'engineer-1', type: 'engineer'),
            UnitSetup(id: 'scout-1', type: 'scout'),
            UnitSetup(id: 'artillery-1', type: 'artillery'),
            UnitSetup(id: 'radio-1', type: 'radio'),
            UnitSetup(id: 'truck-1', type: 'truck'),
            UnitSetup(id: 'helicopter-1', type: 'helicopter'),
            UnitSetup(id: 'jeep-1', type: 'jeep'),
            UnitSetup(id: 'soldier-4', type: 'soldier'),
            UnitSetup(id: 'soldier-5', type: 'soldier'),
            UnitSetup(id: 'camp-1', type: 'encampment'),
          ],
        ),
      ],
    ),
    TeamSetup(
      id: 'team-2',
      sections: [
        SectionSetup(
          id: 's-2',
          accountId: accountTwo,
          serverManaged: serverManaged,
          units: const [
            UnitSetup(id: 'commander-2', type: 'commander'),
            UnitSetup(id: 'soldier-2', type: 'soldier'),
            UnitSetup(id: 'soldier-3', type: 'soldier'),
          ],
        ),
      ],
    ),
  ],
);

/// Where each unit stands on the field (the storage orders come in M5.12).
const ordersPlaces = {
  'commander-1': CellRef(0, 2),
  'soldier-1': CellRef(1, 2),
  'medic-1': CellRef(1, 3),
  'engineer-1': CellRef(2, 3),
  'scout-1': CellRef(3, 3),
  'artillery-1': CellRef(2, 0),
  'radio-1': CellRef(4, 3),
  'truck-1': CellRef(2, 2),
  'helicopter-1': CellRef(3, 2),
  'jeep-1': CellRef(4, 2),
  'commander-2': CellRef(10, 3),
  'soldier-2': CellRef(6, 2),
  'soldier-3': CellRef(7, 0),
};

/// Puts the units of [ordersPlaces] on the field.
void deploy(Battle battle) => battle.change((state) {
  var next = state;
  for (final MapEntry(key: id, value: cell) in ordersPlaces.entries) {
    next = next.withUnit(
      next.units[id]!.copyWith(location: const Deployed(), cell: cell),
    );
  }
  return next;
});

/// A host running the battle of [ordersSetup], deployed, with its log;
/// `a-1` has logged in, so he manages team 1's HQ (HQ-07).
final class OrdersFixture {
  /// A fixture whose senders may send [rateLimit] orders, with the random
  /// of [seed]; the server runs `s-2` when [serverManaged].
  new({RateLimit? rateLimit, this.seed = 11, this.serverManaged = false}) {
    host = SimulationHost(
      clock: clock,
      maps: MapLibrary(
        source: MemoryMapSource({'valley': valley}),
        terrain: planData.terrain,
      ),
      definitions: planData,
      reporter: RecordingErrorReporter(),
      wal: wal,
      rateLimit: rateLimit ?? RateLimit(perSecond: 1000, burst: 1000),
    );
    battle = host.start(ordersSetup(seed: seed, serverManaged: serverManaged));
    deploy(battle);
    send(const EnterBattle(), origin: Origin.server);
  }

  /// The seed of the battle's random.
  final int seed;

  /// Whether the server runs `s-2`.
  final bool serverManaged;

  final clock = ManualClock(DateTime.utc(2026, 11, 2, 8));
  final wal = MemoryWriteAheadLog();
  late final SimulationHost host;
  late final Battle battle;

  /// The battle's log after its start entry: the entries of its orders and
  /// its timers.
  List<LogEntry> get entries => wal.read('b-1').entries.sublist(1);

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

  /// Moves the clock by [step] and brings the battle there.
  void wait(Duration step) {
    clock.advance(step);
    host.advance();
  }

  /// The unit [id].
  UnitState unit(String id) => battle.state.units[id]!;

  /// Changes the unit [id].
  void changeUnit(String id, UnitState Function(UnitState unit) change) =>
      battle.change((state) => state.withUnit(change(state.units[id]!)));

  /// Empties the AP pool of [id] now.
  void drain(String id) => changeUnit(
    id,
    (unit) => unit.copyWith(
      pool: ApPool(
        max: unit.pool.max,
        recoveryPerHour: unit.pool.recoveryPerHour,
        value: 0,
        updatedAt: battle.time,
      ),
    ),
  );
}

/// The position of the centre of [cell] on the valley's ground.
Position centreOf(Battle battle, CellRef cell) {
  final point = battle.orders.world.pointOf(cell);
  return Position.metres(point.x, point.y, point.z);
}

/// Everything [battle] holds, as its snapshot writes it: its state, time,
/// timers, random and sequence numbers.
String snapshotOf(Battle battle) =>
    utf8.decode(encodeSnapshot(battle.save(), startedAt: DateTime.utc(2026)));

/// The state of [battle], as its snapshot writes it.
String stateOf(Battle battle) => jsonEncode(
  (jsonDecode(snapshotOf(battle)) as Map<String, Object?>)['state'],
);

/// Replays the log of [live] on a new battle of the same setup, deployed
/// and changed by [prepare] as the live one was before its first order,
/// and checks that it gives the same events and reaches the same battle.
void expectReplay(OrdersFixture live, {void Function(Battle)? prepare}) {
  final battle = Battle.start(
    setup: ordersSetup(seed: live.seed, serverManaged: live.serverManaged),
    map: live.battle.map,
    definitions: planData,
  );
  deploy(battle);
  prepare?.call(battle);
  replay(battle, live.entries, from: 1);
  battle.advanceTo(live.battle.time);

  expect(snapshotOf(battle), equals(snapshotOf(live.battle)));
}
