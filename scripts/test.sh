#!/bin/sh
# Runs unit tests in an OpenWrt 24.10 container, validates the generated xray
# config with xray-core and the nft rules with nft --check.
set -e
cd "$(dirname "$0")/.."
DOCKER="${DOCKER:-docker}"
IMAGE="${IMAGE:-openwrt/rootfs:x86-64-24.10.4}"

$DOCKER run --rm --cap-add NET_ADMIN -v "$PWD:/src:ro" "$IMAGE" sh -ec '
	mkdir -p /var/lock /tmp/out
	opkg update >/dev/null
	opkg install ucode-mod-uloop xray-core kmod-nft-tproxy >/dev/null 2>&1 || opkg install ucode-mod-uloop xray-core >/dev/null
	ucode -L "/src/luci-app-xvpn/root/usr/share/ucode/*.uc" /src/tests/run.uc /src/tests/fixtures /tmp/out
	for f in /src/luci-app-xvpn/root/usr/share/xvpn/*.uc; do
		ucode -L "/src/luci-app-xvpn/root/usr/share/ucode/*.uc" -c -o /dev/null "$f" || { echo "compile failed: $f"; exit 1; }
	done
	ucode -L "/src/luci-app-xvpn/root/usr/share/ucode/*.uc" -c -o /dev/null /src/luci-app-xvpn/root/usr/share/rpcd/ucode/luci.xvpn
	xray run -test -c /tmp/out/config.json
	for f in /tmp/out/*.nft; do nft -c -f "$f" && echo "nft ok: $f"; done
'
