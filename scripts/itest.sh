#!/bin/sh
# Integration test: runs the service under procd in an OpenWrt container with two
# local VLESS "remote" servers, checks server selection, failover and subscription update
# (from LuCI through the daemon and by a reload past it).
set -e
cd "$(dirname "$0")/.."
DOCKER="${DOCKER:-docker}"
IMAGE="${IMAGE:-openwrt/rootfs:x86-64-24.10.4}"
NAME="${NAME:-xvpn-itest}"

$DOCKER rm -f $NAME >/dev/null 2>&1 || true
$DOCKER run -d --name $NAME --privileged -v "$PWD:/src:ro" "$IMAGE" /sbin/init >/dev/null
trap '$DOCKER rm -f $NAME >/dev/null' EXIT
ADDR=$($DOCKER inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}/{{.IPPrefixLen}} {{.Gateway}}{{end}}' $NAME)
sleep 5

$DOCKER exec -i -e ADDR="$ADDR" $NAME sh -e <<'IN'
UUID=11111111-2222-3333-4444-555555555555
mkdir -p /var/lock
# netifd puts eth0 into br-lan and drops the docker address: give lan that address on eth0
i=0; until uci -q get network.lan >/dev/null && ubus list network >/dev/null 2>&1; do
	[ $i -lt 30 ] || { echo "FAIL: netifd is not up"; exit 1; }; sleep 1; i=$((i+1)); done
uci batch <<UCI
set network.lan.device=eth0
set network.lan.ipaddr=${ADDR% *}
set network.lan.gateway=${ADDR#* }
delete network.lan.netmask
commit network
UCI
/etc/init.d/network reload
i=0; until ip route | grep -q '^default'; do [ $i -lt 15 ] || { echo "FAIL: no network"; exit 1; }; sleep 1; i=$((i+1)); done
opkg update >/dev/null
opkg install ucode-mod-uloop xray-core curl >/dev/null
cp -a /src/luci-app-xvpn/root/. /
/etc/uci-defaults/80_luci-xvpn
/etc/init.d/rpcd restart

remote() { # port
	cat > /tmp/remote-$1.json <<JSON
{ "inbounds": [ { "listen": "127.0.0.1", "port": $1, "protocol": "vless",
    "settings": { "clients": [ { "id": "$UUID" } ], "decryption": "none" } } ],
  "outbounds": [ { "protocol": "freedom" } ] }
JSON
	xray run -c /tmp/remote-$1.json >/dev/null 2>&1 &
	echo $! > /tmp/remote-$1.pid
}
link() { echo "vless://$UUID@127.0.0.1:$1?type=tcp&security=none#$2"; }
b64() { ucode -l fs -e 'print(b64enc(fs.stdin.read("all")))'; }	# busybox has no base64
status() { ubus call xvpn status | jsonfilter -e "$1"; }
wait_for() { # expr value timeout
	i=0; while [ $i -lt $3 ]; do [ "$(status "$1" 2>/dev/null)" = "$2" ] && return 0; sleep 1; i=$((i+1)); done
	echo "TIMEOUT waiting for $1 == $2"; ubus call xvpn status; logread | grep -E 'xvpn|xray' | tail -20; exit 1
}
active_name() { ubus call xvpn status | jsonfilter -e "@.servers[@.id='$(status @.active)'].name"; }
active_is() { [ "$(active_name)" = "$1" ]; }
latency() { ubus call xvpn status | jsonfilter -e "@.servers[@.name='$1'].latency"; }
count_is() { [ "$(ubus call xvpn status | jsonfilter -e '@.servers[*].name' | wc -l)" = "$1" ]; }
xvpnd_pid() { ubus call service list '{"name":"xvpn"}' | jsonfilter -e '@.xvpn.instances.xvpnd.pid'; }
xvpnd_restarted() { p=$(xvpnd_pid); [ -n "$p" ] && [ "$p" != "$1" ] && ubus call xvpn status >/dev/null; }
wait_cmd() { # timeout cmd...
	t=$1; shift; i=0
	while [ $i -lt $t ]; do "$@" >/dev/null 2>&1 && return 0; sleep 1; i=$((i+1)); done
	echo "TIMEOUT waiting for: $*"; ubus call xvpn status; logread | grep -E 'xvpn|xray' | tail -20; exit 1
}

remote 18443
uci batch <<UCI
set xvpn.main.enabled=1
add_list xvpn.access.network=lan
set xvpn.health.interval=3
set xvpn.health.timeout=4
set xvpn.health.fail_threshold=2
add_list xvpn.manual.link='$(link 18444 second)'
add_list xvpn.manual.link='$(link 18443 first)'
commit xvpn
UCI

/etc/init.d/xvpn start
sleep 2
wait_for @.state connected 40
[ "$(active_name)" = first ] || { echo "FAIL: expected first, got $(active_name)"; exit 1; }
echo "OK: picked the live server"
nft list table inet xvpn >/dev/null && echo "OK: nft table present"
ip rule | grep -q 'lookup 100' && echo "OK: ip rule present"

# failover: kill the active remote, start the other one
kill $(cat /tmp/remote-18443.pid); remote 18444
sleep 8
wait_for @.state connected 60
[ "$(active_name)" = second ] || { echo "FAIL: failover expected second, got $(active_name)"; exit 1; }
echo "OK: failover to the other server"
logread | grep xvpn | grep -E 'switching|state' | tail -5

# LuCI: a new subscription; its servers go before the manual links, so every test
# port shifts (20000 was "second", now it is a dead server)
remote 18446
{ link 18445 sub-dead; link 18446 sub-live; } | b64 > /www/sub.b64
uci batch <<UCI
set xvpn.s1=subscription
set xvpn.s1.name=test
set xvpn.s1.url=http://127.0.0.1/sub.b64
set xvpn.s1.via_tunnel=0
commit xvpn
UCI
# apply in LuCI = reload_config: procd restarts xvpnd for the new config
old=$(xvpnd_pid); reload_config
wait_cmd 30 xvpnd_restarted "$old"
wait_for @.state connected 30
r=$(ubus call luci.xvpn update '{"sid":"s1"}')
[ "$(echo "$r" | jsonfilter -e @.ok)" = true ] || { echo "FAIL: luci.xvpn update: $r"; exit 1; }
wait_cmd 30 count_is 4
[ "$(jsonfilter -i /etc/xvpn/subs/s1.json -e '@.servers[*].name' | wc -l)" = 2 ] || { echo "FAIL: subscription cache"; exit 1; }
echo "OK: subscription parsed"
wait_for @.state connected 30
[ "$(status '@.servers[0].name')" = sub-dead ] || { echo "FAIL: index order"; ubus call xvpn status; exit 1; }
[ "$(active_name)" = second ] || { echo "FAIL: after update expected second, got $(active_name)"; exit 1; }
echo "OK: update from LuCI went through the daemon, 4 servers, still on second"

ubus call xvpn test >/dev/null
sleep 1; wait_for @.testing false 30
[ "$(latency sub-dead)" = -1 ] && [ "$(latency first)" = -1 ] \
	&& [ "$(latency sub-live)" -ge 0 ] && [ "$(latency second)" -ge 0 ] \
	|| { echo "FAIL: latencies are attributed to wrong servers"; ubus call xvpn status; exit 1; }
echo "OK: measurements match the new server list"

kill $(cat /tmp/remote-18444.pid)
sleep 6
wait_cmd 60 active_is sub-live
wait_for @.state connected 30
echo "OK: failover after the update went to the live sub-live"

# reload past the daemon (UCI triggers on wireless/network): ports shift again,
# sub-live moves from 20001 to 20002
{ link 18447 sub-x; link 18448 sub-y; link 18446 sub-live; } | b64 > /www/sub.b64
ucode /usr/share/xvpn/cli.uc update s1 >/dev/null
/etc/init.d/xvpn reload
wait_cmd 10 count_is 5
switch=$(status @.last_switch.at)
sleep 12
[ "$(status @.state)" = connected ] && [ "$(active_name)" = sub-live ] && [ "$(status @.last_switch.at)" = "$switch" ] \
	|| { echo "FAIL: external reload broke the state"; ubus call xvpn status; logread | grep xvpn | tail -10; exit 1; }
echo "OK: external reload picked up, still connected to sub-live"

# one update at a time: a live updater holds the lock (pid 1 stands for it)
ln -s 1 /var/run/xvpn/updating
[ "$(ubus call luci.xvpn update | jsonfilter -e @.error)" = busy ] || { echo "FAIL: no busy while updating"; exit 1; }
[ "$(ubus call luci.xvpn subscriptions | jsonfilter -e @.updating)" = true ] || { echo "FAIL: updating flag"; exit 1; }
rm /var/run/xvpn/updating
echo "OK: single update lock"

/etc/init.d/xvpn stop
nft list table inet xvpn >/dev/null 2>&1 && { echo "FAIL: table left after stop"; exit 1; }
echo "OK: rules removed on stop"
IN
