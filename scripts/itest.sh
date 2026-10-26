#!/bin/sh
# Integration test: runs the service under procd in an OpenWrt container with two
# local VLESS "remote" servers, checks server selection, failover and subscription update.
set -e
cd "$(dirname "$0")/.."
DOCKER="${DOCKER:-docker}"
IMAGE="${IMAGE:-openwrt/rootfs:x86-64-24.10.4}"
NAME=xvpn-itest

$DOCKER rm -f $NAME >/dev/null 2>&1 || true
$DOCKER run -d --name $NAME --privileged -v "$PWD:/src:ro" "$IMAGE" /sbin/init >/dev/null
trap '$DOCKER rm -f $NAME >/dev/null' EXIT
sleep 5

$DOCKER exec -i $NAME sh -e <<'IN'
UUID=11111111-2222-3333-4444-555555555555
mkdir -p /var/lock
opkg update >/dev/null
opkg install ucode-mod-uloop xray-core curl >/dev/null
cp -a /src/luci-app-xvpn/root/. /
/etc/uci-defaults/80_luci-xvpn

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
status() { ubus call xvpn status | jsonfilter -e "$1"; }
wait_for() { # expr value timeout
	i=0; while [ $i -lt $3 ]; do [ "$(status "$1" 2>/dev/null)" = "$2" ] && return 0; sleep 1; i=$((i+1)); done
	echo "TIMEOUT waiting for $1 == $2"; ubus call xvpn status; logread | grep -E 'xvpn|xray' | tail -20; exit 1
}
active_name() { ubus call xvpn status | jsonfilter -e "@.servers[@.id='$(status @.active)'].name"; }

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

# subscription from a file
{ link 18443 sub-a; link 18445 sub-b; } | base64 | tr -d '\n' > /tmp/sub.b64
uci batch <<UCI
set xvpn.s1=subscription
set xvpn.s1.name=test
set xvpn.s1.url=file:///tmp/sub.b64
set xvpn.s1.via_tunnel=0
commit xvpn
UCI
ucode /usr/share/xvpn/cli.uc update s1 || true
[ "$(jsonfilter -i /etc/xvpn/subs/s1.json -e '@.servers[*].name' | wc -l)" = 2 ] && echo "OK: subscription parsed"
/etc/init.d/xvpn reload
sleep 3
[ "$(ubus call xvpn status | jsonfilter -e '@.servers[*].name' | wc -l)" = 4 ] && echo "OK: 4 servers after reload"

/etc/init.d/xvpn stop
nft list table inet xvpn >/dev/null 2>&1 && { echo "FAIL: table left after stop"; exit 1; }
echo "OK: rules removed on stop"
IN
