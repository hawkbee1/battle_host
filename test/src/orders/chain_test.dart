import 'package:battle_host/battle_host.dart';
import 'package:battle_pathfinding/battle_pathfinding.dart';
import 'package:battle_protocol/battle_protocol.dart';
import 'package:battle_rules/battle_rules.dart';
import 'package:test/test.dart';

import '../../helpers/orders.dart';

void main() {
  late OrdersFixture f;

  setUp(() => f = OrdersFixture());

  /// Sends [order] and checks it is refused at [link] with [code], changing
  /// nothing, and logged with its refusal.
  void expectRefused(
    Order order,
    CheckLink link,
    String code, {
    String section = 's-1',
    String account = 'a-1',
  }) {
    final before = f.battle.state;
    final handled = f.send(order, section: section, account: account);

    expect(handled.refusal?.link, equals(link), reason: '$order');
    expect(handled.refusal?.code, equals(code));
    expect(handled.refusal.toString(), equals('${link.name}: $code'));
    expect(
      f.battle.state,
      same(before),
      reason:
          'a refused order changes '
          'nothing',
    );
    final entry = f.entries.last;
    expect(
      entry.events,
      equals([OrderRefused(seq: entry.command!.seq!, reason: code)]),
    );
  }

  group('the order chain (stack decision 7)', () {
    test(
      'AI-03 refuses a sender over its rate, before its sequence number',
      () {
        f = OrdersFixture(rateLimit: RateLimit(perSecond: 1, burst: 2));
        const order = Reload(unitId: 'jeep-1');

        expect(f.send(order).refusal, isNull);
        expect(f.send(order).refusal, isNull);
        final third = f.send(order);
        expect(third.refusal, isA<RateRefused>());
        expect(third.refusal!.link, equals(CheckLink.rate));
        expect(third.refusal!.code, equals('rate_limited'));
        expect(third.events, isEmpty);
        // The fixture's login, from the server, is not limited.
        expect(f.entries, hasLength(3));
        expect(f.send(order, origin: Origin.server).refusal, isNull);

        f.clock.advance(const Duration(seconds: 1));
        expect(f.send(order).refusal, isNull);
        expect(f.entries.last.command!.seq, equals(5));
      },
    );

    test('AI-03 decision 157 the same limit holds for an AI agent', () {
      f = OrdersFixture(rateLimit: RateLimit(perSecond: 1, burst: 1))
        ..send(const Reload(unitId: 'jeep-1'));
      expect(
        f.host
            .submit(
              'b-1',
              const Command(
                sender: Sender(accountId: 'a-1', sectionId: 's-1'),
                sentAt: Duration.zero,
                order: Reload(unitId: 'jeep-1'),
              ),
              origin: Origin.ai,
            )
            .refusal,
        isA<RateRefused>(),
      );
    });

    test('refuses an unknown section at the sender link', () {
      expectRefused(
        const Reload(unitId: 'jeep-1'),
        CheckLink.sender,
        'unknown_section',
        section: 's-9',
      );
    });

    test("refuses another account's section at the sender link", () {
      expectRefused(
        const Reload(unitId: 'jeep-1'),
        CheckLink.sender,
        'not_your_section',
        account: 'a-2',
      );
    });

    test('HQ-18 refuses a team out of the battle at the sender link', () {
      f.battle.change(
        (state) => state.withTeam(
          TeamState(
            id: 'team-1',
            hq: state.teams['team-1']!.hq,
            eliminated: true,
          ),
        ),
      );

      expectRefused(
        const Reload(unitId: 'jeep-1'),
        CheckLink.sender,
        'team_eliminated',
      );
    });

    test("AI-01 refuses an order for another section's unit", () {
      expectRefused(
        const Reload(unitId: 'soldier-2'),
        CheckLink.right,
        'not_your_unit',
      );
    });

    test('refuses an unknown unit and a unit in storage', () {
      expectRefused(
        const Reload(unitId: 'ghost'),
        CheckLink.right,
        'unknown_unit',
      );
      expectRefused(
        const Reload(unitId: 'soldier-4'),
        CheckLink.right,
        'not_on_field',
      );
    });

    test('HQ-09 HQ-10 refuses an HQ move from anyone but the manager', () {
      expectRefused(
        MoveHq(to: centreOf(f.battle, const CellRef(10, 0))),
        CheckLink.right,
        'not_manager',
        section: 's-2',
        account: 'a-2',
      );
    });

    test('refuses at the rules link what a rule refuses', () {
      expectRefused(
        const Reload(unitId: 'radio-1'),
        CheckLink.rules,
        'no_weapon',
      );
    });

    test('COMBAT-06 refuses at the AP link an order above the AP maximum', () {
      f.changeUnit(
        'scout-1',
        (unit) => unit.copyWith(
          pool: ApPool(
            max: 5,
            recoveryDelayS: 3600,
            value: 5,
            updatedAt: Duration.zero,
          ),
        ),
      );

      expectRefused(
        const Observe(unitId: 'scout-1'),
        CheckLink.ap,
        'cost_above_ap_max',
      );
    });

    test('the AP link lets through a plan that is not refused', () {
      final context = OrderCheckContext(
        command: const Command(
          sender: Sender(accountId: 'a-1', sectionId: 's-1'),
          sentAt: Duration.zero,
          order: Reload(unitId: 'jeep-1'),
        ),
        state: f.battle.state,
      )..plan = const PlanWaits(Duration(hours: 1));

      expect(const ApCheck().check(context), isNull);
    });
  });

  group('AI-05 every accepted command records its origin', () {
    test('and the sequence number the host gives it (decisions 162, 166)', () {
      f
        ..send(const Reload(unitId: 'jeep-1'))
        ..send(const Reload(unitId: 'jeep-1'), origin: Origin.ai)
        ..send(const Reload(unitId: 'jeep-1'), origin: Origin.server);

      expect(
        f.entries
            .skip(1)
            .map((entry) => (entry.command!.origin, entry.command!.seq)),
        equals([(Origin.player, 2), (Origin.ai, 3), (Origin.server, 4)]),
      );
    });
  });

  group('SimulationHost.submit', () {
    test('refuses a battle that does not run', () {
      expect(
        () => f.host.submit(
          'b-9',
          const Command(
            sender: Sender(accountId: 'a-1', sectionId: 's-1'),
            sentAt: Duration.zero,
            order: Reload(unitId: 'jeep-1'),
          ),
          origin: Origin.player,
        ),
        throwsArgumentError,
      );
    });

    test('fails for a battle that fails while it catches up', () {
      f.battle.schedule(
        const Duration(seconds: 1),
        const SectionUnlocks('s-9'),
      );
      f.clock.advance(const Duration(seconds: 2));

      expect(() => f.send(const Reload(unitId: 'jeep-1')), throwsStateError);
      expect(f.host.failed, equals({'b-1'}));
    });
  });
}
