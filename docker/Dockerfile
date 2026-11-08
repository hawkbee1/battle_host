# The simulation host of Battle Team (stack decision 1, hosting): the
# AOT-compiled `battle_host serve` with the plan's data and its maps, on the
# runtime files of the Dart image (C library, CA certificates), nothing
# else. Provider-neutral: any linux/amd64 Docker host runs it.
#
# The context is build/docker, staged by docker/prepare.sh:
#   docker/prepare.sh saint_lo
#   docker build -f docker/Dockerfile -t battle_host build/docker
FROM dart:3.13 AS runtime

FROM scratch
COPY --from=runtime /runtime/ /
COPY battle_host /app/battle_host
COPY plan /app/plan
COPY maps /app/maps

# The write-ahead logs: keep this volume across restarts, or the orders of
# the last 10 seconds before a stop are lost (stack decision 2).
VOLUME /data

# The endpoints of players and AI agents (`serve --port`).
EXPOSE 8080
ENTRYPOINT ["/app/battle_host", "serve", "--plan", "/app/plan", "--maps", "/app/maps", "--data", "/data"]
CMD ["--map", "saint_lo"]
