#!/bin/sh
# Local CI (there is no GitHub Actions workflow): checks a clean export of HEAD,
# uncommitted changes are not checked.
#   test         scripts/test.sh with xray-core from the OpenWrt 24.10 feed
#   test-xray    scripts/test.sh with the xray release XRAY_TAG from GitHub (sha256 from
#                its .dgst, kept in .cache/xray/<tag>/): the config must pass, the fixture
#                servers that xray forbids (XRAY_REJECT) are rejected one by one by cli.uc
#                generate (#14). The tag is pinned, so a new xray release does not fail
#                every branch; a newer release than XRAY_TAG is only a warning
#   itest        scripts/itest.sh; a hung run is killed after 12 min, the container
#                state goes to the log
#   build        scripts/build.sh, the packages are copied to dist/
#
#   sh scripts/ci.sh           check HEAD
#   sh scripts/ci.sh release   check HEAD (must be origin/main), tag it v<PKG_VERSION>
#                              (v<PKG_VERSION>-r<PKG_RELEASE> when PKG_RELEASE is not 1),
#                              push the tag and publish a GitHub Release with the ipk
#
# Logs: .ci/<step>.log. Variables: DOCKER (default docker --context default), NAME
# (itest container, by default unique per checkout, so worktrees do not collide),
# XRAY_TAG and XRAY_REJECT (another xray release for test-xray and the fixture servers it
# rejects; by default those of XRAY_PINNED).
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
# the xray release test-xray checks and the fixture links (tests/fixtures/links.txt) it
# forbids: vless without TLS to a public address, allowInsecure. A newer release: check it
# with XRAY_TAG=<tag> (and XRAY_REJECT), then update both here
XRAY_PINNED=v26.10.29
XRAY_PINNED_REJECT="HTTPUpgrade Insecure"
XRAY_TAG=${XRAY_TAG:-$XRAY_PINNED}
XRAY_REJECT=${XRAY_REJECT-$XRAY_PINNED_REJECT}
XRAY_URL=https://github.com/XTLS/Xray-core/releases
XRAY_ZIP=Xray-linux-64.zip
XRAY_CACHE=$PWD/.cache/xray/$XRAY_TAG
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

# the release of XRAY_TAG into .cache/xray/<tag>/ (public: no gh, no token); the zip is
# checked against its .dgst on every run, a bad one is removed
fetch_xray() {
	mkdir -p "$XRAY_CACHE" "$CI/xray" || return 1
	for f in "$XRAY_ZIP.dgst" "$XRAY_ZIP"; do
		[ -s "$XRAY_CACHE/$f" ] && continue
		curl -fsSL --retry 3 -o "$XRAY_CACHE/$f.part" "$XRAY_URL/download/$XRAY_TAG/$f" \
			&& mv "$XRAY_CACHE/$f.part" "$XRAY_CACHE/$f" || { rm -f "$XRAY_CACHE/$f.part"; return 1; }
	done
	sum=$(sed -n 's/^SHA2-256= *//p' "$XRAY_CACHE/$XRAY_ZIP.dgst")
	[ -n "$sum" ] || { echo "no SHA2-256 in $XRAY_ZIP.dgst"; rm -f "$XRAY_CACHE/$XRAY_ZIP.dgst"; return 1; }
	echo "$sum  $XRAY_CACHE/$XRAY_ZIP" | sha256sum -c - \
		|| { rm -f "$XRAY_CACHE/$XRAY_ZIP" "$XRAY_CACHE/$XRAY_ZIP.dgst"; return 1; }
	unzip -o "$XRAY_CACHE/$XRAY_ZIP" xray -d "$CI/xray"
}

test_xray() {
	XRAY_BIN="$CI/xray/xray" XRAY_REJECT="$XRAY_REJECT" sh "$SRC/scripts/test.sh"
}

# the tag GitHub redirects releases/latest to
latest_xray() {
	curl -fsS -m 10 -o /dev/null -w '%{redirect_url}' "$XRAY_URL/latest" | sed -n 's|.*/tag/||p'
}

itest() {
	rc=0
	timeout -k 10 720 sh "$SRC/scripts/itest.sh" || rc=$?
	if [ $rc = 124 ] || [ $rc = 137 ]; then
		echo "itest hangs, killed after 12 min"
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
if fetch_xray > "$CI/xray-download.log" 2>&1; then
	step test-xray test_xray || failed="$failed test-xray"
else
	echo "test-xray    download failed ($XRAY_TAG): .ci/xray-download.log"
	failed="$failed test-xray(download)"
fi
latest=$(latest_xray) || latest=
if [ -z "$latest" ]; then
	warned="$warned could not check the latest xray release;"
elif [ "$latest" != "$XRAY_TAG" ] && [ "$(printf '%s\n%s\n' "$XRAY_TAG" "$latest" | sort -V | tail -1)" = "$latest" ]; then
	warned="$warned xray $latest is out, test-xray checks $XRAY_TAG: run XRAY_TAG=$latest sh scripts/ci.sh and update XRAY_PINNED in scripts/ci.sh;"
fi
step itest itest || failed="$failed itest"
step build build || failed="$failed build"

[ -z "$warned" ] || echo "ci: warning:$warned"
[ -z "$failed" ] || die "failed:$failed"
echo "ci: ok, dist/$ipk"

if [ "$MODE" = release ]; then
	git tag -a "$tag" -m "$tag"
	git push origin "refs/tags/$tag"
	gh release create "$tag" dist/*.ipk --repo "$REPO" --title "$tag" --generate-notes --verify-tag
fi
