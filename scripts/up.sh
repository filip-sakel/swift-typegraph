#!/bin/sh
# Builds and starts the stack, then prints the URL it's served on.
# Uses docker compose when the docker daemon is reachable, podman compose
# otherwise; set COMPOSE to override. Extra arguments go to `compose up`.
#
#   scripts/up.sh
#   HTTP_PORT=9000 scripts/up.sh
#   COMPOSE="sudo docker compose" scripts/up.sh

set -eu
cd "$(dirname "$0")/.."

if [ -z "${COMPOSE:-}" ]; then
  if docker info >/dev/null 2>&1; then
    COMPOSE="docker compose"
  else
    COMPOSE="podman compose"
    # podman compose drives docker-compose through podman's API socket.
    systemctl --user start podman.socket 2>/dev/null || true
  fi
fi

$COMPOSE up -d --build "$@"

# The live mapping, e.g. 127.0.0.1:4000 (podman prints a banner on stderr).
address=$($COMPOSE port web 4000 2>/dev/null | tail -n 1)
echo "TypeGraph is up at http://localhost:${address##*:}"
