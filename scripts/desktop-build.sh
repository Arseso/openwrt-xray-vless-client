#!/bin/sh
# Builds the desktop app (desktop/, Tauri 2) for Linux in docker: dist/desktop/ gets the
# binary and the deb. The image is desktop/docker/Dockerfile; the cargo registry, npm
# cache and cargo target dir live in docker volumes, so a second build is incremental.
#
#   sh scripts/desktop-build.sh         build (release)
#   sh scripts/desktop-build.sh test    tsc, vitest and cargo test, no build
#
# Variables: DOCKER (default docker --context default), JOBS (cargo jobs, default 4: a
# release build with LTO takes a lot of memory per job).
set -eu
cd "$(dirname "$0")/.."
DOCKER="${DOCKER:-docker --context default}"
IMAGE="${IMAGE:-xvpn-desktop-build}"
JOBS="${JOBS:-4}"
MODE="${1:-build}"
case "$MODE" in
build|test) ;;
*) echo "usage: sh scripts/desktop-build.sh [test]" >&2; exit 2 ;;
esac

$DOCKER build -q -t "$IMAGE" desktop/docker >/dev/null

TAR="$(mktemp)"
trap 'rm -f "$TAR"' EXIT
trap 'exit 130' INT TERM
# the checkout is mounted read-only and copied without node_modules and target: the
# host's node_modules may be of another platform. The log goes to stderr, the result
# comes back as a tar on stdout.
$DOCKER run --rm --init -v "$PWD/desktop:/src:ro" \
	-v xvpn-desktop-cargo:/cache/cargo -v xvpn-desktop-npm:/cache/npm -v xvpn-desktop-target:/cache/target \
	-e CARGO_BUILD_JOBS="$JOBS" -e MODE="$MODE" "$IMAGE" bash -euo pipefail -c '
	exec 3>&1 1>&2
	mkdir -p /build && cd /src
	tar -c --exclude=./node_modules --exclude=./dist --exclude=./src-tauri/target --exclude=./src-tauri/gen . | tar -x -C /build
	cd /build
	npm ci --no-audit --no-fund
	if [ "$MODE" = test ]; then
		npx tsc --noEmit
		npx vitest run
		cd src-tauri && cargo test --locked
		exit 0
	fi
	# the target dir is a volume: no deb of an older version may come along
	rm -rf "$CARGO_TARGET_DIR/release/bundle/deb"
	npx tauri build --bundles deb -- --locked
	cd "$CARGO_TARGET_DIR/release"
	tar -c xvpn bundle/deb/*.deb >&3
' > "$TAR"
[ "$MODE" = build ] || exit 0
rm -rf dist/desktop
mkdir -p dist/desktop
tar -x -f "$TAR" -C dist/desktop
mv dist/desktop/bundle/deb/*.deb dist/desktop/
rm -rf dist/desktop/bundle
ls -l dist/desktop
