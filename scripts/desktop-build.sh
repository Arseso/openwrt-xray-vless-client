#!/bin/sh
# Builds the desktop app (desktop/, Tauri 2) in docker: dist/desktop/ gets the Linux binary,
# the deb and the AppImage, and the Windows NSIS setup cross-built with cargo-xwin. The
# version is PKG_VERSION of luci-app-xvpn/Makefile (one version for the router package and
# the app; tauri.conf.json is overridden at build time). The image is desktop/docker/
# Dockerfile (pinned tools, see there); the cargo registry, npm cache, MSVC SDK of cargo-xwin
# and the cargo target dir live in docker volumes, so a second build is incremental.
#
#   sh scripts/desktop-build.sh          build (release), then sign when the key is there
#   sh scripts/desktop-build.sh test     tsc, vitest and cargo test, no build
#   sh scripts/desktop-build.sh verify   check the signatures in dist/desktop
#
# Updates (#81): with the key of `tauri signer generate` in $KEYS/updater.key (password in
# $KEYS/updater.pass, empty without it) the AppImage, the deb and the setup get .sig files
# and dist/desktop/latest.json for tauri-plugin-updater is written, its URLs pointing at the
# GitHub release $TAG; the router packages in dist/ (scripts/build.sh) get
# dist/desktop/SHA256SUMS with SHA256SUMS.sig, which the app checks before it installs them. The build itself never sees the key (it runs npm scripts, build.rs of
# hundreds of crates, downloaded tools): a second container signs the finished packages,
# without network, with no volumes and only the key file (desktop/docker/sign.sh), and checks
# every signature against the public key of tauri.conf.json. The key is never in the
# repository; without it nothing is signed.
#
# Variables: DOCKER (default docker --context default), JOBS (cargo jobs, default 4: a
# release build with LTO takes a lot of memory per job), TARGETS (default "linux windows"),
# KEYS (default ~/.config/xvpn-desktop), TAG (default v<PKG_VERSION>[-r<PKG_RELEASE>], as
# scripts/ci.sh tags the release). The host needs docker only.
set -eu
cd "$(dirname "$0")/.."
DOCKER="${DOCKER:-docker --context default}"
# tagged by the Dockerfile: worktrees with another Dockerfile (parallel sessions) build their
# own image instead of replacing this one between the build and the signing step
IMAGE="${IMAGE:-xvpn-desktop-build:$(sha256sum < desktop/docker/Dockerfile | cut -c1-12)}"
JOBS="${JOBS:-4}"
TARGETS="${TARGETS:-linux windows}"
KEYS="${KEYS:-$HOME/.config/xvpn-desktop}"
REPO=Arseso/openwrt-xray-vless-client
MODE="${1:-build}"
case "$MODE" in
build|test|verify) ;;
*) echo "usage: sh scripts/desktop-build.sh [test|verify]" >&2; exit 2 ;;
esac
VERSION=$(sed -n 's/^PKG_VERSION:=//p' luci-app-xvpn/Makefile)
rel=$(sed -n 's/^PKG_RELEASE:=//p' luci-app-xvpn/Makefile)
if [ -z "${TAG:-}" ]; then
	TAG="v$VERSION"; [ "$rel" = 1 ] || TAG="$TAG-r$rel"
fi
# Tauri and the Windows file version take x.y.z only
echo "$VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' || { echo "PKG_VERSION '$VERSION' is not x.y.z" >&2; exit 1; }

$DOCKER build -q -t "$IMAGE" desktop/docker >/dev/null

# sign.sh in the image: no network, no volumes; the key file only to sign
sign() { # sign|verify
	mode=$1
	set -- -v "$PWD/desktop:/src:ro" -v "$PWD/dist/desktop:/out"
	# the router packages of scripts/build.sh: SHA256SUMS of them, signed with the same key
	[ ! -d dist ] || set -- "$@" -v "$PWD/dist:/ipk:ro"
	if [ "$mode" = sign ]; then
		set -- "$@" -v "$KEYS/updater.key:/key/updater.key:ro"
		[ ! -f "$KEYS/updater.pass" ] || set -- "$@" -v "$KEYS/updater.pass:/key/updater.pass:ro"
	fi
	$DOCKER run --rm --network none -u "$(id -u):$(id -g)" -e HOME=/tmp -e MODE="$mode" \
		-e VERSION="$VERSION" -e TAG="$TAG" -e REPO="$REPO" "$@" "$IMAGE" /src/docker/sign.sh
}
if [ "$MODE" = verify ]; then
	sign verify
	exit 0
fi

TAR="$(mktemp)"
trap 'rm -f "$TAR"' EXIT
trap 'exit 130' INT TERM
# the checkout is mounted read-only and copied without node_modules and target: the
# host's node_modules may be of another platform. The log goes to stderr, the result
# comes back as a tar on stdout.
$DOCKER run --rm --init -v "$PWD/desktop:/src:ro" \
	-v xvpn-desktop-cargo:/cache/cargo -v xvpn-desktop-npm:/cache/npm -v xvpn-desktop-target:/cache/target \
	-v xvpn-desktop-xwin:/cache/xwin \
	-e CARGO_BUILD_JOBS="$JOBS" -e MODE="$MODE" -e VERSION="$VERSION" -e TARGETS="$TARGETS" \
	"$IMAGE" bash -euo pipefail -c '
	exec 3>&1 1>&2
	mkdir -p /build && cd /src
	tar -c --exclude=./node_modules --exclude=./dist --exclude=./src-tauri/target --exclude=./src-tauri/gen . | tar -x -C /build
	cd /build
	# PKG_VERSION into the copy: Cargo (the User-Agent, the lock entry of the app itself);
	# tauri.conf.json (bundles, the updater) gets it with --config below
	sed -i "0,/^version = /s/^version = .*/version = \"$VERSION\"/" src-tauri/Cargo.toml
	awk -v v="$VERSION" "p && /^version = / { \$0 = \"version = \\\"\" v \"\\\"\"; p = 0 } { print } /^name = \"xvpn\"\$/ { p = 1 }" \
		src-tauri/Cargo.lock > /tmp/lock && mv /tmp/lock src-tauri/Cargo.lock
	npm ci --no-audit --no-fund
	if [ "$MODE" = test ]; then
		npx tsc --noEmit
		npx vitest run
		cd src-tauri && cargo test --locked
		exit 0
	fi
	conf="{\"version\": \"$VERSION\"}"
	out=/out; mkdir -p $out
	# the NSIS plugins the bundler downloads (the AppImage tools are in the image): a failure
	# there gets one more try with its log (the compile is done by then)
	tauri() { npx tauri build --config "$conf" "$@" || npx tauri build -v --config "$conf" "$@"; }
	T=$CARGO_TARGET_DIR
	for target in $TARGETS; do
		case $target in
		linux)
			# the target dir is a volume: no package of an older version may come along
			rm -rf "$T/release/bundle"
			tauri --bundles deb,appimage -- --locked
			cp "$T/release/xvpn" "$T"/release/bundle/deb/*.deb "$T"/release/bundle/appimage/*.AppImage $out/
			;;
		windows)
			W=$T/x86_64-pc-windows-msvc/release
			rm -rf "$W/bundle"
			tauri --runner cargo-xwin --target x86_64-pc-windows-msvc --bundles nsis -- --locked
			cp "$W"/bundle/nsis/*-setup.exe $out/
			# what Windows would run: the setup holds the app (a PE32+ GUI binary)
			file "$W/xvpn.exe" | grep -q "PE32+ executable (GUI) x86-64" || { file "$W/xvpn.exe"; exit 1; }
			7z l $out/*-setup.exe | grep -q " xvpn.exe$" || { 7z l $out/*-setup.exe; echo "no xvpn.exe in the setup"; exit 1; }
			;;
		*) echo "unknown target $target"; exit 1 ;;
		esac
	done
	tar -c -C $out . >&3
' > "$TAR"
[ "$MODE" = build ] || exit 0
rm -rf dist/desktop
mkdir -p dist/desktop
tar -x -f "$TAR" -C dist/desktop
if [ -f "$KEYS/updater.key" ]; then
	sign sign
else
	echo "no $KEYS/updater.key: the packages are not signed, no latest.json" >&2
fi
ls -l dist/desktop
