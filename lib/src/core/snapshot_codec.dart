import 'dart:convert';
import 'dart:typed_data';

import 'package:battle_host/src/core/battle.dart';
import 'package:battle_host/src/core/battle_state.dart';
import 'package:battle_host/src/core/battle_world.dart';
import 'package:battle_map/battle_map.dart';
import 'package:battle_pathfinding/battle_pathfinding.dart';
import 'package:battle_protocol/battle_protocol.dart' as wire;
import 'package:battle_rules/battle_rules.dart';

/// The version of the snapshot format. A snapshot of another version is
/// not read: a host restores only the snapshots of its own version.
const snapshotVersion = 1;

/// A battle restored from its snapshot's data: what the battle holds, and
/// the wall time it started at.
typedef DecodedSnapshot = ({BattleMemento memento, DateTime startedAt});

typedef _Json = Map<String, Object?>;

/// [memento], of a battle that started at the wall time [startedAt],
/// encoded: JSON in UTF-8, exact for every value (doubles print as the
/// shortest text that reads back as the same double). Maps keep their
/// order, so a restored battle walks its units in the same order.
Uint8List encodeSnapshot(
  BattleMemento memento, {
  required DateTime startedAt,
}) => utf8.encode(
  jsonEncode({
    'v': snapshotVersion,
    'battle': memento.battleId,
    'map': memento.mapId,
    'startedAt': startedAt.toUtc().microsecondsSinceEpoch,
    'settings': memento.settings.toData(),
    'seed': memento.seed,
    'random': memento.randomState,
    'minStartingMoney': memento.minStartingMoney,
    'time': memento.time.inMicroseconds,
    'nextSeq': memento.nextSeq,
    'timersFired': memento.timersFired,
    'timers': [
      for (final (at, timer) in memento.timers)
        {'at': at.inMicroseconds, ..._timer(timer)},
    ],
    'state': _state(memento.state),
    if (memento.alerts.isNotEmpty)
      'alerts': {
        for (final MapEntry(:key, :value) in memento.alerts.entries)
          key: [
            for (final alert in value)
              {
                'at': alert.at.inMicroseconds,
                'relic': alert.relicId,
                'team': alert.team,
              },
          ],
      },
  }),
);

/// The snapshot [data] decoded, with the unit and weapon types of the
/// shared [definitions].
///
/// Throws a [FormatException] for data that is not a snapshot of this
/// version, names a type the definitions lack or holds a waiting command
/// the protocol does not read, and a [GameDataException] for settings
/// `battle.yaml` would not hold.
DecodedSnapshot decodeSnapshot(
  Uint8List data, {
  required GameData definitions,
}) {
  final json = jsonDecode(utf8.decode(data));
  if (json is! _Json) {
    throw const FormatException('not a battle snapshot: not a JSON object');
  }
  final root = _Reader(json, r'$');
  final version = root.integer('v');
  if (version != snapshotVersion) {
    throw FormatException('not a battle snapshot of version 1: $version');
  }
  final decoder = _Decoder(definitions);
  return (
    memento: BattleMemento(
      battleId: root.text('battle'),
      mapId: root.text('map'),
      settings: BattleSettings.parse(jsonEncode(root.item('settings').json)),
      seed: root.integer('seed'),
      randomState: root.integers('random'),
      minStartingMoney: root.integer('minStartingMoney'),
      time: root.time('time'),
      nextSeq: root.integer('nextSeq'),
      timersFired: root.integer('timersFired'),
      timers: [
        for (final timer in root.items('timers'))
          (timer.time('at'), decoder.timer(timer)),
      ],
      state: decoder.state(root.item('state')),
      alerts: {
        if (root.maybeItem('alerts') case final alerts?)
          for (final account in alerts.json.keys)
            account: [
              for (final alert in alerts.items(account))
                wire.RelicAlert(
                  at: alert.time('at'),
                  relicId: alert.text('relic'),
                  team: alert.text('team'),
                ),
            ],
      },
    ),
    startedAt: DateTime.fromMicrosecondsSinceEpoch(
      root.integer('startedAt'),
      isUtc: true,
    ),
  );
}

_Json _timer(BattleTimer timer) => switch (timer) {
  SectionUnlocks(:final sectionId) => {
    'kind': 'sectionUnlocks',
    'section': sectionId,
  },
  RunOrder(:final command) => {
    'kind': 'runOrder',
    'command': jsonDecode(
      const wire.JsonProtocolCodec().encodeCommand(command),
    ),
  },
  WorkEnds(:final unitId) => {'kind': 'workEnds', 'unit': unitId},
  RecallEnds(:final unitId) => {'kind': 'recallEnds', 'unit': unitId},
  CaptureEnds(:final relicId) => {'kind': 'captureEnds', 'relic': relicId},
  RelicArrives(:final relicId) => {'kind': 'relicArrives', 'relic': relicId},
  ServerCheck(:final unitId) => {'kind': 'serverCheck', 'unit': unitId},
  HoldEnds() => {'kind': 'holdEnds'},
  FlightEnds(:final unitId, :final flying) => {
    'kind': 'flightEnds',
    'unit': unitId,
    'flying': flying,
  },
};

_Json _state(BattleState state) => {
  'weather': state.weather,
  'units': [for (final unit in state.units.values) _unit(unit)],
  'sections': [for (final section in state.sections.values) _section(section)],
  'teams': [for (final team in state.teams.values) _team(team)],
  'relics': [for (final relic in state.relics.values) _relic(relic)],
  'dropped': [
    for (final dropped in state.dropped.values)
      {
        'id': dropped.id,
        'weapon': dropped.dropped.weapon.id,
        'goneAt': dropped.dropped.goneAt.inMicroseconds,
        'cell': _cell(dropped.cell),
      },
  ],
  'delta': _delta(state.delta),
  'offers': [
    for (final MapEntry(key: id, value: offer) in state.offers.entries)
      {'id': id, ..._offer(offer)},
  ],
  if (state.victory case final victory?) 'victory': _victory(victory),
  'eliminated': state.eliminated,
};

_Json _unit(UnitState unit) => {
  'id': unit.id,
  'section': unit.sectionId,
  'type': unit.type.id,
  'tree': {
    for (final MapEntry(key: stat, value: steps) in unit.tree.steps.entries)
      stat.name: steps,
  },
  'xp': {'earned': unit.xp.earned, 'unspent': unit.xp.unspent},
  'location': switch (unit.location) {
    Deployed(:final recallDoneAt) => {
      'kind': 'deployed',
      ..._maybeTime('recallDoneAt', recallDoneAt),
    },
    Carried(:final transportId, :final recallDoneAt) => {
      'kind': 'carried',
      'transport': transportId,
      ..._maybeTime('recallDoneAt', recallDoneAt),
    },
    Stored() => {'kind': 'stored'},
    Prisoner(:final captorSectionId) => {
      'kind': 'prisoner',
      'captor': captorSectionId,
    },
  },
  'pool': _pool(unit.pool),
  'health': _health(unit.health),
  'morale': unit.morale,
  'weapon': {
    'weapon': ?unit.weapon.weapon?.id,
    'rounds': unit.weapon.rounds,
    'loaded': unit.weapon.loaded,
    'busyUntil': unit.weapon.busyUntil.inMicroseconds,
    'nextShotAt': unit.weapon.nextShotAt.inMicroseconds,
  },
  if (unit.cell case final cell?) 'cell': _cell(cell),
  'flying': unit.flying,
  ..._maybeTime('movingUntil', unit.movingUntil),
  if (unit.work case final work?)
    'work': {
      'id': work.workId,
      'ap': work.action.ap,
      'duration': work.action.duration.inMicroseconds,
      'progress': work.action.progress,
      ..._maybeTime('startedAt', work.action.startedAt),
      'structure': ?work.structure,
      'cells': [for (final cell in work.cells) _cell(cell)],
    },
  if (unit.observation case final observation?)
    'observation': {
      'visionBonusM': observation.role.visionBonusM,
      'durationS': observation.role.durationS,
      'ap': observation.role.ap,
      'canMove': observation.role.canMove,
      'startedAt': observation.startedAt.inMicroseconds,
    },
  if (unit.xpHistory case final history?)
    'xpHistory': [
      for (final (origin, at) in history.awards)
        {
          'at': at.inMicroseconds,
          ...switch (origin) {
            FromTarget(:final targetId) => {'target': targetId},
            FromBuild(:final xM, :final yM) => {'buildXM': xM, 'buildYM': yM},
          },
        },
    ],
};

_Json _section(SectionState section) => {
  'id': section.id,
  'account': section.accountId,
  'team': section.team,
  'money': section.money,
  'xp': section.xp,
  'medals': section.medals,
  'guild': ?section.guildId,
  'chief': section.guildChief,
  'weapons': section.storedWeapons.weapons,
  ..._maybeTime('lockedUntil', section.lockedUntil),
  'serverManaged': section.serverManaged,
};

_Json _team(TeamState team) => {
  'id': team.id,
  'hq': {
    'cell': _cell(team.hq.cell),
    'health': _health(team.hq.health),
    'pool': _pool(team.hq.pool),
    ..._maybeTime('movingUntil', team.hq.movingUntil),
  },
  'manager': ?team.managerAccountId,
  'holder': ?team.holderAccountId,
  'eliminated': team.eliminated,
};

_Json _relic(RelicState relic) => {
  'id': relic.id,
  'cell': _cell(relic.cell),
  'owner': ?relic.owner,
  if (relic.capturePot case final pot?)
    'capturePot': {
      'team': pot.team,
      'contributions': pot.contributions,
      ..._maybeTime('fullAt', pot.fullAt),
    },
  if (relic.pushPot case final pot?) 'pushPot': _pushPot(pot),
  if (relic.pushPath case final path?)
    'pushPath': [for (final cell in path) _cell(cell)],
  'pushers': relic.pushers.toList(),
  'crushes': relic.crushes,
  if (relic.push case final push?)
    'push': {
      'cell': _cell(push.cell),
      'arrivals': [for (final at in push.arrivals) at.inMicroseconds],
      'spent': push.spent,
      'pushers': push.pushers.toList(),
      'crushed': [
        for (final (:unitId, :at) in push.crushed) {'unit': unitId, 'at': at},
      ],
      if (push.landing case final landing?) 'landing': _cell(landing),
    },
};

_Json _delta(WorldDelta delta) => {
  'changes': [
    for (final change in delta.changes)
      switch (change) {
        ObjectBuilt(:final cell, :final object) => {
          'kind': 'objectBuilt',
          'cell': _cell(cell),
          'object': object,
        },
        ObjectDestroyed(:final cell, :final object) => {
          'kind': 'objectDestroyed',
          'cell': _cell(cell),
          'object': object,
        },
        ConstructionBuilt(:final cell, :final construction) => {
          'kind': 'constructionBuilt',
          'cell': _cell(cell),
          'construction': construction,
        },
        ConstructionDestroyed(:final cell, :final construction) => {
          'kind': 'constructionDestroyed',
          'cell': _cell(cell),
          'construction': construction,
        },
        LinkBuilt(:final link) => {
          'kind': 'linkBuilt',
          'link': link.kind.name,
          'from': _cell(link.from),
          'to': _cell(link.to),
        },
        LinkDestroyed(:final kind, :final from, :final to) => {
          'kind': 'linkDestroyed',
          'link': kind.name,
          'from': _cell(from),
          'to': _cell(to),
        },
        CraterDug(:final crater) => {
          'kind': 'craterDug',
          'centreXM': crater.centreXM,
          'centreYM': crater.centreYM,
          'radiusM': crater.radiusM,
          'depthM': crater.depthM,
        },
      },
  ],
  'hp': delta.hp,
  'built': [
    for (final object in delta.built.values)
      {
        'id': object.id,
        'type': object.type,
        'kind': object.kind.name,
        'cells': [for (final cell in object.cells) _cell(cell)],
        'hp': object.hp,
        'armor': object.armorType,
      },
  ],
  'destroyed': delta.destroyed.toList(),
};

_Json _offer(PrisonerOffer offer) => {
  'captor': offer.captorSectionId,
  'owner': offer.ownerSectionId,
  'released': offer.released,
  ...switch (offer) {
    ExchangeOffer(:final wanted) => {'kind': 'exchange', 'wanted': wanted},
    RansomOffer(:final price) => {'kind': 'ransom', 'price': price},
  },
};

_Json _victory(VictoryState victory) => {
  'relicOwners': victory.relicOwners,
  'teams': victory.teams.toList(),
  if (victory.hold case final hold?)
    'hold': {
      'team': hold.team,
      'since': hold.since.inMicroseconds,
      'winsAt': hold.winsAt.inMicroseconds,
    },
  if (victory.winner case final winner?)
    'winner': {'team': winner.team, 'kind': winner.kind.name},
};

_Json _pool(ApPool pool) => {
  'max': pool.max,
  'recoveryPerHour': pool.recoveryPerHour,
  'value': pool.value,
  'at': pool.updatedAt.inMicroseconds,
};

_Json _health(Health health) => {'current': health.current, 'max': health.max};

_Json _pushPot(PushPot pot) => {'owner': pot.owner, 'ap': pot.ap};

List<Object> _cell(CellRef cell) => [
  cell.x,
  cell.y,
  if (cell.surface != groundSurface) cell.surface,
];

_Json _maybeTime(String key, Duration? time) => {
  if (time != null) key: time.inMicroseconds,
};

/// Reads a snapshot's state back with the shared definitions.
final class _Decoder {
  new(this.definitions) : _evolution = Evolution(definitions.units.trees);

  final GameData definitions;
  final Evolution _evolution;

  BattleTimer timer(_Reader timer) => switch (timer.text('kind')) {
    'sectionUnlocks' => SectionUnlocks(timer.text('section')),
    'runOrder' => RunOrder(_command(timer)),
    'workEnds' => WorkEnds(timer.text('unit')),
    'recallEnds' => RecallEnds(timer.text('unit')),
    'captureEnds' => CaptureEnds(timer.text('relic')),
    'relicArrives' => RelicArrives(timer.text('relic')),
    'serverCheck' => ServerCheck(timer.text('unit')),
    'holdEnds' => const HoldEnds(),
    'flightEnds' => FlightEnds(
      timer.text('unit'),
      flying: timer.flag('flying'),
    ),
    _ => timer.unknown('kind'),
  };

  wire.Command _command(_Reader timer) {
    try {
      return const wire.JsonProtocolCodec().decodeCommand(
        jsonEncode(timer.item('command').json),
      );
    } on wire.ProtocolException catch (error) {
      throw FormatException('not a battle snapshot: ${error.message}');
    }
  }

  BattleState state(_Reader state) {
    final victory = state.maybeItem('victory');
    return BattleState(
      weather: state.text('weather'),
      units: _byId([
        for (final unit in state.items('units')) _unit(unit),
      ], (unit) => unit.id),
      sections: _byId([
        for (final section in state.items('sections')) _section(section),
      ], (section) => section.id),
      teams: _byId([
        for (final team in state.items('teams')) _team(team),
      ], (team) => team.id),
      relics: _byId([
        for (final relic in state.items('relics')) _relic(relic),
      ], (relic) => relic.id),
      dropped: _byId([
        for (final dropped in state.items('dropped'))
          DroppedWeaponState(
            id: dropped.text('id'),
            dropped: DroppedWeapon(
              weapon: _weapon(dropped, 'weapon'),
              goneAt: dropped.time('goneAt'),
            ),
            cell: dropped.cell('cell'),
          ),
      ], (dropped) => dropped.id),
      delta: _delta(state.item('delta')),
      offers: Map.unmodifiable({
        for (final offer in state.items('offers'))
          offer.integer('id'): _offer(offer),
      }),
      victory: victory == null ? null : _victory(victory),
      eliminated: List.unmodifiable(state.texts('eliminated')),
    );
  }

  static Map<String, T> _byId<T>(List<T> values, String Function(T) id) =>
      Map.unmodifiable({for (final value in values) id(value): value});

  UnitState _unit(_Reader unit) {
    final base =
        definitions.units.unitTypes[unit.text('type')] ?? unit.unknown('type');
    final stats = EvolvableStat.values.asNameMap();
    final tree = SkillTree({
      for (final MapEntry(:key, :value) in unit.counts('tree').entries)
        stats[key] ?? unit.unknown('tree'): value,
    });
    final xp = unit.item('xp');
    final location = unit.item('location');
    final weapon = unit.item('weapon');
    final work = unit.maybeItem('work');
    final observation = unit.maybeItem('observation');
    final history = unit.maybeItems('xpHistory');
    return UnitState(
      id: unit.text('id'),
      sectionId: unit.text('section'),
      type: _evolution.evolve(base, tree),
      tree: tree,
      xp: UnitXp(earned: xp.number('earned'), unspent: xp.number('unspent')),
      location: switch (location.text('kind')) {
        'deployed' => Deployed(
          recallDoneAt: location.maybeTime('recallDoneAt'),
        ),
        'carried' => Carried(
          location.text('transport'),
          recallDoneAt: location.maybeTime('recallDoneAt'),
        ),
        'stored' => const Stored(),
        'prisoner' => Prisoner(location.text('captor')),
        _ => location.unknown('kind'),
      },
      pool: _pool(unit.item('pool')),
      health: _health(unit.item('health')),
      morale: unit.number('morale'),
      weapon: WeaponState(
        weapon: weapon.has('weapon') ? _weapon(weapon, 'weapon') : null,
        rounds: weapon.integer('rounds'),
        loaded: weapon.flag('loaded'),
        busyUntil: weapon.time('busyUntil'),
        nextShotAt: weapon.time('nextShotAt'),
      ),
      cell: unit.has('cell') ? unit.cell('cell') : null,
      flying: unit.flag('flying'),
      movingUntil: unit.maybeTime('movingUntil'),
      work: work == null
          ? null
          : Work(
              workId: work.text('id'),
              action: TimedAction(
                ap: work.number('ap'),
                duration: work.time('duration'),
                progress: work.number('progress'),
                startedAt: work.maybeTime('startedAt'),
              ),
              structure: work.maybeText('structure'),
              cells: work.cells('cells'),
            ),
      observation: observation == null
          ? null
          : Observation(
              role: ObserveRole(
                visionBonusM: observation.number('visionBonusM'),
                durationS: observation.number('durationS'),
                ap: observation.number('ap'),
                canMove: observation.flag('canMove'),
              ),
              startedAt: observation.time('startedAt'),
            ),
      xpHistory: history == null
          ? null
          : XpHistory([
              for (final award in history)
                (
                  award.has('target')
                      ? FromTarget(award.text('target'))
                      : FromBuild(
                          xM: award.number('buildXM'),
                          yM: award.number('buildYM'),
                        ),
                  award.time('at'),
                ),
            ]),
    );
  }

  WeaponType _weapon(_Reader reader, String key) =>
      definitions.combat.weaponTypes[reader.text(key)] ?? reader.unknown(key);

  SectionState _section(_Reader section) => SectionState(
    id: section.text('id'),
    accountId: section.text('account'),
    team: section.text('team'),
    money: section.integer('money'),
    xp: section.number('xp'),
    medals: Map.unmodifiable(section.counts('medals')),
    guildId: section.maybeText('guild'),
    guildChief: section.flag('chief'),
    storedWeapons: StoredWeapons(List.unmodifiable(section.texts('weapons'))),
    lockedUntil: section.maybeTime('lockedUntil'),
    serverManaged: section.flag('serverManaged'),
  );

  TeamState _team(_Reader team) {
    final hq = team.item('hq');
    return TeamState(
      id: team.text('id'),
      hq: HqState(
        cell: hq.cell('cell'),
        health: _health(hq.item('health')),
        pool: _pool(hq.item('pool')),
        movingUntil: hq.maybeTime('movingUntil'),
      ),
      managerAccountId: team.maybeText('manager'),
      holderAccountId: team.maybeText('holder'),
      eliminated: team.flag('eliminated'),
    );
  }

  RelicState _relic(_Reader relic) {
    final capture = relic.maybeItem('capturePot');
    final pushPot = relic.maybeItem('pushPot');
    final push = relic.maybeItem('push');
    return RelicState(
      id: relic.text('id'),
      cell: relic.cell('cell'),
      owner: relic.maybeText('owner'),
      capturePot: capture == null
          ? null
          : CapturePot(
              team: capture.text('team'),
              contributions: Map.unmodifiable(capture.numbers('contributions')),
              fullAt: capture.maybeTime('fullAt'),
            ),
      pushPot: pushPot == null ? null : _pushPot(pushPot),
      pushPath: relic.has('pushPath')
          ? List.unmodifiable(relic.cells('pushPath'))
          : null,
      pushers: Set.unmodifiable(relic.texts('pushers')),
      crushes: relic.integer('crushes'),
      push: push == null ? null : _push(push),
    );
  }

  static WorldDelta _delta(_Reader delta) => WorldDelta(
    changes: List.unmodifiable([
      for (final change in delta.items('changes'))
        switch (change.text('kind')) {
          'objectBuilt' => ObjectBuilt(
            change.cell('cell'),
            change.text('object'),
          ),
          'objectDestroyed' => ObjectDestroyed(
            change.cell('cell'),
            change.text('object'),
          ),
          'constructionBuilt' => ConstructionBuilt(
            change.cell('cell'),
            change.text('construction'),
          ),
          'constructionDestroyed' => ConstructionDestroyed(
            change.cell('cell'),
            change.text('construction'),
          ),
          'linkBuilt' => LinkBuilt(
            SurfaceLink(
              kind: change.choice('link', LinkKind.values),
              from: change.cell('from'),
              to: change.cell('to'),
            ),
          ),
          'linkDestroyed' => LinkDestroyed(
            kind: change.choice('link', LinkKind.values),
            from: change.cell('from'),
            to: change.cell('to'),
          ),
          'craterDug' => CraterDug(
            Crater(
              centreXM: change.number('centreXM'),
              centreYM: change.number('centreYM'),
              radiusM: change.number('radiusM'),
              depthM: change.number('depthM'),
            ),
          ),
          _ => change.unknown('kind'),
        },
    ]),
    hp: Map.unmodifiable(delta.numbers('hp')),
    built: _byId([
      for (final object in delta.items('built'))
        MapObject(
          id: object.text('id'),
          type: object.text('type'),
          kind: object.choice('kind', FeatureKind.values),
          cells: List.unmodifiable(object.cells('cells')),
          hp: object.number('hp'),
          armorType: object.text('armor'),
        ),
    ], (object) => object.id),
    destroyed: Set.unmodifiable(delta.texts('destroyed')),
  );

  static PrisonerOffer _offer(_Reader offer) {
    final captor = offer.text('captor');
    final owner = offer.text('owner');
    final released = List<String>.unmodifiable(offer.texts('released'));
    return switch (offer.text('kind')) {
      'exchange' => ExchangeOffer(
        captorSectionId: captor,
        ownerSectionId: owner,
        released: released,
        wanted: List.unmodifiable(offer.texts('wanted')),
      ),
      'ransom' => RansomOffer(
        captorSectionId: captor,
        ownerSectionId: owner,
        released: released,
        price: offer.integer('price'),
      ),
      _ => offer.unknown('kind'),
    };
  }

  static VictoryState _victory(_Reader victory) {
    final hold = victory.maybeItem('hold');
    final winner = victory.maybeItem('winner');
    return VictoryState(
      relicOwners: Map.unmodifiable(victory.maybeTexts('relicOwners')),
      teams: Set.unmodifiable(victory.texts('teams')),
      hold: hold == null
          ? null
          : RelicHold(
              team: hold.text('team'),
              since: hold.time('since'),
              winsAt: hold.time('winsAt'),
            ),
      winner: winner == null
          ? null
          : BattleWon(
              team: winner.text('team'),
              kind: winner.choice('kind', VictoryKind.values),
            ),
    );
  }

  static ApPool _pool(_Reader pool) => ApPool(
    max: pool.number('max'),
    recoveryPerHour: pool.number('recoveryPerHour'),
    value: pool.number('value'),
    updatedAt: pool.time('at'),
  );

  static Health _health(_Reader health) =>
      Health(current: health.number('current'), max: health.number('max'));

  static RelicPush _push(_Reader push) {
    final arrivals = [
      for (final micros in push.integers('arrivals'))
        Duration(microseconds: micros),
    ];
    final spent = push.numberList('spent');
    if (arrivals.length < 2 || spent.length != arrivals.length) {
      throw FormatException(
        'not a battle snapshot: ${push.path}.arrivals is not a push',
      );
    }
    return RelicPush(
      cell: push.cell('cell'),
      arrivals: arrivals,
      spent: spent,
      pushers: push.texts('pushers').toSet(),
      crushed: [
        for (final crush in push.items('crushed'))
          (unitId: crush.text('unit'), at: crush.integer('at')),
      ],
      landing: push.has('landing') ? push.cell('landing') : null,
    );
  }

  static PushPot _pushPot(_Reader pot) =>
      PushPot(owner: pot.text('owner'), ap: pot.number('ap'));
}

/// Reads the fields of one JSON object of a snapshot, at [path]: any value
/// of the wrong kind throws a [FormatException] naming where it is.
final class _Reader {
  new(this.json, this.path);

  final _Json json;
  final String path;

  static T _as<T>(Object? value, String path) => value is T
      ? value
      : throw FormatException('not a battle snapshot: $path is not a $T');

  T _get<T>(String key) => _as<T>(json[key], '$path.$key');

  List<Object?> _list(String key) => _get<List<Object?>>(key);

  Never unknown(String key) =>
      throw FormatException('not a battle snapshot: $path.$key is unknown');

  bool has(String key) => json[key] != null;

  int integer(String key) => _get<int>(key);

  double number(String key) => _get<num>(key).toDouble();

  String text(String key) => _get<String>(key);

  String? maybeText(String key) => _get<String?>(key);

  bool flag(String key) => _get<bool>(key);

  Duration time(String key) => Duration(microseconds: integer(key));

  Duration? maybeTime(String key) => has(key) ? time(key) : null;

  T choice<T extends Enum>(String key, List<T> values) =>
      values.asNameMap()[text(key)] ?? unknown(key);

  _Reader item(String key) => _Reader(_get<_Json>(key), '$path.$key');

  _Reader? maybeItem(String key) => has(key) ? item(key) : null;

  List<_Reader> items(String key) => [
    for (final (index, value) in _list(key).indexed)
      _Reader(_as<_Json>(value, '$path.$key[$index]'), '$path.$key[$index]'),
  ];

  List<_Reader>? maybeItems(String key) => has(key) ? items(key) : null;

  List<int> integers(String key) => [
    for (final (index, value) in _list(key).indexed)
      _as<int>(value, '$path.$key[$index]'),
  ];

  List<double> numberList(String key) => [
    for (final (index, value) in _list(key).indexed)
      _as<num>(value, '$path.$key[$index]').toDouble(),
  ];

  List<String> texts(String key) => [
    for (final (index, value) in _list(key).indexed)
      _as<String>(value, '$path.$key[$index]'),
  ];

  Map<String, T> _values<T>(String key, T Function(Object?, String) read) => {
    for (final MapEntry(key: name, :value) in _get<_Json>(key).entries)
      name: read(value, '$path.$key.$name'),
  };

  Map<String, int> counts(String key) => _values(key, _as<int>);

  Map<String, double> numbers(String key) =>
      _values(key, (value, at) => _as<num>(value, at).toDouble());

  Map<String, String?> maybeTexts(String key) => _values(key, _as<String?>);

  CellRef cell(String key) => _cellOf(_get<List<Object?>>(key), '$path.$key');

  List<CellRef> cells(String key) => [
    for (final (index, value) in _list(key).indexed)
      _cellOf(_as<List<Object?>>(value, '$path.$key[$index]'), '$path.$key'),
  ];

  static CellRef _cellOf(List<Object?> cell, String path) => switch (cell) {
    [final int x, final int y] => CellRef(x, y),
    [final int x, final int y, final String surface] => CellRef(
      x,
      y,
      surface: surface,
    ),
    _ => throw FormatException('not a battle snapshot: $path is not a cell'),
  };
}
