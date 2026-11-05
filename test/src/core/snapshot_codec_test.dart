import 'dart:convert';
import 'dart:typed_data';

import 'package:battle_host/battle_host.dart';
import 'package:battle_map/battle_map.dart';
import 'package:battle_pathfinding/battle_pathfinding.dart';
import 'package:battle_protocol/battle_protocol.dart' as wire;
import 'package:battle_rules/battle_rules.dart';
import 'package:test/test.dart';

import '../../helpers/fixtures.dart';
import '../../helpers/orders.dart';

final _startedAt = DateTime.utc(2026, 11, 5, 9, 30);

Duration _s(int seconds) => Duration(seconds: seconds);

/// A battle whose state holds every variant a snapshot writes: each
/// location, timer, world change and offer, the optional values set.
Battle richBattle() {
  final battle = Battle.start(
    setup: ordersSetup(),
    map: MapLibrary(
      source: MemoryMapSource({'valley': valley}),
      terrain: planData.terrain,
    ).load('valley'),
    definitions: planData,
  );
  deploy(battle);
  final rifle = planData.combat.weaponTypes['rifle']!;
  battle.change((state) {
    UnitState unit(String id) => state.units[id]!;
    final team1 = state.teams['team-1']!;
    final team2 = state.teams['team-2']!;
    final victory = state.victory!;
    return state
        .withUnit(
          unit('soldier-1').copyWith(
            location: Deployed(recallDoneAt: _s(3600)),
            movingUntil: _s(5),
            work: Work(
              workId: 'wall@(3, 4)',
              action: TimedAction(
                ap: 5,
                duration: _s(600),
                progress: 0.25,
                startedAt: _s(1),
              ),
              structure: 'wall',
              cells: const [CellRef(3, 4)],
            ),
            xpHistory: XpHistory([
              (const FromTarget('soldier-2'), _s(2)),
              (const FromBuild(xM: 1.5, yM: 2.5), _s(3)),
            ]),
          ),
        )
        .withUnit(
          unit('medic-1')
              .copyWith(location: Carried('truck-1', recallDoneAt: _s(7200))),
        )
        .withUnit(unit('soldier-5').copyWith(location: const Prisoner('s-2')))
        .withUnit(
          unit('scout-1').copyWith(
            observation: Observation(
              role: const ObserveRole(
                visionBonusM: 50,
                durationS: 120,
                ap: 2,
                canMove: false,
              ),
              startedAt: _s(4),
            ),
          ),
        )
        .withUnit(unit('helicopter-1').copyWith(flying: true))
        .withUnit(
          unit('jeep-1').copyWith(
            tree: SkillTree({EvolvableStat.hp: 5}),
            xp: const UnitXp(earned: 1600.5, unspent: 100.25),
          ),
        )
        .withUnit(
          unit('artillery-1').copyWith(weapon: const WeaponState.unarmed()),
        )
        .withSection(
          SectionState(
            id: 's-1',
            accountId: 'a-1',
            team: 'team-1',
            money: 1234,
            xp: 56.5,
            medals: const {'gold': 1, 'silver': 3},
            guildId: 'g-1',
            guildChief: true,
            storedWeapons: const StoredWeapons(['machine_gun']),
            lockedUntil: _s(10800),
          ),
        )
        .withTeam(team1.withManager('a-1'))
        .withTeam(
          TeamState(
            id: 'team-2',
            hq: HqState(
              cell: team2.hq.cell,
              health: const Health(current: 10.5, max: 1000),
              pool: team2.hq.pool,
              movingUntil: _s(6),
            ),
            eliminated: true,
          ),
        )
        .withRelic(
          state.relics['relic-1']!.copyWith(
            owner: 'team-1',
            capturePot: () => CapturePot(
              team: 'team-2',
              contributions: const {'soldier-2': 5, 'soldier-3': 2.5},
              fullAt: _s(7),
            ),
            pushPot: () => const PushPot(owner: 'team-1', ap: 3),
            pushPath: () => const [CellRef(0, 3), CellRef(1, 3)],
            pushers: {'radio-1', 'scout-1'},
            push: () => RelicPush(
              cell: const CellRef(1, 3),
              reached: 1,
              endsAt: _s(8),
              pot: const PushPot(owner: 'team-1', ap: 1),
              crushed: const ['soldier-3'],
              landing: const CellRef(5, 5),
            ),
          ),
        )
        .withDropped(
          DroppedWeaponState(
            id: 'w-1',
            dropped: DroppedWeapon(weapon: rifle, goneAt: _s(9)),
            cell: const CellRef(2, 2),
          ),
        )
        .withDelta(
          const WorldDelta().withChanges(
            [
              const ObjectBuilt(CellRef(3, 4), 'wall'),
              const ObjectDestroyed(CellRef(1, 4), 'tree'),
              const ConstructionBuilt(CellRef(5, 5), 'road_segment'),
              const ConstructionDestroyed(CellRef(5, 5), 'road_segment'),
              const LinkBuilt(
                SurfaceLink(
                  kind: LinkKind.bridge,
                  from: CellRef(2, 2),
                  to: CellRef(2, 4),
                ),
              ),
              const LinkDestroyed(
                kind: LinkKind.bridge,
                from: CellRef(2, 2),
                to: CellRef(2, 4),
              ),
              const CraterDug(
                Crater(centreXM: 65, centreYM: 45, radiusM: 8, depthM: 1.5),
              ),
            ],
            built: const MapObject(
              id: 'wall@(3, 4)',
              type: 'wall',
              kind: FeatureKind.object,
              cells: [CellRef(3, 4)],
              hp: 200,
              armorType: 'structure',
            ),
            hp: ('wall@(3, 4)', 150.25),
          ),
        )
        .withOffer(
          5,
          const ExchangeOffer(
            captorSectionId: 's-1',
            ownerSectionId: 's-2',
            released: ['soldier-2'],
            wanted: ['soldier-5'],
          ),
        )
        .withOffer(
          6,
          const RansomOffer(
            captorSectionId: 's-1',
            ownerSectionId: 's-2',
            released: ['soldier-3'],
            price: 300,
          ),
        )
        .withVictory(
          VictoryState(
            relicOwners: {...victory.relicOwners, 'relic-1': 'team-1'},
            teams: const {'team-1'},
            hold: RelicHold(team: 'team-1', since: _s(1), winsAt: _s(10)),
            winner: const BattleWon(team: 'team-1', kind: VictoryKind.relics),
          ),
          eliminated: const ['team-2'],
        );
  });
  final command = const wire.Command(
    sender: wire.Sender(accountId: 'a-1', sectionId: 's-1'),
    sentAt: Duration.zero,
    order: wire.Heal(unitId: 'medic-1', targetId: 'soldier-1'),
  ).stamped(origin: wire.Origin.player, seq: battle.takeSeq());
  battle
    ..schedule(_s(100), const SectionUnlocks('s-1'))
    ..schedule(_s(30), RunOrder(command))
    ..schedule(_s(30), const WorkEnds('soldier-1'))
    ..schedule(_s(40), const RecallEnds('medic-1'))
    ..schedule(_s(50), const CaptureEnds('relic-1'))
    ..schedule(_s(60), const RelicArrives('relic-1'))
    ..schedule(_s(70), const HoldEnds())
    ..schedule(_s(80), const FlightEnds('helicopter-1', flying: false));
  battle.random.nextDouble();
  return battle;
}

void main() {
  group('the snapshot format', () {
    late Battle battle;
    late Uint8List data;

    setUp(() {
      battle = richBattle();
      data = encodeSnapshot(battle.save(), startedAt: _startedAt);
    });

    Battle restore(Uint8List data) => Battle.restore(
      decodeSnapshot(data, definitions: planData).memento,
      map: battle.map,
      definitions: planData,
    );

    test('a battle restored from its snapshot writes the same snapshot', () {
      final decoded = decodeSnapshot(data, definitions: planData);
      final restored = restore(data);

      expect(decoded.startedAt, _startedAt);
      expect(
        utf8.decode(encodeSnapshot(restored.save(), startedAt: _startedAt)),
        equals(utf8.decode(data)),
      );
      expect(restored.time, battle.time);
      expect(restored.timers, hasLength(8));
      expect(restored.random.state, battle.random.state);
      expect(restored.takeSeq(), battle.takeSeq());
      expect(
        restored.state.units['jeep-1']!.type.stats.hp,
        greaterThan(planData.units.unitTypes['jeep']!.stats.hp),
      );
    });

    test('a restored battle rebuilds its world from its delta layer', () {
      final restored = restore(data);

      expect(restored.world.ownsGrid, isTrue);
      expect(restored.world.navigation.craters, hasLength(1));
      expect(
        restored.world.navigation.objectsAt(const CellRef(3, 4)),
        contains('wall'),
      );
    });

    test('a battle is restored only on the map it names', () {
      final other = SharedMap.load(
        id: 'other',
        host: battle.map.host,
        terrain: planData.terrain,
      );

      expect(
        () => Battle.restore(battle.save(), map: other, definitions: planData),
        throwsArgumentError,
      );
    });

    group('refuses data that is not a snapshot of its version', () {
      Uint8List changed(void Function(Map<String, Object?> json) change) {
        final json = jsonDecode(utf8.decode(data)) as Map<String, Object?>;
        change(json);
        return utf8.encode(jsonEncode(json));
      }

      Map<String, Object?> at(Object? json, List<Object> path) {
        var node = json;
        for (final key in path) {
          node = key is int
              ? (node! as List<Object?>)[key]
              : (node! as Map<String, Object?>)[key as String];
        }
        return node! as Map<String, Object?>;
      }

      Map<String, Object?> unit(Map<String, Object?> json, String id) =>
          ((json['state']! as Map)['units']! as List)
              .cast<Map<String, Object?>>()
              .firstWhere((unit) => unit['id'] == id);

      final cases = <String, void Function(Map<String, Object?>)>{
        'another version': (json) => json['v'] = 2,
        'a value of the wrong kind': (json) => json['battle'] = 5,
        'an unknown timer': (json) =>
            at(json, ['timers', 0])['kind'] = 'meteor',
        'a waiting command the protocol does not read': (json) =>
            (json['timers']! as List).cast<Map<String, Object?>>().firstWhere(
              (timer) => timer['kind'] == 'runOrder',
            )['command'] = {
              'v': 1,
            },
        'an unknown unit type': (json) =>
            unit(json, 'soldier-1')['type'] = 'dragon',
        'an unknown stat': (json) => unit(json, 'jeep-1')['tree'] = {'luck': 1},
        'an unknown location': (json) =>
            at(unit(json, 'soldier-1'), ['location'])['kind'] = 'limbo',
        'an unknown weapon': (json) =>
            at(unit(json, 'soldier-1'), ['weapon'])['weapon'] = 'laser',
        'an unknown world change': (json) =>
            at(json, ['state', 'delta', 'changes', 0])['kind'] = 'quake',
        'an unknown link kind': (json) =>
            at(json, ['state', 'delta', 'changes', 4])['link'] = 'tunnel',
        'an unknown offer': (json) =>
            at(json, ['state', 'offers', 0])['kind'] = 'gift',
        'a cell that is not one': (json) =>
            unit(json, 'soldier-1')['cell'] = [1],
        'a list item of the wrong kind': (json) =>
            at(json, ['state'])['eliminated'] = [1],
        'a list of cells with a wrong one': (json) =>
            at(json, ['state', 'delta', 'built', 0])['cells'] = [5],
        'an object where none is': (json) => at(json, ['state'])['units'] = [1],
        'a map value of the wrong kind': (json) =>
            unit(json, 'jeep-1')['tree'] = {'hp': 'five'},
      };

      for (final MapEntry(key: name, value: change) in cases.entries) {
        test(name, () {
          final damaged = changed(change);

          expect(
            () => decodeSnapshot(damaged, definitions: planData),
            throwsFormatException,
          );
        });
      }

      test('not a JSON object', () {
        expect(
          () => decodeSnapshot(utf8.encode('[]'), definitions: planData),
          throwsFormatException,
        );
      });
    });
  });
}
