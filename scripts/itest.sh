#!/bin/sh
# Integration test: runs the service under procd in an OpenWrt container with two
# local VLESS "remote" servers, checks server selection, failover, subscription update and
# that a VPN client (network namespace behind a bridge port) never reaches the "internet"
# (another namespace) directly: boot guard, restart, stop, broken fw-apply, fw4 flush.
set -e
cd "$(dirname "$0")/.."
DOCKER="${DOCKER:-docker}"
IMAGE="${IMAGE:-openwrt/rootfs:x86-64-24.10.4}"
NAME=${NAME:-xvpn-itest}

$DOCKER rm -f $NAME >/dev/null 2>&1 || true
$DOCKER run -d --name $NAME --privileged -v "$PWD:/src:ro" "$IMAGE" /sbin/init >/dev/null
trap '$DOCKER rm -f $NAME >/dev/null' EXIT
sleep 5

NET=$($DOCKER inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}/{{.IPPrefixLen}} {{.Gateway}}{{end}}' $NAME)

$DOCKER exec -i -e NET="$NET" $NAME sh -e <<'IN'
UUID=11111111-2222-3333-4444-555555555555
mkdir -p /var/lock
i=0; until logread 2>/dev/null | grep -q 'init complete'; do [ $i -lt 30 ] || break; sleep 1; i=$((i+1)); done
# netifd puts eth0 into br-lan and drops the docker address: give it back as wan
set -- $NET
uci batch <<UCI
del_list network.@device[0].ports=eth0
set network.@device[0].bridge_empty=1
set network.wan=interface
set network.wan.device=eth0
set network.wan.proto=static
set network.wan.ipaddr=$1
set network.wan.gateway=$2
commit network
UCI
/etc/init.d/network restart
sleep 3
opkg update >/dev/null
opkg install ucode-mod-uloop xray-core curl ip-full >/dev/null
cp -a /src/luci-app-xvpn/root/. /
/etc/uci-defaults/80_luci-xvpn
/etc/init.d/rpcd restart
/etc/init.d/xvpn enable
# fw4 stays running; the test devices are in no zone, so the defaults decide
[ "$(uci -q get firewall.xvpn.path)" = /usr/share/xvpn/firewall.include ] || { echo "FAIL: no fw4 include"; exit 1; }
uci set firewall.@defaults[0].input=ACCEPT; uci set firewall.@defaults[0].forward=ACCEPT; uci commit firewall
/etc/init.d/firewall restart

# client --vc1/vc0-- [brt 10.77.0.1, router] --vw0/vw1-- wan 45.0.0.2 (http server)
ip netns add cl; ip netns add wan
ip link add vc0 type veth peer name vc1 netns cl
ip link add vw0 type veth peer name vw1 netns wan
ip link add brt type bridge; ip link set vc0 master brt
ip addr add 10.77.0.1/24 dev brt; ip addr add 45.0.0.1/24 dev vw0
for l in brt vc0 vw0; do ip link set $l up; done
ip -n cl addr add 10.77.0.2/24 dev vc1; ip -n cl link set vc1 up; ip -n cl link set lo up
ip -n cl route add default via 10.77.0.1
ip -n wan addr add 45.0.0.2/24 dev vw1; ip -n wan link set vw1 up; ip -n wan link set lo up
ip -n wan route add default via 45.0.0.1
sysctl -qw net.ipv4.ip_forward=1
mkdir -p /tmp/www; echo hello > /tmp/www/index.html
ip netns exec wan uhttpd -f -p 45.0.0.2:80 -h /tmp/www >/dev/null 2>&1 &

direct() { ip netns exec cl ping -c1 -W1 45.0.0.2 >/dev/null 2>&1; }
tunnel() { [ "$(ip netns exec cl curl -s -m 5 http://45.0.0.2/)" = hello ]; }
blocked() { # what
	if direct; then echo "FAIL: client reaches the internet directly ($1)"; exit 1; fi
	echo "OK: client blocked ($1)"
}
no_tproxy() { # what
	nft list table inet xvpn 2>/dev/null | grep -q 'reject with icmpx' || { echo "FAIL: no guard table ($1)"; exit 1; }
	nft list table inet xvpn | grep -q tproxy && { echo "FAIL: full rules instead of the guard ($1)"; exit 1; }
	return 0
}
fw() { ubus call luci.xvpn firewall | jsonfilter -e "$1"; }
want_mode() { # want mode
	[ "$(fw @.want)" = "$1" ] && [ "$(fw @.mode)" = "$2" ] || { echo "FAIL: firewall want/mode: $(ubus call luci.xvpn firewall)"; exit 1; }
}
full_rules() { # what
	nft list table inet xvpn 2>/dev/null | grep -q tproxy || { echo "FAIL: no full rules ($1)"; exit 1; }
}
# nft that rejects tproxy (kernel without nft_tproxy) and, with /tmp/nft-no-bridge, the bridge family
break_nft() {
	mv /usr/sbin/nft /usr/sbin/nft.real
	cat > /usr/sbin/nft <<'SH'
#!/bin/sh
if [ "$1" = -f ]; then
	grep -q tproxy "$2" && { echo "Error: Could not process rule: No such file or directory" >&2; exit 1; }
	[ -f /tmp/nft-no-bridge ] && grep -q 'table bridge' "$2" && { echo "Error: Could not process rule: Operation not supported" >&2; exit 1; }
fi
exec /usr/sbin/nft.real "$@"
SH
	chmod +x /usr/sbin/nft
}
direct || { echo "FAIL: test network: client cannot reach wan without xvpn"; exit 1; }
echo "OK: test network, client goes direct without xvpn"

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
add_list xvpn.access.port=vc0
set xvpn.health.interval=3
set xvpn.health.timeout=4
set xvpn.health.fail_threshold=2
add_list xvpn.manual.link='$(link 18444 second)'
add_list xvpn.manual.link='$(link 18443 first)'
commit xvpn
UCI

# boot: the guard (START=18) runs before network and xvpn
[ -L /etc/rc.d/S18xvpn-guard ] || { echo "FAIL: xvpn-guard is not enabled"; exit 1; }
/etc/init.d/xvpn-guard boot
no_tproxy "boot guard"
blocked "boot, xvpn not started"

/etc/init.d/xvpn start
sleep 2
wait_for @.state connected 40
[ "$(active_name)" = first ] || { echo "FAIL: expected first, got $(active_name)"; exit 1; }
echo "OK: picked the live server"
full_rules "connected"
ip rule | grep -q 'lookup 100' || { echo "FAIL: no ip rule"; exit 1; }
want_mode full full
echo "OK: full rules, ip rule, luci.xvpn firewall"
tunnel || { echo "FAIL: client gets no internet through the tunnel"; exit 1; }
echo "OK: client goes through the tunnel"
blocked "connected, ICMP is not tunneled"
/etc/init.d/xvpn-guard start
full_rules "xvpn-guard start"
echo "OK: xvpn-guard start keeps the full rules"

# restart: the client must not get a single packet through directly
( while [ ! -f /tmp/stop-probe ]; do direct && echo leak >> /tmp/leaks; done ) &
/etc/init.d/xvpn restart
sleep 1
wait_for @.state connected 40
touch /tmp/stop-probe; sleep 2
[ -s /tmp/leaks ] && { echo "FAIL: $(wc -l < /tmp/leaks) direct pings during restart"; exit 1; }
echo "OK: no direct traffic during restart"
tunnel || { echo "FAIL: no tunnel after restart"; exit 1; }
echo "OK: tunnel is back after restart"

# fw4 flush (service firewall stop/restart) deletes all tables: the include puts them back
/etc/init.d/firewall restart
full_rules "after firewall restart"
/etc/init.d/firewall stop; /etc/init.d/firewall start
full_rules "after firewall stop + start"
tunnel || { echo "FAIL: no tunnel after firewall stop + start"; exit 1; }
echo "OK: rules restored after fw4 flush"

# fw-* run one at a time: fw-remove waits for the lock
ucode -l fs -e 'let f = fs.open("/var/lock/xvpn-fw", "w"); f.lock("x"); system("sleep 3");' &
sleep 1
ucode /usr/share/xvpn/cli.uc fw-remove & R=$!
sleep 1
full_rules "fw-remove while the lock is held"
wait $R
nft list table inet xvpn >/dev/null 2>&1 && { echo "FAIL: fw-remove did not run after the lock"; exit 1; }
echo "OK: fw-remove waited for the lock"
ucode /usr/share/xvpn/cli.uc fw-apply
full_rules "fw-apply after the lock test"

# fw-apply fails (kernel without nft_tproxy): fail closed and status "error".
# Start from passthrough (clients go direct) so that only the fallback in cli.uc can block them.
ucode /usr/share/xvpn/cli.uc fw-apply passthrough
direct || { echo "FAIL: passthrough does not let the client out"; exit 1; }
break_nft
/etc/init.d/xvpn reload
wait_for @.state error 20
status @.last_error | grep -q 'No such file' || { echo "FAIL: status has no nft error: $(status @.last_error)"; exit 1; }
want_mode full block
fw @.error | grep -q 'No such file' || { echo "FAIL: luci.xvpn firewall has no error"; exit 1; }
no_tproxy "broken fw-apply"
blocked "broken fw-apply"
ucode /usr/share/xvpn/cli.uc fw-refresh || true
want_mode full block
[ "$(status @.state)" = error ] || { echo "FAIL: fw-refresh cleared the error"; exit 1; }
blocked "fw-refresh with broken nft"
echo "OK: fw-refresh keeps the error"

# block is rejected too (no bridge support): minimal inet table for the VPN networks
touch /tmp/nft-no-bridge
ucode /usr/share/xvpn/cli.uc fw-refresh || true
want_mode full minimal
nft list table inet xvpn | grep -q 'iifname @nets reject' || { echo "FAIL: no minimal table"; exit 1; }
nft list set inet xvpn nets | grep -q br-lan || { echo "FAIL: minimal table without the networks"; exit 1; }
echo "OK: minimal fallback when block is rejected"
rm /tmp/nft-no-bridge
mv /usr/sbin/nft.real /usr/sbin/nft
/etc/init.d/xvpn reload
sleep 1
wait_for @.state connected 40
want_mode full full
[ -z "$(fw @.error)" ] || { echo "FAIL: error left after a successful fw-apply"; exit 1; }
echo "OK: error cleared after a successful fw-apply"

# failover: kill the active remote, start the other one
kill $(cat /tmp/remote-18443.pid); remote 18444
sleep 8
wait_for @.state connected 60
[ "$(active_name)" = second ] || { echo "FAIL: failover expected second, got $(active_name)"; exit 1; }
echo "OK: failover to the other server"
logread | grep xvpn | grep -E 'switching|state' | tail -5

# subscription over http (curl reports file:// as HTTP 0), busybox has no base64
{ link 18446 sub-a; link 18445 sub-b; } | ucode -l fs -e 'print(b64enc(fs.stdin.read("all")))' > /www/sub.b64
uci batch <<UCI
set xvpn.s1=subscription
set xvpn.s1.name=test
set xvpn.s1.url=http://127.0.0.1/sub.b64
set xvpn.s1.via_tunnel=0
commit xvpn
UCI
ucode /usr/share/xvpn/cli.uc update s1 || true
[ "$(jsonfilter -i /etc/xvpn/subs/s1.json -e '@.servers[*].name' | wc -l)" = 2 ] || { echo "FAIL: subscription not parsed"; exit 1; }
echo "OK: subscription parsed"
/etc/init.d/xvpn reload
sleep 3
# the daemon re-reads the index after an outside reload only with issue #3 fixed: check the index
[ "$(jsonfilter -i /var/etc/xvpn/index.json -e '@.servers[*].name' | wc -l)" = 4 ] || { echo "FAIL: expected 4 servers in the index after reload"; exit 1; }
echo "OK: 4 servers in the index after reload"

/etc/init.d/xvpn stop
no_tproxy "stop with the service enabled"
blocked "stopped, service enabled"

uci set xvpn.main.enabled=0; uci commit xvpn
/etc/init.d/xvpn stop
nft list table inet xvpn >/dev/null 2>&1 && { echo "FAIL: table left after stop with enabled=0"; exit 1; }
direct || { echo "FAIL: client is still blocked with the service turned off"; exit 1; }
echo "OK: rules removed when the service is turned off"

# package removal: default_prerm disables, then stops
uci set xvpn.main.enabled=1; uci commit xvpn
/etc/init.d/xvpn start; sleep 2
/etc/init.d/xvpn disable; /etc/init.d/xvpn stop
nft list table inet xvpn >/dev/null 2>&1 && { echo "FAIL: table left after disable + stop"; exit 1; }
echo "OK: rules removed on package removal"
IN
