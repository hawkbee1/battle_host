import 'dart:convert';

import 'package:battle_host/battle_host.dart';
import 'package:battle_pathfinding/battle_pathfinding.dart' show CellRef;
import 'package:battle_protocol/battle_protocol.dart';
import 'package:battle_rules/battle_rules.dart';
import 'package:test/test.dart';

import '../../helpers/plain.dart';
import '../../helpers/scripted_battle.dart';
import '../../helpers/view_holder.dart';

/// Every string a message holds, from its JSON encoding.
Set<String> _strings(Object? json) => switch (json) {
  final String text => {text},
  final List<Object?> list => {for (final item in list) ..._strings(item)},
  final Map<String, Object?> map => {
    for (final value in map.values) ..._strings(value),
  },
  _ => const {},
};

/// Checks, at every message, that it names no unit outside what the
/// section sees before and after it, its own units, and what every
/// section knows (MAP-29, MAP-49).
final class _Checker implements SectionSubscriber {
  new(this.battle, this.sectionId);

  final Battle battle;
  final String sectionId;
  final everyUnit = <String>{};
  final problems = <String>[];
  int updates = 0;
  int unseenHits = 0;
  Set<String> _units = {};
  Set<String> _hqs = {};

  @override
  void send(HostMessage message) {
    final state = battle.state;
    final sight = battle.orders.fog.of(sectionId);
    everyUnit.addAll(state.units.keys);
    final allowed = {
      ..._units,
      ...sight.units,
      for (final unit in state.units.values)
        if (unit.sectionId == sectionId) unit.id,
    };
    final named = _strings(
      jsonDecode(const JsonProtocolCodec().encodeHostMessage(message)),
    );
    for (final id in named.intersection(everyUnit).difference(allowed)) {
      problems.add('$sectionId at ${battle.time}: $id in $message');
    }
    if (message case TickUpdate(:final hqs, :final hqsGone)) {
      updates++;
      unseenHits += message.unseenHits.length;
      for (final team in [...hqs.map((hq) => hq.team), ...hqsGone]) {
        if (!_hqs.contains(team) && !sight.hqs.contains(team)) {
          problems.add('$sectionId at ${battle.time}: HQ $team');
        }
      }
    }
    _units = {...sight.units};
    _hqs = {...sight.hqs};
  }
}

void main() {
  group(UpdateStream, () {
    for (final weather in ['clear', 'fog']) {
      group('on the scripted battle in $weather weather', () {
        late ScriptedHost s;

        setUp(() async {
          s = ScriptedHost.alone();
          await s.begin();
          s.battle.change(
            (state) => BattleState(
              victory: state.victory,
              units: state.units,
              sections: state.sections,
              teams: state.teams,
              relics: state.relics,
              delta: state.delta,
              offers: state.offers,
              dropped: state.dropped,
              weather: weather,
            ),
          );
        });

        test('MAP-08 a subscriber that joins halfway, or again, holds the '
            'same view at the end as one present from the start', () {
          final early = {
            for (final id in ['s-1', 's-2']) id: ViewHolder(),
          };
          final late = {
            for (final id in ['s-1', 's-2']) id: ViewHolder(),
          };
          final again = {
            for (final id in ['s-1', 's-2']) id: ViewHolder(),
          };
          for (final MapEntry(:key, :value) in early.entries) {
            s.host.subscribe('b-1', key, value);
          }
          for (final MapEntry(:key, :value) in again.entries) {
            s.host.subscribe('b-1', key, value);
          }
          for (final (index, step) in script.indexed) {
            if (index == 10) {
              for (final holder in again.values) {
                s.host.unsubscribe('b-1', holder);
              }
            }
            if (index == script.length ~/ 2) {
              for (final MapEntry(:key, :value) in late.entries) {
                s.host.subscribe('b-1', key, value);
              }
            }
            if (index == 30) {
              for (final MapEntry(:key, :value) in again.entries) {
                s.host.subscribe('b-1', key, value);
              }
            }
            step(s);
          }

          for (final id in ['s-1', 's-2']) {
            expect(early[id]!.received.length, greaterThan(10));
            expect(late[id]!.held, equals(early[id]!.held), reason: id);
            expect(again[id]!.held, equals(early[id]!.held), reason: id);
          }
        });

        test('MAP-29 MAP-49 COMBAT-57 decisions 21 and 232 no update names a '
            'unit outside the section visible set at that time, but its '
            'own units', () {
          final checkers = [
            for (final id in ['s-1', 's-2']) _Checker(s.battle, id),
          ];
          for (final checker in checkers) {
            s.host.subscribe('b-1', checker.sectionId, checker);
          }
          for (final step in script) {
            step(s);
          }

          for (final checker in checkers) {
            expect(checker.problems, isEmpty);
            expect(checker.updates, greaterThan(5));
          }
        });
      });
    }

    group('relic alerts', () {
      late FogFixture f;

      setUp(() {
        f = FogFixture();
        f.battle.change((state) {
          final victory = state.victory!;
          return state
              .withRelic(state.relics['relic-1']!.copyWith(owner: 'team-1'))
              .withVictory(
                VictoryState(
                  relicOwners: {...victory.relicOwners, 'relic-1': 'team-1'},
                  teams: victory.teams,
                ),
              );
        });
        for (final id in ['commander-2', 'soldier-2', 'soldier-4']) {
          f.place(id, const CellRef(40, 1));
        }
      });

      void capture() {
        for (var i = 0; i < 10; i++) {
          final id = ['commander-2', 'soldier-2', 'soldier-4'][i % 3];
          f.send(
            Capture(unitId: id, relicId: 'relic-1'),
            section: 's-2',
          );
        }
        f.wait(const Duration(minutes: 31));
      }

      List<RelicAlert> alerts(ViewHolder holder) =>
          holder.received.whereType<RelicAlert>().toList();

      test('RELIC-10 decision 233 a relic captured alerts the previous owner '
          'team and nobody else; a player who connects afterwards receives '
          'the alert once', () {
        final one = ViewHolder();
        final two = ViewHolder();
        f.host
          ..subscribe('f-1', 's-1', one)
          ..subscribe('f-1', 's-2', two);

        capture();

        final alert = alerts(one).single;
        expect(alert.relicId, 'relic-1');
        expect(alert.team, 'team-2');
        expect(alerts(two), isEmpty);
        expect(f.battle.alerts.pending.keys, equals(['a-3']));

        final three = ViewHolder();
        f.host.subscribe('f-1', 's-3', three);
        expect(three.received.first, isA<SectionView>());
        expect(alerts(three), equals([alert]));

        final threeAgain = ViewHolder();
        f.host.subscribe('f-1', 's-3', threeAgain);
        expect(alerts(threeAgain), isEmpty);
      });

      test('decision 233 the alerts not received yet survive a restart, from '
          'the snapshot or from the log after it', () async {
        f.host.snapshot('f-1');
        capture();
        await f.host.settle();

        final replayed = f.hostOn(f.wal, f.logs, f.snapshots);
        await replayed.recover('f-1');
        expect(
          replayed['f-1']!.alerts.pending.keys,
          unorderedEquals(['a-1', 'a-3']),
        );

        f.host.snapshot('f-1');
        await f.host.settle();
        final restored = f.hostOn(f.wal, f.logs, f.snapshots);
        final battle = await restored.recover('f-1');
        expect(battle.alerts.pending, equals(f.battle.alerts.pending));

        final three = ViewHolder();
        restored.subscribe('f-1', 's-3', three);
        expect(alerts(three).single.relicId, 'relic-1');
      });

      test('HQ-07 a connection, its EnterBattle entry, clears the alerts of '
          'its player', () {
        capture();
        f.host.submit(
          'f-1',
          Command(
            sender: const Sender(accountId: 'a-3', sectionId: 's-3'),
            sentAt: f.battle.time,
            order: const EnterBattle(),
          ),
          origin: Origin.server,
        );

        expect(f.battle.alerts.pending.keys, equals(['a-1']));
      });
    });

    group('per event type', () {
      late FogFixture f;
      late UpdateStream stream;
      late Map<String, ViewHolder> holders;

      setUp(() {
        f = FogFixture()
          ..place('soldier-1', const CellRef(20, 15))
          ..place('soldier-2', const CellRef(25, 15))
          ..place('soldier-3', const CellRef(70, 15))
          ..place('soldier-4', const CellRef(78, 2));
        stream = UpdateStream(f.battle);
        holders = {
          for (final id in ['s-1', 's-2', 's-3']) id: ViewHolder(),
        };
        for (final MapEntry(:key, :value) in holders.entries) {
          stream.subscribe(key, value);
        }
      });

      /// The events of the next update of each section, by section.
      Map<String, List<BattleEvent>> heard(
        List<BattleEvent> events, {
        Command? command,
      }) {
        for (final holder in holders.values) {
          holder.received.clear();
        }
        stream
          ..hear(LogEntry(at: f.battle.time, command: command, events: events))
          ..flush();
        return {
          for (final MapEntry(:key, :value) in holders.entries)
            key: [
              for (final update in value.received.whereType<TickUpdate>())
                ...update.events,
            ],
        };
      }

      Set<String> sectionsOf(BattleEvent event, {Command? command}) => {
        for (final MapEntry(:key, :value) in heard([
          event,
        ], command: command).entries)
          if (value.contains(event)) key,
      };

      test('MAP-49 relics, the countdown, eliminations and the world go to '
          'every section', () {
        for (final event in [
          const RelicCaptured(relicId: 'relic-1', team: 'team-2'),
          const RelicLost(relicId: 'relic-2'),
          const CaptureLost(relicId: 'relic-1', team: 'team-2'),
          const VictoryHoldStarted(team: 'team-1', winsAt: Duration(days: 1)),
          const VictoryHoldReset(team: 'team-1'),
          const Eliminated(team: 'team-2', loss: HqLoss.destroyed),
          const BattleStarted(battleId: 'f-1', mapId: 'plain', seed: 3),
          const BattleEnded(
            winner: 'team-1',
            kind: WinKind.relics,
            eliminated: [],
          ),
          const StructureBuilt(siteId: 'w', structure: 'wall', cells: <Cell>[]),
          const ObjectDamaged(object: 'tree', cells: [], hp: 5),
          const ObjectDestroyed(object: 'tree', cells: []),
          CraterDug(at: Position.metres(1, 2, 0), radiusM: 8, depthM: 1),
        ]) {
          expect(sectionsOf(event), {'s-1', 's-2', 's-3'}, reason: '$event');
        }
      });

      test('a unit action, a purchase, storage and orders go to its own '
          'section only', () {
        for (final event in [
          const WeaponSwapped(
            unitId: 'soldier-1',
            weapon: 'rifle',
            readyAt: Duration(days: 1),
          ),
          const TimeOnlyStarted(
            unitId: 'soldier-1',
            action: TimeOnly.reload,
            endsAt: Duration(days: 1),
          ),
          const Embarked(unitId: 'soldier-1', transportId: 'truck-1'),
          Disembarked(unitId: 'soldier-1', at: Position.metres(0, 0, 0)),
          const BuildStarted(
            unitId: 'soldier-1',
            siteId: 'w',
            structure: 'wall',
            cells: [],
            endsAt: Duration(days: 1),
          ),
          const RepairStarted(
            unitId: 'soldier-1',
            targetId: 'truck-1',
            endsAt: Duration(days: 1),
          ),
          const WorkResumed(
            unitId: 'soldier-1',
            workId: 'w',
            endsAt: Duration(days: 1),
          ),
          const WorkInterrupted(unitId: 'soldier-1', workId: 'w'),
          const ObservationStarted(
            unitId: 'soldier-1',
            endsAt: Duration(days: 1),
          ),
          const AddedToCapture(
            unitId: 'soldier-1',
            relicId: 'relic-1',
            potAp: 5,
          ),
          const AddedToPush(unitId: 'soldier-1', relicId: 'relic-1', potAp: 5),
          const UnitStored(unitId: 'soldier-1'),
          const RecallBegan(unitId: 'soldier-1', storedAt: Duration(days: 1)),
          UnitDeployed(unitId: 'soldier-1', at: Position.metres(0, 0, 0)),
          const NodePurchased(unitId: 'soldier-1', stat: 'hp', step: 1),
          const SectionLocked(sectionId: 's-1', until: Duration(days: 1)),
          const UnitPurchased(
            sectionId: 's-1',
            unitId: 'unit-9',
            unitType: 'soldier',
            price: 100,
          ),
          const WeaponPurchased(sectionId: 's-1', weapon: 'rifle', price: 10),
          const SectionJoined(
            sectionId: 's-1',
            accountId: 'a-1',
            team: 'team-1',
            units: [],
          ),
        ]) {
          expect(sectionsOf(event), {'s-1'}, reason: '$event');
        }
        final command = const Command(
          sender: Sender(accountId: 'a-2', sectionId: 's-2'),
          sentAt: Duration.zero,
          order: Observe(unitId: 'soldier-2'),
        ).stamped(origin: Origin.player, seq: 77);
        expect(
          sectionsOf(
            const OrderRefused(seq: 77, reason: 'x'),
            command: command,
          ),
          {'s-2'},
        );
        expect(
          sectionsOf(const OrderDelayed(seq: 77, until: Duration(days: 1))),
          {'s-2'},
        );
      });

      test('transfers, offers and the HQ manager go to the sections they '
          'concern', () {
        expect(
          sectionsOf(
            const MoneyTransferred(
              fromSectionId: 's-1',
              toSectionId: 's-3',
              received: 5,
              fee: 0,
            ),
          ),
          {'s-1', 's-3'},
        );
        expect(
          sectionsOf(
            const OfferPosted(
              offerId: 9,
              captorSectionId: 's-2',
              ownerSectionId: 's-1',
              released: [],
              wanted: [],
              price: 5,
            ),
          ),
          {'s-1', 's-2'},
        );
        f.battle.change(
          (state) => state.withOffer(
            9,
            const RansomOffer(
              captorSectionId: 's-2',
              ownerSectionId: 's-1',
              released: [],
              price: 5,
            ),
          ),
        );
        expect(sectionsOf(const OfferAccepted(offerId: 9)), {'s-1', 's-2'});
        expect(sectionsOf(const OfferRefused(offerId: 8)), isEmpty);
        expect(
          sectionsOf(const ManagerChanged(team: 'team-1', accountId: 'a-3')),
          {'s-1', 's-3'},
        );
      });

      test('MAP-29 a move, a crush, a heal or a repair goes to the sections '
          'that know every unit it names', () {
        // s-1 and s-2 see each other; s-3 sees neither.
        for (final event in [
          const MoveStarted(moverId: 'soldier-2', arrivesAt: Duration.zero),
          MoveStopped(moverId: 'soldier-1', at: Position.metres(0, 0, 0)),
          const UnitHealed(unitId: 'soldier-1', targetId: 'soldier-2', hp: 9),
          const Repaired(targetId: 'soldier-2', hp: 9),
          const WeaponPickedUp(unitId: 'soldier-2', droppedId: 'w-1'),
          const Crushed(byId: 'relic-1', unitId: 'soldier-1', unitType: 'x'),
        ]) {
          expect(sectionsOf(event), {'s-1', 's-2'}, reason: '$event');
        }
        expect(
          sectionsOf(
            const MoveStarted(moverId: 'hq-team-1', arrivesAt: Duration.zero),
          ),
          {'s-1', 's-3'},
        );
      });

      test('a dropped weapon goes to the sections that see where it fell', () {
        final at = f.views.positionOf(const CellRef(22, 15));
        expect(
          sectionsOf(
            WeaponDropped(
              droppedId: 'w-1',
              weapon: 'rifle',
              at: at,
              goneAt: Duration.zero,
            ),
          ),
          {'s-1', 's-2'},
        );
      });

      test('COMBAT-57 decision 234 a shot by an unseen shooter shows only the '
          'hits on units the section knows', () {
        const shot = Attacked(
          attackerId: 'soldier-4',
          sectionId: 's-2',
          weapon: 'rifle',
          hit: true,
          impacts: [
            Impact(
              targetId: 'soldier-3',
              targetType: 'soldier',
              damage: 12,
              friendly: false,
              result: ImpactResult.damaged,
            ),
          ],
        );
        heard([shot]);

        final three = holders['s-3']!.received.whereType<TickUpdate>().single;
        expect(three.events, isEmpty);
        expect(three.unseenHits, equals(shot.impacts));
        expect(holders['s-1']!.received.whereType<TickUpdate>(), isEmpty);
      });

      test('stack decision 3 a unit shots of one update are grouped into one '
          'burst; a shot alone stays an event, cut to what it hits that the '
          'section knows', () {
        Attacked shot(String target, double damage) => Attacked(
          attackerId: 'soldier-2',
          sectionId: 's-2',
          weapon: 'machine_gun',
          hit: true,
          impacts: [
            Impact(
              targetId: target,
              targetType: 'soldier',
              damage: damage,
              friendly: false,
              result: ImpactResult.damaged,
            ),
          ],
        );
        heard([
          shot('soldier-1', 3),
          shot('soldier-1', 4),
          shot('soldier-3', 1),
        ]);
        final burst = holders['s-1']!.received
            .whereType<TickUpdate>()
            .single
            .bursts
            .single;
        expect(burst.shots, 3);
        expect(burst.hits, 2);
        expect(burst.impacts.single.damage, 7);

        heard([shot('soldier-3', 5)]);
        final alone =
            holders['s-1']!.received
                    .whereType<TickUpdate>()
                    .single
                    .events
                    .single
                as Attacked;
        expect(alone.impacts, isEmpty);
        expect(alone.hit, isFalse);
      });

      test('HQ-29 a unit stored leaves the other sections views, and stays '
          'in its own section view with its place', () {
        f.battle.change(
          (state) => state.withUnit(
            state.units['soldier-1']!.copyWith(
              location: const Stored(),
              clearCell: true,
            ),
          ),
        );
        heard(const []);

        final two = holders['s-2']!.received.whereType<TickUpdate>().single;
        expect(two.gone, equals(['soldier-1']));
        final one = holders['s-1']!.received.whereType<TickUpdate>().single;
        expect(one.ownUnits.single.private!.place, UnitPlace.stored);
        expect(holders['s-1']!.units['soldier-1']!.position, isNull);
      });

      test('an update holds nothing that did not change', () {
        heard(const []);
        for (final holder in holders.values) {
          expect(holder.received, isEmpty);
        }
      });

      test('throws an $ArgumentError for a section not in the battle', () {
        expect(
          () => stream.subscribe('s-9', ViewHolder()),
          throwsArgumentError,
        );
        expect(
          () => f.host.subscribe('nope', 's-1', ViewHolder()),
          throwsArgumentError,
        );
      });
    });
  });
}

extension on FogFixture {
  SectionViews get views => SectionViews(battle);
}
