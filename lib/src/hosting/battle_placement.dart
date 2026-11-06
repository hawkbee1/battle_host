import 'package:battle_backend/battle_backend.dart';
import 'package:battle_host/src/core/battle.dart';
import 'package:battle_host/src/core/battle_setup.dart';
import 'package:battle_host/src/core/simulation_host.dart';
import 'package:battle_host/src/ports/error_reporter.dart';
import 'package:battle_rules/battle_rules.dart';
import 'package:hawkbee_schema/hawkbee_schema.dart';

/// {@template battle_placement}
/// Which host runs which battle (stack decision 1, hosting), recorded in
/// the `battles` rows of the Hawkbee database (M5 Issue 19).
///
/// A host process serves its [mapIds]. When it [sync]s, it claims each
/// running battle on one of them that no host holds, by writing its
/// [hostId] in the row's `host`, and runs the battles that name it: a
/// battle with a snapshot is recovered (stack decision 2), the others start
/// from their rows. Two hosts of one map may claim the same battle at
/// once: the row keeps the last write, and the host it does not name lets
/// the battle go.
///
/// Once a battle has ended, [report] writes its result in its row (status
/// `ended`, winner, `BattleResult`), which triggers `end_battle`
/// (M5 Issue 18).
/// {@endtemplate}
final class BattlePlacement {
  /// {@macro battle_placement}
  new({
    required this.rows,
    required this.host,
    required this.hostId,
    required this.mapIds,
    required this.reporter,
  });

  /// The tables of the Hawkbee database.
  final Rows rows;

  /// The host process.
  final SimulationHost host;

  /// This host's ID, in the `host` column of the battles it runs.
  final String hostId;

  /// The maps it serves.
  final Set<String> mapIds;

  /// Where errors go.
  final ErrorReporter reporter;

  final _setups = <String, BattleSetup>{};
  final _reported = <String>{};

  static const String _battles = AppwriteIds.battlesTableId;

  /// Claims the running battles of its maps that no host holds and runs
  /// those that name it; returns the battles it began to run. A battle
  /// that fails to start or recover is reported and tried again at the
  /// next sync.
  Future<List<String>> sync() async {
    final begun = <String>[];
    final found = await rows.find(_battles, {
      'status': BattleStatus.running.name,
    });
    for (final (:id, :data) in found) {
      final row = BattleRow.fromData(id, data);
      if (!mapIds.contains(row.mapId) || host[id] != null) continue;
      if (row.host != null && row.host != hostId) continue;
      try {
        if (row.host == null && !await _claim(row)) continue;
        final setup = await setupOf(row);
        _setups[id] = setup;
        if (await host.snapshots.latest(id) == null) {
          host.start(setup);
        } else {
          await host.recover(id);
        }
        begun.add(id);
      } on Object catch (error, stackTrace) {
        await reporter.report(error, stackTrace, battleId: id);
      }
    }
    return begun;
  }

  Future<bool> _claim(BattleRow row) async {
    await rows.put(_battles, row.id, row.copyWith(host: hostId).toData());
    final again = await rows.get(_battles, row.id);
    return again != null && BattleRow.fromData(row.id, again).host == hostId;
  }

  /// Writes the result of each battle it runs that has ended and is not
  /// reported yet; returns those battles.
  Future<List<String>> report() async {
    final done = <String>[];
    for (final battle in host.battles.toList()) {
      final winner = battle.state.victory?.winner;
      if (winner == null || _reported.contains(battle.id)) continue;
      final data = await rows.get(_battles, battle.id);
      if (data == null) continue;
      final result = resultOf(battle, _setups[battle.id]);
      await rows.put(
        _battles,
        battle.id,
        BattleRow.fromData(battle.id, data)
            .copyWith(
              status: BattleStatus.ended,
              winner: winner.team,
              result: result,
            )
            .toData(),
      );
      _reported.add(battle.id);
      done.add(battle.id);
    }
    return done;
  }

  /// The setup of the running battle [row]: its teams in the order of its
  /// row, each section as its row keeps it (UNIT-30), its guild role
  /// (SOC-50), and the money floor of its war (SOC-10). Its settings are
  /// `battle.yaml`'s (decision 172).
  ///
  /// Throws a [StateError] for a war, section or guild with no row, and a
  /// [FormatException] for a tree step of no evolvable stat.
  Future<BattleSetup> setupOf(BattleRow row) async {
    final war = WarRow.fromData(
      row.warId,
      await _row(AppwriteIds.warsTableId, row.warId),
    );
    return BattleSetup(
      battleId: row.id,
      mapId: row.mapId,
      seed: row.seed,
      settings: host.definitions.battle,
      minStartingMoney: war.minStartingMoney,
      teams: [
        for (final MapEntry(key: team, value: ids) in row.teams.entries)
          TeamSetup(
            id: team,
            sections: [for (final id in ids) await _section(id)],
          ),
      ],
    );
  }

  Future<RowData> _row(String table, String id) async =>
      await rows.get(table, id) ?? (throw StateError('$table has no row $id'));

  Future<SectionSetup> _section(String id) async {
    final section = SectionRow.fromData(
      id,
      await _row(AppwriteIds.sectionsTableId, id),
    );
    final guildId = section.guildId;
    final guild = guildId == null
        ? null
        : GuildRow.fromData(
            guildId,
            await _row(AppwriteIds.guildsTableId, guildId),
          );
    final stats = {for (final stat in EvolvableStat.values) stat.key: stat};
    final kept = section.kept;
    return SectionSetup(
      id: id,
      accountId: section.accountId,
      money: kept.money,
      xp: kept.xp,
      weapons: kept.weapons,
      guildId: guildId,
      guildChief: guild?.roles[id] == 'chief',
      units: [
        for (final unit in kept.units)
          UnitSetup(
            id: unit.id,
            type: unit.type,
            tree: SkillTree({
              for (final MapEntry(:key, :value) in unit.tree.entries)
                stats[key] ?? (throw FormatException('no evolvable stat $key')):
                    value,
            }),
            xp: UnitXp(earned: unit.xpEarned, unspent: unit.xpUnspent),
            weapon: unit.weapon,
          ),
      ],
    );
  }
}

/// What each section of [battle], which has ended, keeps (UNIT-30): its
/// money, section XP, spare weapons and units still in the battle, each with
/// its XP, tree and weapon (null for its type's default).
///
/// The XP each section's units earned in the battle, the dead included,
/// comes from its section XP, which takes `section_xp_share` of every XP
/// point (UNIT-14): its gain since [setup], the battle's start, over that
/// share (SOC-47). With no setup, all its section XP counts.
BattleResult resultOf(Battle battle, BattleSetup? setup) {
  final state = battle.state;
  final share = battle.definitions.units.progression.sectionXpShare;
  final start = {
    for (final team in setup?.teams ?? const <TeamSetup>[])
      for (final section in team.sections) section.id: section.xp,
  };
  final units = <String, List<KeptUnit>>{};
  for (final unit in state.units.values) {
    final weapon = unit.weapon.weapon?.id;
    (units[unit.sectionId] ??= []).add(
      KeptUnit(
        id: unit.id,
        type: unit.type.id,
        xpEarned: unit.xp.earned,
        xpUnspent: unit.xp.unspent,
        tree: {
          for (final MapEntry(:key, :value) in unit.tree.steps.entries)
            key.key: value,
        },
        weapon: weapon == unit.type.weapons.defaultWeapon ? null : weapon,
      ),
    );
  }
  return BattleResult(
    winner: state.victory!.winner!.team,
    sections: {
      for (final section in state.sections.values)
        section.id: KeptSection(
          money: section.money,
          xp: section.xp,
          weapons: section.storedWeapons.weapons,
          units: units[section.id] ?? const [],
        ),
    },
    earned: {
      for (final section in state.sections.values)
        section.id: share == 0
            ? 0
            : (section.xp - (start[section.id] ?? 0)) / share,
    },
  );
}
