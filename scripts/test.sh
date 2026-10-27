#!/bin/sh
# Runs unit tests in an OpenWrt 24.10 container, validates the generated xray
# config with xray-core and the nft rules with nft --check.
# XRAY_BIN=<path to an xray binary on the host> checks the config with that build
# instead of xray-core from the feed (CI runs the latest xray release this way).
set -e
cd "$(dirname "$0")/.."
DOCKER="${DOCKER:-docker}"
IMAGE="${IMAGE:-openwrt/rootfs:x86-64-24.10.4}"
set --
[ -z "${XRAY_BIN:-}" ] || set -- -v "$(realpath "$XRAY_BIN"):/opt/xray:ro"

$DOCKER run --rm --cap-add NET_ADMIN -v "$PWD:/src:ro" "$@" "$IMAGE" sh -ec '
	mkdir -p /var/lock /tmp/out
	opkg update >/dev/null
	opkg install ucode-mod-uloop xray-core kmod-nft-tproxy >/dev/null 2>&1 || opkg install ucode-mod-uloop xray-core >/dev/null
	ucode -L "/src/luci-app-xvpn/root/usr/share/ucode/*.uc" /src/tests/run.uc /src/tests/fixtures /tmp/out
	for f in /src/luci-app-xvpn/root/usr/share/xvpn/*.uc; do
		ucode -L "/src/luci-app-xvpn/root/usr/share/ucode/*.uc" -c -o /dev/null "$f" || { echo "compile failed: $f"; exit 1; }
	done
	ucode -L "/src/luci-app-xvpn/root/usr/share/ucode/*.uc" -c -o /dev/null /src/luci-app-xvpn/root/usr/share/rpcd/ucode/luci.xvpn
	xray=xray; [ ! -e /opt/xray ] || xray=/opt/xray
	$xray version | head -1
	$xray run -test -c /tmp/out/config.json
	$xray run -test -c /tmp/out/config-doh.json
	$xray run -test -c /tmp/out/config-noipv6.json
	for f in /tmp/out/*.nft; do nft -c -f "$f" && echo "nft ok: $f"; done
'
