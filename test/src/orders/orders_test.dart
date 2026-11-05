import 'package:battle_host/battle_host.dart';
import 'package:battle_pathfinding/battle_pathfinding.dart';
import 'package:battle_protocol/battle_protocol.dart';
import 'package:battle_rules/battle_rules.dart';
import 'package:test/test.dart';

import '../../helpers/fixtures.dart';
import '../../helpers/orders.dart';

void main() {
  late OrdersFixture f;

  setUp(() => f = OrdersFixture());

  WeaponType weaponType(String id) => planData.combat.weaponTypes[id]!;

  void place(String id, CellRef cell) =>
      f.changeUnit(id, (unit) => unit.copyWith(cell: cell));

  void hurt(String id, double hp) => f.changeUnit(
    id,
    (unit) => unit.copyWith(
      health: Health(current: hp, max: unit.health.max),
    ),
  );

  String? refusalOf(Order order, {String section = 's-1'}) =>
      f.send(order, section: section, account: 'a-${section[2]}').refusal?.code;

  List<BattleEvent> eventsOf(Order order) {
    final handled = f.send(order);
    expect(handled.refusal, isNull, reason: '$order');
    return handled.events;
  }

  /// The events the battle made on its own since the last command.
  List<BattleEvent> hostEvents() => [
    for (final entry in f.entries.reversed.takeWhile((e) => e.command == null))
      ...entry.events,
  ];

  group('waiting orders (COMBAT-06, deferred from M4.11)', () {
    test('a waiting heal is carried out when its wait ends', () {
      hurt('soldier-1', 50);
      f.drain('medic-1');

      final events = eventsOf(
        const Heal(unitId: 'medic-1', targetId: 'soldier-1'),
      );
      final seq = f.entries.last.command!.seq!;
      expect(
        events,
        equals([OrderDelayed(seq: seq, until: const Duration(hours: 10))]),
      );
      expect(f.unit('soldier-1').health.current, equals(50));

      f.wait(const Duration(hours: 10));
      expect(
        hostEvents(),
        equals([
          const UnitHealed(unitId: 'medic-1', targetId: 'soldier-1', hp: 70),
        ]),
      );
      expect(f.entries.last.at, equals(const Duration(hours: 10)));
    });

    test('a waiting heal whose target died before the wait ends is refused '
        'when it ends', () {
      hurt('soldier-1', 50);
      f
        ..drain('medic-1')
        ..send(const Heal(unitId: 'medic-1', targetId: 'soldier-1'));
      final seq = f.entries.last.command!.seq!;

      f.wait(const Duration(hours: 5));
      f.battle.change((state) => state.withoutUnit('soldier-1'));
      f.wait(const Duration(hours: 5));

      expect(
        hostEvents(),
        equals([OrderRefused(seq: seq, reason: 'unknown_target')]),
      );
      expect(f.unit('medic-1').pool.apAt(f.battle.time), equals(10));
    });
  });

  group('movement', () {
    test('MAP-04 a move without a path follows a searched one', () {
      final events = eventsOf(
        Move(unitId: 'soldier-1', to: centreOf(f.battle, const CellRef(4, 1))),
      );

      final soldier = f.unit('soldier-1');
      expect(soldier.cell, equals(const CellRef(4, 1)));
      final arrives = soldier.movingUntil!;
      expect(
        events,
        equals([MoveStarted(moverId: 'soldier-1', arrivesAt: arrives)]),
      );
      expect(arrives, greaterThan(Duration.zero));
      expect(soldier.pool.apAt(arrives), lessThan(30));
    });

    test('stack decision 8 checks the client path cell by cell', () {
      expect(
        refusalOf(
          Move(
            unitId: 'soldier-1',
            to: centreOf(f.battle, const CellRef(1, 0)),
            path: const [Cell(1, 2), Cell(1, 1), Cell(1, 0)],
          ),
        ),
        isNull,
      );
      expect(
        refusalOf(
          Move(
            unitId: 'jeep-1',
            to: centreOf(f.battle, const CellRef(6, 2)),
            path: const [Cell(4, 2), Cell(5, 2), Cell(6, 2)],
          ),
        ),
        equals('impassable'),
      );
      expect(
        refusalOf(
          Move(
            unitId: 'jeep-1',
            to: centreOf(f.battle, const CellRef(4, 1)),
            path: const [Cell(3, 1), Cell(4, 1)],
          ),
        ),
        equals('path_not_from_mover'),
      );
      expect(
        refusalOf(
          Move(
            unitId: 'jeep-1',
            to: centreOf(f.battle, const CellRef(4, 1)),
            path: const [Cell(4, 2), Cell(40, 1)],
          ),
        ),
        equals('off_map'),
      );
    });

    test('refuses a goal off the map or out of reach', () {
      expect(
        refusalOf(Move(unitId: 'soldier-1', to: Position.metres(-50, 10, 10))),
        equals('off_map'),
      );
      expect(
        refusalOf(
          Move(unitId: 'jeep-1', to: centreOf(f.battle, const CellRef(8, 0))),
        ),
        isNull,
      );
      expect(
        refusalOf(
          Move(unitId: 'jeep-1', to: centreOf(f.battle, const CellRef(11, 7))),
        ),
        equals('no_path'),
      );
    });

    test('a carried unit and a unit with a loaded artillery piece do not '
        'move', () {
      final to = centreOf(f.battle, const CellRef(1, 1));
      expect(
        refusalOf(Move(unitId: 'artillery-1', to: to)),
        equals('weapon_loaded'),
      );
      place('medic-1', const CellRef(2, 2));
      f.send(const Embark(unitId: 'medic-1', transportId: 'truck-1'));
      expect(refusalOf(Move(unitId: 'medic-1', to: to)), equals('carried'));
    });

    test('COMBAT-09 a move interrupts a build: its AP are lost, its progress '
        'kept, and any unit may resume it', () {
      eventsOf(
        const Build(
          unitId: 'engineer-1',
          structure: 'wall',
          cells: [Cell(3, 4)],
        ),
      );
      f.wait(const Duration(minutes: 1));

      final events = eventsOf(
        Move(unitId: 'engineer-1', to: centreOf(f.battle, const CellRef(2, 4))),
      );
      expect(
        events.last,
        equals(
          const WorkInterrupted(unitId: 'engineer-1', workId: 'wall@(3, 4)'),
        ),
      );
      final work = f.unit('engineer-1').work!;
      expect(work.action.startedAt, isNull);
      expect(work.action.progress, greaterThan(0));

      expect(
        refusalOf(const Resume(unitId: 'soldier-1', workId: 'trap@(0, 0)')),
        equals('unknown_work'),
      );
      final resumed = eventsOf(
        const Resume(unitId: 'soldier-1', workId: 'wall@(3, 4)'),
      );
      expect(
        resumed,
        equals([
          WorkResumed(
            unitId: 'soldier-1',
            workId: 'wall@(3, 4)',
            endsAt: f.battle.time + const Duration(minutes: 4),
          ),
        ]),
      );
      expect(f.unit('engineer-1').work, isNull);
      f.wait(const Duration(minutes: 4));
      expect(hostEvents().single, isA<StructureBuilt>());
    });

    test('HQ-10 the manager moves the HQ', () {
      final free = eventsOf(
        MoveHq(to: centreOf(f.battle, const CellRef(1, 0))),
      );
      expect(free.single, isA<MoveStarted>());
      expect(f.battle.state.teams['team-1']!.hq.cell, const CellRef(1, 0));
      expect(
        refusalOf(MoveHq(to: Position.metres(-5, 5, 10))),
        equals('off_map'),
      );
    });

    test('HQ-12 a unit in the path of the HQ ends its move order', () {
      final blocked = eventsOf(
        MoveHq(
          to: centreOf(f.battle, const CellRef(3, 0)),
          path: const [Cell(0, 0), Cell(1, 0), Cell(2, 0), Cell(3, 0)],
        ),
      );
      expect(blocked, hasLength(2));
      expect(
        blocked.last,
        equals(
          MoveStopped(
            moverId: hqId('team-1'),
            at: centreOf(f.battle, const CellRef(1, 0)),
          ),
        ),
      );
      expect(f.battle.state.teams['team-1']!.hq.cell, const CellRef(1, 0));
    });

    test('MAP-38 a radio moves on a floating island like any unit; an '
        'encampment never goes onto one', () {
      final island = centreOf(f.battle, const CellRef(9, 5, surface: 'sky'));
      place('radio-1', const CellRef(9, 5, surface: 'sky'));
      f.changeUnit(
        'camp-1',
        (unit) => unit.copyWith(
          location: const Deployed(),
          cell: const CellRef(9, 4),
        ),
      );

      expect(
        refusalOf(Move(unitId: 'camp-1', to: island)),
        'island_unreachable',
      );
      expect(
        refusalOf(
          Move(
            unitId: 'camp-1',
            to: centreOf(f.battle, const CellRef(9, 4)),
            path: const [
              Cell(9, 4),
              Cell(9, 5, island: 'sky'),
              Cell(9, 4),
            ],
          ),
        ),
        'island_unreachable',
      );
      final across = centreOf(f.battle, const CellRef(10, 5, surface: 'sky'));
      expect(refusalOf(Move(unitId: 'radio-1', to: across)), isNull);
      expect(f.unit('radio-1').cell, const CellRef(10, 5, surface: 'sky'));
    });
  });

  group('no order, no action', () {
    test('AI-01 decision 156 a unit without an order does nothing, even with '
        'an enemy in sight', () {
      final before = stateOf(f.battle);

      f.wait(const Duration(hours: 3));
      expect(f.entries.where((entry) => entry.command == null), isEmpty);
      expect(stateOf(f.battle), equals(before));
    });

    test(
      "AI-02 an offline player's unit stays passive and can be attacked",
      () {
        expect(f.battle.state.teams['team-2']!.managerAccountId, isNull);
        eventsOf(const Fire(unitId: 'commander-1', targetId: 'soldier-2'));

        f.wait(const Duration(hours: 3));
        expect(hostEvents(), isEmpty);
        expect(f.unit('soldier-2').weapon.rounds, equals(10));
      },
    );
  });

  group('the HQ manager', () {
    void join(String section, String account, Map<String, int> medals) =>
        f.battle.change(
          (state) => state.withSection(
            SectionState(
              id: section,
              accountId: account,
              team: 'team-1',
              money: 0,
              xp: 0,
              medals: medals,
            ),
          ),
        );

    List<BattleEvent> logIn(String section, String account) => f
        .send(
          const EnterBattle(),
          section: section,
          account: account,
          origin: Origin.server,
        )
        .events;

    test('HQ-07 decision 220 the first player of a team to log in manages '
        'its HQ', () {
      expect(
        logIn('s-2', 'a-2'),
        equals([const ManagerChanged(team: 'team-2', accountId: 'a-2')]),
      );
      expect(f.battle.state.teams['team-2']!.managerAccountId, 'a-2');
      expect(logIn('s-2', 'a-2'), isEmpty);
    });

    test('HQ-07 decision 220 a higher-ranking player who logs in takes the '
        'role; a lower-ranking one does not', () {
      join('s-3', 'a-3', {'gold': 1});
      join('s-4', 'a-4', {});
      // a-1 outranks a-4 on his commander's XP.
      f.changeUnit(
        'commander-1',
        (unit) => unit.copyWith(xp: const UnitXp(earned: 100)),
      );

      expect(logIn('s-4', 'a-4'), isEmpty);
      expect(
        logIn('s-3', 'a-3'),
        equals([const ManagerChanged(team: 'team-1', accountId: 'a-3')]),
      );
      expect(logIn('s-1', 'a-1'), isEmpty);
      expect(
        refusalOf(MoveHq(to: centreOf(f.battle, const CellRef(1, 0)))),
        equals('not_manager'),
      );
    });

    test('decision 220 only the server tells that a player logs in', () {
      final refusal = f
          .send(const EnterBattle(), section: 's-2', account: 'a-2')
          .refusal!;
      expect((refusal.link, refusal.code), (CheckLink.right, 'not_server'));
      expect(f.battle.state.teams['team-2']!.managerAccountId, isNull);
    });
  });

  group('shots', () {
    test('COMBAT-11 a unit fires at a target it sees', () {
      final events = eventsOf(
        const Fire(unitId: 'commander-1', targetId: 'soldier-2'),
      );

      final attack = events.single as Attacked;
      expect(attack.attackerId, equals('commander-1'));
      expect(attack.weapon, equals('rifle'));
      expect(f.unit('commander-1').weapon.rounds, equals(9));
      expect(f.unit('commander-1').pool.apAt(f.battle.time), equals(28));
    });

    test('COMBAT-11 a unit does not fire at what it does not see', () {
      place('soldier-1', const CellRef(7, 2));
      place('soldier-2', const CellRef(9, 2));

      expect(
        refusalOf(const Fire(unitId: 'soldier-1', targetId: 'soldier-2')),
        equals('target_not_seen'),
      );
      expect(
        refusalOf(const Fire(unitId: 'soldier-1', targetId: 'ghost')),
        equals('unknown_target'),
      );
      expect(
        refusalOf(const Fire(unitId: 'radio-1', targetId: 'soldier-2')),
        equals('no_weapon'),
      );
    });

    test('a target beyond the range of the weapon is out of range', () {
      f.changeUnit(
        'engineer-1',
        (unit) =>
            unit.copyWith(weapon: WeaponState.ready(weaponType('explosive'))),
      );

      expect(
        refusalOf(const Fire(unitId: 'engineer-1', targetId: 'soldier-2')),
        equals('out_of_range'),
      );
    });

    test(
      'COMBAT-25 a weapon with no airborne factor cannot fire at a flyer',
      () {
        f.changeUnit('helicopter-1', (unit) => unit.copyWith(flying: true));

        expect(
          refusalOf(
            const Fire(unitId: 'artillery-1', targetId: 'helicopter-1'),
          ),
          equals('cannot_hit_flying'),
        );
      },
    );

    test('COMBAT-34 a charge hurts every unit around it, friend or foe, and '
        'a killed unit drops its weapon (COMBAT-29)', () {
      f.changeUnit(
        'engineer-1',
        (unit) =>
            unit.copyWith(weapon: WeaponState.ready(weaponType('explosive'))),
      );
      place('soldier-2', const CellRef(2, 3));

      final events = eventsOf(
        FireAtPosition(
          unitId: 'engineer-1',
          target: centreOf(f.battle, const CellRef(2, 3)),
        ),
      );

      final attack = events.first as Attacked;
      expect(attack.hit, isTrue);
      expect(
        attack.impacts.map((i) => (i.targetId, i.friendly, i.result)),
        unorderedEquals([
          ('engineer-1', true, ImpactResult.killed),
          ('soldier-2', false, ImpactResult.killed),
        ]),
      );
      expect(events.whereType<WeaponDropped>(), hasLength(2));
      expect(f.battle.state.units, isNot(contains('soldier-2')));
      expect(f.battle.state.dropped, hasLength(2));
    });

    test('COMBAT-12 indirect fire needs a position its section sees or a '
        'scout reports', () {
      final events = eventsOf(
        FireAtPosition(
          unitId: 'artillery-1',
          target: centreOf(f.battle, const CellRef(6, 2)),
        ),
      );
      expect(events.first, isA<Attacked>());

      expect(
        refusalOf(
          FireAtPosition(
            unitId: 'soldier-1',
            target: centreOf(f.battle, const CellRef(6, 2)),
          ),
        ),
        equals('not_indirect'),
      );
      expect(
        refusalOf(
          FireAtPosition(
            unitId: 'artillery-1',
            target: Position.metres(-9, 9, 9),
          ),
        ),
        equals('off_map'),
      );
    });

    test('COMBAT-12 a position nobody sees nor reports cannot be targeted', () {
      f.battle.change(
        (state) => BattleState(
          units: state.units,
          sections: state.sections,
          teams: state.teams,
          relics: state.relics,
          weather: 'fog',
        ),
      );
      for (final id in ['commander-1', 'soldier-1', 'medic-1', 'engineer-1']) {
        place(id, const CellRef(0, 7));
      }
      place('scout-1', const CellRef(0, 6));

      expect(
        refusalOf(
          FireAtPosition(
            unitId: 'artillery-1',
            target: centreOf(f.battle, const CellRef(11, 7)),
          ),
        ),
        equals('position_not_seen'),
      );
      f.changeUnit(
        'engineer-1',
        (unit) =>
            unit.copyWith(weapon: WeaponState.ready(weaponType('explosive'))),
      );
      expect(
        refusalOf(
          FireAtPosition(
            unitId: 'engineer-1',
            target: centreOf(f.battle, const CellRef(11, 7)),
          ),
        ),
        equals('out_of_range'),
      );
    });

    test('COMBAT-14 decision 183 a first-person shot flies to the first hit '
        'volume on its path', () {
      // The helicopter stands between the jeep and the truck.
      final hit =
          eventsOf(
                FireAimed(
                  unitId: 'jeep-1',
                  aim: Direction.of(-1, 0, 0),
                  fireTime: f.battle.time,
                ),
              ).single
              as Attacked;
      expect(hit.hit, isTrue);
      expect(hit.impacts.single.targetId, equals('helicopter-1'));
      f.wait(const Duration(seconds: 1));

      final up =
          eventsOf(
                FireAimed(
                  unitId: 'jeep-1',
                  aim: Direction.of(0, 0, 1),
                  fireTime: f.battle.time,
                ),
              ).single
              as Attacked;
      expect(up.hit, isFalse);
      expect(up.impacts, isEmpty);

      expect(
        refusalOf(
          FireAimed(
            unitId: 'artillery-1',
            aim: Direction.of(1, 0, 0),
            fireTime: f.battle.time,
          ),
        ),
        equals('not_aimed'),
      );
    });

    test('COMBAT-14 a first-person shot hits an HQ and an obstacle', () {
      place('soldier-1', const CellRef(3, 1));
      final hq =
          eventsOf(
                FireAimed(
                  unitId: 'soldier-1',
                  aim: Direction.of(-3, -1, 0),
                  fireTime: f.battle.time,
                ),
              ).single
              as Attacked;
      expect(hq.impacts.single.targetId, equals(hqId('team-1')));
      expect(hq.impacts.single.friendly, isTrue);
      expect(
        f.battle.state.teams['team-1']!.hq.health.current,
        lessThan(planData.battle.hq.hp),
      );

      place('soldier-1', const CellRef(7, 2));
      place('soldier-2', const CellRef(9, 2));
      f.wait(const Duration(seconds: 2));
      final events = eventsOf(
        FireAimed(
          unitId: 'soldier-1',
          aim: Direction.of(1, 0, 0),
          fireTime: f.battle.time,
        ),
      );
      expect((events.first as Attacked).hit, isFalse);
      // MAP-10: the building that stopped the shot takes its hit.
      expect((events.last as ObjectDamaged).object, equals('building'));
    });

    group('COMBAT-38 the final blow of a commander', () {
      /// The result of commander-1's final blow on soldier-2, a beaten
      /// soldier at 1 HP, in a battle of [seed], when its section has
      /// [room] for one more unit (UNIT-39).
      ImpactResult finalBlow(int seed, {required bool room}) {
        f = OrdersFixture(seed: seed)
          ..changeUnit(
            'soldier-2',
            (unit) => unit.copyWith(
              health: Health(current: 1, max: unit.health.max),
              morale: 0,
              pool: ApPool(
                max: 30,
                recoveryPerHour: 1,
                value: 0,
                updatedAt: Duration.zero,
              ),
            ),
          );
        place('commander-1', const CellRef(7, 2));
        if (room) {
          // Level 60: room beside the section's 13 units.
          f.battle.change(
            (state) => state.withSection(
              const SectionState(
                id: 's-1',
                accountId: 'a-1',
                team: 'team-1',
                money: 0,
                xp: 1000000000,
              ),
            ),
          );
        }
        for (var shot = 0; shot < 10; shot++) {
          final attack =
              eventsOf(
                    FireAimed(
                      unitId: 'commander-1',
                      aim: Direction.of(-1, 0, 0),
                      fireTime: f.battle.time,
                    ),
                  ).first
                  as Attacked;
          if (attack.hit) return attack.impacts.single.result;
          f.wait(const Duration(seconds: 2));
        }
        throw StateError('no hit in 10 shots');
      }

      test('may kill its target', () {
        expect(finalBlow(5, room: true), ImpactResult.killed);
        expect(f.battle.state.units, isNot(contains('soldier-2')));
      });

      test('may take it prisoner', () {
        expect(finalBlow(11, room: true), ImpactResult.prisoner);
        expect(f.unit('soldier-2').location, isA<Prisoner>());
      });

      test('may turn it into a unit of its section', () {
        expect(finalBlow(1, room: true), ImpactResult.defected);
        expect(f.unit('soldier-2').sectionId, equals('s-1'));
      });

      test('UNIT-39 takes it prisoner instead when the section is full', () {
        expect(finalBlow(1, room: false), ImpactResult.prisoner);
      });
    });

    test('COMBAT-11 a unit fires at an HQ and at a moving unit', () {
      final hq = eventsOf(Fire(unitId: 'commander-1', targetId: hqId('team-2')))
          .single;
      expect(hq, isA<Attacked>());
      expect(
        refusalOf(Fire(unitId: 'commander-1', targetId: hqId('team-9'))),
        equals('unknown_target'),
      );

      f
        ..send(
          Move(
            unitId: 'soldier-2',
            to: centreOf(f.battle, const CellRef(6, 0)),
          ),
          section: 's-2',
          account: 'a-2',
        )
        ..wait(const Duration(seconds: 2));
      expect(f.unit('soldier-2').movingUntil, greaterThan(f.battle.time));
      expect(
        eventsOf(const Fire(unitId: 'commander-1', targetId: 'soldier-2')),
        hasLength(1),
      );
    });

    test('an unarmed unit fires at nothing', () {
      expect(
        refusalOf(
          FireAtPosition(
            unitId: 'radio-1',
            target: centreOf(f.battle, const CellRef(6, 2)),
          ),
        ),
        equals('no_weapon'),
      );
      expect(
        refusalOf(
          FireAimed(
            unitId: 'radio-1',
            aim: Direction.of(1, 0, 0),
            fireTime: f.battle.time,
          ),
        ),
        equals('no_weapon'),
      );
    });

    test('UNIT-28 a commander killed goes to storage, whole', () {
      hurt('commander-2', 1);
      f.changeUnit(
        'engineer-1',
        (unit) =>
            unit.copyWith(weapon: WeaponState.ready(weaponType('explosive'))),
      );
      place('commander-2', const CellRef(2, 3));

      eventsOf(
        FireAtPosition(
          unitId: 'engineer-1',
          target: centreOf(f.battle, const CellRef(2, 3)),
        ),
      );

      final commander = f.unit('commander-2');
      expect(commander.location, isA<Stored>());
      expect(commander.cell, isNull);
      expect(commander.health.current, equals(commander.health.max));
    });

    test('COMBAT-54 units in a transport take a share of its hits', () {
      place('medic-1', const CellRef(2, 2));
      f.send(const Embark(unitId: 'medic-1', transportId: 'truck-1'));
      place('soldier-1', const CellRef(0, 7));
      f.changeUnit(
        'jeep-1',
        (unit) => unit.copyWith(cell: const CellRef(1, 2), sectionId: 's-2'),
      );

      Attacked? hit;
      for (var shot = 0; shot < 10 && hit == null; shot++) {
        final attack =
            f
                    .send(
                      FireAimed(
                        unitId: 'jeep-1',
                        aim: Direction.of(1, 0, 0),
                        fireTime: f.battle.time,
                      ),
                      section: 's-2',
                      account: 'a-2',
                    )
                    .events
                    .first
                as Attacked;
        if (attack.hit) hit = attack;
        f.wait(const Duration(seconds: 1));
      }

      expect(
        hit!.impacts.map((impact) => impact.targetId),
        equals(['truck-1', 'medic-1']),
      );
    });
  });

  group('weapons', () {
    test(
      'COMBAT-33 a reload gives a full magazine after its time, with no AP',
      () {
        f.changeUnit(
          'jeep-1',
          (unit) => unit.copyWith(
            weapon: WeaponState(
              weapon: weaponType('machine_gun'),
              rounds: 3,
              loaded: true,
              busyUntil: Duration.zero,
              nextShotAt: Duration.zero,
            ),
          ),
        );

        expect(
          eventsOf(const Reload(unitId: 'jeep-1')),
          equals([
            const TimeOnlyStarted(
              unitId: 'jeep-1',
              action: TimeOnly.reload,
              endsAt: Duration(seconds: 8),
            ),
          ]),
        );
        expect(f.unit('jeep-1').weapon.rounds, equals(100));
        expect(f.unit('jeep-1').pool.apAt(f.battle.time), equals(30));
      },
    );

    test('COMBAT-05 an unload takes its time', () {
      expect(
        eventsOf(const UnloadWeapon(unitId: 'artillery-1')),
        equals([
          const TimeOnlyStarted(
            unitId: 'artillery-1',
            action: TimeOnly.unloadWeapon,
            endsAt: Duration(seconds: 30),
          ),
        ]),
      );
      expect(f.unit('artillery-1').weapon.loaded, isFalse);
    });

    test(
      'COMBAT-28 a swap takes a stored weapon next to the storage place',
      () {
        f.battle.change(
          (state) => state.withSection(
            state.sections['s-1']!.withWeapons(
              const StoredWeapons(['machine_gun']),
            ),
          ),
        );
        expect(
          refusalOf(
            const SwapWeapon(unitId: 'soldier-1', weapon: 'machine_gun'),
          ),
          equals('not_at_storage'),
        );

        place('soldier-1', const CellRef(0, 1));
        expect(
          eventsOf(
            const SwapWeapon(unitId: 'soldier-1', weapon: 'machine_gun'),
          ),
          equals([
            const WeaponSwapped(
              unitId: 'soldier-1',
              weapon: 'machine_gun',
              readyAt: Duration(seconds: 5),
            ),
          ]),
        );
        expect(f.unit('soldier-1').weapon.weapon!.id, equals('machine_gun'));
        expect(f.unit('soldier-1').weapon.loaded, isFalse);
        expect(
          f.battle.state.sections['s-1']!.storedWeapons.weapons,
          equals(['rifle']),
        );
      },
    );

    test('COMBAT-30 a unit picks up a dropped weapon on the spot, for AP', () {
      f.battle.change(
        (state) => state.withDropped(
          DroppedWeaponState(
            id: 'w-x',
            dropped: DroppedWeapon(
              weapon: weaponType('machine_gun'),
              goneAt: const Duration(hours: 1),
            ),
            cell: const CellRef(1, 2),
          ),
        ),
      );
      expect(
        refusalOf(const PickUpWeapon(unitId: 'medic-1', droppedId: 'w-x')),
        equals('not_on_the_spot'),
      );

      final events = eventsOf(
        const PickUpWeapon(unitId: 'soldier-1', droppedId: 'w-x'),
      );
      expect(
        events.first,
        equals(const WeaponPickedUp(unitId: 'soldier-1', droppedId: 'w-x')),
      );
      expect((events.last as WeaponDropped).weapon, equals('rifle'));
      expect(f.unit('soldier-1').weapon.weapon!.id, equals('machine_gun'));
      expect(f.battle.state.dropped.keys, isNot(contains('w-x')));

      f.wait(const Duration(hours: 2));
      final own = f.battle.state.dropped.keys.single;
      expect(
        refusalOf(PickUpWeapon(unitId: 'soldier-1', droppedId: own)),
        equals('unknown_dropped'),
      );
    });
  });

  group('flight and transports', () {
    test('COMBAT-05 a take-off and a landing take their time', () {
      expect(
        eventsOf(const TakeOff(unitId: 'helicopter-1')).single,
        equals(
          const TimeOnlyStarted(
            unitId: 'helicopter-1',
            action: TimeOnly.takeOff,
            endsAt: Duration(seconds: 8),
          ),
        ),
      );
      expect(f.unit('helicopter-1').flying, isFalse);
      f.wait(const Duration(seconds: 8));
      expect(f.unit('helicopter-1').flying, isTrue);
      expect(
        refusalOf(const TakeOff(unitId: 'helicopter-1')),
        'already_flying',
      );

      eventsOf(const Land(unitId: 'helicopter-1'));
      f.wait(const Duration(seconds: 8));
      expect(f.unit('helicopter-1').flying, isFalse);
      expect(refusalOf(const Land(unitId: 'helicopter-1')), 'not_flying');
      expect(refusalOf(const TakeOff(unitId: 'jeep-1')), 'cannot_fly');
    });

    test(
      'a flight that ends after its unit left the field changes nothing',
      () {
        eventsOf(const TakeOff(unitId: 'helicopter-1'));
        f.battle.change((state) => state.withoutUnit('helicopter-1'));

        f.wait(const Duration(seconds: 8));
        expect(f.battle.state.units, isNot(contains('helicopter-1')));
      },
    );

    test('UNIT-37 a transport carries friendly units by weight', () {
      for (final id in [
        'commander-1',
        'soldier-1',
        'medic-1',
        'engineer-1',
        'scout-1',
        'soldier-4',
        'soldier-5',
      ]) {
        f.changeUnit(
          id,
          (unit) => unit.copyWith(
            location: const Deployed(),
            cell: const CellRef(2, 2),
          ),
        );
      }
      for (final id in [
        'commander-1',
        'soldier-1',
        'medic-1',
        'engineer-1',
        'scout-1',
        'soldier-4',
      ]) {
        expect(
          eventsOf(Embark(unitId: id, transportId: 'truck-1')),
          equals([Embarked(unitId: id, transportId: 'truck-1')]),
        );
      }
      expect(
        refusalOf(const Embark(unitId: 'soldier-5', transportId: 'truck-1')),
        equals('transport_full'),
      );
      place('artillery-1', const CellRef(2, 2));
      expect(
        refusalOf(const Embark(unitId: 'artillery-1', transportId: 'truck-1')),
        equals('too_heavy'),
      );
      place('radio-1', const CellRef(2, 2));
      expect(
        refusalOf(const Embark(unitId: 'radio-1', transportId: 'truck-1')),
        equals('not_transportable'),
      );
      place('jeep-1', const CellRef(2, 2));
      expect(
        refusalOf(const Embark(unitId: 'soldier-5', transportId: 'jeep-1')),
        equals('not_a_transport'),
      );
      expect(
        refusalOf(const Embark(unitId: 'soldier-5', transportId: 'soldier-2')),
        equals('target_not_friendly'),
      );
      expect(
        refusalOf(const Embark(unitId: 'soldier-5', transportId: 'ghost')),
        equals('unknown_target'),
      );
      place('soldier-5', const CellRef(4, 4));
      expect(
        refusalOf(const Embark(unitId: 'soldier-5', transportId: 'truck-1')),
        equals('too_far'),
      );

      eventsOf(
        Move(unitId: 'truck-1', to: centreOf(f.battle, const CellRef(3, 1))),
      );
      expect(f.unit('medic-1').cell, equals(const CellRef(3, 1)));
      expect(
        eventsOf(const Disembark(unitId: 'medic-1')),
        equals([
          Disembarked(
            unitId: 'medic-1',
            at: centreOf(f.battle, const CellRef(3, 1)),
          ),
        ]),
      );
      expect(refusalOf(const Disembark(unitId: 'medic-1')), 'not_carried');
    });

    test('no unit gets in or out of a flying transport', () {
      place('medic-1', const CellRef(2, 2));
      f
        ..send(const Embark(unitId: 'medic-1', transportId: 'truck-1'))
        ..changeUnit('truck-1', (unit) => unit.copyWith(flying: true));
      place('soldier-1', const CellRef(2, 2));

      expect(
        refusalOf(const Embark(unitId: 'soldier-1', transportId: 'truck-1')),
        equals('transport_flying'),
      );
      expect(
        refusalOf(const Disembark(unitId: 'medic-1')),
        equals('transport_flying'),
      );
    });
  });

  group('role actions', () {
    test('COMBAT-07 a build is paid up front and done after its time', () {
      expect(
        eventsOf(
          const Build(
            unitId: 'engineer-1',
            structure: 'wall',
            cells: [Cell(3, 4)],
          ),
        ),
        equals([
          const BuildStarted(
            unitId: 'engineer-1',
            siteId: 'wall@(3, 4)',
            structure: 'wall',
            cells: [Cell(3, 4)],
            endsAt: Duration(minutes: 5),
          ),
        ]),
      );
      expect(f.unit('engineer-1').pool.apAt(f.battle.time), equals(20));

      f.wait(const Duration(minutes: 5));
      expect(
        hostEvents(),
        equals([
          const StructureBuilt(
            siteId: 'wall@(3, 4)',
            structure: 'wall',
            cells: [Cell(3, 4)],
          ),
        ]),
      );
      expect(f.battle.state.delta.built, contains('wall@(3, 4)'));
      expect(f.unit('engineer-1').work, isNull);
    });

    test('a build is refused off its role, off the map or out of reach', () {
      expect(
        refusalOf(
          const Build(
            unitId: 'soldier-1',
            structure: 'wall',
            cells: [Cell(1, 1)],
          ),
        ),
        equals('not_in_actions'),
      );
      expect(
        refusalOf(
          const Build(
            unitId: 'engineer-1',
            structure: 'building',
            cells: [Cell(3, 4)],
          ),
        ),
        equals('not_buildable'),
      );
      expect(
        refusalOf(
          const Build(
            unitId: 'engineer-1',
            structure: 'wall',
            cells: [Cell(9, 7)],
          ),
        ),
        equals('too_far'),
      );
      expect(
        refusalOf(
          const Build(unitId: 'engineer-1', structure: 'wall', cells: []),
        ),
        equals('off_map'),
      );
    });

    test('a ladder to a floating island names its island cell', () {
      place('engineer-1', const CellRef(7, 4));
      eventsOf(
        const Build(
          unitId: 'engineer-1',
          structure: 'ladder',
          cells: [
            Cell(7, 4),
            Cell(8, 5, island: 'sky'),
          ],
        ),
      );
      f.wait(const Duration(minutes: 2));

      expect(
        (hostEvents().single as StructureBuilt).cells.last,
        equals(const Cell(8, 5, island: 'sky')),
      );
    });

    test('COMBAT-07 a repair restores HP after its time', () {
      hurt('jeep-1', 100);
      place('jeep-1', const CellRef(2, 2));

      expect(
        eventsOf(const Repair(unitId: 'engineer-1', targetId: 'jeep-1')).single,
        isA<RepairStarted>(),
      );
      final endsAt = f.unit('engineer-1').work!.action.endsAt!;
      f.wait(endsAt - f.battle.time);

      final repaired = hostEvents().single as Repaired;
      expect(repaired.targetId, equals('jeep-1'));
      expect(repaired.hp, greaterThan(100));
      expect(f.unit('jeep-1').health.current, equals(repaired.hp));
    });

    test('a repair whose target left ends without it', () {
      place('jeep-1', const CellRef(2, 2));
      eventsOf(const Repair(unitId: 'engineer-1', targetId: 'jeep-1'));
      final endsAt = f.unit('engineer-1').work!.action.endsAt!;
      f.battle.change((state) => state.withoutUnit('jeep-1'));

      f.wait(endsAt - f.battle.time);
      expect(hostEvents(), isEmpty);
      expect(f.unit('engineer-1').work, isNull);
    });

    test('HQ-17 the HQ is not repaired and has no weapon', () {
      place('engineer-1', const CellRef(1, 0));
      expect(
        refusalOf(const Repair(unitId: 'engineer-1', targetId: 'hq-team-1')),
        equals('target_is_hq'),
      );
      expect(
        refusalOf(Fire(unitId: hqId('team-1'), targetId: 'soldier-2')),
        equals('unknown_unit'),
      );
    });

    test('a repair is refused for an unknown HQ, an enemy, an unknown or far '
        'target', () {
      place('engineer-1', const CellRef(1, 0));
      expect(
        refusalOf(const Repair(unitId: 'engineer-1', targetId: 'hq-team-9')),
        equals('unknown_target'),
      );
      place('soldier-2', const CellRef(1, 1));
      expect(
        refusalOf(const Repair(unitId: 'engineer-1', targetId: 'soldier-2')),
        equals('target_not_friendly'),
      );
      expect(
        refusalOf(const Repair(unitId: 'engineer-1', targetId: 'jeep-1')),
        equals('too_far'),
      );
    });

    test('UNIT-35 a heal is instant and refused off its role or reach', () {
      hurt('soldier-1', 50);
      expect(
        eventsOf(const Heal(unitId: 'medic-1', targetId: 'soldier-1')),
        equals([
          const UnitHealed(unitId: 'medic-1', targetId: 'soldier-1', hp: 70),
        ]),
      );
      expect(
        refusalOf(const Heal(unitId: 'soldier-1', targetId: 'medic-1')),
        equals('not_in_actions'),
      );
      expect(
        refusalOf(const Heal(unitId: 'medic-1', targetId: 'jeep-1')),
        equals('too_far'),
      );
      expect(
        refusalOf(const Heal(unitId: 'medic-1', targetId: 'ghost')),
        equals('unknown_target'),
      );
      place('medic-1', const CellRef(1, 0));
      expect(
        refusalOf(const Heal(unitId: 'medic-1', targetId: 'hq-team-1')),
        equals('target_is_hq'),
      );
    });

    test(
      'UNIT-34 a scout observes for its time and does not move meanwhile',
      () {
        expect(
          eventsOf(const Observe(unitId: 'scout-1')),
          equals([
            const ObservationStarted(
              unitId: 'scout-1',
              endsAt: Duration(minutes: 30),
            ),
          ]),
        );
        final to = centreOf(f.battle, const CellRef(3, 2));
        expect(refusalOf(Move(unitId: 'scout-1', to: to)), equals('observing'));
        expect(refusalOf(const Observe(unitId: 'soldier-1')), 'not_in_actions');

        f.wait(const Duration(minutes: 30));
        expect(refusalOf(Move(unitId: 'scout-1', to: to)), isNull);
      },
    );

    test('UNIT-34 a scout without AP observes once they come back', () {
      f.drain('scout-1');

      expect(
        eventsOf(const Observe(unitId: 'scout-1')).single,
        isA<OrderDelayed>(),
      );
    });
  });

  group('relics', () {
    test('RELIC-27 a relic is no target, and a charge leaves it whole', () {
      expect(
        refusalOf(const Fire(unitId: 'commander-1', targetId: 'relic-1')),
        equals('unknown_target'),
      );
      f.changeUnit(
        'engineer-1',
        (unit) => unit.copyWith(
          cell: const CellRef(0, 3),
          weapon: WeaponState.ready(weaponType('explosive')),
        ),
      );
      final before = f.battle.state.relics['relic-1']!;

      eventsOf(
        FireAtPosition(
          unitId: 'engineer-1',
          target: centreOf(f.battle, const CellRef(0, 3)),
        ),
      );
      final after = f.battle.state.relics['relic-1']!;
      expect((after.cell, after.owner), equals((before.cell, before.owner)));
    });

    test('RELIC-05 a capture contribution fills the team pot', () {
      for (var i = 1; i <= 10; i++) {
        final added =
            eventsOf(const Capture(unitId: 'commander-1', relicId: 'relic-1'))
                    .single
                as AddedToCapture;
        expect(added.potAp, equals(5.0 * i));
        f.wait(const Duration(hours: 3));
      }
      // Full, then captured 30 minutes later (RELIC-05).
      final relic = f.battle.state.relics['relic-1']!;
      expect((relic.owner, relic.capturePot), equals(('team-1', null)));
    });

    test('RELIC-06 a capture is refused with an enemy in the radius, outside '
        'it, for an owned or unknown relic', () {
      place('soldier-2', const CellRef(0, 4));
      expect(
        refusalOf(const Capture(unitId: 'commander-1', relicId: 'relic-1')),
        equals('enemy_in_radius'),
      );
      expect(
        refusalOf(const Capture(unitId: 'jeep-1', relicId: 'relic-3')),
        equals('outside_radius'),
      );
      expect(
        refusalOf(const Capture(unitId: 'commander-1', relicId: 'relic-9')),
        equals('unknown_relic'),
      );
      f.battle.change(
        (state) => state.withRelic(
          const RelicState(id: 'relic-1', cell: CellRef(0, 3), owner: 'team-1'),
        ),
      );
      expect(
        refusalOf(const Capture(unitId: 'commander-1', relicId: 'relic-1')),
        equals('already_owned'),
      );
    });

    test("RELIC-08 another team's contribution starts its own pot", () {
      eventsOf(const Capture(unitId: 'commander-1', relicId: 'relic-1'));
      for (final id in [
        'commander-1',
        'soldier-1',
        'medic-1',
        'engineer-1',
        'scout-1',
        'truck-1',
      ]) {
        place(id, const CellRef(7, 7));
      }
      place('soldier-2', const CellRef(0, 4));
      f.send(
        const Capture(unitId: 'soldier-2', relicId: 'relic-1'),
        section: 's-2',
        account: 'a-2',
      );
      expect(
        f.battle.state.relics['relic-1']!.capturePot!.contributions,
        equals({'soldier-2': 5}),
      );
      expect(
        f.battle.state.relics['relic-1']!.capturePot!.team,
        equals('team-2'),
      );
    });

    test(
      'decision 219 the first push while the pot is empty sets the path',
      () {
        f.battle.change(
          (state) => state.withRelic(
            const RelicState(
              id: 'relic-1',
              cell: CellRef(0, 3),
              owner: 'team-1',
            ),
          ),
        );

        final added =
            eventsOf(
                  const Push(
                    unitId: 'commander-1',
                    relicId: 'relic-1',
                    path: [Cell(0, 3), Cell(0, 4)],
                  ),
                ).single
                as AddedToPush;
        expect(added.potAp, equals(5));
        eventsOf(
          const Push(
            unitId: 'soldier-1',
            relicId: 'relic-1',
            path: [Cell(0, 3), Cell(1, 3)],
          ),
        );

        final relic = f.battle.state.relics['relic-1']!;
        expect(relic.pushPot!.ap, equals(10));
        expect(relic.pushPath, equals(const [CellRef(0, 3), CellRef(0, 4)]));
      },
    );

    test('a push is refused for a relic of another team, far away, unknown, '
        'or with a path off the map', () {
      expect(
        refusalOf(const Push(unitId: 'commander-1', relicId: 'relic-1')),
        equals('not_owner'),
      );
      expect(
        refusalOf(const Push(unitId: 'jeep-1', relicId: 'relic-3')),
        equals('outside_radius'),
      );
      expect(
        refusalOf(const Push(unitId: 'jeep-1', relicId: 'relic-9')),
        equals('unknown_relic'),
      );
      expect(
        refusalOf(
          const Push(
            unitId: 'commander-1',
            relicId: 'relic-1',
            path: [Cell(-1, 3)],
          ),
        ),
        equals('off_map'),
      );
    });
  });

  group('a replay', () {
    test('of a battle with each M4 order reaches the live state', () {
      void prepare(Battle battle) => battle.change(
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
            ),
      );
      prepare(f.battle);
      final to = centreOf(f.battle, const CellRef(1, 1));
      f
        ..send(Move(unitId: 'soldier-1', to: to))
        ..send(const Fire(unitId: 'commander-1', targetId: 'soldier-2'))
        ..send(
          FireAtPosition(
            unitId: 'artillery-1',
            target: centreOf(f.battle, const CellRef(6, 2)),
          ),
        )
        ..send(
          FireAimed(
            unitId: 'jeep-1',
            aim: Direction.of(1, 0, 0),
            fireTime: f.battle.time,
          ),
        )
        ..send(const Reload(unitId: 'jeep-1'))
        ..send(const UnloadWeapon(unitId: 'artillery-1'))
        ..send(const TakeOff(unitId: 'helicopter-1'))
        ..send(const Embark(unitId: 'medic-1', transportId: 'truck-1'))
        ..send(
          const Build(
            unitId: 'engineer-1',
            structure: 'wall',
            cells: [Cell(3, 4)],
          ),
        )
        ..send(const Observe(unitId: 'scout-1'))
        ..send(const Capture(unitId: 'commander-1', relicId: 'relic-1'))
        ..send(const Push(unitId: 'radio-1', relicId: 'relic-2'))
        ..send(
          const Push(
            unitId: 'scout-1',
            relicId: 'relic-2',
            path: [Cell(3, 0), Cell(4, 0)],
          ),
        )
        ..send(MoveHq(to: centreOf(f.battle, const CellRef(1, 0))))
        ..wait(const Duration(seconds: 30))
        ..send(const Disembark(unitId: 'medic-1'))
        ..send(const Heal(unitId: 'medic-1', targetId: 'soldier-1'))
        ..send(const Land(unitId: 'helicopter-1'))
        ..send(
          Move(
            unitId: 'engineer-1',
            to: centreOf(f.battle, const CellRef(2, 2)),
          ),
        )
        ..send(const Repair(unitId: 'engineer-1', targetId: 'jeep-1'))
        ..wait(const Duration(minutes: 1))
        ..send(const Resume(unitId: 'scout-1', workId: 'wall@(3, 4)'))
        ..send(const PickUpWeapon(unitId: 'soldier-1', droppedId: 'nothing'))
        ..send(
          Move(
            unitId: 'soldier-1',
            to: centreOf(f.battle, const CellRef(0, 1)),
          ),
        )
        ..wait(const Duration(minutes: 1))
        ..send(const SwapWeapon(unitId: 'soldier-1', weapon: 'machine_gun'))
        ..send(const Fire(unitId: 'commander-1', targetId: 'soldier-2'))
        ..wait(const Duration(hours: 3));

      expect(f.entries.where((entry) => entry.command == null), isNotEmpty);
      expectReplay(f, prepare: prepare);
    });
  });
}
