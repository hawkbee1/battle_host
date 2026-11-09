#!/usr/bin/env bash
# Stages the Docker build context of the host in build/docker/: the sources
# the host is compiled from, the plan's data files and the built maps the
# container serves. No Dart SDK is needed to run this: docker/Dockerfile
# resolves the packages and runs `dart compile exe` inside the image build.
# Run it from packages/battle_host of a hawkbee checkout.
#
#   docker/prepare.sh [map ...]      # saint_lo by default
#   docker build -f docker/Dockerfile -t battle_host build/docker
set -euo pipefail

cd "$(dirname "$0")/.."
root=../..
plan=$root/apps/battle_team/plan
maps=../battle_map/maps/built
out=build/docker
[ "$#" -gt 0 ] || set -- saint_lo

# battle_host and the workspace packages it depends on, transitively, plus
# battle_client (its dev dependency). Pub resolves a workspace as a whole, so
# the staged workspace lists exactly these; add a package here when
# battle_host starts to depend on it.
members=(battle_host battle_backend battle_client battle_map battle_pathfinding battle_protocol battle_rules hawkbee_schema)

rm -rf "$out"
mkdir -p "$out/src" "$out/plan/data" "$out/plan/milestones" "$out/maps"

{
  printf 'name: hawkbee_workspace\npublish_to: none\n\nenvironment:\n  sdk: ^3.13.0\n\nworkspace:\n'
  printf '  - packages/%s\n' "${members[@]}"
} > "$out/src/pubspec.yaml"
cp "$root/pubspec.lock" "$out/src/"
for member in "${members[@]}"; do
  mkdir -p "$out/src/packages/$member"
  cp "../$member/pubspec.yaml" "$out/src/packages/$member/"
  for dir in lib bin; do
    if [ -d "../$member/$dir" ]; then cp -r "../$member/$dir" "$out/src/packages/$member/"; fi
  done
done

cp "$plan"/data/*.yaml "$out/plan/data/"
cp "$plan/milestones/economy.yaml" "$out/plan/milestones/"
for map in "$@"; do
  cp -r "$maps/$map" "$out/maps/$map"
done
echo "Staged $out: $(du -sh "$out" | cut -f1), maps: $*"
