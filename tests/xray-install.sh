#!/bin/sh
# cli.uc xray-install and xray-rollback (#31) against the fake release of tests/mkrelease.py
# in /rel; run by scripts/test.sh in the container after the files are copied.
set -e
export XVPN_XRAY_RELEASES=file:///rel
CLI="ucode /usr/share/xvpn/cli.uc"
fail() { echo "xray-install: $*"; cat /var/run/xvpn/xray-job.json 2>/dev/null; exit 1; }
job() { jsonfilter -i /var/run/xvpn/xray-job.json -e "@.$1"; }

prev=$(uci get xvpn.main.xray_bin)
for tag in v9.9.9 v9.9.8; do
	$CLI xray-install $tag id-$tag || fail "$tag failed"
	[ "$(job state):$(job id):$(job version)" = "done:id-$tag:${tag#v}" ] || fail "$tag: job"
	[ "$(uci get xvpn.main.xray_bin)" = /usr/lib/xvpn/xray ] || fail "$tag: xray_bin"
	/usr/lib/xvpn/xray version | grep -q "^Xray ${tag#v} " || fail "$tag: version"
	[ "$(jsonfilter -i /usr/lib/xvpn/xray.json -e @.tag)" = $tag ] || fail "$tag: xray.json"
done
echo "xray-install ok: deflated and stored zips"

for t in "v9.9.7:sha256 of Xray-linux-64.zip does not match" "v9.9.6:says it is 1.2.3" \
	"v9.9.5:no xray in the zip" "v9.9.4:download of v9.9.4/Xray-linux-64.zip"; do
	tag=${t%%:*} want=${t#*:}
	! $CLI xray-install $tag 2>/dev/null || fail "$tag passed"
	[ "$(job state)" = failed ] || fail "$tag: state"
	job error | grep -qF "$want" || fail "$tag: error '$(job error)', want '$want'"
	/usr/lib/xvpn/xray version | grep -q '^Xray 9.9.8 ' || fail "$tag replaced the release"
done
[ ! -e /usr/lib/xvpn/xray.new ] && ! ls /tmp/xvpn-Xray-* 2>/dev/null || fail "files left behind"
! $CLI xray-install 9.9.9 2>/dev/null || fail "a tag without v passed"
echo "xray-install ok: rejects a bad digest, version, zip, download"

ucode -e 'import { info } from "xvpn.xraycore"; import { load_config } from "xvpn.util"; printf("%J\n", info(load_config()));' > /tmp/xray-info.json
for want in source=github github.tag=v9.9.8 asset=Xray-linux-64.zip job.state=failed; do
	[ "$(jsonfilter -i /tmp/xray-info.json -e "@.${want%%=*}")" = "${want#*=}" ] || fail "info: $want: $(cat /tmp/xray-info.json)"
done

$CLI xray-rollback || fail "rollback failed"
[ "$(uci get xvpn.main.xray_bin)" = /usr/bin/xray ] && [ ! -e /usr/lib/xvpn/xray ] && [ ! -e /usr/lib/xvpn/xray.json ] || fail "rollback"
# after a sysupgrade: the config names the release, the file is gone
uci set xvpn.main.xray_bin=/usr/lib/xvpn/xray
[ "$($CLI xray-bin)" = /usr/bin/xray ] || fail "no fallback to the feed's xray"
uci set xvpn.main.xray_bin="$prev"
uci commit xvpn
echo "xray-install ok: rollback, fallback after a sysupgrade"
