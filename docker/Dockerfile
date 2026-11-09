# The simulation host of Battle Team (stack decision 1, hosting): the
# `battle_host serve` executable, compiled ahead of time inside this build
# (`dart compile exe`), with the plan's data and its maps, on the runtime
# files of the Dart image (C library, CA certificates), nothing else. The
# Dart SDK stays in the build stage: the machine that builds the image needs
# only Docker. Provider-neutral: any linux/amd64 Docker host runs it.
#
# The context is build/docker, staged by docker/prepare.sh (no Dart needed):
#   docker/prepare.sh saint_lo
#   docker build -f docker/Dockerfile -t battle_host build/docker
FROM dart:3.13 AS build
WORKDIR /src
COPY src/ ./
# The staged workspace is a subset of the hawkbee lock: pub get keeps the
# locked versions, but --enforce-lockfile would refuse the pruned lock.
RUN dart pub get \
 && mkdir -p /out \
 && dart compile exe packages/battle_host/bin/battle_host.dart -o /out/battle_host

FROM dart:3.13 AS runtime

FROM scratch
COPY --from=runtime /runtime/ /
COPY --from=build /out/battle_host /app/battle_host
COPY plan /app/plan
COPY maps /app/maps

# The write-ahead logs: keep this volume across restarts, or the orders of
# the last 10 seconds before a stop are lost (stack decision 2).
VOLUME /data

# The endpoints of players and AI agents (`serve --port`).
EXPOSE 8080
ENTRYPOINT ["/app/battle_host", "serve", "--plan", "/app/plan", "--maps", "/app/maps", "--data", "/data"]
CMD ["--map", "saint_lo"]
