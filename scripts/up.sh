#!/bin/sh
# Builds and starts the stack, then prints the URL it's served on.
# Uses docker compose when the docker daemon is reachable, podman compose
# otherwise (with WEB_NETWORK_MODE=pasta); set COMPOSE to override. Extra
# arguments go to `compose up`.
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
    # Keep client addresses for the rate limit (compose.yaml), unless .env
    # chooses: the shell environment would override it.
    # Read more here: https://github.com/podman-container-tools/podman/blob/main/docs/tutorials/basic_networking.md
    if [ -z "${WEB_NETWORK_MODE:-}" ] && ! grep -q '^WEB_NETWORK_MODE=' .env 2>/dev/null; then
      export WEB_NETWORK_MODE=pasta
    fi
  fi
fi

$COMPOSE up -d --build "$@"

# SITE_ADDRESS may come from .env, which compose reads but this shell doesn't.
site=${SITE_ADDRESS:-$(sed -n 's/^SITE_ADDRESS=//p' .env 2>/dev/null | tail -n 1)}
case $site in
"" | :*)
  # The live mapping, e.g. 0.0.0.0:8080 (podman prints a banner on stderr).
  address=$($COMPOSE port web 80 2>/dev/null | tail -n 1)
  echo "TypeGraph is up at http://localhost:${address##*:}"
  ;;
*)
  echo "TypeGraph is up at https://$site (the first start fetches its certificate)"
  ;;
esac
