import 'package:battle_host/battle_host.dart';
import 'package:battle_protocol/battle_protocol.dart';
import 'package:battle_rules/battle_rules.dart';
import 'package:test/test.dart';

import '../../helpers/orders.dart';

/// A newcomer's section: `s-3` of `a-3`, in `team-2`, with the starting money
/// and its commander (SOC-15, SOC-30).
const _newcomer = AdmitSection(
  team: 'team-2',
  money: 500,
  units: [AdmittedUnit(unitId: 's-3-commander', unitType: 'commander')],
);

void main() {
  late OrdersFixture f;

  setUp(() => f = OrdersFixture());

  /// The server sends [order] for the section [section] of [account].
  HandledOrder admit(
    Order order, {
    String section = 's-3',
    String account = 'a-3',
    Origin origin = Origin.server,
  }) => f.send(order, section: section, account: account, origin: origin);

  group('SOC-30 the admission of a newcomer to a running battle', () {
    test(
      'SOC-30 the server admits the section of the sender to the team it was '
      'given, with its money and its commander',
      () {
        final handled = admit(_newcomer);

        expect(handled.refusal, isNull);
        expect(handled.events, [
          const SectionJoined(
            sectionId: 's-3',
            accountId: 'a-3',
            team: 'team-2',
            units: [JoinedUnit(unitId: 's-3-commander', unitType: 'commander')],
          ),
        ]);
        final section = f.battle.state.sections['s-3']!;
        expect(
          (section.team, section.accountId, section.money, section.xp),
          ('team-2', 'a-3', 500, 0.0),
        );
        expect(section.serverManaged, isFalse);
        expect(f.unit('s-3-commander').sectionId, 's-3');
      },
    );

    test(
      'UNIT-31 HQ-03 the units of a newcomer start in storage with full AP and '
      'HP, as at the start of a battle',
      () {
        admit(_newcomer);

        final commander = f.unit('s-3-commander');
        expect(commander.location, isA<Stored>());
        expect(commander.pool.apAt(f.battle.time), commander.pool.max);
        expect(commander.health.current, commander.health.max);
        // The same as a commander the battle started with.
        expect(commander.pool.max, f.unit('commander-1').pool.max);
        expect(commander.morale, f.unit('commander-2').morale);
      },
    );

    test('SOC-30 the newcomer logs in (HQ-07) and buys units with its '
        'starting money', () {
      admit(_newcomer);

      final login = admit(const EnterBattle());
      final bought = admit(const BuyUnit(unitType: 'soldier'));

      expect(login.refusal, isNull);
      expect(bought.refusal, isNull);
      expect(f.battle.state.sections['s-3']!.money, lessThan(500));
      expect(
        f.battle.state.units.values.where((unit) => unit.sectionId == 's-3'),
        hasLength(2),
      );
    });

    test('SOC-30 an admission is in the log, from the server, so that a '
        'replay makes it again', () {
      admit(_newcomer);

      final entry = f.entries.last;
      expect(entry.command!.order, _newcomer);
      expect(entry.command!.origin, Origin.server);
      expect(
        entry.command!.sender,
        const Sender(accountId: 'a-3', sectionId: 's-3'),
      );
    });

    test('SOC-30 the section of another team joins its own: the team is '
        'the one given', () {
      admit(
        const AdmitSection(
          team: 'team-1',
          money: 500,
          units: [AdmittedUnit(unitId: 's-3-commander', unitType: 'commander')],
        ),
      );

      expect(f.battle.state.sections['s-3']!.team, 'team-1');
    });

    for (final origin in [Origin.player, Origin.ai]) {
      test('decision 220 SOC-30 an order of $origin cannot admit a section: '
          'only the server does', () {
        final handled = admit(_newcomer, origin: origin);

        expect(handled.refusal?.code, 'not_server');
        expect(f.battle.state.sections, isNot(contains('s-3')));
      });
    }

    test('SOC-30 refuses a section that is in the battle already', () {
      expect(
        admit(_newcomer, section: 's-1', account: 'a-1').refusal?.code,
        'section_exists',
      );
    });

    test('SOC-45 refuses an account that has a section in the battle '
        'already: one section per war', () {
      expect(
        admit(_newcomer, section: 's-9', account: 'a-1').refusal?.code,
        'account_seated',
      );
      expect(f.battle.state.sections, isNot(contains('s-9')));
    });

    test('SOC-30 refuses a team the battle does not have', () {
      expect(
        admit(
          const AdmitSection(
            team: 'team-9',
            money: 500,
            units: [AdmittedUnit(unitId: 'u-9', unitType: 'commander')],
          ),
        ).refusal?.code,
        'unknown_team',
      );
    });

    test('HQ-18 refuses a team that is out of the battle', () {
      f.battle.change((state) => state.withTeam(state.teams['team-2']!.out));

      expect(admit(_newcomer).refusal?.code, 'team_eliminated');
    });

    test('SOC-30 refuses a unit type the battle does not have', () {
      expect(
        admit(
          const AdmitSection(
            team: 'team-2',
            money: 500,
            units: [AdmittedUnit(unitId: 'u-9', unitType: 'dragon')],
          ),
        ).refusal?.code,
        'unknown_type',
      );
      expect(f.battle.state.sections, isNot(contains('s-3')));
    });

    test('SOC-30 refuses a unit that is in the battle already, or twice in '
        'the admission', () {
      expect(
        admit(
          const AdmitSection(
            team: 'team-2',
            money: 500,
            units: [AdmittedUnit(unitId: 'soldier-1', unitType: 'soldier')],
          ),
        ).refusal?.code,
        'unit_exists',
      );
      expect(
        admit(
          const AdmitSection(
            team: 'team-2',
            money: 500,
            units: [
              AdmittedUnit(unitId: 'u-9', unitType: 'commander'),
              AdmittedUnit(unitId: 'u-9', unitType: 'soldier'),
            ],
          ),
        ).refusal?.code,
        'unit_exists',
      );
      expect(f.battle.state.sections, isNot(contains('s-3')));
    });

    test('SOC-30 a section is admitted once: a second admission of it is '
        'refused and changes nothing', () {
      admit(_newcomer);
      final before = f.battle.state.units.length;

      expect(admit(_newcomer).refusal?.code, 'section_exists');
      expect(f.battle.state.units, hasLength(before));
    });
  });

  group('Battle.admit', () {
    const section = SectionSetup(
      id: 's-4',
      accountId: 'a-4',
      units: [UnitSetup(id: 'u-4', type: 'commander')],
    );

    test('SOC-30 puts the section and its units in the state', () {
      f.battle.admit(section, team: 'team-1');

      expect(f.battle.state.sections['s-4']!.team, 'team-1');
      expect(f.battle.state.units['u-4']!.sectionId, 's-4');
    });

    test('throws for a team the battle does not have', () {
      expect(
        () => f.battle.admit(section, team: 'team-9'),
        throwsArgumentError,
      );
    });

    test('throws for a section or a unit the battle has', () {
      expect(
        () => f.battle.admit(
          const SectionSetup(id: 's-1', accountId: 'a-4', units: []),
          team: 'team-1',
        ),
        throwsArgumentError,
      );
      expect(
        () => f.battle.admit(
          const SectionSetup(
            id: 's-4',
            accountId: 'a-4',
            units: [UnitSetup(id: 'soldier-1', type: 'soldier')],
          ),
          team: 'team-1',
        ),
        throwsArgumentError,
      );
      expect(f.battle.state.sections, isNot(contains('s-4')));
    });
  });
}
