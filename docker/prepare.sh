#!/usr/bin/env bash
# Stages the Docker build context of the host in build/docker/: the
# AOT-compiled executable, the plan's data files and the built maps the
# container serves. Run it from packages/battle_host of a hawkbee checkout
# (the host only builds inside the workspace), on linux/amd64.
#
#   docker/prepare.sh [map ...]      # saint_lo by default
#   docker build -f docker/Dockerfile -t battle_host build/docker
set -euo pipefail

cd "$(dirname "$0")/.."
plan=../../apps/battle_team/plan
maps=../battle_map/maps/built
out=build/docker
[ "$#" -gt 0 ] || set -- saint_lo

rm -rf "$out"
mkdir -p "$out/plan/data" "$out/plan/milestones" "$out/maps"
dart compile exe bin/battle_host.dart -o "$out/battle_host"
cp "$plan"/data/*.yaml "$out/plan/data/"
cp "$plan/milestones/economy.yaml" "$out/plan/milestones/"
for map in "$@"; do
  cp -r "$maps/$map" "$out/maps/$map"
done
echo "Staged $out: $(du -sh "$out" | cut -f1), maps: $*"
