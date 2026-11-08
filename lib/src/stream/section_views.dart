import 'package:battle_host/src/core/battle.dart';
import 'package:battle_host/src/core/battle_state.dart';
import 'package:battle_host/src/fog/fog_of_war.dart';
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

  Duration? _after(Duration? time) =>
      time != null && time > battle.time ? time : null;

  ApView _ap(ApPool pool) => ApView(
    value: pool.value,
    at: pool.updatedAt,
    perHour: pool.recoveryPerHour,
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
}
