#!/bin/sh
# Runs unit tests in an OpenWrt 24.10 container, validates the generated xray
# config with xray-core and the nft rules with nft --check.
# XRAY_BIN=<path to an xray binary on the host> checks the config with that build
# instead of xray-core from the feed (CI runs the latest xray release this way): servers
# whose links set what that xray forbids are dropped (tests/xray-check.uc), the rest of
# the config must pass. cli.uc generate runs with the links of tests/fixtures/links.txt:
# the servers named in XRAY_REJECT (space-separated, empty for the feed's xray) and only
# they are rejected, with xray's reason kept in tested.json; a second generate runs no
# xray and logs them as rejected earlier, with the reasons (#14).
set -e
cd "$(dirname "$0")/.."
DOCKER="${DOCKER:-docker}"
IMAGE="${IMAGE:-openwrt/rootfs:x86-64-24.10.4}"
set --
[ -z "${XRAY_BIN:-}" ] || set -- -v "$(realpath "$XRAY_BIN"):/opt/xray:ro"

$DOCKER run --rm --cap-add NET_ADMIN -v "$PWD:/src:ro" -e XRAY_REJECT="${XRAY_REJECT:-}" "$@" "$IMAGE" sh -ec '
	mkdir -p /var/lock /tmp/out
	# downloads.openwrt.org now and then fails with "wget returned 4": try again
	n=0; until opkg update >/dev/null; do
		n=$((n + 1)); [ $n -lt 5 ] || { echo "opkg update failed 5 times"; exit 1; }; sleep 5
	done
	n=0; until opkg install ucode-mod-uloop xray-core kmod-nft-tproxy >/dev/null 2>&1 || opkg install ucode-mod-uloop xray-core >/dev/null; do
		n=$((n + 1)); [ $n -lt 5 ] || { echo "opkg install failed 5 times"; exit 1; }; sleep 5
	done
	ucode -L "/src/luci-app-xvpn/root/usr/share/ucode/*.uc" /src/tests/run.uc /src/tests/fixtures /tmp/out
	for f in /src/luci-app-xvpn/root/usr/share/xvpn/*.uc; do
		ucode -L "/src/luci-app-xvpn/root/usr/share/ucode/*.uc" -c -o /dev/null "$f" || { echo "compile failed: $f"; exit 1; }
	done
	ucode -L "/src/luci-app-xvpn/root/usr/share/ucode/*.uc" -c -o /dev/null /src/luci-app-xvpn/root/usr/share/rpcd/ucode/luci.xvpn
	xray=/usr/bin/xray mode=strict; [ ! -e /opt/xray ] || { xray=/opt/xray; mode=lenient; }
	v=$($xray version) || { echo "$xray version failed: $v"; exit 1; }
	echo "$v" | head -1
	for f in config config-doh config-noipv6 config-bt config-split; do
		ucode /src/tests/xray-check.uc config $xray /tmp/out/$f.json $mode
	done

	# the real generate: the rejected servers are found one by one and dropped
	root=/src/luci-app-xvpn/root
	mkdir -p /usr/share/ucode/xvpn /usr/share/xvpn
	cp $root/usr/share/ucode/xvpn/*.uc /usr/share/ucode/xvpn/
	cp $root/usr/share/xvpn/cli.uc /usr/share/xvpn/
	cp $root/etc/config/xvpn /etc/config/xvpn
	# xray_bin counts its runs; logger writes to a file (no logd in the container)
	printf "#!/bin/sh\necho \"\$*\" >> /tmp/xray-runs\nexec $xray \"\$@\"\n" > /tmp/xray-count
	rm /usr/bin/logger	# a link to busybox: > would overwrite busybox itself
	printf "#!/bin/sh\nshift 2\necho \"\$*\" >> /tmp/xvpn.log\n" > /usr/bin/logger
	chmod +x /tmp/xray-count /usr/bin/logger
	uci set xvpn.main.xray_bin=/tmp/xray-count
	while read -r l; do [ -z "$l" ] || uci add_list xvpn.manual.link="$l"; done < /src/tests/fixtures/links.txt
	uci commit xvpn
	ucode /usr/share/xvpn/cli.uc generate
	$xray run -test -c /var/etc/xvpn/config.json >/dev/null || { echo "generate: xray rejects the config"; exit 1; }
	ucode /src/tests/xray-check.uc generate 12
	runs=$(wc -l < /tmp/xray-runs)
	ucode /usr/share/xvpn/cli.uc generate
	ucode /src/tests/xray-check.uc again $runs /tmp/xvpn.log
	for f in /tmp/out/*.nft; do s=$(date +%s); nft -c -f "$f" && echo "nft ok: $f ($(($(date +%s) - s)) s)"; done
'
