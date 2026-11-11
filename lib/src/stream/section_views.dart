import 'package:battle_host/src/core/battle.dart';
import 'package:battle_host/src/core/battle_state.dart';
import 'package:battle_host/src/fog/fog_of_war.dart';
import 'package:battle_host/src/orders/section_orders.dart'
    show commanderCategory, encampmentCategory;
import 'package:battle_map/battle_map.dart' show MapObject;
import 'package:battle_pathfinding/battle_pathfinding.dart' as nav;
import 'package:battle_protocol/battle_protocol.dart';
import 'package:battle_rules/battle_rules.dart';

/// {@template section_views}
/// What a section is sent of a battle, built from its state at its time:
/// the values of the messages of M6 Issue 2. A unit's private state goes
/// to its own section only; an HQ's AP to its own team only.
/// {@endtemplate}
final class SectionViews {
  /// {@macro section_views}
  const new(this.battle);

  /// The battle.
  final Battle battle;

  BattleState get _state => battle.state;

  /// The point of [cell] on the map, flying or not.
  Position positionOf(nav.CellRef cell, {bool flying = false}) {
    final point = battle.orders.world.pointOf(cell, flying: flying);
    return Position.metres(point.x, point.y, point.z);
  }

  /// [unit] as [sectionId] sees it.
  UnitView unit(UnitState unit, String sectionId) {
    final cell = unit.cell;
    final location = unit.location;
    return UnitView(
      unitId: unit.id,
      unitType: unit.type.id,
      sectionId: unit.sectionId,
      team: _state.sections[unit.sectionId]!.team,
      hp: unit.health.current,
      maxHp: unit.health.max,
      position: location is OnField && cell != null
          ? positionOf(cell, flying: unit.flying)
          : null,
      flying: unit.flying,
      weapon: unit.weapon.weapon?.id,
      private: unit.sectionId != sectionId
          ? null
          : UnitPrivate(
              place: switch (location) {
                Deployed() => UnitPlace.deployed,
                Carried() => UnitPlace.carried,
                Stored() => UnitPlace.stored,
                Prisoner() => UnitPlace.prisoner,
              },
              ap: _ap(unit.pool),
              sightRangeM: _sightRangeM(unit),
              morale: unit.morale,
              rounds: unit.weapon.rounds,
              xpEarned: unit.xp.earned,
              xpUnspent: unit.xp.unspent,
              transportId: location is Carried ? location.transportId : null,
              movingUntil: _after(unit.movingUntil),
              busyUntil: _after(unit.weapon.busyUntil),
              observingUntil: unit.observation?.isActiveAt(battle.time) ?? false
                  ? unit.observation!.endsAt
                  : null,
            ),
    );
  }

  /// How far [unit] sees before weather, terrain and height: the vision
  /// range of its type, which its skills already evolved (UNIT-18), plus the
  /// observe bonus while it observes (UNIT-34). What the fog computes with
  /// (`FogOfWar`), so that its section's client lights the same ground
  /// (M7 Issue 9, MAP-31).
  double _sightRangeM(UnitState unit) =>
      unit.type.stats.visionRange +
      (unit.observation?.bonusAt(battle.time) ?? 0);

  Duration? _after(Duration? time) =>
      time != null && time > battle.time ? time : null;

  ApView _ap(ApPool pool) => ApView(
    value: pool.value,
    at: pool.updatedAt,
    perHour: Duration.secondsPerHour / pool.recoveryDelayS,
    max: pool.max,
  );

  /// The HQ of [team] as [sectionId] knows it; its AP for its own team.
  HqView hq(String team, String sectionId) {
    final hq = _state.teams[team]!.hq;
    return HqView(
      team: team,
      position: positionOf(hq.cell),
      hp: hq.health.current,
      maxHp: hq.health.max,
      ap: _state.sections[sectionId]!.team == team ? _ap(hq.pool) : null,
    );
  }

  /// [relic] as every section knows it (MAP-49).
  RelicView relic(RelicState relic) => RelicView(
    relicId: relic.id,
    position: positionOf(relic.cell),
    owner: relic.owner,
  );

  /// The own state of [sectionId].
  SectionPrivate section(String sectionId) {
    final section = _state.sections[sectionId]!;
    return SectionPrivate(
      money: section.money,
      xp: section.xp,
      lockedUntil: _after(section.lockedUntil),
      storedWeapons: section.storedWeapons.weapons,
      prisoners: [
        for (final unit in _state.units.values)
          if (unit.location case Prisoner(:final captorSectionId)
              when captorSectionId == sectionId)
            JoinedUnit(unitId: unit.id, unitType: unit.type.id),
      ],
      offers: [
        for (final MapEntry(key: id, value: offer) in _state.offers.entries)
          if (offer.captorSectionId == sectionId ||
              offer.ownerSectionId == sectionId)
            OfferPosted(
              offerId: id,
              captorSectionId: offer.captorSectionId,
              ownerSectionId: offer.ownerSectionId,
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
      ],
    );
  }

  /// The running victory countdown (RELIC-16).
  HoldView? get hold => switch (_state.victory?.hold) {
    final hold? => HoldView(
      team: hold.team,
      since: hold.since,
      winsAt: hold.winsAt,
    ),
    null => null,
  };

  /// The whole delta layer as world events (MAP-08): the craters, in the
  /// order they were dug, the structures built, the objects damaged and
  /// those destroyed.
  List<BattleEvent> get world {
    final delta = _state.delta;
    MapObject object(String id) =>
        delta.built[id] ?? battle.map.host.objects[id]!;
    List<Cell> cells(MapObject object) => [
      for (final cell in object.cells)
        Cell(
          cell.x,
          cell.y,
          island: cell.surface == nav.groundSurface ? null : cell.surface,
        ),
    ];
    return [
      for (final change in delta.changes)
        if (change case nav.CraterDug(:final crater))
          CraterDug(
            at: Position.metres(
              crater.centreXM,
              crater.centreYM,
              battle.orders.world
                  .pointOf(
                    nav.CellRef(
                      (crater.centreXM / battle.orders.world.cellSizeM).floor(),
                      (crater.centreYM / battle.orders.world.cellSizeM).floor(),
                    ),
                  )
                  .z,
            ),
            radiusM: crater.radiusM,
            depthM: crater.depthM,
          ),
      for (final built in delta.built.values)
        StructureBuilt(
          siteId: built.id,
          structure: built.type,
          cells: cells(built),
        ),
      for (final MapEntry(key: id, value: hp) in delta.hp.entries)
        ObjectDamaged(
          object: object(id).type,
          cells: cells(object(id)),
          hp: hp,
        ),
      for (final id in delta.destroyed)
        ObjectDestroyed(object: object(id).type, cells: cells(object(id))),
    ];
  }

  /// The whole view of [sectionId] with what it knows ([sight]).
  SectionView whole(String sectionId, SectionSight sight) => SectionView(
    at: battle.time,
    weather: _state.weather,
    section: section(sectionId),
    units: [
      for (final id in sight.units)
        if (_state.units[id] case final known?) unit(known, sectionId),
    ],
    hqs: [for (final team in sight.hqs) hq(team, sectionId)],
    relics: [for (final state in _state.relics.values) relic(state)],
    hold: hold,
    world: world,
  );

  /// What the battle lets a section buy (ECO-04, ECO-05, COMBAT-27): the
  /// unit types a commander buys, at their price, and the weapons, at
  /// theirs. The commander comes with his section (UNIT-41), the guild camp
  /// is the guild chief's own order (ECO-06) and the test unit is on sale
  /// only where the battle allows test units (UNIT-44): the same list as
  /// the purchase orders accept, whatever the section.
  Roster roster() {
    final definitions = battle.definitions;
    final prices = definitions.economy;
    return Roster(
      units: [
        for (final type in definitions.units.unitTypes.values)
          if (type.category != commanderCategory &&
              type.category != encampmentCategory &&
              (type.id != testUnitId || battle.settings.testUnits))
            RosterUnit(
              unitType: type.id,
              category: type.category,
              price: prices.priceOf(type.id),
              weapons: type.weapons.allowed,
            ),
      ],
      weapons: [
        for (final weapon in definitions.combat.weaponTypes.keys)
          RosterWeapon(weapon: weapon, price: prices.priceOf(weapon)),
      ],
    );
  }
}
