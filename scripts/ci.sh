#!/bin/sh
# Local CI (there is no GitHub Actions workflow): checks a clean export of HEAD,
# uncommitted changes are not checked.
#   test         scripts/test.sh with xray-core from the OpenWrt 24.10 feed
#   test-latest  scripts/test.sh with the latest xray release from GitHub (sha256 from
#                its .dgst); informational until #14, a failure is only a warning
#   itest        scripts/itest.sh; a hung run is killed after 15 min, the container
#                state goes to the log
#   build        scripts/build.sh, the packages are copied to dist/
#
#   sh scripts/ci.sh           check HEAD
#   sh scripts/ci.sh release   check HEAD (must be origin/main), tag it v<PKG_VERSION>
#                              (v<PKG_VERSION>-r<PKG_RELEASE> when PKG_RELEASE is not 1),
#                              push the tag and publish a GitHub Release with the ipk
#
# Logs: .ci/<step>.log. Variables: DOCKER (default docker --context default), NAME
# (itest container, by default unique per checkout, so worktrees do not collide).
set -eu
cd "$(dirname "$0")/.."
DOCKER="${DOCKER:-docker --context default}"
NAME=${NAME:-xvpn-ci-$(printf %s "$PWD" | cksum | cut -d' ' -f1)}
export DOCKER NAME
REPO=Arseso/openwrt-xray-vless-client
MODE=${1:-check}
case "$MODE" in
check|release) ;;
*) echo "usage: sh scripts/ci.sh [release]" >&2; exit 2 ;;
esac
die() { echo "ci: $*" >&2; exit 1; }

ver=$(sed -n 's/^PKG_VERSION:=//p' luci-app-xvpn/Makefile)
rel=$(sed -n 's/^PKG_RELEASE:=//p' luci-app-xvpn/Makefile)
tag="v$ver"; [ "$rel" = 1 ] || tag="v$ver-r$rel"
ipk="luci-app-xvpn_${ver}-r${rel}_all.ipk"

if [ "$MODE" = release ]; then
	[ -z "$(git status --porcelain)" ] || die "uncommitted changes"
	git fetch -q origin main --tags
	[ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] \
		|| die "HEAD is not origin/main: a release is made from the pushed main"
	! git rev-parse -q --verify "refs/tags/$tag" >/dev/null \
		|| die "tag $tag already exists: raise PKG_VERSION or PKG_RELEASE in luci-app-xvpn/Makefile"
elif [ -n "$(git status --porcelain)" ]; then
	echo "ci: uncommitted changes are not checked, only HEAD $(git rev-parse --short HEAD)" >&2
fi

CI="$PWD/.ci"
SRC="$CI/src"
rm -rf "$CI"
mkdir -p "$SRC"
git archive HEAD | tar -x -C "$SRC"

failed=
warned=
# step <name> <command...>: output to .ci/<name>.log
step() {
	name=$1; shift
	printf '%-12s ' "$name"
	t=$(date +%s)
	if "$@" > "$CI/$name.log" 2>&1; then
		echo "ok, $(( $(date +%s) - t )) s"
		return 0
	fi
	echo "FAILED, $(( $(date +%s) - t )) s: .ci/$name.log"
	return 1
}

# set -e does not work in functions called from step (|| context): every command is checked
test_latest() {
	mkdir -p "$CI/xray" && (
		cd "$CI/xray" || exit 1
		gh release download --repo XTLS/Xray-core --pattern Xray-linux-64.zip --pattern Xray-linux-64.zip.dgst || exit 1
		sum=$(sed -n 's/^SHA2-256= *//p' Xray-linux-64.zip.dgst)
		[ -n "$sum" ] || { echo "no SHA2-256 in Xray-linux-64.zip.dgst"; exit 1; }
		echo "$sum  Xray-linux-64.zip" | sha256sum -c - && unzip -o Xray-linux-64.zip xray
	) && XRAY_BIN="$CI/xray/xray" sh "$SRC/scripts/test.sh"
}

itest() {
	rc=0
	timeout -k 10 900 sh "$SRC/scripts/itest.sh" || rc=$?
	if [ $rc = 124 ] || [ $rc = 137 ]; then
		echo "itest hangs, killed after 15 min"
		timeout 60 $DOCKER exec "$NAME" sh -c 'ps w; ubus -t 3 call xvpn status; ubus -t 3 call service list "{\"name\":\"xvpn\"}"; logread | tail -80' || true
		$DOCKER rm -f "$NAME" >/dev/null 2>&1 || true
	fi
	return $rc
}

build() {
	sh "$SRC/scripts/build.sh" || return 1
	[ -f "$SRC/dist/$ipk" ] || { echo "no dist/$ipk: $(ls "$SRC/dist")"; return 1; }
	rm -rf dist && cp -r "$SRC/dist" dist
}

echo "ci: HEAD $(git rev-parse --short HEAD), package $ipk"
step test sh "$SRC/scripts/test.sh" || failed="$failed test"
step test-latest test_latest || warned="$warned test-latest"
step itest itest || failed="$failed itest"
step build build || failed="$failed build"

[ -z "$warned" ] || echo "ci: warning:$warned failed (informational until #14)"
[ -z "$failed" ] || die "failed:$failed"
echo "ci: ok, dist/$ipk"

if [ "$MODE" = release ]; then
	git tag -a "$tag" -m "$tag"
	git push origin "refs/tags/$tag"
	gh release create "$tag" dist/*.ipk --repo "$REPO" --title "$tag" --generate-notes --verify-tag
fi
