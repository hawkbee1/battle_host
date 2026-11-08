# battle_host

[![style: very good analysis][very_good_analysis_badge]][very_good_analysis_link]
[![License: MIT][license_badge]][license_link]

The **simulation host** of Battle Team, a 3D, massive, persistent, real-time team battle
game: a native executable that runs whole battles in memory (stack decisions 1, 6 and 7 of
the plan).

- **One process, several battles**, each started from a setup (teams, sections, units and
  the battle's own settings), on maps loaded once and shared by every battle and every
  mover on them (Flyweight).
- **Lazy state with a slow tick**: a unit's AP are read at any time from its last update
  and the battle's recovery rate; idle units cost nothing, and time where no timer is due
  is skipped. Timers run from seconds to days.
- **A core without I/O**: it takes a `Clock`, the seeded random of
  [battle_rules](https://github.com/hawkbee1/battle_rules) and ports (`MapSource`,
  `ErrorReporter`, `WriteAheadLog`, `LogSink`, `SnapshotStore`). Adapters in
  `lib/src/adapters/` read the plan and the maps from disk, report errors to Sentry, write
  the write-ahead log to disk and keep logs and snapshots in Appwrite Storage.
- **Nothing acknowledged is lost** (stack decision 2): an order is acknowledged once its
  log entry is synced to the write-ahead log; every 10 seconds the new entries go up as
  one compressed batch, and every 5 minutes a snapshot. A stopped battle is recovered from
  its latest snapshot and the log after it, replayed and checked entry by entry.
- **Server-managed sections** look like any other (AI-06). Each of their units has a fire
  check every 30 minutes (AI-07); its `Fire` orders, like every order the server gives its
  sections, go through the command handler with the origin `server` and are logged.

The Appwrite adapters use the buckets `bt_battle_logs` and `bt_battle_snapshots` of hawkbee's
`backend/appwrite.config.json`. Their contract tests on the local Appwrite are opt-in: tag
`appwrite`, with `APPWRITE_API_KEY` set (`dart_test.yaml`).

```sh
dart run battle_host run --plan <apps/battle_team/plan> --maps <built maps> --map <id> \
  [--days 1] [--seed 1] [--teams <count>]
```

`run` starts the process, loads the map and runs one battle with no order for the
simulated days, one commander per team. Errors go to Sentry when `SENTRY_DSN` is set
(`SENTRY_ENVIRONMENT`, `development` by default), to the error output otherwise. Maps are
built by [battle_map](https://github.com/hawkbee1/battle_map)'s `build_map`.

## Hosting

```sh
battle_host serve --plan <plan> --maps <built maps> --map <id> [--map <id>...] \
  --data <write-ahead logs> [--host-id <id>] [--poll 10]
```

`serve` is the process of one container. It prepares the path searches of its maps, then
every `--poll` seconds runs the battles placed on it and reports those that ended
(`BattlePlacement`, over hawkbee's `battles`, `sections`, `wars` and `guilds` tables):

- **Placement**: it claims each `running` battle of its maps whose row has no `host`, by
  writing its `--host-id` (the container's `HOSTNAME` by default), and runs the battles
  that name it: recovered from their snapshot, or started from their rows.
- **End**: once a battle has a winner, its row gets status `ended`, the winner and a
  `BattleResult`, which triggers the `end_battle` function.

Every battle advances each second. SIGTERM (`docker stop`) snapshots every battle and
waits for the uploads. Appwrite comes from `APPWRITE_ENDPOINT`, `APPWRITE_PROJECT_ID` and
`APPWRITE_API_KEY` (tables and storage scopes).

The Docker image is the AOT executable, the plan's data and the maps, on the Dart runtime
files (any linux/amd64 host):

```sh
docker/prepare.sh saint_lo                       # in the hawkbee checkout
docker build -f docker/Dockerfile -t battle_host build/docker
APPWRITE_API_KEY=<key> docker compose -f docker/compose.yaml up -d
```

`docker/compose.yaml` runs one container per map on the local Appwrite's network
(`hermes-net`, endpoint `http://appwrite/v1`); keep its `/data` volume.

## Load test

`bin/load_test.dart` plays a 1,000-unit battle on a real map over a simulated day through
the host's one entry (`package:battle_host/load.dart`), and prints one machine-readable
line for each of P-01, P-02 and P-03 of the plan's `performance-tests.md`:

```sh
dart compile exe bin/load_test.dart -o /tmp/load_test
/tmp/load_test [--map saint_lo] [--units 1000] [--hours 24] [--battles 1] \
  [--server-managed 0] [--wal <folder>]
```

## Recorded streams

`tool/record_streams.dart` plays the scripted battle of the tests and writes what the
host sends each section, and its whole view at the end, to `battle_client`'s
`test/fixtures/streams/`. Run it again when a message or the update stream changes:

```sh
dart run tool/record_streams.dart
```

## Part of hawkbee

This repository is a git submodule of the
[hawkbee](https://github.com/hawkbee1/hawkbee) monorepo and **only builds inside
it** (pub workspace, `resolution: workspace`):

```sh
git clone --recurse-submodules https://github.com/hawkbee1/hawkbee.git
cd hawkbee && flutter pub get
```

The tests read the game data from the plan in that checkout
(`apps/battle_team/plan/data`) and build `battle_map`'s test map.

[license_badge]: https://img.shields.io/badge/license-MIT-blue.svg
[license_link]: https://opensource.org/licenses/MIT
[very_good_analysis_badge]: https://img.shields.io/badge/style-very_good_analysis-B22C89.svg
[very_good_analysis_link]: https://pub.dev/packages/very_good_analysis
