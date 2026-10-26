#!/bin/sh
# Builds dist/luci-app-xvpn_*.ipk with the OpenWrt 24.10 SDK in docker.
# Only luci.mk, luci-base and csstidy are taken from the luci feed, without their
# dependencies, and only their host tools are built. The package itself is built
# with NO_DEPS=1: otherwise the SDK would compile every runtime dependency
# (luci-base, xray-core with the Go toolchain), while for an arch "all" package
# they only matter in the ipk Depends.
set -eu
cd "$(dirname "$0")/.."
DOCKER="${DOCKER:-docker --context default}"
IMAGE="${IMAGE:-openwrt/sdk:mediatek-filogic-24.10.4}"
LUCI_FEED="${LUCI_FEED:-https://github.com/openwrt/luci.git;openwrt-24.10}"

TAR="$(mktemp)"
trap 'rm -f "$TAR"' EXIT
trap 'exit 130' INT TERM
# build log goes to stderr, the packages come back as a tar on stdout
$DOCKER run --rm --init -v "$PWD:/src:ro" -e LUCI_FEED="$LUCI_FEED" \
	"$IMAGE" bash -euc '
	exec 3>&1 1>&2
	cd /builder
	echo "src-git luci $LUCI_FEED" > feeds.conf
	./scripts/feeds update luci >/dev/null
	mkdir -p package/feeds/luci
	ln -s ../../../feeds/luci/modules/luci-base ../../../feeds/luci/contrib/package/csstidy package/feeds/luci/
	cp -r /src/luci-app-xvpn package/
	make defconfig >/dev/null
	make package/luci-base/host/compile package/csstidy/host/compile -j"$(nproc)"
	make package/luci-app-xvpn/compile NO_DEPS=1
	cd bin/packages/*/base
	tar -c luci-app-xvpn_*.ipk $(ls luci-i18n-xvpn-*.ipk 2>/dev/null) >&3
' > "$TAR"
# replace dist/ only after a successful build
rm -rf dist
mkdir dist
tar -x -f "$TAR" -C dist
ls -l dist
