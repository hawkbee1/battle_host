import 'package:battle_client/battle_client.dart';
import 'package:battle_host/battle_host.dart';
import 'package:battle_pathfinding/battle_pathfinding.dart' show CellRef;
import 'package:battle_protocol/battle_protocol.dart';
import 'package:battle_rules/battle_rules.dart';
import 'package:test/test.dart';

import '../../helpers/fixtures.dart';
import '../../helpers/orders.dart';

/// A fresh battle of the valley, and `battle_client`'s previewer on the same
/// navigation model, the same data and the same clock as its host.
final class _Rig {
  new({void Function(OrdersFixture f)? setUp}) : f = OrdersFixture() {
    setUp?.call(f);
    previewer = MovePreviewer(
      planner: NavigationPathPlanner(
        map: f.battle.world.shared.host.navigation,
        terrain: planData.terrain,
      ),
      units: planData.units,
      terrain: planData.terrain,
    );
  }

  final OrdersFixture f;
  late final MovePreviewer previewer;

  Position at(CellRef cell) => centreOf(f.battle, cell);

  /// What the client plans for the unit `unitId` going to `to`, as its
  /// section sees.
  MovePlan plan(String unitId, Position to) {
    final views = SectionViews(f.battle);
    return previewer.preview(
      unit: views.unit(f.unit(unitId), 's-1'),
      destination: to,
      seen: [
        for (final unit in f.battle.state.units.values)
          if (unit.onField) views.unit(unit, 's-1'),
      ],
      time: f.battle.time,
    );
  }
}

void main() {
  /// [unitId] goes to [cell]: the host's answer to the order, with the path
  /// the client planned, and without it.
  void agrees(
    String unitId,
    CellRef cell, {
    void Function(OrdersFixture f)? setUp,
    bool refused = false,
  }) {
    final rig = _Rig(setUp: setUp);
    final to = rig.at(cell);
    final plan = rig.plan(unitId, to);

    if (refused) {
      expect(plan, isA<MoveRefused>(), reason: '$unitId to $cell');
      final answer = rig.f.send(Move(unitId: unitId, to: to)).refusal?.code;
      expect((plan as MoveRefused).reason.code, answer);
      return;
    }
    expect(plan, isA<MovePreview>(), reason: '$unitId to $cell');
    final preview = plan as MovePreview;
    // The host searches its own path...
    final searched = rig.f.send(Move(unitId: unitId, to: to));
    expect(searched.refusal, isNull, reason: '$unitId to $cell');
    final started = searched.events.whereType<MoveStarted>().single;
    expect(preview.arrivesAt, started.arrivesAt, reason: 'arrival');
    expect(
      rig.f.unit(unitId).pool.apAt(started.arrivesAt),
      lessThanOrEqualTo(rig.f.unit(unitId).pool.max),
    );
    // ... and checks the client's, cell by cell, to the same arrival.
    final checked = _Rig(setUp: setUp).f
        .send(Move(unitId: unitId, to: to, path: preview.cells));
    expect(checked.refusal, isNull, reason: 'the client path is checked');
    expect(
      checked.events.whereType<MoveStarted>().single.arrivesAt,
      started.arrivesAt,
    );
  }

  group('the move preview against the host (stack decision 8)', () {
    test('COMBAT-03 grass: a soldier across open ground', () {
      agrees('soldier-1', const CellRef(4, 1));
    });

    test('MAP-42 a bridge deck costs as road, over the river', () {
      agrees('soldier-1', const CellRef(8, 1));
    });

    test('MAP-15 a road under foot and under wheels', () {
      agrees('soldier-1', const CellRef(7, 6));
      agrees('jeep-1', const CellRef(7, 6));
    });

    test('MAP-47 MAP-44 a path round a wall and a building, corners kept', () {
      agrees('soldier-1', const CellRef(7, 4));
      agrees('jeep-1', const CellRef(9, 1));
    });

    test('MAP-22 water: a river cell has no path for a foot unit', () {
      agrees('soldier-1', const CellRef(5, 2), refused: true);
    });

    test('MAP-37 a cell no path leads to is refused as the host refuses '
        'it: the jeep beyond the river', () {
      agrees('jeep-1', const CellRef(11, 7), refused: true);
    });

    test('COMBAT-06 MAP-20 a unit short of AP arrives when its AP come back, '
        'at the host time', () {
      agrees(
        'soldier-1',
        const CellRef(6, 1),
        setUp: (f) => f.changeUnit(
          'soldier-1',
          (unit) => unit.copyWith(
            pool: ApPool(
              max: 30,
              recoveryDelayS: 60,
              value: 4,
              updatedAt: f.battle.time,
            ),
          ),
        ),
      );
    });

    test('MAP-37 a destination off the map is refused as the host refuses '
        'it', () {
      final rig = _Rig();
      final to = Position.metres(-50, 10, 10);

      expect(
        rig.plan('soldier-1', to),
        const MoveRefused(PreCheckRefusal.offMap),
      );
      expect(
        rig.f.send(Move(unitId: 'soldier-1', to: to)).refusal?.code,
        'off_map',
      );
    });

    test('a flying unit: the helicopter in the air plans a straight path at '
        'the altitude limit, as the host', () {
      final rig = _Rig(
        setUp: (f) =>
            f.changeUnit('helicopter-1', (unit) => unit.copyWith(flying: true)),
      );
      final to = rig.at(const CellRef(9, 4));

      final plan = rig.plan('helicopter-1', to) as MovePreview;
      final started = rig.f
          .send(Move(unitId: 'helicopter-1', to: to))
          .events
          .whereType<MoveStarted>()
          .single;

      expect(plan.arrivesAt, started.arrivesAt);
    });
  });
}
