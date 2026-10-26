#!/bin/sh
# Builds dist/luci-app-xvpn_*.ipk with the OpenWrt 24.10 SDK in docker.
# Only the luci feed is added (luci.mk and the luci-base host tools): the runtime
# dependencies still end up in the ipk Depends, while installing them into the SDK
# would make it compile xray-core with the whole Go toolchain.
set -e
cd "$(dirname "$0")/.."
DOCKER="${DOCKER:-docker --context default}"
IMAGE="${IMAGE:-openwrt/sdk:mediatek-filogic-24.10.4}"
LUCI_FEED="${LUCI_FEED:-https://github.com/openwrt/luci.git;openwrt-24.10}"

rm -rf dist
mkdir -p dist
# build log goes to stderr, the packages come back as a tar on stdout
$DOCKER run --rm -v "$PWD:/src:ro" -e LUCI_FEED="$LUCI_FEED" \
	"$IMAGE" bash -ec '
	exec 3>&1 1>&2
	cd /builder
	echo "src-git luci $LUCI_FEED" > feeds.conf
	./scripts/feeds update luci >/dev/null
	./scripts/feeds install luci-base >/dev/null
	cp -r /src/luci-app-xvpn package/
	make defconfig >/dev/null
	make package/luci-app-xvpn/compile -j"$(nproc)" || make package/luci-app-xvpn/compile V=s
	cd bin/packages/*/base
	tar -c luci-app-xvpn_*.ipk $(ls luci-i18n-xvpn-*.ipk 2>/dev/null) >&3
' > dist/packages.tar
tar -x -f dist/packages.tar -C dist
rm dist/packages.tar
ls -l dist
