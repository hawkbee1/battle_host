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

The Appwrite adapters use the buckets `battle_logs` and `battle_snapshots` of hawkbee's
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
