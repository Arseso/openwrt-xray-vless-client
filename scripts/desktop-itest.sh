#!/bin/sh
# The TS client of the desktop app (desktop/src/api) against the LuCI stand of
# scripts/luci.sh: login, every read method of luci.xvpn, uci, a lost session, rpcd
# restart and uhttpd down/up; the tabs of #79 (apply / confirm / rollback seen by LuCI, the
# rpcd user without root, the diagnostics). Starts the stand when its container is not running.
#
#   sh scripts/desktop-itest.sh        NAME (default xvpn-luci) and PORT (8019) as in luci.sh
#
# Runs node on the host (node 20+), the stand in docker.
set -eu
cd "$(dirname "$0")/.."
DOCKER="${DOCKER:-docker --context default}"
NAME=${NAME:-xvpn-luci}
PORT=${PORT:-8019}
PASS=${PASS:-xvpn-luci-test}
export DOCKER NAME PORT PASS

if [ "$($DOCKER inspect -f '{{.State.Running}}' "$NAME" 2>/dev/null)" != true ]; then
	sh scripts/luci.sh
fi
cd desktop
[ -d node_modules ] || npm ci --no-audit --no-fund
XVPN_URL="http://127.0.0.1:$PORT" XVPN_PASS="$PASS" XVPN_CONTAINER="$NAME" npx vitest run --config vitest.stand.config.ts
