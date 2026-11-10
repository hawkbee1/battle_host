import 'package:battle_host/src/core/battle.dart';
import 'package:battle_host/src/core/battle_state.dart';
import 'package:battle_host/src/orders/order_chain.dart';
import 'package:battle_host/src/orders/refusal.dart';
import 'package:battle_host/src/orders/world.dart';
import 'package:battle_pathfinding/battle_pathfinding.dart';
import 'package:battle_protocol/battle_protocol.dart';
import 'package:battle_rules/battle_rules.dart';

/// The category of a section's commander (UNIT-24).
const commanderCategory = 'commander';

/// The category of a guild camp (HQ-47).
const encampmentCategory = 'encampment';

/// {@template section_orders}
/// The orders of a section about its units and its money (M5 Issue 12):
/// storage, recall and deployment (HQ-31 to HQ-36, HQ-49), purchases
/// (ECO-04 to ECO-07, HQ-46), transfers (ECO-08 to ECO-11), tree nodes
/// (UNIT-18), prisoner offers (COMBAT-44) and the HQ manager's delegation
/// (HQ-05); and the commander's death applied to his section (UNIT-28,
/// UNIT-29).
///
/// A section's portal, where its units are stored, deploy and arrive, is
/// its guild's camp on the field, or the team's HQ (HQ-27, HQ-38, HQ-41).
/// {@endtemplate}
final class SectionOrders {
  /// {@macro section_orders}
  new({required this.battle, required this.world})
    : _storage = StorageRules(
        battle: battle.settings,
        morale: battle.definitions.combat.morale,
      ),
      _money = MoneyRules(battle.definitions.economy),
      _levels = SectionLevel(battle.definitions.units.progression),
      _evolution = Evolution(battle.definitions.units.trees);

  /// The battle.
  final Battle battle;

  /// Its world geometry.
  final World world;

  final StorageRules _storage;
  final MoneyRules _money;
  final SectionLevel _levels;
  final Evolution _evolution;

  BattleState get _state => battle.state;
  Duration get _now => battle.time;

  void _put(UnitState unit) => battle.change((state) => state.withUnit(unit));

  void _putSection(SectionState section) =>
      battle.change((state) => state.withSection(section));

  Position _positionOf(CellRef cell) {
    final point = world.pointOf(cell);
    return Position.metres(point.x, point.y, point.z);
  }

  String _teamOf(UnitState unit) => _state.sections[unit.sectionId]!.team;

  // Portals (HQ-27, HQ-38, HQ-41, HQ-46).

  /// The guild camp on the field of [section]'s guild; null when it has
  /// none there.
  UnitState? _campOf(SectionState section) {
    final guild = section.guildId;
    if (guild == null) return null;
    return _state.units.values
        .where(
          (unit) =>
              unit.type.category == encampmentCategory &&
              unit.onField &&
              _state.sections[unit.sectionId]!.guildId == guild,
        )
        .firstOrNull;
  }

  /// Where [section] stores, deploys and receives its units.
  CellRef portalOf(SectionState section) {
    final camp = _campOf(section);
    return switch (_storage.placeOf(
      inGuild: section.guildId != null,
      guildHasCamp: camp != null,
    )) {
      StoragePlace.guildCamp => camp!.cell!,
      StoragePlace.hq => _state.teams[section.team]!.hq.cell,
    };
  }

  /// The distance from [section]'s portal to the nearest enemy unit on the
  /// field; null when there is none (HQ-36).
  double? _nearestEnemyM(SectionState section) {
    final portal = portalOf(section);
    double? nearest;
    for (final unit in _state.units.values) {
      if (!unit.onField || _teamOf(unit) == section.team) continue;
      final metres = world.distanceM(portal, unit.cell!);
      if (nearest == null || metres < nearest) nearest = metres;
    }
    return nearest;
  }

  /// Whether [section] has room for one more unit on the field: its units
  /// that count toward its cap, on the field and owned (UNIT-39, UNIT-40).
  bool hasRoom(SectionState section) {
    final own = [
      for (final unit in _state.units.values)
        if (unit.sectionId == section.id && unit.type.countsInSectionCap) unit,
    ];
    return _levels.hasRoom(
      level: _levels.levelFor(section.xp),
      active: own.where((unit) => unit.onField).length,
      owned: own.length,
    );
  }

  // Storage (HQ-31, HQ-32, HQ-49).

  /// [unit] stored at once, within the storage radius of its portal
  /// (HQ-31); [recall] recalls it from anywhere (HQ-32).
  OrderPlan store(UnitState unit, {required bool recall}) {
    final section = _state.sections[unit.sectionId]!;
    final result = _storage.store(
      type: unit.type,
      location: unit.location,
      distanceM: world.distanceM(unit.cell!, portalOf(section)),
      carriesUnits: _state.units.values.any(
        (other) => switch (other.location) {
          Carried(:final transportId) => transportId == unit.id,
          _ => false,
        },
      ),
      now: _now,
    );
    return switch (result) {
      StoreRefused(:final reason) => refused(reason),
      StoredAtOnce() => PlanReady(() => [_stored(unit)]),
      // A store order does not turn into a recall.
      RecallStarted() when !recall => refused(HostRule.notAtStorage),
      RecallStarted(:final location) => PlanReady(() {
        _put(unit.copyWith(location: location));
        final doneAt = location.recallDoneAt!;
        battle.schedule(doneAt, RecallEnds(unit.id));
        return [RecallBegan(unitId: unit.id, storedAt: doneAt)];
      }),
    };
  }

  UnitStored _stored(UnitState unit) {
    _put(
      unit.copyWith(
        location: const Stored(),
        flying: false,
        clearCell: true,
        clearMove: true,
        clearWork: true,
        clearObservation: true,
      ),
    );
    return UnitStored(unitId: unit.id);
  }

  /// Ends the recall of [unitId] due now: it is stored, unless it died,
  /// was taken or was stored since (HQ-32).
  List<BattleEvent> finishRecall(String unitId) {
    final unit = _state.units[unitId];
    if (unit == null) return const [];
    return switch (unit.location) {
      OnField(:final recallDoneAt) when recallDoneAt == _now => [_stored(unit)],
      _ => const [],
    };
  }

  // Deployment (HQ-33 to HQ-36, HQ-39).

  /// [unit] deployed next to its portal, for its AP (HQ-33).
  OrderPlan deploy(UnitState unit) {
    final section = _state.sections[unit.sectionId]!;
    final result = _storage.deploy(
      location: unit.location,
      pool: unit.pool,
      now: _now,
      nearestEnemyM: _nearestEnemyM(section),
      lockedUntil: section.lockedUntil,
    );
    return switch (result) {
      DeployRefused(reason: DeployRefusal.costAboveApMax) => const PlanRefused(
        ApRefused(),
      ),
      DeployRefused(:final reason) => refused(reason),
      DeployStarts(:final at, :final pool) => planAt(at, _now, () {
        final portal = portalOf(section);
        _put(
          unit.copyWith(location: const Deployed(), cell: portal, pool: pool),
        );
        return [UnitDeployed(unitId: unit.id, at: _positionOf(portal))];
      }),
    };
  }

  // Purchases (ECO-04 to ECO-07, HQ-42, HQ-46, COMBAT-27).

  /// [section] buys a unit of [typeId] as `unit-[seq]` (ECO-04, ECO-05). The
  /// test unit is sold only where the battle allows it (UNIT-44).
  OrderPlan buyUnit(SectionState section, String typeId, int seq) {
    final type = battle.definitions.units.unitTypes[typeId];
    if (type == null) return refused(HostRule.unknownType);
    if (type.id == testUnitId && !battle.settings.testUnits) {
      return refused(HostRule.testUnitsOff);
    }
    return _buy(section, type, seq);
  }

  /// [section]'s chief buys the guild camp as `unit-[seq]` (ECO-06, HQ-42).
  OrderPlan buyCamp(SectionState section, int seq) => _buy(
    section,
    battle.definitions.units.unitTypes.values.firstWhere(
      (type) => type.category == encampmentCategory,
    ),
    seq,
  );

  OrderPlan _buy(SectionState section, UnitType type, int seq) {
    final guild = section.guildId;
    final result = _money.buyUnit(
      type: type,
      money: section.money,
      hasRoom: hasRoom(section),
      locked: _storage.isLocked(lockedUntil: section.lockedUntil, now: _now),
      arrivalBlocked: _storage.blocks(_nearestEnemyM(section)),
      guildChief: section.guildChief,
      guildHasCamp:
          guild != null &&
          _state.units.values.any(
            (unit) =>
                unit.type.category == encampmentCategory &&
                _state.sections[unit.sectionId]!.guildId == guild,
          ),
    );
    return switch (result) {
      PurchaseRefused(:final reason) => refused(reason),
      Bought(:final price, :final moneyLeft) => PlanReady(() {
        final id = 'unit-$seq';
        final portal = portalOf(section);
        _putSection(section.withWallet(money: moneyLeft));
        _put(
          UnitState(
            id: id,
            sectionId: section.id,
            type: type,
            tree: SkillTree(),
            xp: const UnitXp(),
            location: const Deployed(),
            pool: ApPool.full(
              max: type.stats.apMax,
              recoveryDelayS: battle.settings.ap.recoveryDelayS,
              at: _now,
            ),
            health: Health.full(type.stats.hp),
            morale: battle.definitions.combat.morale.base,
            weapon: WeaponState.forNewUnit(type, battle.definitions.combat),
            cell: portal,
          ),
        );
        return [
          UnitPurchased(
            sectionId: section.id,
            unitId: id,
            unitType: type.id,
            price: price,
          ),
          UnitDeployed(unitId: id, at: _positionOf(portal)),
        ];
      }),
    };
  }

  /// [section] buys [weaponId] for its storage (COMBAT-27, decision 151).
  OrderPlan buyWeapon(SectionState section, String weaponId) {
    final weapon = battle.definitions.combat.weaponTypes[weaponId];
    if (weapon == null) return refused(HostRule.unknownType);
    return switch (_money.buyWeapon(weapon: weapon, money: section.money)) {
      PurchaseRefused(:final reason) => refused(reason),
      Bought(:final price, :final moneyLeft) => PlanReady(() {
        _putSection(
          section
              .withWallet(money: moneyLeft)
              .withWeapons(section.storedWeapons.added(weaponId)),
        );
        return [
          WeaponPurchased(
            sectionId: section.id,
            weapon: weaponId,
            price: price,
          ),
        ];
      }),
    };
  }

  // Transfers (ECO-08 to ECO-11, ECO-19).

  /// [from] sends [amount] w€ to [toSectionId].
  OrderPlan transfer(SectionState from, String toSectionId, int amount) {
    final to = _state.sections[toSectionId];
    if (to == null) return refused(HostRule.unknownSection);
    if (to.id == from.id) return refused(HostRule.toItself);
    final result = _money.transfer(
      amount: amount,
      senderMoney: from.money,
      sameTeam: to.team == from.team,
      sameGuild: from.guildId != null && from.guildId == to.guildId,
    );
    return switch (result) {
      TransferRefused(:final reason) => refused(reason),
      Transferred(:final received, :final fee) => PlanReady(() {
        _putSection(from.withWallet(money: from.money - amount));
        _putSection(to.withWallet(money: to.money + received));
        return [
          MoneyTransferred(
            fromSectionId: from.id,
            toSectionId: to.id,
            received: received,
            fee: fee,
          ),
        ];
      }),
    };
  }

  // Tree nodes (UNIT-18 to UNIT-23).

  /// [unit] buys step [step] of [statKey] with its own unspent XP.
  OrderPlan buyNode(UnitState unit, String statKey, int step) {
    if (unit.location is Prisoner) return refused(HostRule.isPrisoner);
    final stat = EvolvableStat.values
        .where((stat) => stat.key == statKey)
        .firstOrNull;
    if (stat == null) return refused(HostRule.unknownType);
    final base = battle.definitions.units.unitTypes[unit.type.id]!;
    final result = _evolution.buy(
      type: base,
      tree: unit.tree,
      stat: stat,
      step: step,
      unspentXp: unit.xp.unspent,
    );
    return switch (result) {
      NodeRefused(:final reason) => refused(reason),
      NodeBought(:final tree, :final xpLeft) => PlanReady(() {
        final type = _evolution.evolve(base, tree);
        _put(
          unit.copyWith(
            type: type,
            tree: tree,
            xp: unit.xp.spent(unit.xp.unspent - xpLeft),
            health: Health(current: unit.health.current, max: type.stats.hp),
          ),
        );
        return [NodePurchased(unitId: unit.id, stat: statKey, step: step)];
      }),
    };
  }

  // Prisoner offers (COMBAT-44).

  /// [captor] posts [offer], as the offer [seq].
  OrderPlan offer(SectionState captor, PrisonerOffer offer, int seq) {
    final owner = _state.sections[offer.ownerSectionId];
    if (owner == null) return refused(HostRule.unknownSection);
    if (owner.id == captor.id) return refused(HostRule.toItself);
    return PlanReady(() {
      battle.change((state) => state.withOffer(seq, offer));
      return [
        OfferPosted(
          offerId: seq,
          captorSectionId: captor.id,
          ownerSectionId: owner.id,
          released: offer.released,
          wanted: switch (offer) {
            ExchangeOffer(:final wanted) => wanted,
            RansomOffer() => const [],
          },
          price: switch (offer) {
            ExchangeOffer() => 0,
            RansomOffer(:final price) => price,
          },
        ),
      ];
    });
  }

  /// [owner] answers the offer [offerId]: accepts it or [refuse]s it.
  OrderPlan answer(SectionState owner, int offerId, {required bool refuse}) {
    final offer = _state.offers[offerId];
    if (offer == null) return refused(HostRule.unknownOffer);
    if (offer.ownerSectionId != owner.id) {
      return refused(HostRule.notYourOffer);
    }
    if (refuse) {
      return PlanReady(() {
        battle.change((state) => state.withoutOffer(offerId));
        return [OfferRefused(offerId: offerId)];
      });
    }
    final result = offer.accept(
      captorPrisoners: _state.prisonersOf(offer.captorSectionId),
      ownerPrisoners: _state.prisonersOf(owner.id),
      ownerMoney: owner.money,
    );
    return switch (result) {
      DealRefused(:final reason) => refused(reason),
      DealDone(:final ransom) => PlanReady(() {
        final captor = _state.sections[offer.captorSectionId]!;
        _putSection(owner.withWallet(money: owner.money - ransom));
        _putSection(captor.withWallet(money: captor.money + ransom));
        battle.change((state) => state.withoutOffer(offerId));
        final released = [
          ...offer.released,
          if (offer case ExchangeOffer(:final wanted)) ...wanted,
        ];
        return [
          OfferAccepted(offerId: offerId),
          for (final id in released) _stored(_state.units[id]!),
        ];
      }),
    };
  }

  // The HQ manager's delegation (HQ-05).

  /// The manager of [section]'s team hands the role to [accountId].
  OrderPlan delegate(SectionState section, String sender, String accountId) {
    final team = _state.teams[section.team]!;
    final manager = team.managerAccountId;
    final result = manager == null
        ? const DelegationRefused(DelegationRefusal.notManager)
        : HqManager(manager).delegate(
            by: sender,
            to: accountId,
            teamPlayers: {
              for (final other in _state.sections.values)
                if (other.team == team.id) other.accountId,
            },
          );
    return switch (result) {
      DelegationRefused(:final reason) => refused(reason),
      Delegated(manager: HqManager(:final playerId)) => PlanReady(() {
        battle.change((state) => state.withTeam(team.withManager(playerId)));
        return [ManagerChanged(team: team.id, accountId: playerId)];
      }),
    };
  }

  // The commander's death (UNIT-28, UNIT-29, ECO-13).

  /// [commander] killed now: he resurrects in storage with his losses, and
  /// his section's units on the field are stored with theirs; other
  /// sections' units his transports carry are set down (decision 206). The
  /// section's money gets its floor (ECO-13). There is no lock
  /// (decision 125).
  List<BattleEvent> commanderDied(UnitState commander) {
    final back = _storage.resurrect(
      commander: commander.type,
      pool: commander.pool,
      morale: commander.morale,
      xp: commander.xp,
      at: _now,
    );
    final events = <BattleEvent>[_stored(commander)];
    _put(
      _state.units[commander.id]!.copyWith(
        pool: back.condition.pool,
        morale: back.condition.morale,
        health: back.health,
        xp: back.xp,
        weapon: const WeaponState.unarmed(),
      ),
    );
    final section = commander.sectionId;
    // Where its transports stood, for the passengers set down.
    final stood = <String, CellRef>{};
    for (final unit in _state.units.values.toList()) {
      if (unit.sectionId != section || unit.id == commander.id) continue;
      if (!unit.onField || !unit.type.storable) continue;
      stood[unit.id] = unit.cell!;
      final condition = _storage.atCommanderDeath(
        type: unit.type,
        location: unit.location,
        pool: unit.pool,
        morale: unit.morale,
        at: _now,
      );
      events.add(_stored(unit));
      _put(
        _state.units[unit.id]!.copyWith(
          pool: condition.pool,
          morale: condition.morale,
        ),
      );
    }
    // Decision 206: other sections' passengers are set down where their
    // transport stood.
    for (final unit in _state.units.values.toList()) {
      if (unit.location case final Carried carried
          when stood.containsKey(carried.transportId)) {
        final cell = stood[carried.transportId]!;
        _put(unit.copyWith(location: carried.setDown(), cell: cell));
        events.add(Disembarked(unitId: unit.id, at: _positionOf(cell)));
      }
    }
    final wallet = _state.sections[section]!;
    _putSection(
      wallet.withWallet(
        money: _money.afterCommanderDeath(
          wallet.money,
          warMinStartingMoney: battle.minStartingMoney,
        ),
      ),
    );
    return events;
  }
}
