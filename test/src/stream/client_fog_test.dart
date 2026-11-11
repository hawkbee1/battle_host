import 'package:battle_client/battle_client.dart';
import 'package:battle_host/battle_host.dart';
import 'package:battle_pathfinding/battle_pathfinding.dart' show CellRef;
import 'package:test/test.dart';

import '../../helpers/fixtures.dart';
import '../../helpers/plain.dart';
import '../../helpers/scripted_battle.dart';
import '../../helpers/view_holder.dart';

/// The ground [holder]'s section lights, as the client computes it from what
/// the host sent: `battle_client`'s [HeldView] of the messages, and
/// [GroundSight] on the map as built with the delta layer the host sent, from
/// each own unit's position, sight range and the weather (M7 Issue 9). Cell
/// indices `y × width + x`.
Set<int> _clientLit(Battle battle, ViewHolder holder) {
  final definitions = battle.definitions;
  final view = HeldView();
  holder.received.forEach(view.apply);
  final sight = GroundSight(
    map: battle.map.host.navigation,
    terrain: definitions.terrain,
  ).withWorld(view.world);
  final lit = <int>{};
  for (final unit in view.units.values) {
    final private = unit.private;
    final position = unit.position;
    if (private == null || position == null) continue;
    lit.addAll(
      sight.seenFrom(
        from: sight.cellAt(position)!,
        flying: unit.flying,
        heightM: definitions.units.unitTypes[unit.unitType]!.hitBox.height,
        rangeM: private.sightRangeM,
        weather: view.weather!,
      ),
    );
  }
  return lit;
}

/// The ground [sectionId]'s own units see, by the host's own fog: what
/// `FogOfWar.seesGround` says of each cell (COMBAT-12).
Set<int> _hostLit(Battle battle, String sectionId) {
  final navigation = battle.map.host.navigation;
  final lit = <int>{};
  for (final unit in battle.state.units.values) {
    if (unit.sectionId != sectionId || !unit.onField) continue;
    for (var y = 0; y < navigation.depth; y++) {
      for (var x = 0; x < navigation.width; x++) {
        if (battle.orders.fog.seesGround(unit, CellRef(x, y))) {
          lit.add(y * navigation.width + x);
        }
      }
    }
  }
  return lit;
}

BattleState _inWeather(BattleState state, String weather) => BattleState(
  victory: state.victory,
  units: state.units,
  sections: state.sections,
  teams: state.teams,
  relics: state.relics,
  delta: state.delta,
  offers: state.offers,
  dropped: state.dropped,
  weather: weather,
);

void main() {
  group('M7.9 the client lit cells equal the host visible set', () {
    for (final weather in ['clear', 'fog']) {
      test('M7.9 MAP-27 MAP-29 on the scripted battle of M5.15 in $weather '
          'weather, own units sight only, both sides, at every step', () async {
        final s = ScriptedHost.alone();
        await s.begin();
        s.battle.change((state) => _inWeather(state, weather));
        final holders = {
          for (final id in ['s-1', 's-2']) id: ViewHolder(),
        };
        for (final MapEntry(:key, :value) in holders.entries) {
          s.host.subscribe('b-1', key, value);
        }

        var compared = 0;
        var lit = 0;
        var dark = 0;
        for (final step in script) {
          step(s);
          for (final MapEntry(:key, :value) in holders.entries) {
            final host = _hostLit(s.battle, key);
            final client = _clientLit(s.battle, value);
            expect(
              client,
              equals(host),
              reason:
                  '$key at step ${script.indexOf(step)}: client only '
                  '${client.difference(host)}, host only '
                  '${host.difference(client)}',
            );
            compared++;
            lit += host.length;
            final cells =
                s.battle.map.host.navigation.width *
                s.battle.map.host.navigation.depth;
            dark += cells - host.length;
          }
        }

        // The comparison is not trivial: the delta layer changed, some
        // ground is lit and, in fog, some is dark.
        expect(s.battle.state.delta.built, isNotEmpty);
        expect(compared, equals(script.length * 2));
        expect(lit, greaterThan(0));
        if (weather == 'fog') expect(dark, greaterThan(0));
      });
    }

    for (final weather in planData.battle.weather.states) {
      test('M7.9 MAP-26 MAP-27 MAP-33 decision 235 on the plain with a wood, '
          'a ridge and a building, in $weather weather, for every unit '
          'type on the field', () {
        final f = FogFixture()..weather(weather);
        // Soldiers by the wood, on and behind the ridge, by the building;
        // a scout, a radio and an artillery piece besides.
        const places = {
          'soldier-1': CellRef(14, 5),
          'soldier-3': CellRef(49, 14),
          'soldier-2': CellRef(52, 14),
          'soldier-4': CellRef(59, 5),
          'scout-1': CellRef(20, 4),
          'radio-1': CellRef(40, 10),
          'artillery-1': CellRef(46, 12),
        };
        for (final MapEntry(key: id, value: cell) in places.entries) {
          if (f.battle.state.units.containsKey(id)) f.place(id, cell);
        }
        final holders = {
          for (final id in ['s-1', 's-2', 's-3']) id: ViewHolder(),
        };
        final stream = UpdateStream(f.battle);
        for (final MapEntry(:key, :value) in holders.entries) {
          stream.subscribe(key, value);
        }

        for (final MapEntry(:key, :value) in holders.entries) {
          final host = _hostLit(f.battle, key);
          expect(host, isNotEmpty, reason: key);
          expect(_clientLit(f.battle, value), equals(host), reason: key);
        }
      });
    }
  });
}
