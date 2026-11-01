#!/bin/sh
# Local CI (there is no GitHub Actions workflow): checks a clean export of HEAD,
# uncommitted changes are not checked.
#   test         scripts/test.sh with xray-core from the OpenWrt 24.10 feed
#   test-xray    scripts/test.sh with the xray release XRAY_TAG from GitHub (sha256 from
#                its .dgst, kept in .cache/xray/<tag>/): the config must pass, the fixture
#                servers that xray forbids (XRAY_REJECT) are rejected one by one by cli.uc
#                generate (#14). The tag is pinned, so a new xray release does not fail
#                every branch; a newer release than XRAY_TAG is only a warning
#   itest        scripts/itest.sh; a hung run is killed after 15 min, the container
#                state goes to the log
#   build        scripts/build.sh, the packages are copied to dist/
#   desktop      scripts/desktop-build.sh test, then the build: Linux binary, deb and
#                AppImage, Windows NSIS setup (cross-built), copied to dist/desktop/; signed
#                with latest.json when the updater key is there (~/.config/xvpn-desktop,
#                scripts/desktop-build.sh). DESKTOP_TARGETS limits the build ("linux"),
#                DESKTOP_ITEST=1 also runs scripts/desktop-itest.sh against the LuCI stand
#
#   sh scripts/ci.sh           check HEAD
#   sh scripts/ci.sh release   check HEAD (must be origin/main) and publish the GitHub
#                              Release v<PKG_VERSION> (v<PKG_VERSION>-r<PKG_RELEASE> when
#                              PKG_RELEASE is not 1) with the ipk and the desktop app (all
#                              its packages signed with the key tauri.conf.json knows,
#                              latest.json for the updater): a draft first, its tag is made
#                              on publishing; a run that failed half way goes on from it
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

# the updater key of the desktop app (scripts/desktop-build.sh signs with it)
KEYS=${KEYS:-$HOME/.config/xvpn-desktop}
export KEYS
# a release that stopped half way (upload failed): the tag exists only once it is published
# (gh creates it then), a draft release of HEAD is taken up again; see the end
resume=
if [ "$MODE" = release ]; then
	[ -z "$(git status --porcelain)" ] || die "uncommitted changes"
	command -v jq >/dev/null || die "jq is needed to check latest.json"
	gh auth status >/dev/null 2>&1 || die "gh is not logged in (gh auth login): the release could not be uploaded"
	git fetch -q origin main --tags
	[ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] \
		|| die "HEAD is not origin/main: a release is made from the pushed main"
	draft=$(gh release view "$tag" --repo "$REPO" --json isDraft --jq .isDraft 2>/dev/null) || draft=none
	if git rev-parse -q --verify "refs/tags/$tag" >/dev/null || [ "$draft" = false ]; then
		die "release $tag exists: raise PKG_VERSION or PKG_RELEASE in luci-app-xvpn/Makefile"
	fi
	if [ "$draft" = true ]; then
		[ "$(gh release view "$tag" --repo "$REPO" --json targetCommitish --jq .targetCommitish)" = "$(git rev-parse HEAD)" ] \
			|| die "draft release $tag is of another commit: delete it (gh release delete $tag) or release that commit"
		resume=1
	fi
	[ -f "$KEYS/updater.key" ] || die "no updater key $KEYS/updater.key: the desktop app would be unsigned"
	# the app has PKG_VERSION only: a -rN with another desktop/ would not reach the updater
	# (same version as the previous release)
	if [ "$rel" != 1 ]; then
		prev=$(git tag -l "v$ver" "v$ver-r*" | sort -V | tail -1)
		[ -z "$prev" ] || git diff --quiet "$prev" HEAD -- desktop/ \
			|| die "desktop/ changed since $prev: the updater would not see it, raise PKG_VERSION instead of PKG_RELEASE"
	fi
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
	# 15 min: a whole run takes ~12 on a busy host (716 s in #85, the speed meter and the rpcd
	# user added), 12 min killed runs that were about to pass; a hang still stops here
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
	# the translations (po/*/xvpn.po) come as luci-i18n-xvpn-<lang> packages
	for po in "$SRC"/luci-app-xvpn/po/*/xvpn.po; do
		lang=$(basename "$(dirname "$po")")
		[ "$lang" = templates ] || ls "$SRC/dist"/luci-i18n-xvpn-"$lang"_*.ipk >/dev/null 2>&1 ||
			{ echo "no dist/luci-i18n-xvpn-${lang}_*.ipk: $(ls "$SRC/dist")"; return 1; }
	done
	mkdir -p dist && rm -f dist/*.ipk && cp "$SRC"/dist/*.ipk dist/
}

# the desktop app (#81): tests, then the packages of TARGETS; the version is PKG_VERSION
desktop() {
	sh "$SRC/scripts/desktop-build.sh" test || return 1
	TARGETS="${DESKTOP_TARGETS:-linux windows}" TAG="$tag" sh "$SRC/scripts/desktop-build.sh" || return 1
	if [ "${DESKTOP_ITEST:-0}" = 1 ]; then
		(cd "$SRC" && sh scripts/desktop-itest.sh) || return 1
	fi
	rm -rf dist/desktop && mkdir -p dist && cp -r "$SRC/dist/desktop" dist/desktop
}

# what the release uploads besides the ipk: all of it, each .sig checked against the public
# key of tauri.conf.json (a key other than the one the apps know would publish an update every
# installed app refuses), latest.json for this version and tag
desktop_assets() {
	d=dist/desktop
	for f in "$d"/xvpn_"$ver"_amd64.deb "$d"/xvpn_"$ver"_amd64.deb.sig "$d"/xvpn_"$ver"_amd64.AppImage \
		"$d"/xvpn_"$ver"_amd64.AppImage.sig "$d"/xvpn_"$ver"_x64-setup.exe "$d"/xvpn_"$ver"_x64-setup.exe.sig "$d"/latest.json; do
		[ -s "$f" ] || { echo "ci: no $f (the updater key: scripts/desktop-build.sh)" >&2; return 1; }
		echo "$f"
	done
	jq -e --arg v "$ver" --arg t "$tag" '.version == $v and (.platforms | length == 3)
		and all(.platforms[]; .url | contains("/download/" + $t + "/"))' "$d/latest.json" >/dev/null \
		|| { echo "ci: $d/latest.json is not for $ver / $tag" >&2; return 1; }
	sh scripts/desktop-build.sh verify >&2 || { echo "ci: the signatures do not match the public key of tauri.conf.json" >&2; return 1; }
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
step desktop desktop || failed="$failed desktop"

[ -z "$warned" ] || echo "ci: warning:$warned"
[ -z "$failed" ] || die "failed:$failed"
echo "ci: ok, dist/$ipk"

if [ "$MODE" = release ]; then
	assets=$(desktop_assets) || die "the desktop app is not ready for the release"
	notes="Пакеты:
- \`$ipk\` и \`luci-i18n-xvpn-*\` — роутер (OpenWrt 24.10)
- \`xvpn_${ver}_x64-setup.exe\` — приложение для Windows (установщик NSIS)
- \`xvpn_${ver}_amd64.AppImage\`, \`xvpn_${ver}_amd64.deb\` — приложение для Linux (оба обновляются из приложения)
- \`*.sig\`, \`latest.json\` — подписи и манифест автообновления приложения"
	# a draft first: gh creates the tag only when it is published, so a failed upload leaves
	# no tag behind, and the next run uploads into the same draft
	# shellcheck disable=SC2086 # one asset per line, no spaces in the names
	if [ -z "$resume" ]; then
		gh release create "$tag" --draft --target "$(git rev-parse HEAD)" --repo "$REPO" --title "$tag" \
			--notes "$notes" --generate-notes || die "could not create the draft release $tag"
	fi
	gh release upload "$tag" dist/*.ipk $assets --clobber --repo "$REPO" \
		|| die "upload to the draft $tag failed: run sh scripts/ci.sh release again to go on"
	gh release edit "$tag" --draft=false --repo "$REPO" || die "could not publish $tag: run again to go on"
	git fetch -q origin --tags
	echo "ci: released $tag"
fi
