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

  final economy = planData.economy;
  final xpRules = XpRules(planData.units.progression);

  void place(String id, CellRef cell) =>
      f.changeUnit(id, (unit) => unit.copyWith(cell: cell));

  SectionState section(String id) => f.battle.state.sections[id]!;

  /// Puts [unitId] in storage now.
  void stored(String unitId) => f.changeUnit(
    unitId,
    (unit) => unit.copyWith(location: const Stored(), clearCell: true),
  );

  /// Replaces section [id] with one of the same team and account.
  void rebuild(
    String id, {
    int? money,
    double? xp,
    String? guildId,
    bool guildChief = false,
  }) {
    final old = section(id);
    f.battle.change(
      (state) => state.withSection(
        SectionState(
          id: id,
          accountId: old.accountId,
          team: old.team,
          money: money ?? old.money,
          xp: xp ?? old.xp,
          guildId: guildId,
          guildChief: guildChief,
          storedWeapons: old.storedWeapons,
        ),
      ),
    );
  }

  /// Adds the section `s-3` of `a-3` to team 1.
  void joinS3({String? guildId}) => f.battle.change(
    (state) => state.withSection(
      SectionState(
        id: 's-3',
        accountId: 'a-3',
        team: 'team-1',
        money: 0,
        xp: 0,
        guildId: guildId,
      ),
    ),
  );

  HandledOrder send(Order order, String section) =>
      f.send(order, section: section, account: 'a-${section[2]}');

  String? refusalOf(Order order, {String section = 's-1'}) =>
      send(order, section).refusal?.code;

  List<BattleEvent> eventsOf(Order order, {String section = 's-1'}) {
    final handled = send(order, section);
    expect(handled.refusal, isNull, reason: '$order');
    return handled.events;
  }

  /// Gives [unitId] an explosive charge and enough HP to survive it.
  void armWithCharge(String unitId) => f.changeUnit(
    unitId,
    (unit) => unit.copyWith(
      health: const Health(current: 1000, max: 1000),
      weapon: WeaponState.ready(planData.combat.weaponTypes['explosive']!),
    ),
  );

  group('storage', () {
    test('HQ-31 a unit within the storage radius of its portal is stored at '
        'once; further, a store order is refused', () {
      place('soldier-1', const CellRef(0, 1));

      expect(
        eventsOf(const Store(unitId: 'soldier-1')),
        equals([const UnitStored(unitId: 'soldier-1')]),
      );
      final soldier = f.unit('soldier-1');
      expect((soldier.location, soldier.cell), equals((const Stored(), null)));
      expect(
        refusalOf(const Store(unitId: 'commander-1')),
        equals('not_at_storage'),
      );
    });

    test('HQ-32 a recall stores a unit from anywhere after its time, unless '
        'it dies first', () {
      final events = eventsOf(const Recall(unitId: 'commander-1'));
      const storedAt = Duration(hours: 6);
      expect(
        events,
        equals([const RecallBegan(unitId: 'commander-1', storedAt: storedAt)]),
      );
      expect(
        refusalOf(const Recall(unitId: 'commander-1')),
        equals('already_recalled'),
      );
      eventsOf(const Recall(unitId: 'soldier-1'));
      f.battle.change((state) => state.withoutUnit('soldier-1'));

      f.wait(storedAt);
      expect(f.unit('commander-1').location, isA<Stored>());
      expect(
        f.entries.last.events,
        equals([const UnitStored(unitId: 'commander-1')]),
      );
    });

    test('a recall ends with nothing when its unit was stored meanwhile', () {
      place('soldier-1', const CellRef(0, 1));
      eventsOf(const Recall(unitId: 'commander-1'));
      place('commander-1', const CellRef(1, 0));
      eventsOf(const Store(unitId: 'commander-1'));

      f.wait(const Duration(hours: 6));
      expect(f.entries.last.command, isNotNull);
    });

    test('HQ-49 a loaded transport is not stored; a recalled one takes no '
        'passengers', () {
      place('medic-1', const CellRef(2, 2));
      eventsOf(const Embark(unitId: 'medic-1', transportId: 'truck-1'));
      expect(refusalOf(const Recall(unitId: 'truck-1')), 'carries_units');

      eventsOf(const Disembark(unitId: 'medic-1'));
      eventsOf(const Recall(unitId: 'truck-1'));
      expect(
        refusalOf(const Embark(unitId: 'medic-1', transportId: 'truck-1')),
        equals('transport_recalled'),
      );
    });

    test('HQ-47 the guild camp is never stored', () {
      f.changeUnit(
        'camp-1',
        (unit) => unit.copyWith(
          location: const Deployed(),
          cell: const CellRef(0, 1),
        ),
      );
      expect(refusalOf(const Store(unitId: 'camp-1')), 'never_stored');
    });
  });

  group('deployment', () {
    test('HQ-33 a stored unit deploys next to its portal for 10 AP', () {
      final events = eventsOf(const Deploy(unitId: 'soldier-4'));

      expect(
        events,
        equals([
          UnitDeployed(
            unitId: 'soldier-4',
            at: centreOf(f.battle, const CellRef(0, 0)),
          ),
        ]),
      );
      final soldier = f.unit('soldier-4');
      expect(soldier.location, isA<Deployed>());
      expect(soldier.pool.apAt(f.battle.time), equals(20));
      expect(
        refusalOf(const Deploy(unitId: 'soldier-1')),
        equals('not_stored'),
      );
    });

    test('HQ-34 a stored unit without AP deploys once they come back', () {
      f.drain('soldier-4');
      expect(
        eventsOf(const Deploy(unitId: 'soldier-4')).single,
        isA<OrderDelayed>(),
      );
    });

    test('HQ-36 an enemy within 20 m of the portal blocks deployment', () {
      place('soldier-2', const CellRef(1, 1));
      expect(
        refusalOf(const Deploy(unitId: 'soldier-4')),
        equals('blocked_by_enemy'),
      );
    });

    test('HQ-27 HQ-39 a guild with its camp on the field uses the camp, '
        'with no fallback to the HQ', () {
      rebuild('s-1', guildId: 'g-1', guildChief: true);
      f.changeUnit(
        'camp-1',
        (unit) => unit.copyWith(
          location: const Deployed(),
          cell: const CellRef(4, 5),
        ),
      );
      place('soldier-1', const CellRef(4, 4));
      expect(
        eventsOf(const Store(unitId: 'soldier-1')),
        equals([const UnitStored(unitId: 'soldier-1')]),
      );

      place('soldier-2', const CellRef(4, 6));
      expect(
        refusalOf(const Deploy(unitId: 'soldier-4')),
        equals('blocked_by_enemy'),
      );
    });
  });

  group('the 24-hour lock', () {
    test('HQ-35 SOC-09 a section whose last unit is stored cannot deploy for '
        '24 hours', () {
      for (final id in ['commander-2', 'soldier-2', 'soldier-3']) {
        place(id, const CellRef(11, 1));
      }
      eventsOf(const Store(unitId: 'commander-2'), section: 's-2');
      eventsOf(const Store(unitId: 'soldier-2'), section: 's-2');
      const until = Duration(hours: 24);
      expect(
        eventsOf(const Store(unitId: 'soldier-3'), section: 's-2'),
        equals([
          const UnitStored(unitId: 'soldier-3'),
          const SectionLocked(sectionId: 's-2', until: until),
        ]),
      );
      expect(
        refusalOf(const Deploy(unitId: 'soldier-3'), section: 's-2'),
        equals('section_locked'),
      );

      f.wait(until);
      expect(section('s-2').lockedUntil, isNull);
      expect(
        eventsOf(const Deploy(unitId: 'soldier-3'), section: 's-2').single,
        isA<UnitDeployed>(),
      );
    });

    test('decision 204 the lock starts when the last recall ends, or the last '
        'unit is killed', () {
      for (final id in ['commander-2', 'soldier-2']) {
        eventsOf(Recall(unitId: id), section: 's-2');
      }
      stored('soldier-3');
      f.wait(const Duration(hours: 6));
      expect(
        f.entries.last.events.last,
        equals(
          const SectionLocked(sectionId: 's-2', until: Duration(hours: 30)),
        ),
      );

      f = OrdersFixture();
      stored('commander-2');
      stored('soldier-3');
      armWithCharge('engineer-1');
      place('soldier-2', const CellRef(2, 3));
      final events = eventsOf(
        FireAtPosition(
          unitId: 'engineer-1',
          target: centreOf(f.battle, const CellRef(2, 3)),
        ),
      );
      expect(events.whereType<SectionLocked>().single.sectionId, 's-2');
    });
  });

  group("the commander's death", () {
    test('UNIT-28 UNIT-29 decision 206 the commander resurrects in storage '
        'with his section, and other passengers are set down', () {
      joinS3();
      f
        ..changeUnit('scout-1', (unit) => unit.copyWith(sectionId: 's-3'))
        ..changeUnit(
          'commander-1',
          (unit) => unit.copyWith(
            health: Health(current: 1, max: unit.health.max),
            xp: const UnitXp(earned: 200, unspent: 100),
          ),
        );
      rebuild('s-1', money: 100);
      eventsOf(const Embark(unitId: 'medic-1', transportId: 'truck-1'));
      eventsOf(
        const Embark(unitId: 'scout-1', transportId: 'truck-1'),
        section: 's-3',
      );
      armWithCharge('soldier-2');
      place('soldier-2', const CellRef(0, 2));

      final events = eventsOf(
        FireAtPosition(
          unitId: 'soldier-2',
          target: centreOf(f.battle, const CellRef(0, 2)),
        ),
        section: 's-2',
      );

      final commander = f.unit('commander-1');
      expect(commander.location, isA<Stored>());
      expect(commander.health.current, equals(commander.health.max));
      expect(commander.xp.earned, equals(175));
      expect(commander.xp.unspent, equals(75));
      expect(commander.pool.apAt(f.battle.time), equals(0));
      expect(
        commander.morale,
        equals(
          planData.combat.morale.base -
              planData.battle.commanderDeath.moraleLoss,
        ),
      );
      for (final id in ['soldier-1', 'medic-1', 'truck-1', 'artillery-1']) {
        expect(f.unit(id).location, isA<Stored>(), reason: id);
      }
      expect(events, contains(const UnitStored(unitId: 'medic-1')));
      final scout = f.unit('scout-1');
      expect(scout.location, isA<Deployed>());
      expect(scout.cell, equals(const CellRef(2, 2)));
      expect(
        events,
        contains(
          Disembarked(
            unitId: 'scout-1',
            at: centreOf(f.battle, const CellRef(2, 2)),
          ),
        ),
      );
      expect(events.whereType<SectionLocked>(), isEmpty);
      expect(section('s-1').lockedUntil, isNull);
      expect(section('s-1').money, equals(economy.minStartingMoney));
      place('soldier-2', const CellRef(6, 2));
      expect(
        eventsOf(const Deploy(unitId: 'soldier-1')).single,
        isA<OrderDelayed>(),
      );
    });
  });

  group('purchases', () {
    test('ECO-04 ECO-05 ECO-07 UNIT-27 HQ-46 a commander buys a unit that '
        'arrives at the portal', () {
      rebuild('s-1', xp: 1000000000);
      final seq = f.entries.length + 1;

      final events = eventsOf(const BuyUnit(unitType: 'soldier'));
      final id = 'unit-$seq';
      expect(
        events,
        equals([
          UnitPurchased(
            sectionId: 's-1',
            unitId: id,
            unitType: 'soldier',
            price: economy.priceOf('soldier'),
          ),
          UnitDeployed(unitId: id, at: centreOf(f.battle, const CellRef(0, 0))),
        ]),
      );
      expect(section('s-1').money, equals(1000 - economy.priceOf('soldier')));
      expect(f.unit(id).location, isA<Deployed>());
      expect(
        eventsOf(const BuyUnit(unitType: 'radio')).first,
        isA<UnitPurchased>(),
      );
    });

    test('ECO-04 a purchase is refused without room, money, for a commander '
        'or an unknown type', () {
      expect(refusalOf(const BuyUnit(unitType: 'soldier')), 'no_room');
      rebuild('s-1', xp: 1000000000, money: 10);
      expect(refusalOf(const BuyUnit(unitType: 'soldier')), 'not_enough_money');
      expect(refusalOf(const BuyUnit(unitType: 'commander')), 'not_for_sale');
      expect(refusalOf(const BuyUnit(unitType: 'dragon')), 'unknown_type');
    });

    test('HQ-46 decision 205 a blocked arrival or a locked section buys '
        'nothing', () {
      rebuild('s-1', xp: 1000000000);
      place('soldier-2', const CellRef(1, 1));
      expect(refusalOf(const BuyUnit(unitType: 'soldier')), 'arrival_blocked');

      f.battle.change(
        (state) => state.withSection(
          section('s-1').lockedTo(const Duration(hours: 1)),
        ),
      );
      expect(refusalOf(const BuyUnit(unitType: 'soldier')), 'section_locked');
      expect(section('s-1').money, equals(1000));
    });

    test('ECO-06 HQ-42 the guild chief buys the guild camp, one at a time', () {
      expect(refusalOf(const BuyGuildCamp()), 'not_guild_chief');
      rebuild('s-1', guildId: 'g-1', guildChief: true);
      expect(refusalOf(const BuyGuildCamp()), 'camp_exists');

      f.battle.change((state) => state.withoutUnit('camp-1'));
      final bought = eventsOf(const BuyGuildCamp()).first as UnitPurchased;
      expect(bought.unitType, equals('encampment'));
      expect(
        section('s-1').money,
        equals(1000 - economy.priceOf('encampment')),
      );
    });

    test('COMBAT-27 a weapon bought goes to the section storage', () {
      expect(
        eventsOf(const BuyWeapon(weapon: 'anti_tank')),
        equals([
          WeaponPurchased(
            sectionId: 's-1',
            weapon: 'anti_tank',
            price: economy.priceOf('anti_tank'),
          ),
        ]),
      );
      expect(section('s-1').storedWeapons.weapons, contains('anti_tank'));
      expect(refusalOf(const BuyWeapon(weapon: 'laser')), 'unknown_type');
      rebuild('s-1', money: 0);
      expect(refusalOf(const BuyWeapon(weapon: 'rifle')), 'not_enough_money');
    });
  });

  group('transfers', () {
    test('ECO-08 ECO-09 ECO-19 money sent loses its fee, lower inside a '
        'guild', () {
      joinS3();
      final events = eventsOf(
        const TransferMoney(toSectionId: 's-3', amount: 100),
      );
      final outside = MoneyRules(economy).transfer(
        amount: 100,
        senderMoney: 1000,
        sameTeam: true,
        sameGuild: false,
      ) as Transferred;
      expect(
        events,
        equals([
          MoneyTransferred(
            fromSectionId: 's-1',
            toSectionId: 's-3',
            received: outside.received,
            fee: outside.fee,
          ),
        ]),
      );
      expect(section('s-1').money, equals(900));
      expect(section('s-3').money, equals(outside.received));

      rebuild('s-1', guildId: 'g-1');
      joinS3(guildId: 'g-1');
      final inside =
          eventsOf(const TransferMoney(toSectionId: 's-3', amount: 100)).single
              as MoneyTransferred;
      expect(inside.fee, lessThan(outside.fee));
    });

    test('ECO-10 a transfer is refused across teams, to itself, to nobody, '
        'or beyond the money', () {
      expect(
        refusalOf(const TransferMoney(toSectionId: 's-2', amount: 10)),
        'other_team',
      );
      expect(
        refusalOf(const TransferMoney(toSectionId: 's-1', amount: 10)),
        'to_itself',
      );
      expect(
        refusalOf(const TransferMoney(toSectionId: 's-9', amount: 10)),
        'unknown_section',
      );
      joinS3();
      expect(
        refusalOf(const TransferMoney(toSectionId: 's-3', amount: 5000)),
        'not_enough_money',
      );
    });
  });

  group('tree nodes', () {
    test('UNIT-18 a unit buys a node with its own XP, stored or not', () {
      f.changeUnit(
        'soldier-1',
        (unit) => unit.copyWith(xp: const UnitXp(earned: 100, unspent: 100)),
      );

      expect(
        eventsOf(const BuyNode(unitId: 'soldier-1', stat: 'hp', step: 1)),
        equals([const NodePurchased(unitId: 'soldier-1', stat: 'hp', step: 1)]),
      );
      final soldier = f.unit('soldier-1');
      expect(soldier.tree.stepsOf(EvolvableStat.hp), equals(1));
      expect(soldier.health.max, greaterThan(soldier.health.current));
      expect(soldier.xp.unspent, equals(0));
      expect(soldier.xp.earned, equals(100));
      expect(
        refusalOf(const BuyNode(unitId: 'soldier-1', stat: 'hp', step: 2)),
        'not_enough_xp',
      );
      expect(
        refusalOf(const BuyNode(unitId: 'soldier-1', stat: 'luck', step: 1)),
        'unknown_type',
      );

      f.changeUnit(
        'soldier-4',
        (unit) => unit.copyWith(xp: const UnitXp(earned: 100, unspent: 100)),
      );
      expect(
        refusalOf(const BuyNode(unitId: 'soldier-4', stat: 'attack', step: 1)),
        isNull,
      );
      f.changeUnit(
        'soldier-5',
        (unit) => unit.copyWith(location: const Prisoner('s-2')),
      );
      expect(
        refusalOf(const BuyNode(unitId: 'soldier-5', stat: 'hp', step: 1)),
        'is_prisoner',
      );
    });
  });

  group('prisoners', () {
    setUp(() {
      f
        ..changeUnit(
          'soldier-2',
          (unit) =>
              unit.copyWith(location: const Prisoner('s-1'), clearCell: true),
        )
        ..changeUnit(
          'soldier-1',
          (unit) =>
              unit.copyWith(location: const Prisoner('s-2'), clearCell: true),
        );
    });

    test('COMBAT-44 an exchange posted by the captor and accepted by the '
        'owner returns both prisoners to storage', () {
      final seq = f.entries.length + 1;
      expect(
        eventsOf(
          const OfferExchange(
            ownerSectionId: 's-2',
            released: ['soldier-2'],
            wanted: ['soldier-1'],
          ),
        ),
        equals([
          OfferPosted(
            offerId: seq,
            captorSectionId: 's-1',
            ownerSectionId: 's-2',
            released: const ['soldier-2'],
            wanted: const ['soldier-1'],
            price: 0,
          ),
        ]),
      );
      expect(refusalOf(AcceptOffer(offerId: seq)), 'not_your_offer');

      expect(
        eventsOf(AcceptOffer(offerId: seq), section: 's-2'),
        equals([
          OfferAccepted(offerId: seq),
          const UnitStored(unitId: 'soldier-2'),
          const UnitStored(unitId: 'soldier-1'),
        ]),
      );
      expect(f.unit('soldier-2').location, isA<Stored>());
      expect(f.unit('soldier-1').location, isA<Stored>());
      expect(f.battle.state.offers, isEmpty);
    });

    test('COMBAT-44 a ransom goes entirely to the captor; an offer can be '
        'refused', () {
      final seq = f.entries.length + 1;
      eventsOf(
        const OfferRansom(
          ownerSectionId: 's-2',
          released: ['soldier-2'],
          price: 50,
        ),
      );
      expect(
        refusalOf(AcceptOffer(offerId: seq), section: 's-2'),
        'not_enough_money',
      );
      rebuild('s-2', money: 80);
      eventsOf(AcceptOffer(offerId: seq), section: 's-2');
      expect(section('s-2').money, equals(30));
      expect(section('s-1').money, equals(1050));

      final next = f.entries.length + 1;
      eventsOf(
        const OfferRansom(
          ownerSectionId: 's-1',
          released: ['soldier-1'],
          price: 10,
        ),
        section: 's-2',
      );
      expect(
        eventsOf(RefuseOffer(offerId: next)),
        equals([OfferRefused(offerId: next)]),
      );
      expect(refusalOf(RefuseOffer(offerId: next)), 'unknown_offer');
      expect(
        refusalOf(
          const OfferRansom(ownerSectionId: 's-9', released: [], price: 1),
        ),
        'unknown_section',
      );
      expect(
        refusalOf(
          const OfferRansom(ownerSectionId: 's-1', released: [], price: 1),
        ),
        'to_itself',
      );
      final empty = f.entries.length + 1;
      eventsOf(
        const OfferRansom(ownerSectionId: 's-2', released: [], price: 1),
      );
      expect(
        refusalOf(AcceptOffer(offerId: empty), section: 's-2'),
        'nothing_released',
      );
    });
  });

  group('the HQ manager', () {
    test('HQ-05 the manager delegates the role to a player of his team', () {
      joinS3();
      expect(
        eventsOf(const DelegateHq(accountId: 'a-3')),
        equals([const ManagerChanged(team: 'team-1', accountId: 'a-3')]),
      );
      expect(refusalOf(const DelegateHq(accountId: 'a-3')), 'not_manager');
      expect(
        refusalOf(const DelegateHq(accountId: 'a-9'), section: 's-3'),
        'not_in_team',
      );
      expect(
        refusalOf(const DelegateHq(accountId: 'a-2'), section: 's-2'),
        'not_manager',
      );
    });
  });

  group('rewards', () {
    test('UNIT-05 UNIT-14 decisions 201 202 a killing hit earns the hit and '
        'the kill; hitting an ally earns nothing', () {
      armWithCharge('engineer-1');
      place('soldier-2', const CellRef(2, 3));

      eventsOf(
        FireAtPosition(
          unitId: 'engineer-1',
          target: centreOf(f.battle, const CellRef(2, 3)),
        ),
      );

      final xp =
          xpRules
              .earn(
                const HitXp(targetId: 'x', attackerXp: 0, targetXp: 0),
                history: XpHistory(),
                at: Duration.zero,
              )
              .xp +
          xpRules
              .earn(
                const KillXp(targetId: 'x', attackerXp: 0, targetXp: 0),
                history: XpHistory(),
                at: Duration.zero,
              )
              .xp;
      final split = xpRules.split(xp);
      expect(f.unit('engineer-1').xp.earned, closeTo(split.unit, 1e-9));
      expect(section('s-1').xp, closeTo(split.section, 1e-9));
      expect(
        section('s-1').money,
        equals(1000 + economy.earnings.hit + economy.earnings.kill),
      );
    });

    double hqXp(List<XpEvent> events) => xpRules
        .split(
          events.fold(
            0,
            (sum, event) =>
                sum +
                xpRules.earn(event, history: XpHistory(), at: Duration.zero).xp,
          ),
        )
        .unit;

    test('ECO-02 HQ-04 decision 224 an enemy HQ hit earns money and XP', () {
      place('soldier-1', const CellRef(8, 1));
      final attack =
          eventsOf(
                FireAimed(
                  unitId: 'soldier-1',
                  aim: Direction.of(3, -1, 0),
                  fireTime: f.battle.time,
                ),
              ).single
              as Attacked;

      expect(attack.impacts.single.targetId, equals(hqId('team-2')));
      expect(section('s-1').money, equals(1000 + economy.earnings.hqHit));
      expect(
        f.unit('soldier-1').xp.earned,
        closeTo(hqXp([const HqHitXp(hqId: 'hq')]), 1e-9),
      );
    });

    test('HQ-04 decisions 201 224 the shot that destroys an enemy HQ earns '
        'its hit and its destruction, money and XP', () {
      final team = f.battle.state.teams['team-2']!;
      f.battle.change(
        (state) => state.withTeam(
          team.withHq(
            HqState(
              cell: team.hq.cell,
              health: Health(current: 0.1, max: team.hq.health.max),
              pool: team.hq.pool,
            ),
          ),
        ),
      );
      place('soldier-1', const CellRef(8, 1));
      eventsOf(
        FireAimed(
          unitId: 'soldier-1',
          aim: Direction.of(3, -1, 0),
          fireTime: f.battle.time,
        ),
      );

      expect(
        section('s-1').money,
        equals(1000 + economy.earnings.hqHit + economy.earnings.hqDestruction),
      );
      // UNIT-11: the last HQ standing wins, with its victory XP.
      expect(
        f.unit('soldier-1').xp.earned,
        closeTo(
          hqXp([const HqHitXp(hqId: 'hq'), const HqDestroyedXp(hqId: 'hq')]) +
              xpRules.split(xpRules.victoryXp).unit,
          1e-9,
        ),
      );
    });

    test('UNIT-06 ECO-03 ECO-15 builds, heals and repairs earn XP; builds and '
        'heals earn money', () {
      final roleXp = xpRules.split(
        planData.units.progression.xpSources.roleAction,
      );
      eventsOf(
        const Build(
          unitId: 'engineer-1',
          structure: 'wall',
          cells: [Cell(3, 4)],
        ),
      );
      f.wait(const Duration(minutes: 5));
      expect(f.unit('engineer-1').xp.earned, closeTo(roleXp.unit, 1e-9));
      expect(
        section('s-1').money,
        equals(1000 + economy.earnings.construction),
      );

      f.changeUnit(
        'soldier-1',
        (unit) => unit.copyWith(health: const Health(current: 50, max: 100)),
      );
      eventsOf(const Heal(unitId: 'medic-1', targetId: 'soldier-1'));
      expect(f.unit('medic-1').xp.earned, closeTo(roleXp.unit, 1e-9));
      expect(
        section('s-1').money,
        equals(1000 + economy.earnings.construction + economy.earnings.heal),
      );

      place('jeep-1', const CellRef(2, 2));
      f.changeUnit(
        'jeep-1',
        (unit) =>
            unit.copyWith(health: Health(current: 50, max: unit.health.max)),
      );
      place('engineer-1', const CellRef(2, 3));
      eventsOf(const Repair(unitId: 'engineer-1', targetId: 'jeep-1'));
      f.wait(f.unit('engineer-1').work!.action.endsAt! - f.battle.time);
      expect(f.unit('engineer-1').xp.earned, closeTo(2 * roleXp.unit, 1e-9));
    });

    test('ECO-13 a section that loses its last unit besides its commander '
        'gets the money floor', () {
      armWithCharge('engineer-1');
      place('soldier-2', const CellRef(2, 3));
      place('soldier-3', const CellRef(2, 3));

      eventsOf(
        FireAtPosition(
          unitId: 'engineer-1',
          target: centreOf(f.battle, const CellRef(2, 3)),
        ),
      );
      expect(section('s-2').money, equals(economy.minStartingMoney));
    });
  });

  group('a replay', () {
    test('of a section that buys, deploys, fights, stores itself and is '
        'locked for 24 hours reaches the live state', () {
      void prepare(Battle battle) => battle.change(
        (state) =>
            state.withSection(state.sections['s-2']!.withWallet(money: 1000)),
      );
      prepare(f.battle);
      final bought = f.entries.length + 1;
      eventsOf(const BuyUnit(unitType: 'soldier'), section: 's-2');
      final recruit = 'unit-$bought';
      eventsOf(
        FireAimed(
          unitId: recruit,
          aim: Direction.of(-1, 0, 0),
          fireTime: f.battle.time,
        ),
        section: 's-2',
      );
      for (final (id, cell) in [
        ('commander-2', const CellRef(11, 1)),
        ('soldier-2', const CellRef(10, 0)),
        ('soldier-3', const CellRef(11, 0)),
      ]) {
        eventsOf(
          Move(unitId: id, to: centreOf(f.battle, cell)),
          section: 's-2',
        );
      }
      f.wait(const Duration(minutes: 5));
      for (final id in ['commander-2', 'soldier-2', 'soldier-3', recruit]) {
        eventsOf(Store(unitId: id), section: 's-2');
      }
      expect(section('s-2').lockedUntil, isNotNull);
      f.wait(const Duration(hours: 24));
      eventsOf(const Deploy(unitId: 'commander-2'), section: 's-2');

      expectReplay(f, prepare: prepare);
    });

    test('of a commander killed with units on the field and in a transport '
        'reaches the live state', () {
      void prepare(Battle battle) => battle.change(
        (state) => state
            .withUnit(
              state.units['commander-1']!.copyWith(
                health: const Health(current: 1, max: 100),
              ),
            )
            .withUnit(
              state.units['soldier-2']!.copyWith(
                cell: const CellRef(0, 2),
                health: const Health(current: 1000, max: 1000),
                weapon: WeaponState.ready(
                  planData.combat.weaponTypes['explosive']!,
                ),
              ),
            ),
      );
      prepare(f.battle);
      eventsOf(const Embark(unitId: 'medic-1', transportId: 'truck-1'));
      eventsOf(
        FireAtPosition(
          unitId: 'soldier-2',
          target: centreOf(f.battle, const CellRef(0, 2)),
        ),
        section: 's-2',
      );
      eventsOf(
        Move(unitId: 'soldier-2', to: centreOf(f.battle, const CellRef(6, 2))),
        section: 's-2',
      );
      f.wait(const Duration(hours: 11));
      eventsOf(const Deploy(unitId: 'commander-1'));

      expect(f.unit('commander-1').location, isA<Deployed>());
      expectReplay(f, prepare: prepare);
    });
  });
}
