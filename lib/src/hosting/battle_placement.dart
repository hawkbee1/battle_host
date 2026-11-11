import 'package:battle_backend/battle_backend.dart';
import 'package:battle_host/src/core/battle.dart';
import 'package:battle_host/src/core/battle_setup.dart';
import 'package:battle_host/src/core/simulation_host.dart';
import 'package:battle_host/src/ports/error_reporter.dart';
import 'package:battle_protocol/battle_protocol.dart';
import 'package:battle_rules/battle_rules.dart';
import 'package:hawkbee_schema/hawkbee_schema.dart';

/// {@template battle_placement}
/// Which host runs which battle (stack decision 1, hosting), recorded in
/// the `battles` rows of the Hawkbee database (M5 Issue 19), and where
/// clients reach it, in the `hosts` rows (M6 Issue 6).
///
/// A host process serves its [mapIds]. When it [sync]s, it writes its
/// public [address] and the time in its `hosts` row, then claims each
/// running battle on one of its maps that no live host holds, by writing
/// its [hostId] in the row's `host`, and runs the battles that name it: a
/// battle with a snapshot is recovered (stack decision 2), the others start
/// from their rows. A host is live while its `hosts` row is younger than
/// the [lease]; the battles of one that is not (stopped, or cut off from
/// Appwrite) move to another host of their map. Two hosts of one map may
/// claim the same battle at once: the row keeps the last write, and the
/// host it does not name lets the battle go.
///
/// A battle it runs whose row names another host has moved: it stops
/// running it, and the endpoints send its clients to look for the new
/// host. A section that joined the war while the battle runs is in its row's
/// teams (the backend put it there, SOC-30): at each sync the host admits the
/// sections of the row that the battle does not have, with the server's
/// `AdmitSection`, which the log holds and a replay makes again; one it
/// cannot admit is reported and tried again at the next sync.
///
/// A battle it claims may have run elsewhere since this host last held it,
/// so its own write-ahead log of it is discarded: the uploaded log is its
/// history. A host that [leave]s lets go of its battles whose
/// log is all uploaded, so that another host takes them at once.
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
    required this.address,
    required this.reporter,
    this.lease = const Duration(minutes: 1),
  });

  /// The tables of the Hawkbee database.
  final Rows rows;

  /// The host process.
  final SimulationHost host;

  /// This host's ID, in the `host` column of the battles it runs.
  final String hostId;

  /// The maps it serves.
  final Set<String> mapIds;

  /// Its public address, the base URL of its endpoints, in its `hosts`
  /// row: `https://…` live, behind the reverse proxy that ends TLS.
  final String address;

  /// How long a host is live after it last wrote its `hosts` row: several
  /// syncs, so that one slow look at the battles moves none.
  final Duration lease;

  /// Where errors go.
  final ErrorReporter reporter;

  final _setups = <String, BattleSetup>{};
  final _reported = <String>{};

  static const String _battles = AppwriteIds.battlesTableId;
  static const String _hosts = AppwriteIds.hostsTableId;

  /// Writes its `hosts` row, lets go of the battles that moved, claims the
  /// running battles of its maps that no live host holds, and runs those
  /// that name it; returns the battles it began to run. A battle that
  /// fails to start or recover is reported and tried again at the next
  /// sync.
  Future<List<String>> sync() async {
    final now = host.clock.now();
    await rows.put(
      _hosts,
      hostId,
      HostRow(address: address, seenAt: now).toData(),
    );
    final begun = <String>[];
    final found = await rows.find(_battles, {
      'status': BattleStatus.running.name,
    });
    final live = <String, bool>{};
    for (final (:id, :data) in found) {
      final row = BattleRow.fromData(id, data);
      if (!mapIds.contains(row.mapId)) continue;
      final named = row.host;
      if (host[id] != null) {
        if (named != hostId) {
          _let(id);
        } else {
          await _admitNewcomers(row);
        }
        continue;
      }
      if (named != null &&
          named != hostId &&
          (live[named] ??= await _live(named, now))) {
        continue;
      }
      try {
        if (named != hostId) {
          if (!await _claim(row)) continue;
          host.wal.discard(id);
        }
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

  /// Admits to the running battle of [row] each section its teams name that
  /// the battle does not have (SOC-30). A section that joined during the
  /// battle is a new one (SOC-18): its commander and its starting money. A
  /// section with more than that, or a refused admission, is reported.
  Future<void> _admitNewcomers(BattleRow row) async {
    final battle = host[row.id]!;
    for (final MapEntry(key: team, value: ids) in row.teams.entries) {
      for (final id in ids) {
        if (battle.state.sections.containsKey(id)) continue;
        try {
          final section = await _section(id);
          if (!_isNew(section)) {
            throw StateError('the section $id is not a new one: not admitted');
          }
          final handled = host.submit(
            row.id,
            Command(
              sender: Sender(accountId: section.accountId, sectionId: id),
              sentAt: battle.time,
              order: AdmitSection(
                team: team,
                money: section.money,
                units: [
                  for (final unit in section.units)
                    AdmittedUnit(unitId: unit.id, unitType: unit.type),
                ],
              ),
            ),
            origin: Origin.server,
          );
          if (handled.refusal case final refusal?) {
            throw StateError('the section $id is not admitted: $refusal');
          }
        } on Object catch (error, stackTrace) {
          await reporter.report(error, stackTrace, battleId: row.id);
        }
      }
    }
  }

  /// Whether [section] is what a newcomer starts with, which is all an
  /// `AdmitSection` carries: no XP, no spare weapon, and units with no tree
  /// step, no XP and no other weapon than their type's.
  static bool _isNew(SectionSetup section) =>
      section.xp == 0 &&
      section.weapons.isEmpty &&
      section.units.every(
        (unit) =>
            (unit.tree?.steps.isEmpty ?? true) &&
            unit.xp.earned == 0 &&
            unit.xp.unspent == 0 &&
            unit.weapon == null,
      );

  /// Lets go of every battle it runs whose log is all uploaded, in their
  /// rows, and deletes its `hosts` row: the host stops, after its battles'
  /// last snapshots ([SimulationHost.settle]). Its other battles move once
  /// its lease ends, or come back to it if it starts again first.
  Future<void> leave() async {
    for (final battle in host.battles.toList()) {
      if (!host.saved(battle.id)) continue;
      final data = await rows.get(_battles, battle.id);
      if (data == null) continue;
      final row = BattleRow.fromData(battle.id, data);
      if (row.host != hostId) continue;
      await rows.put(_battles, row.id, row.copyWith(host: () => null).toData());
      _let(battle.id);
    }
    await rows.delete(_hosts, hostId);
  }

  void _let(String battleId) {
    host.release(battleId);
    _setups.remove(battleId);
  }

  Future<bool> _live(String other, DateTime now) async {
    final data = await rows.get(_hosts, other);
    return data != null && HostRow.fromData(data).aliveAt(now, lease);
  }

  Future<bool> _claim(BattleRow row) async {
    await rows.put(_battles, row.id, row.copyWith(host: () => hostId).toData());
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
  /// `battle.yaml`'s, except those its row overrides (decisions 172, 238).
  ///
  /// Throws a [StateError] for a war, section or guild with no row, a
  /// [GameDataException] for settings the plan refuses, and a
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
      settings: host.definitions.settingsWith(row.settings),
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
