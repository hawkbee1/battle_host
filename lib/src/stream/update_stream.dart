import 'package:battle_host/src/core/battle.dart';
import 'package:battle_host/src/core/battle_state.dart';
import 'package:battle_host/src/fog/fog_of_war.dart';
import 'package:battle_host/src/stream/section_views.dart';
import 'package:battle_protocol/battle_protocol.dart';
import 'package:battle_rules/battle_rules.dart' show Deployed;

/// A section's end of the update stream (a port, stack decision 7): the
/// endpoints of M6 Issue 5 implement it over a socket.
abstract interface class SectionSubscriber {
  /// Sends [message] to the section's client.
  void send(HostMessage message);
}

/// What a subscriber was last sent: what its next update is built
/// against.
final class _Sent {
  new(this.sectionId);

  final String sectionId;
  Set<String> units = {};
  Set<String> hqs = {};
  final positions = <String, Position?>{};
  final own = <String, UnitView>{};
  final hqViews = <String, HqView>{};
  final relics = <String, RelicView>{};
  SectionPrivate? section;
  String weather = '';
}

/// {@template update_stream}
/// The update stream of one battle (Observer, stack decision 7): it hears
/// every entry of the battle's log, and after each tick and each accepted
/// order ([flush]) sends each subscribed section what changed for it,
/// with the update policy of `stack/03` (decision 100, MAP-29): a moving
/// unit's position when it changes, a still unit nothing, events when
/// they happen, nothing that did not change. A section that subscribes,
/// late or again, gets its whole view first, the delta layer included
/// (MAP-08), then its updates.
///
/// What a section receives names only the units it sees before or after
/// the change, its own units, and what every section knows (MAP-49). Per
/// event type, see [_visibility]; for shots, COMBAT-57 and COMBAT-58:
/// the unseen leaves no clue (decision 237). A moving unit's position is
/// the one the host holds, its destination from the start of its move
/// (decision 236). Its relic alerts
/// reach the previous owner team's players at once, or on their next
/// connection (RELIC-10, decision 233, `PendingAlerts`).
/// {@endtemplate}
final class UpdateStream {
  /// {@macro update_stream}
  new(this.battle) : views = SectionViews(battle), _before = battle.state;

  /// The battle.
  final Battle battle;

  /// The views of its state.
  final SectionViews views;

  final _subscribers = <SectionSubscriber, _Sent>{};
  final _heard = <LogEntry>[];
  final _senders = <int, String>{};
  BattleState _before;

  FogOfWar get _fog => battle.orders.fog;

  Set<String> get _connected => {
    for (final sent in _subscribers.values)
      battle.state.sections[sent.sectionId]!.accountId,
  };

  /// Subscribes [subscriber] to [sectionId]: it gets the section's whole
  /// view at once, then what the battle lets it buy (`Roster`), then the
  /// alerts its player has not received yet, then
  /// its updates.
  ///
  /// Throws an [ArgumentError] for a section not in the battle.
  void subscribe(String sectionId, SectionSubscriber subscriber) {
    final section =
        battle.state.sections[sectionId] ??
        (throw ArgumentError.value(sectionId, 'sectionId', 'not in battle'));
    flush();
    final sent = _Sent(sectionId);
    final sight = _fog.of(sectionId);
    final view = views.whole(sectionId, sight);
    _subscribers[subscriber] = sent
      ..units = {...sight.units}
      ..hqs = {...sight.hqs}
      ..section = view.section
      ..weather = view.weather;
    for (final unit in view.units) {
      sent.positions[unit.unitId] = unit.position;
      if (unit.private != null) sent.own[unit.unitId] = unit;
    }
    for (final hq in view.hqs) {
      sent.hqViews[hq.team] = hq;
    }
    for (final relic in view.relics) {
      sent.relics[relic.relicId] = relic;
    }
    subscriber
      ..send(view)
      ..send(views.roster());
    battle.alerts.take(section.accountId).forEach(subscriber.send);
  }

  /// Stops sending to [subscriber].
  void unsubscribe(SectionSubscriber subscriber) =>
      _subscribers.remove(subscriber);

  /// Hears [entry], just logged: its events go out with the next [flush];
  /// a relic alert goes out at once to the connected players it is for.
  void hear(LogEntry entry) {
    _heard.add(entry);
    if (entry.command case Command(:final seq?, :final sender)) {
      _senders[seq] = sender.sectionId;
    }
    final connected = _connected;
    for (final (account, alert) in battle.alerts.hear(
      entry,
      battle.state,
      connected: connected,
    )) {
      for (final MapEntry(key: subscriber, value: sent)
          in _subscribers.entries) {
        if (battle.state.sections[sent.sectionId]!.accountId == account) {
          subscriber.send(alert);
        }
      }
    }
  }

  /// Sends each subscriber the update of what changed since the last one,
  /// if anything did: after each tick and each accepted order.
  void flush() {
    for (final MapEntry(key: subscriber, value: sent) in _subscribers.entries) {
      final update = _update(sent);
      if (update != null) subscriber.send(update);
    }
    _heard.clear();
    _before = battle.state;
  }

  TickUpdate? _update(_Sent sent) {
    final state = battle.state;
    final sectionId = sent.sectionId;
    final sight = _fog.of(sectionId);
    final known = {...sent.units, ...sight.units};
    final knownHqs = {...sent.hqs, ...sight.hqs};
    final appeared = <UnitView>[];
    final moved = <UnitPosition>[];
    final ownUnits = <UnitView>[];
    for (final id in sight.units) {
      final unit = state.units[id];
      if (unit == null) continue;
      final view = views.unit(unit, sectionId);
      if (!sent.units.contains(id)) {
        appeared.add(view);
      } else {
        if (view.position case final position?
            when position != sent.positions[id]) {
          moved.add(UnitPosition(id, position));
        }
        if (view.private != null && view != sent.own[id]) ownUnits.add(view);
      }
      sent.positions[id] = view.position;
      if (view.private != null) sent.own[id] = view;
    }
    final gone = [
      for (final id in sent.units)
        if (!sight.units.contains(id)) id,
    ];
    for (final id in gone) {
      sent.positions.remove(id);
      sent.own.remove(id);
    }
    final (events, bursts, fired, unseenHits) = _events(
      sectionId,
      known,
      knownHqs,
    );
    final section = views.section(sectionId);
    final hqs = <HqView>[
      for (final team in sight.hqs)
        if (views.hq(team, sectionId) case final hq
            when hq != sent.hqViews[team])
          hq,
    ];
    final hqsGone = [
      for (final team in sent.hqs)
        if (!sight.hqs.contains(team)) team,
    ];
    final relics = <RelicView>[
      for (final relic in state.relics.values)
        if (views.relic(relic) case final view
            when view != sent.relics[relic.id])
          view,
    ];
    final update = TickUpdate(
      at: battle.time,
      weather: state.weather == sent.weather ? null : state.weather,
      moved: moved,
      appeared: appeared,
      gone: gone,
      events: events,
      bursts: bursts,
      unseenHits: unseenHits,
      fired: fired,
      ownUnits: ownUnits,
      section: section == sent.section ? null : section,
      hqs: hqs,
      hqsGone: hqsGone,
      relics: relics,
    );
    sent
      ..units = {...sight.units}
      ..hqs = {...sight.hqs}
      ..section = section
      ..weather = state.weather;
    for (final hq in hqs) {
      sent.hqViews[hq.team] = hq;
    }
    hqsGone.forEach(sent.hqViews.remove);
    for (final relic in relics) {
      sent.relics[relic.relicId] = relic;
    }
    return update == TickUpdate(at: battle.time) ? null : update;
  }

  /// The events of the entries heard since the last flush that
  /// [sectionId] may see; a seen unit's shots that hit only units it knows,
  /// grouped into bursts; its other shots, outcome unknown, with only the
  /// hits it sees (COMBAT-58); and the hits on units it knows by shooters it
  /// does not see (COMBAT-57). The unseen leaves no clue (decision 237).
  (List<BattleEvent>, List<Burst>, List<Fired>, List<UnseenHit>) _events(
    String sectionId,
    Set<String> known,
    Set<String> knownHqs,
  ) {
    final team = battle.state.sections[sectionId]!.team;
    bool knows(String id) => id.startsWith('hq-')
        ? knownHqs.contains(id.substring(3))
        : known.contains(id) || !_isUnit(id);
    final events = <BattleEvent>[];
    final shots = <String, List<Attacked>>{};
    final unknown = <String, List<Attacked>>{};
    final unseenHits = <UnseenHit>[];
    for (final event in _heard.expand((entry) => entry.events)) {
      switch (_visibility(event, sectionId, team, knows)) {
        case _Visibility.shown:
          events.add(event);
        case _Visibility.hidden:
          break;
        case _Visibility.shot:
          final attacked = event as Attacked;
          final impacts = [
            for (final impact in attacked.impacts)
              if (knows(impact.targetId)) impact,
          ];
          if (!knows(attacked.attackerId)) {
            unseenHits.addAll([
              for (final impact in impacts)
                UnseenHit(
                  targetId: impact.targetId,
                  damage: impact.damage,
                  result: impact.result,
                ),
            ]);
          } else if (attacked.hit &&
              impacts.isNotEmpty &&
              impacts.length == attacked.impacts.length) {
            (shots[attacked.attackerId] ??= []).add(attacked);
          } else {
            (unknown[attacked.attackerId] ??= []).add(
              Attacked(
                attackerId: attacked.attackerId,
                sectionId: attacked.sectionId,
                weapon: attacked.weapon,
                hit: false,
                impacts: impacts,
              ),
            );
          }
      }
    }
    final bursts = <Burst>[];
    for (final MapEntry(key: attacker, value: fired) in shots.entries) {
      if (fired.length == 1) {
        events.add(fired.single);
        continue;
      }
      bursts.add(
        Burst(
          attackerId: attacker,
          sectionId: fired.first.sectionId,
          weapon: fired.first.weapon,
          shots: fired.length,
          hits: fired.length,
          impacts: _merged(fired),
        ),
      );
    }
    return (
      events,
      bursts,
      [
        for (final MapEntry(key: attacker, value: shots) in unknown.entries)
          Fired(
            attackerId: attacker,
            sectionId: shots.first.sectionId,
            weapon: shots.first.weapon,
            shots: shots.length,
            impacts: _merged(shots),
          ),
      ],
      unseenHits,
    );
  }

  /// The hits of [shots], each unit hit once with the damage of all of
  /// them and its last result.
  static List<Impact> _merged(List<Attacked> shots) {
    final hit = <String, Impact>{};
    for (final impact in shots.expand((shot) => shot.impacts)) {
      final before = hit[impact.targetId];
      hit[impact.targetId] = Impact(
        targetId: impact.targetId,
        targetType: impact.targetType,
        damage: (before?.damage ?? 0) + impact.damage,
        friendly: impact.friendly,
        result: impact.result,
      );
    }
    return hit.values.toList();
  }

  /// Whether [id] names a unit of the battle, now or at the last flush;
  /// other targets are HQs and objects of the world.
  bool _isUnit(String id) =>
      battle.state.units.containsKey(id) || _before.units.containsKey(id);

  /// The section of the unit [id], now or at the last flush.
  String? _sectionOf(String id) =>
      (battle.state.units[id] ?? _before.units[id])?.sectionId;

  /// Who sees [event], per event type: its own section only (orders, the
  /// unit's actions, purchases, storage), every section (relics, the
  /// countdown, eliminations, the world's delta layer: MAP-49), the
  /// sections that know every unit it names (moves, crushes, heals,
  /// repairs, weapons picked up), the sections that see where a weapon
  /// fell, or a shot, cut down to what the section sees (COMBAT-57).
  _Visibility _visibility(
    BattleEvent event,
    String sectionId,
    String team,
    bool Function(String id) knows,
  ) {
    _Visibility mine(String? section) =>
        section == sectionId ? _Visibility.shown : _Visibility.hidden;
    _Visibility seen(Iterable<String> ids) =>
        ids.every(knows) ? _Visibility.shown : _Visibility.hidden;
    _Visibility offer(int offerId) {
      final offer = battle.state.offers[offerId] ?? _before.offers[offerId];
      return offer != null &&
              (offer.captorSectionId == sectionId ||
                  offer.ownerSectionId == sectionId)
          ? _Visibility.shown
          : _Visibility.hidden;
    }

    return switch (event) {
      OrderRefused(:final seq) ||
      OrderDelayed(:final seq) => mine(_senders[seq]),
      MoveStarted(:final moverId) ||
      MoveStopped(:final moverId) => seen([moverId]),
      Attacked() => _Visibility.shot,
      Crushed(:final byId, :final unitId) => seen([byId, unitId]),
      WeaponDropped(:final at) => _seesGround(sectionId, at),
      WeaponPickedUp(:final unitId) ||
      Repaired(targetId: final unitId) => seen([unitId]),
      UnitHealed(:final unitId, :final targetId) => seen([unitId, targetId]),
      WeaponSwapped(:final unitId) ||
      TimeOnlyStarted(:final unitId) ||
      Embarked(:final unitId) ||
      Disembarked(:final unitId) ||
      BuildStarted(:final unitId) ||
      RepairStarted(:final unitId) ||
      WorkResumed(:final unitId) ||
      WorkInterrupted(:final unitId) ||
      ObservationStarted(:final unitId) ||
      AddedToCapture(:final unitId) ||
      AddedToPush(:final unitId) ||
      UnitStored(:final unitId) ||
      RecallBegan(:final unitId) ||
      UnitDeployed(:final unitId) ||
      NodePurchased(:final unitId) => mine(_sectionOf(unitId)),
      SectionLocked(:final sectionId) ||
      UnitPurchased(:final sectionId) ||
      WeaponPurchased(:final sectionId) ||
      SectionJoined(:final sectionId) => mine(sectionId),
      MoneyTransferred(:final fromSectionId, :final toSectionId) =>
        fromSectionId == sectionId || toSectionId == sectionId
            ? _Visibility.shown
            : _Visibility.hidden,
      OfferPosted(:final captorSectionId, :final ownerSectionId) =>
        captorSectionId == sectionId || ownerSectionId == sectionId
            ? _Visibility.shown
            : _Visibility.hidden,
      OfferAccepted(:final offerId) ||
      OfferRefused(:final offerId) => offer(offerId),
      ManagerChanged(team: final managed) =>
        managed == team ? _Visibility.shown : _Visibility.hidden,
      StructureBuilt() ||
      ObjectDamaged() ||
      ObjectDestroyed() ||
      CraterDug() ||
      CaptureLost() ||
      RelicCaptured() ||
      RelicLost() ||
      VictoryHoldStarted() ||
      VictoryHoldReset() ||
      Eliminated() ||
      BattleStarted() ||
      BattleEnded() => _Visibility.shown,
    };
  }

  /// Whether a unit of [sectionId] on the field sees the ground at [at].
  _Visibility _seesGround(String sectionId, Position at) {
    final cell = battle.orders.world.cellAt(at);
    return cell != null &&
            battle.state.units.values.any(
              (unit) =>
                  unit.sectionId == sectionId &&
                  unit.location is Deployed &&
                  _fog.seesGround(unit, cell),
            )
        ? _Visibility.shown
        : _Visibility.hidden;
  }
}

/// Who sees an event.
enum _Visibility { shown, hidden, shot }
