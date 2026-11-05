import 'package:battle_host/src/core/battle_world.dart';
import 'package:battle_pathfinding/battle_pathfinding.dart';
import 'package:battle_rules/battle_rules.dart';

/// {@template work}
/// A build or a repair under way or interrupted: the [action] of
/// `RoleActionRules` on the site or target [workId], building [structure]
/// on [cells] for a build (COMBAT-07, COMBAT-09).
/// {@endtemplate}
final class Work {
  /// {@macro work}
  const new({
    required this.workId,
    required this.action,
    this.structure,
    this.cells = const [],
  });

  /// The construction site, or the repaired target.
  final String workId;

  /// Its AP, duration and progress.
  final TimedAction action;

  /// The structure built; null for a repair.
  final String? structure;

  /// The cells of the structure.
  final List<CellRef> cells;

  /// This work with [action] in place of its own.
  Work withAction(TimedAction action) =>
      Work(workId: workId, action: action, structure: structure, cells: cells);
}

/// {@template unit_state}
/// A unit as of its last update: where it is, its AP pool, health, morale,
/// weapon and what it is doing. AP are lazy (stack decision 1): [pool]
/// holds the value at its last update and the battle's recovery rate, and
/// gives the AP at any later time (COMBAT-02). Morale has no rate: it
/// changes only through events (COMBAT-47), so [morale] holds until the
/// next one.
/// {@endtemplate}
final class UnitState {
  /// {@macro unit_state}
  const new({
    required this.id,
    required this.sectionId,
    required this.type,
    required this.tree,
    required this.xp,
    required this.location,
    required this.pool,
    required this.health,
    required this.morale,
    required this.weapon,
    this.cell,
    this.flying = false,
    this.movingUntil,
    this.work,
    this.observation,
    this.xpHistory,
  });

  /// The unit.
  final String id;

  /// Its section.
  final String sectionId;

  /// The type it plays: its base type evolved by [tree] (UNIT-18).
  final UnitType type;

  /// Its bought nodes.
  final SkillTree tree;

  /// Its XP.
  final UnitXp xp;

  /// Where it is (State, stack decision 7).
  final UnitLocation location;

  /// Its AP pool.
  final ApPool pool;

  /// Its hit points.
  final Health health;

  /// Its morale.
  final double morale;

  /// Its weapon slot.
  final WeaponState weapon;

  /// Its cell while on the field, its destination while it moves; null in
  /// storage or as a prisoner.
  final CellRef? cell;

  /// Whether it flies.
  final bool flying;

  /// The battle time its move ends, while it moves.
  final Duration? movingUntil;

  /// Its build or repair, under way or interrupted.
  final Work? work;

  /// Its observation, for a scout (UNIT-34).
  final Observation? observation;

  /// Whether it is on the field: deployed or carried.
  /// Its recent XP awards, for the repeats that shrink (UNIT-10); null
  /// before its first award.
  final XpHistory? xpHistory;

  bool get onField => location is OnField;

  /// This unit with the values given changed; [clearCell], [clearMove],
  /// [clearWork] remove those.
  UnitState copyWith({
    String? sectionId,
    UnitType? type,
    SkillTree? tree,
    UnitXp? xp,
    XpHistory? xpHistory,
    UnitLocation? location,
    ApPool? pool,
    Health? health,
    double? morale,
    WeaponState? weapon,
    CellRef? cell,
    bool? flying,
    Duration? movingUntil,
    Work? work,
    Observation? observation,
    bool clearCell = false,
    bool clearMove = false,
    bool clearWork = false,
    bool clearObservation = false,
  }) => UnitState(
    id: id,
    sectionId: sectionId ?? this.sectionId,
    type: type ?? this.type,
    tree: tree ?? this.tree,
    xp: xp ?? this.xp,
    xpHistory: xpHistory ?? this.xpHistory,
    location: location ?? this.location,
    pool: pool ?? this.pool,
    health: health ?? this.health,
    morale: morale ?? this.morale,
    weapon: weapon ?? this.weapon,
    cell: clearCell ? null : cell ?? this.cell,
    flying: flying ?? this.flying,
    movingUntil: clearMove ? null : movingUntil ?? this.movingUntil,
    work: clearWork ? null : work ?? this.work,
    observation: clearObservation ? null : observation ?? this.observation,
  );
}

/// {@template section_state}
/// A section in the battle: its commander's account, its team, its guild
/// and role there, its money, its section XP, its spare weapons
/// (decision 151), the end of its full storage lock (HQ-35), if any, and
/// whether the server runs it (AI-06).
/// {@endtemplate}
final class SectionState {
  /// {@macro section_state}
  const new({
    required this.id,
    required this.accountId,
    required this.team,
    required this.money,
    required this.xp,
    this.medals = const {},
    this.guildId,
    this.guildChief = false,
    this.storedWeapons = const StoredWeapons([]),
    this.lockedUntil,
    this.serverManaged = false,
  });

  /// The section.
  final String id;

  /// Its guild; null without one.
  final String? guildId;

  /// Whether its player is the guild's chief (SOC-50).
  final bool guildChief;

  /// Its commander's account.
  final String accountId;

  /// Its team.
  final String team;

  /// Its money, in whole w€.
  final int money;

  /// Its section XP.
  final double xp;

  /// The medals its player holds, by tier (SOC-29).
  final Map<String, int> medals;

  /// Its spare weapons, in storage.
  final StoredWeapons storedWeapons;

  /// The battle time its lock ends; null when it is not locked.
  final Duration? lockedUntil;

  /// Whether the server runs it (AI-06): nothing else tells it from the
  /// other sections.
  final bool serverManaged;

  /// This section with its lock set to [until], or lifted when null.
  SectionState lockedTo(Duration? until) => _copy(lockedUntil: () => until);

  /// This section with [weapons] as its spare weapons.
  SectionState withWeapons(StoredWeapons weapons) =>
      _copy(storedWeapons: weapons);

  /// This section with [money] w€ and [xp] section XP.
  SectionState withWallet({int? money, double? xp}) =>
      _copy(money: money, xp: xp);

  SectionState _copy({
    int? money,
    double? xp,
    StoredWeapons? storedWeapons,
    Duration? Function()? lockedUntil,
  }) => SectionState(
    id: id,
    accountId: accountId,
    team: team,
    money: money ?? this.money,
    xp: xp ?? this.xp,
    medals: medals,
    guildId: guildId,
    guildChief: guildChief,
    storedWeapons: storedWeapons ?? this.storedWeapons,
    lockedUntil: lockedUntil == null ? this.lockedUntil : lockedUntil(),
    serverManaged: serverManaged,
  );
}

/// {@template hq_state}
/// A team's HQ: its [cell], its hit points, its own AP pool (HQ-14,
/// HQ-22) and the end of its move, while it moves.
/// {@endtemplate}
final class HqState {
  /// {@macro hq_state}
  const new({
    required this.cell,
    required this.health,
    required this.pool,
    this.movingUntil,
  });

  /// Where it stands; its destination while it moves.
  final CellRef cell;

  /// Its hit points.
  final Health health;

  /// Its AP pool.
  final ApPool pool;

  /// The battle time its move ends, while it moves.
  final Duration? movingUntil;
}

/// {@template team_state}
/// A team: its HQ, its HQ manager (HQ-05), the player who would manage it
/// had nobody delegated the role, and whether it is eliminated (HQ-18).
/// {@endtemplate}
final class TeamState {
  /// {@macro team_state}
  const new({
    required this.id,
    required this.hq,
    this.managerAccountId,
    this.holderAccountId,
    this.eliminated = false,
  });

  /// The team.
  final String id;

  /// Its HQ.
  final HqState hq;

  /// The account that manages its HQ; null until one of its players logs
  /// in (HQ-07, decision 220).
  final String? managerAccountId;

  /// The account that would manage its HQ had nobody delegated the role:
  /// the first of its players to log in, then each who logged in ranking
  /// above (decisions 220, 227).
  final String? holderAccountId;

  /// Whether it is out of the battle.
  final bool eliminated;

  /// This team with [hq] in place of its HQ.
  TeamState withHq(HqState hq) => TeamState(
    id: id,
    hq: hq,
    managerAccountId: managerAccountId,
    holderAccountId: holderAccountId,
    eliminated: eliminated,
  );

  /// This team with [accountId] as its HQ manager, by delegation (HQ-05).
  TeamState withManager(String accountId) => TeamState(
    id: id,
    hq: hq,
    managerAccountId: accountId,
    holderAccountId: holderAccountId,
    eliminated: eliminated,
  );

  /// This team with [accountId] holding the role by rank, and managing its
  /// HQ (HQ-07, decision 227).
  TeamState withHolder(String accountId) => TeamState(
    id: id,
    hq: hq,
    managerAccountId: accountId,
    holderAccountId: accountId,
    eliminated: eliminated,
  );

  /// This team out of the battle (HQ-18).
  TeamState get out => TeamState(
    id: id,
    hq: hq,
    managerAccountId: managerAccountId,
    holderAccountId: holderAccountId,
    eliminated: true,
  );
}

/// {@template relic_push}
/// A push under way (RELIC-24), planned when it starts: the relic reaches
/// the cells of its path, up to [cell], at the [arrivals], having spent
/// [spent] AP of its pot by each. The [pushers] push it, those inside the
/// radius when it starts (decision 225). It crushes the units [crushed] on
/// the way, each where it meets them (RELIC-25), and, when it goes over an
/// island's edge, lands on [landing] (RELIC-22).
/// {@endtemplate}
final class RelicPush {
  /// {@macro relic_push}
  new({
    required this.cell,
    required List<Duration> arrivals,
    required List<double> spent,
    required Set<String> pushers,
    List<({String unitId, int at})> crushed = const [],
    this.landing,
  }) : arrivals = List.unmodifiable(arrivals),
       spent = List.unmodifiable(spent),
       pushers = Set.unmodifiable(pushers),
       crushed = List.unmodifiable(crushed);

  /// Where it stops.
  final CellRef cell;

  /// The battle time it reaches each cell of its path, from its start.
  final List<Duration> arrivals;

  /// The AP of its pot it has spent by each cell of its path.
  final List<double> spent;

  /// The pushers that push it.
  final Set<String> pushers;

  /// The units it crushes, with the index of the cell where it meets each.
  final List<({String unitId, int at})> crushed;

  /// The ground cell it falls on; null when it does not fall.
  final CellRef? landing;

  /// How many cells of its path it covers.
  int get reached => arrivals.length - 1;

  /// The battle time it stops.
  Duration get endsAt => arrivals.last;

  /// The index of the last cell of its path it has reached at [time].
  int reachedAt(Duration time) =>
      arrivals.lastIndexWhere((arrival) => arrival <= time);
}

/// {@template relic_state}
/// A relic: its [cell], its owner, its pots (RELIC-05, RELIC-24), the
/// path its owner's push follows (decision 219), the units that pushed
/// since its push pot was last empty, and the push under way.
/// {@endtemplate}
final class RelicState {
  /// {@macro relic_state}
  const new({
    required this.id,
    required this.cell,
    this.owner,
    this.capturePot,
    this.pushPot,
    this.pushPath,
    this.pushers = const {},
    this.crushes = 0,
    this.push,
  });

  /// The relic.
  final String id;

  /// Where it stands; where it stops while it is pushed.
  final CellRef cell;

  /// The team that owns it; null before its first capture.
  final String? owner;

  /// The capture under way, if any.
  final CapturePot? capturePot;

  /// Its owner's push pot, if any.
  final PushPot? pushPot;

  /// The path of the push, chosen while the pot was empty.
  final List<CellRef>? pushPath;

  /// The units that put AP into its push pot since it was last empty:
  /// those on the field inside the capture radius push it (RELIC-24,
  /// decision 225).
  final Set<String> pushers;

  /// The units its push crushed since its path was chosen: they count
  /// among those its extra pushers may crush (RELIC-25, decision 185).
  final int crushes;

  /// The push under way; null while it stands still.
  final RelicPush? push;

  /// This relic with the pots and path given.
  RelicState withPots({
    CapturePot? capturePot,
    PushPot? pushPot,
    List<CellRef>? pushPath,
  }) => copyWith(
    capturePot: () => capturePot ?? this.capturePot,
    pushPot: () => pushPot ?? this.pushPot,
    pushPath: () => pushPath ?? this.pushPath,
  );

  /// This relic with the values given changed; a function gives a value
  /// that may be null.
  RelicState copyWith({
    CellRef? cell,
    String? owner,
    CapturePot? Function()? capturePot,
    PushPot? Function()? pushPot,
    List<CellRef>? Function()? pushPath,
    Set<String>? pushers,
    int? crushes,
    RelicPush? Function()? push,
  }) => RelicState(
    id: id,
    cell: cell ?? this.cell,
    owner: owner ?? this.owner,
    capturePot: capturePot == null ? this.capturePot : capturePot(),
    pushPot: pushPot == null ? this.pushPot : pushPot(),
    pushPath: pushPath == null ? this.pushPath : pushPath(),
    pushers: pushers ?? this.pushers,
    crushes: crushes ?? this.crushes,
    push: push == null ? this.push : push(),
  );
}

/// {@template dropped_weapon_state}
/// A weapon lying on [cell] (COMBAT-29): it vanishes at its `goneAt`.
/// {@endtemplate}
final class DroppedWeaponState {
  /// {@macro dropped_weapon_state}
  const new({required this.id, required this.dropped, required this.cell});

  /// The dropped weapon.
  final String id;

  /// Its weapon and when it vanishes.
  final DroppedWeapon dropped;

  /// Where it lies.
  final CellRef cell;
}

/// {@template battle_state}
/// Everything a battle holds in memory (decision 3), immutable: each
/// change makes a new state that shares what did not change.
/// {@endtemplate}
final class BattleState {
  /// {@macro battle_state}
  const new({
    required this.units,
    required this.sections,
    required this.teams,
    required this.relics,
    required this.weather,
    this.dropped = const {},
    this.delta = const WorldDelta(),
    this.offers = const {},
    this.victory,
    this.eliminated = const [],
  });

  /// The units, by ID.
  final Map<String, UnitState> units;

  /// The sections, by ID.
  final Map<String, SectionState> sections;

  /// The teams, by ID, in the order of their HQ starting points.
  final Map<String, TeamState> teams;

  /// The relics, by ID.
  final Map<String, RelicState> relics;

  /// The weather (MAP-31).
  final String weather;

  /// The weapons on the ground, by ID.
  final Map<String, DroppedWeaponState> dropped;

  /// The world's delta layer (MAP-06).
  final WorldDelta delta;

  /// Relic owners, the teams still in, the running hold and the winner
  /// (RELIC-14, HQ-45); null only for a state built by hand.
  final VictoryState? victory;

  /// The teams eliminated, first first (HQ-18).
  final List<String> eliminated;

  /// Whether the battle has ended.
  bool get ended => victory?.winner != null;

  /// The prisoner offers waiting for an answer, by offer id: the sequence
  /// number of the order that posted it (COMBAT-44).
  final Map<int, PrisonerOffer> offers;

  /// The prisoners [captor] holds, with their owners (COMBAT-43).
  PrisonerStorage prisonersOf(String captor) => PrisonerStorage({
    for (final unit in units.values)
      if (unit.location case Prisoner(:final captorSectionId)
          when captorSectionId == captor)
        unit.id: unit.sectionId,
  });

  /// This state with [unit] in place of the unit of its ID.
  BattleState withUnit(UnitState unit) =>
      _with(units: {...units, unit.id: unit});

  /// This state without the unit [unitId].
  BattleState withoutUnit(String unitId) =>
      _with(units: {...units}..remove(unitId));

  /// This state with [section] in place of the section of its ID.
  BattleState withSection(SectionState section) =>
      _with(sections: {...sections, section.id: section});

  /// This state with [team] in place of the team of its ID.
  BattleState withTeam(TeamState team) =>
      _with(teams: {...teams, team.id: team});

  /// This state with [relic] in place of the relic of its ID.
  BattleState withRelic(RelicState relic) =>
      _with(relics: {...relics, relic.id: relic});

  /// This state with [weapon] on the ground.
  BattleState withDropped(DroppedWeaponState weapon) =>
      _with(dropped: {...dropped, weapon.id: weapon});

  /// This state without the dropped weapon [id].
  BattleState withoutDropped(String id) =>
      _with(dropped: {...dropped}..remove(id));

  /// This state with [delta] as its delta layer.
  BattleState withDelta(WorldDelta delta) => _with(delta: delta);

  /// This state without the relic [relicId], which left the battle
  /// (RELIC-26).
  BattleState withoutRelic(String relicId) =>
      _with(relics: {...relics}..remove(relicId));

  /// This state with [offer] waiting as [offerId].
  BattleState withOffer(int offerId, PrisonerOffer offer) =>
      _with(offers: {...offers, offerId: offer});

  /// This state without the offer [offerId].
  BattleState withoutOffer(int offerId) =>
      _with(offers: {...offers}..remove(offerId));

  /// This state with [victory] as its victory state, and [eliminated] as
  /// its eliminated teams when given.
  BattleState withVictory(VictoryState victory, {List<String>? eliminated}) =>
      _with(victory: victory, eliminated: eliminated);

  BattleState _with({
    Map<String, UnitState>? units,
    Map<String, SectionState>? sections,
    Map<String, TeamState>? teams,
    Map<String, RelicState>? relics,
    Map<String, DroppedWeaponState>? dropped,
    WorldDelta? delta,
    Map<int, PrisonerOffer>? offers,
    VictoryState? victory,
    List<String>? eliminated,
  }) => BattleState(
    units: units == null ? this.units : Map.unmodifiable(units),
    sections: sections == null ? this.sections : Map.unmodifiable(sections),
    teams: teams == null ? this.teams : Map.unmodifiable(teams),
    relics: relics == null ? this.relics : Map.unmodifiable(relics),
    weather: weather,
    dropped: dropped == null ? this.dropped : Map.unmodifiable(dropped),
    delta: delta ?? this.delta,
    offers: offers == null ? this.offers : Map.unmodifiable(offers),
    victory: victory ?? this.victory,
    eliminated: eliminated == null
        ? this.eliminated
        : List.unmodifiable(eliminated),
  );
}
