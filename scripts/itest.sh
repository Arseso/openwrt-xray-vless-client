#!/bin/sh
# Integration test: runs the service under procd in an OpenWrt container with two
# local VLESS "remote" servers, checks server selection, failover, subscription update and
# that a VPN client (network namespace behind a bridge port) never reaches the "internet"
# (another namespace) directly: boot guard, restart, stop, broken fw-apply, fw4 flush;
# fixed SSID names in /etc/config/wireless, fail closed for an SSID without a name;
# subscription update from LuCI through the daemon and by a reload past it; a hung xray
# and a broken xray_bin are xray_down, not dead servers; a hung reload (sleep in init.d,
# procd lock held) does not stop the health checks, a slow generate is not killed and a
# killed one leaves the running config; before NTP sets the clock no server goes to quarantine;
# the status tab and a reload of the same servers start no xray; a test port taken by another
# program is skipped, a main one is an error, xray starts with IPv6 off; split tunneling:
# listed addresses go around xray, listed domains out of xray directly, the Russian list.
set -e
cd "$(dirname "$0")/.."
DOCKER="${DOCKER:-docker}"
IMAGE="${IMAGE:-openwrt/rootfs:x86-64-24.10.4}"
# unique per checkout: parallel runs from other worktrees must not remove this container
NAME=${NAME:-xvpn-itest-$(printf %s "$PWD" | cksum | cut -d' ' -f1)}

$DOCKER rm -f $NAME >/dev/null 2>&1 || true
# without S11sysctl: in a privileged container it would write the host's kernel.* sysctls
$DOCKER run -d --name $NAME --privileged -v "$PWD:/src:ro" "$IMAGE" \
	sh -c 'rm -f /etc/rc.d/S11sysctl; exec /sbin/init' >/dev/null
trap '$DOCKER rm -f $NAME >/dev/null' EXIT
sleep 5

NET=$($DOCKER inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}/{{.IPPrefixLen}} {{.Gateway}}{{end}}' $NAME)

$DOCKER exec -i -e NET="$NET" $NAME sh -e <<'IN'
UUID=11111111-2222-3333-4444-555555555555
mkdir -p /var/lock
# every ubus call is bounded: a hung procd or xvpnd ends in TIMEOUT with diag below
# instead of 30 s per call; the calls that timed out go to /tmp/ubus-timeouts
ubus() {
	_rc=0; command ubus -t 5 "$@" || _rc=$?
	[ $_rc != 249 ] || echo "$(date +%T) ubus timeout: $*" | tee -a /tmp/ubus-timeouts >&2	# -UBUS_STATUS_TIMEOUT
	return $_rc
}
diag() {
	echo "--- xvpn status"; command ubus -t 3 call xvpn status || echo "(rc=$?)"
	echo "--- service list"; command ubus -t 3 call service list '{"name":"xvpn"}' || echo "(rc=$?)"
	[ ! -s /tmp/ubus-timeouts ] || { echo "--- ubus timeouts"; cat /tmp/ubus-timeouts; }
	echo "--- logread"; logread | grep -E 'xvpn|xray|procd' | grep -v 'daemon.info xray' | tail -30
	# a runtime error of xvpnd: procd logs its stderr under the binary name
	echo "--- ucode"; logread | grep 'ucode\[' | tail -20
}
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
# DNS for wan: the host's resolvers, but not one in the router's own LAN (a home router at
# 192.168.1.1 as the host's DNS: dnsmasq would ask itself and refuse), 1.1.1.1 as the fallback
for ns in $(awk '/^nameserver/ { print $2 }' /etc/resolv.conf) 1.1.1.1; do
	case $ns in 192.168.1.*|127.*|*:*) continue ;; esac
	uci add_list network.wan.dns=$ns
done
uci commit network
/etc/init.d/network restart
sleep 3
# downloads.openwrt.org may fail right after the network restart or on a busy host
# (wget returned 4): opkg update and install are tried again
for i in 1 2 3 4 5; do opkg update >/dev/null && break; sleep 5; done
for i in 1 2 3 4 5; do opkg install ucode-mod-uloop xray-core curl ip-full >/dev/null && break; sleep 5; done
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
# health.url2 (#61) by domain on its own address: the remotes resolve it, a whitelisting one
# drops it, a DROP of 45.0.0.3 in wan stands for its CDN down
ip -n wan addr add 45.0.0.3/24 dev vw1
ip netns exec wan uhttpd -f -p 45.0.0.3:80 -h /tmp/www >/dev/null 2>&1 &
echo '45.0.0.3 check2.test' >> /etc/hosts

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
uci_is() { # option value
	[ "$(uci -q get $1)" = "$2" ] || { echo "FAIL: $1 is '$(uci -q get $1)', expected '$2'"; exit 1; }
}
in_set() { nft list set $1 xvpn $2 2>/dev/null | grep -q "\"$3\""; }
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

remote() { # port [freedom settings] [domain it drops: a whitelist without it]
	_fr=${2:-}; [ -n "$_fr" ] || _fr='{}'
	_drop=${3:+'"routing": { "rules": [ { "domain": [ "full:'$3'" ], "outboundTag": "drop" } ] },'}
	cat > /tmp/remote-$1.json <<JSON
{ "inbounds": [ { "listen": "127.0.0.1", "port": $1, "protocol": "vless",
    "settings": { "clients": [ { "id": "$UUID" } ], "decryption": "none" } } ], $_drop
  "outbounds": [ { "protocol": "freedom", "settings": $_fr }, { "protocol": "blackhole", "tag": "drop" } ] }
JSON
	xray run -c /tmp/remote-$1.json >/dev/null 2>&1 &
	echo $! > /tmp/remote-$1.pid
}
link() { echo "vless://$UUID@127.0.0.1:$1?type=tcp&security=none#$2"; }
status() { ubus call xvpn status | jsonfilter -e "$1"; }
wait_for() { # expr value timeout
	_end=$(($(date +%s) + $3))
	while [ $(date +%s) -lt $_end ]; do [ "$(status "$1" 2>/dev/null)" = "$2" ] && return 0; sleep 1; done
	echo "TIMEOUT waiting for $1 == $2 ($3 s)"; diag; exit 1
}
active_name() { ubus call xvpn status | jsonfilter -e "@.servers[@.id='$(status @.active)'].name"; }
active_is() { [ "$(active_name)" = "$1" ]; }
latency() { ubus call xvpn status | jsonfilter -e "@.servers[@.name='$1'].latency"; }
count_is() { [ "$(ubus call xvpn status | jsonfilter -e '@.servers[*].name' | wc -l)" = "$1" ]; }
xvpnd_pid() { ubus call service list '{"name":"xvpn"}' | jsonfilter -e '@.xvpn.instances.xvpnd.pid'; }
xvpnd_restarted() { p=$(xvpnd_pid); [ -n "$p" ] && [ "$p" != "$1" ] && ubus call xvpn status >/dev/null; }
xray_pid() { ubus call service list '{"name":"xvpn"}' | jsonfilter -e '@.xvpn.instances.xray.pid'; }
xray_restarted() { p=$(xray_pid); [ -n "$p" ] && [ "$p" != "$1" ]; }
wait_cmd() { # timeout cmd...
	_end=$(($(date +%s) + $1)); shift
	while [ $(date +%s) -lt $_end ]; do "$@" >/dev/null 2>&1 && return 0; sleep 1; done
	echo "TIMEOUT waiting for: $*"; diag; exit 1
}
# a test of all servers; waits for this very run to finish, testing=false may still be
# the moment before it starts or the end of another run
tests_done() { [ "$(status @.tests)" -ge "$1" ]; }
test_all() {
	_run=$(ubus call xvpn test | jsonfilter -e @.run)
	[ -n "$_run" ] || { echo "FAIL: ubus call xvpn test started no test"; diag; exit 1; }
	wait_cmd 30 tests_done "$_run"
}


remote 18443
uci batch <<UCI
set xvpn.main.enabled=1
add_list xvpn.access.network=lan
add_list xvpn.access.port=vc0
set xvpn.health.interval=3
set xvpn.health.url=http://45.0.0.2/
set xvpn.health.url2=http://check2.test/
set xvpn.health.url2_cdn=1
set xvpn.health.timeout=4
set xvpn.health.fail_threshold=2
set xvpn.health.reload_idle=15
set xvpn.health.reload_retry=5
set xvpn.health.retry_max=12
add_list xvpn.manual.link='$(link 18444 second)'
add_list xvpn.manual.link='$(link 18443 first)'
commit xvpn
UCI

# boot: the guard (START=18) runs before network and xvpn
[ -L /etc/rc.d/S18xvpn-guard ] || { echo "FAIL: xvpn-guard is not enabled"; exit 1; }
/etc/init.d/xvpn-guard boot
no_tproxy "boot guard"
blocked "boot, xvpn not started"

# another program holds the first test port (busybox nc cannot listen, uhttpd stands for it):
# generate skips it, "second" gets 20001 and "first" 20002
uhttpd -f -p 127.0.0.1:20000 -h /tmp/www >/dev/null 2>&1 & holder=$!
/etc/init.d/xvpn start
sleep 2
wait_for @.state connected 40
[ "$(active_name)" = first ] || { echo "FAIL: expected first, got $(active_name)"; exit 1; }
echo "OK: picked the live server"
[ "$(jsonfilter -i /var/etc/xvpn/index.json -e '@.servers[*].test_port' | tr '\n' ' ')" = "20001 20002 " ] \
	|| { echo "FAIL: test ports with 20000 taken: $(cat /var/etc/xvpn/index.json)"; exit 1; }
[ "$(latency first)" -ge 0 ] || { echo "FAIL: first is not measured on its shifted port"; ubus call xvpn status; exit 1; }
echo "OK: a taken test port is skipped, xray runs, the server works on 20002"
kill $holder
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

# a main port taken by another program: generate keeps the running config (xray is not
# restarted), the status shows which port until it is free, the daemon tries again
uhttpd -f -p 0.0.0.0:10854 -h /tmp/www >/dev/null 2>&1 & holder=$!
x=$(xray_pid)
uci set xvpn.main.dns_port=10854; uci commit xvpn
/etc/init.d/xvpn reload
wait_for @.state error 30
status @.last_error | grep -q 'dns_port 10854' || { echo "FAIL: no port error: $(status @.last_error)"; exit 1; }
[ "$(xray_pid)" = "$x" ] && grep -q '"port": 10853' /var/etc/xvpn/config.json || { echo "FAIL: running config replaced"; exit 1; }
echo "OK: a taken main port is an error in the status, xray goes on with its config"
# the rules follow the running config: DNS of the clients goes to xray, not to the holder
nft list table inet xvpn | grep -q 'redirect to :10853' || { echo "FAIL: DNS not redirected to the running xray"; nft list table inet xvpn; exit 1; }
[ "$(ip netns exec cl curl -s -m 3 http://45.0.0.2:53/)" = hello ] && { echo "FAIL: client DNS goes to the program on the new port"; exit 1; }
tunnel || { echo "FAIL: no tunnel while the port is taken"; exit 1; }
echo "OK: while the port is taken, clients and their DNS go through the running xray"
kill $holder
wait_for @.state connected 40
grep -q '"port": 10854' /var/etc/xvpn/config.json || { echo "FAIL: dns_port not applied once free"; exit 1; }
echo "OK: the port applied once free"
uci set xvpn.main.dns_port=10853; uci commit xvpn
/etc/init.d/xvpn reload
wait_for @.state connected 40

# the same at boot: no config yet (tmpfs), xray does not start, the clients are blocked
# instead of their DNS going to the holder; the daemon tries again until the port is free
/etc/init.d/xvpn stop
rm -f /var/etc/xvpn/config.json /var/etc/xvpn/index.json
uhttpd -f -p 0.0.0.0:10853 -h /tmp/www >/dev/null 2>&1 & holder=$!
/etc/init.d/xvpn start
wait_for @.state error 30
status @.last_error | grep -q 'dns_port 10853' || { echo "FAIL: no port error at boot: $(status @.last_error)"; exit 1; }
want_mode full block
nft list table inet xvpn | grep -q redirect && { echo "FAIL: DNS redirected without xray"; exit 1; }
[ "$(ip netns exec cl curl -s -m 3 http://45.0.0.2:53/)" = hello ] && { echo "FAIL: client DNS goes to the holder at boot"; exit 1; }
blocked "port taken at boot"
kill $holder
wait_for @.state connected 60
full_rules "port free after boot"
tunnel || { echo "FAIL: no tunnel once the port is free after boot"; exit 1; }
echo "OK: a port taken at boot blocks the clients until it is free"

# IPv6 off on the router (disable_ipv6, the container's own netns): nothing to tunnel,
# xray listens on 0.0.0.0; ipv6 = tunnel is a config error then, IPv4 still goes through
sysctl -qw net.ipv6.conf.all.disable_ipv6=1
/etc/init.d/xvpn reload
sleep 2
wait_for @.state connected 40
[ "$(jsonfilter -i /var/etc/xvpn/config.json -e '@.inbounds[@.tag="tproxy"].listen')" = 0.0.0.0 ] \
	|| { echo "FAIL: tproxy does not listen on 0.0.0.0 without IPv6"; exit 1; }
tunnel || { echo "FAIL: no tunnel with IPv6 off"; diag; exit 1; }
echo "OK: IPv6 off: xray on 0.0.0.0, client goes through the tunnel"
uci set xvpn.access.ipv6=tunnel; uci commit xvpn
/etc/init.d/xvpn reload
wait_for @.state error 30
status @.last_error | grep -q 'IPv6 is off' || { echo "FAIL: no config error: $(status @.last_error)"; exit 1; }
full_rules "ipv6 tunnel without IPv6"
nft list table inet xvpn | grep -q 'tproxy ip6' && { echo "FAIL: tproxy ip6 without IPv6"; exit 1; }
tunnel || { echo "FAIL: no tunnel with ipv6 tunnel and IPv6 off"; exit 1; }
echo "OK: ipv6 tunnel without IPv6 is an error in the status, IPv4 still tunneled"
uci set xvpn.access.ipv6=block; uci commit xvpn
sysctl -qw net.ipv6.conf.all.disable_ipv6=0
/etc/init.d/xvpn reload
wait_for @.state connected 40
[ "$(jsonfilter -i /var/etc/xvpn/config.json -e '@.inbounds[@.tag="tproxy"].listen')" = :: ] \
	|| { echo "FAIL: tproxy not back on :: with IPv6 on"; cat /proc/net/if_inet6; exit 1; }
echo "OK: back on :: once IPv6 is on"

# split tunneling (#67): a CGI on 45.0.0.4 and 45.0.0.5 answers with the address the request
# came from: 10.77.0.2 — the router forwarded the client (direct), 45.0.0.1 — xray (tunnel)
mkdir -p /tmp/www/cgi-bin
printf '#!/bin/sh\nprintf "Content-Type: text/plain\\r\\n\\r\\n%%s\\n" "$REMOTE_ADDR"\n' > /tmp/www/cgi-bin/ip
chmod +x /tmp/www/cgi-bin/ip
ip -n wan addr add 45.0.0.4/24 dev vw1; ip -n wan addr add 45.0.0.5/24 dev vw1
ip netns exec wan uhttpd -f -p 45.0.0.4:80 -p 45.0.0.5:80 -h /tmp/www -x /cgi-bin >/dev/null 2>&1 &
echo '45.0.0.5 direct.test' >> /etc/hosts
from() { ip netns exec cl curl -s -m 5 "$@" 2>/dev/null || true; }
via() { # what url [curl args]: the request goes as what (direct | tunnel | none)
	_w=$1; shift; _a=$(from "$@")
	case "$_a" in 10.77.0.2) _g=direct ;; 45.0.0.1) _g=tunnel ;; *) _g=none ;; esac
	[ "$_g" = "$_w" ] || { echo "FAIL: $* went $_g ('$_a'), expected $_w"; nft list table inet xvpn | head -40; diag; exit 1; }
}
ping_ok() { ip netns exec cl ping -c1 -W1 "$1" >/dev/null 2>&1; }
in_direct() { nft list set inet xvpn direct4 2>/dev/null | grep -q "$1"; }
sleep 1
via tunnel http://45.0.0.4/cgi-bin/ip
# the active remote drops direct.test (a whitelist without it): it opens only around the tunnel
active_is first || { echo "FAIL: split tests expect first active, got $(active_name)"; exit 1; }
kill $(cat /tmp/remote-18443.pid); sleep 1; remote 18443 '' direct.test
wait_for @.state connected 40
via none http://45.0.0.5/cgi-bin/ip -H 'Host: direct.test'
uci batch <<UCI
add_list xvpn.split.ip=45.0.0.4
add_list xvpn.split.ip=not-an-address
add_list xvpn.split.domain=direct.test
commit xvpn
UCI
/etc/init.d/xvpn reload
sleep 2
wait_for @.state connected 40
in_direct 45.0.0.4 || { echo "FAIL: 45.0.0.4 not in direct4"; nft list table inet xvpn; exit 1; }
via direct http://45.0.0.4/cgi-bin/ip
ping_ok 45.0.0.4 || { echo "FAIL: kill switch blocks an address of the direct list"; exit 1; }
via tunnel http://45.0.0.5/cgi-bin/ip
blocked "split on, an address out of the list"
echo "OK: split: the listed address goes around xray (ICMP too), the rest through the tunnel"
via tunnel http://45.0.0.5/cgi-bin/ip -H 'Host: direct.test'
# the freedom outbound connects from the router: the remote never sees direct.test
[ "$(from http://45.0.0.5/ -H 'Host: direct.test')" = hello ] || { echo "FAIL: direct.test is not sent out directly"; diag; exit 1; }
[ "$(from http://45.0.0.2/ -H 'Host: other.test')" = hello ] || { echo "FAIL: other domains broke"; exit 1; }
echo "OK: split: a listed domain goes out directly through xray (freedom), the remote dropping it is not asked"
logread | grep -q '"not-an-address" is not an IP address' || { echo "FAIL: bad entry not logged"; exit 1; }
# flow offload (fw4 flowtable) on: the direct connections still work, the tunnel too
if uci set firewall.@defaults[0].flow_offloading=1 && uci commit firewall && /etc/init.d/firewall restart >/dev/null 2>&1 \
	&& nft list flowtables 2>/dev/null | grep -q flowtable; then
	full_rules "flow offloading on"
	via direct http://45.0.0.4/cgi-bin/ip; via tunnel http://45.0.0.5/cgi-bin/ip
	echo "OK: split with flow offloading: direct and tunnel work"
else
	echo "SKIP: no flowtable in this kernel"
fi
uci -q delete firewall.@defaults[0].flow_offloading || true; uci commit firewall; /etc/init.d/firewall restart >/dev/null 2>&1
full_rules "flow offloading off"
# kill switch: stopped (guard, block) the direct list is closed too
/etc/init.d/xvpn stop
no_tproxy "split, stopped"
ping_ok 45.0.0.4 && { echo "FAIL: direct list open while stopped"; exit 1; }
via none http://45.0.0.4/cgi-bin/ip
nft list table inet xvpn | grep -q direct && { echo "FAIL: lists in the guard table"; exit 1; }
echo "OK: split: stopped (kill switch) the direct list is blocked too"
/etc/init.d/xvpn start
sleep 2
wait_for @.state connected 40
# the Russian list: downloaded (here from 45.0.0.2 through the tunnel), cached on the flash,
# applied to the rules without a restart of xray
echo '45.0.0.5/32 # x' > /tmp/www/ru.zone
uci batch <<UCI
set xvpn.split.ru=1
add_list xvpn.split.ru_url=http://45.0.0.2/ru.zone
commit xvpn
UCI
/etc/init.d/xvpn reload
sleep 2
wait_for @.state connected 40
x=$(xray_pid)
r=$(ubus call luci.xvpn split_update)
echo "$r" | grep -Eq '"ok": true|busy' || { echo "FAIL: split_update: $r"; exit 1; }
wait_cmd 30 in_direct 45.0.0.5
grep -qx 45.0.0.5 /etc/xvpn/lists/ru.txt || { echo "FAIL: list not cached: $(cat /etc/xvpn/lists/ru.txt)"; exit 1; }
[ "$(ubus call luci.xvpn split | jsonfilter -e @.cached.v4)" = 1 ] || { echo "FAIL: luci.xvpn split: $(ubus call luci.xvpn split)"; exit 1; }
[ "$(xray_pid)" = "$x" ] || { echo "FAIL: the list restarted xray"; exit 1; }
via direct http://45.0.0.5/cgi-bin/ip
in_direct 45.0.0.4 || { echo "FAIL: own list lost beside the Russian one"; exit 1; }
echo "OK: split: the Russian list is downloaded, cached and applied without restarting xray"
# a broken source keeps the cached list
echo '<html>error</html>' > /tmp/www/ru.zone
ubus call xvpn lists >/dev/null
wait_cmd 30 sh -c 'ubus call luci.xvpn split | grep -q "are not networks"'
in_direct 45.0.0.5 || { echo "FAIL: a failed download dropped the list"; exit 1; }
echo "OK: split: a failed download keeps the cached list"
uci batch <<UCI
set xvpn.split.ru=0
delete xvpn.split.ru_url
delete xvpn.split.ip
delete xvpn.split.domain
commit xvpn
UCI
/etc/init.d/xvpn reload
sleep 2
wait_for @.state connected 40
[ ! -e /etc/xvpn/lists/ru.txt ] || { echo "FAIL: cache of the list left on the flash"; exit 1; }
nft list table inet xvpn | grep -q '@direct' && { echo "FAIL: direct rules without lists"; exit 1; }
via tunnel http://45.0.0.4/cgi-bin/ip
echo "OK: split off: cache removed, all through the tunnel"
kill $(cat /tmp/remote-18443.pid); sleep 1; remote 18443
wait_for @.state connected 40

# fw4 flush (service firewall stop/restart) deletes all tables: the include puts them back
/etc/init.d/firewall restart
full_rules "after firewall restart"
/etc/init.d/firewall stop; /etc/init.d/firewall start
full_rules "after firewall stop + start"
tunnel || { echo "FAIL: no tunnel after firewall stop + start"; exit 1; }
echo "OK: rules restored after fw4 flush"

# SSIDs: fixed names in /etc/config/wireless; there is no radio in the container,
# so the names come from UCI alone, as on boot before Wi-Fi is up
cat > /etc/config/wireless <<'W'
config wifi-device 'radio0'
	option type 'mac80211'
	option path 'virtual/none'
	option band '5g'

config wifi-iface 'vpnap'
	option device 'radio0'
	option network 'lan'
	option mode 'ap'
	option ssid 'VPN'

config wifi-iface 'homeap'
	option device 'radio0'
	option network 'lan'
	option mode 'ap'
	option ssid 'Home'

config wifi-iface 'ownap'
	option device 'radio0'
	option network 'lan'
	option mode 'ap'
	option ssid 'Own'
	option ifname 'myvpn0'

config wifi-iface 'onlyap'
	option device 'radio0'
	option network 'wonly'
	option mode 'ap'
	option ssid 'Only'

config wifi-iface 'uplink'
	option device 'radio0'
	option network 'wonly'
	option mode 'sta'
	option ssid 'Upstream'
W
uci batch <<UCI
set network.wonly=interface
set network.wonly.proto=none
commit network
add_list xvpn.access.wifi=vpnap
add_list xvpn.access.wifi=ownap
add_list xvpn.access.network=wonly
commit xvpn
UCI
/etc/init.d/xvpn reload
sleep 1
wait_for @.state connected 40
uci_is wireless.vpnap.ifname xvpn-ap0
uci_is wireless.onlyap.ifname xvpn-ap1
uci_is wireless.ownap.ifname myvpn0
uci_is wireless.homeap.ifname ''
uci_is wireless.uplink.ifname ''
uci_is wireless.vpnap.xvpn_ifname 1
uci_is wireless.ownap.xvpn_ifname ''
# a bridged SSID is seen by the bridge table, a Wi-Fi only network (no bridge) by inet only
for d in xvpn-ap0 xvpn-ap1 myvpn0; do
	in_set inet nets $d && in_set bridge ports $d || { echo "FAIL: $d is not in the rules"; nft list ruleset; exit 1; }
done
echo "OK: VPN SSIDs got fixed names, the user's name is kept, all are in the rules"
tunnel || { echo "FAIL: no tunnel after fixing the SSID names"; exit 1; }
# the names changed: a background refresh waits until netifd reports them (no radio: timeout)
ps w | grep -q '[i]fnames-wait' || { echo "FAIL: no refresh after the names changed"; exit 1; }
wait_cmd 40 sh -c "! ps w | grep -q '[i]fnames-wait'"
want_mode full full

# a device that appears after the rules: the client's port renamed into the SSID names
rename_port() { # from to
	ip link set $1 down; ip link set $1 name $2; ip link set $2 up
}
rename_port vc0 xvpn-ap0
wait_cmd 10 tunnel
blocked "port renamed to the VPN SSID name"
rename_port xvpn-ap0 xvpn-ap0.sta1
wait_cmd 10 tunnel
blocked "WDS station of the VPN SSID"
# xvpn-ap1 is in the rules, xvpn-ap10 is not covered by its wildcard
rename_port xvpn-ap0.sta1 xvpn-ap10
wait_cmd 10 direct
echo "OK: xvpn-ap10 is not caught by xvpn-ap1.*"
rename_port xvpn-ap10 vc0
wait_cmd 10 tunnel
echo "OK: a device created after the rules is covered by its name, WDS/VLAN by the wildcard"

# the radio was reconfigured: hostapd renames the interfaces in place ("move") or creates them ("add")
for a in move add; do
	nft delete element inet xvpn nets '{ "xvpn-ap0" }'
	ACTION=$a DEVTYPE=wlan INTERFACE=xvpn-ap0 sh /etc/hotplug.d/net/50-xvpn
	wait_cmd 25 in_set inet nets xvpn-ap0
done
echo "OK: hotplug net refreshes the rules on add and move"

# an SSID without a usable name cannot be covered: everyone is blocked, status "error"
uci set wireless.ownap.ifname=a-very-long-name0; uci commit wireless
ucode /usr/share/xvpn/cli.uc fw-refresh && { echo "FAIL: fw-refresh ignores an unresolved SSID"; exit 1; }
want_mode full block
wait_for @.state error 10
fw @.error | grep -q '"ownap"' || { echo "FAIL: no error about the SSID: $(fw @.error)"; exit 1; }
blocked "SSID without a name"
# kill switch off and no live server: clients go direct anyway, the error stays visible
ucode /usr/share/xvpn/cli.uc fw-apply passthrough && { echo "FAIL: passthrough ignores an unresolved SSID"; exit 1; }
want_mode passthrough passthrough
fw @.error | grep -q '"ownap"' || { echo "FAIL: no error in passthrough: $(fw @.error)"; exit 1; }
direct || { echo "FAIL: passthrough with an unresolved SSID blocks the clients"; exit 1; }
# only tproxy needs the policy route: dropped outside full, back with full
ip rule | grep -q 'lookup 100' && { echo "FAIL: ip rule left in passthrough"; exit 1; }
echo "OK: passthrough with an unresolved SSID: clients direct, error shown"
# disabled, it has no clients: no error
uci set wireless.ownap.disabled=1; uci commit wireless
ucode /usr/share/xvpn/cli.uc fw-apply
want_mode full full
wait_for @.state connected 10
tunnel || { echo "FAIL: no tunnel after the SSID was disabled"; exit 1; }
uci set wireless.ownap.ifname=myvpn0; uci delete wireless.ownap.disabled; uci commit wireless
ucode /usr/share/xvpn/cli.uc fw-refresh
echo "OK: fail closed while an SSID has no name"

# a VPN network comes up (its device may be known only now): hotplug iface resolves again
nft delete element inet xvpn nets '{ "br-lan" }'
in_set inet nets br-lan && { echo "FAIL: test setup, br-lan still in the set"; exit 1; }
ifup lan
wait_cmd 20 in_set inet nets br-lan
echo "OK: rules refreshed when a VPN network came up"

# someone's uncommitted change to wireless: the names are not fixed, a warning instead
uci set wireless.homeap.ssid=Staged
uci add_list xvpn.access.wifi=homeap; uci commit xvpn
/etc/init.d/xvpn reload
wait_cmd 20 sh -c 'ubus -t 5 call luci.xvpn firewall | grep -q uncommitted'
uci_is wireless.homeap.ifname ''
grep -q Staged /etc/config/wireless && { echo "FAIL: someone's change was committed"; exit 1; }
uci revert wireless
uci del_list xvpn.access.wifi=homeap; uci commit xvpn
echo "OK: uncommitted wireless changes: warning, nothing committed"

# deselected: our name is removed, the user's one stays
uci del_list xvpn.access.wifi=vpnap; uci commit xvpn
/etc/init.d/xvpn reload
sleep 1
wait_for @.state connected 40
uci_is wireless.vpnap.ifname ''
uci_is wireless.ownap.ifname myvpn0
uci_is wireless.onlyap.ifname xvpn-ap1
uci_is wireless.vpnap.xvpn_ifname ''
in_set inet nets xvpn-ap0 && { echo "FAIL: deselected SSID is still in the rules"; exit 1; }
[ -z "$(fw @.warning)" ] || { echo "FAIL: warning left: $(fw @.warning)"; exit 1; }
echo "OK: deselected SSID got its name back"

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
ip rule | grep -q 'lookup 100' || { echo "FAIL: no ip rule after returning to full"; exit 1; }
echo "OK: error cleared after a successful fw-apply"

# boot with the clock not set (no RTC, NTP pending): the servers look dead, none goes to
# quarantine until sysntpd sets the clock (hotplug ntp), then the VPN comes up. The clock of
# the container cannot be changed: a stopped remote stands for a server that rejects the
# time. sysntpd is stopped meanwhile (with system.ntp in place the daemon waits), the hotplug
# event is sent by hand.
not_quarantined() { # what
	ubus call xvpn status | grep -q '"quarantined": true' && { echo "FAIL: quarantine while waiting for the time ($1)"; ubus call xvpn status; exit 1; }
	return 0
}
# /etc/config/system is put back byte for byte: reload_config below would reload log and sysntpd
cp /etc/config/system /tmp/system.orig
ntpd_was=$(pidof ntpd || true)
/etc/init.d/sysntpd stop
uci batch <<UCI
set system.ntp=timeserver
add_list system.ntp.server=127.0.0.1
commit system
set xvpn.health.time_wait=20
commit xvpn
UCI
kill $(cat /tmp/remote-18443.pid)
rm -f /var/run/xvpn/time_synced /var/run/xvpn/time_wait	# a boot
/etc/init.d/xvpn restart
wait_for @.state waiting_time 15
env -i ACTION=stratum stratum=16 /sbin/hotplug-call ntp
sleep 9	# 3 checks
[ "$(status @.state)" = waiting_time ] && [ "$(status @.passthrough)" = false ] || { echo "FAIL: waiting for the time"; ubus call xvpn status; exit 1; }
not_quarantined "kill switch"
[ "$(ubus call xvpn test | jsonfilter -e @.error)" = busy ] || { echo "FAIL: test while waiting for the time"; exit 1; }
blocked "waiting for the time, kill switch on"
remote 18443
env -i ACTION=stratum stratum=2 /sbin/hotplug-call ntp
[ -f /var/run/xvpn/time_synced ] || { echo "FAIL: hotplug ntp set no flag"; exit 1; }
wait_for @.state connected 10
logread | grep -q 'the clock is set by NTP' && active_is first || { echo "FAIL: after NTP sync"; ubus call xvpn status; exit 1; }
tunnel || { echo "FAIL: no tunnel after NTP sync"; exit 1; }
echo "OK: no quarantine before NTP sync, connected right after it"

# kill switch off: clients go direct while the active server does not answer; no sync in
# time_wait s: the daemon goes on with the clock as it is
uci set xvpn.access.killswitch=0; uci commit xvpn
kill $(cat /tmp/remote-18443.pid)
rm -f /var/run/xvpn/time_synced /var/run/xvpn/time_wait	# a boot
/etc/init.d/xvpn restart
wait_for @.state waiting_time 15
t0=$(date +%s)
wait_for @.passthrough true 15
direct || { echo "FAIL: no passthrough while waiting for the time, kill switch off"; exit 1; }
not_quarantined "kill switch off"
/etc/init.d/xvpn restart	# a restart (uci commit, respawn) does not start the wait over
wait_for @.state waiting_time 15
remote 18443
wait_cmd 30 sh -c "logread | grep -q 'no NTP sync in 20 s'"
[ $(($(date +%s) - t0)) -le 30 ] || { echo "FAIL: the restart started the wait over"; exit 1; }
wait_for @.state connected 15
wait_for @.passthrough false 10
active_is first && tunnel || { echo "FAIL: after the time wait ran out"; ubus call xvpn status; exit 1; }
echo "OK: passthrough while waiting for the time, going on after time_wait"
uci set xvpn.access.killswitch=1; uci delete xvpn.health.time_wait; uci commit xvpn
cp /tmp/system.orig /etc/config/system
touch /var/run/xvpn/time_synced	# the clock is right: no wait from here on
[ -z "$ntpd_was" ] || /etc/init.d/sysntpd start
/etc/init.d/xvpn restart
wait_for @.state connected 40

# failover: kill the active remote, start the other one
kill $(cat /tmp/remote-18443.pid); remote 18444
sleep 8
wait_for @.state connected 60
[ "$(active_name)" = second ] || { echo "FAIL: failover expected second, got $(active_name)"; exit 1; }
echo "OK: failover to the other server"
logread | grep xvpn | grep -E 'switching|state' | tail -5

# no live servers (#12): the test of all again after a pause, twice as long each time
# (interval 3 s, retry_max 12 s: 3, 6, 12 …), once a run, the pause in the status; a test
# by hand starts it over. Dead remotes answer at once (blackhole: HTTP 403), xray works.
# The active one is probed meanwhile: back, it is connected by that probe, before the next
# test and without a test run
dead() { # port: kept in /tmp/remote-$1.pid for slow() or a kill before remote()
	kill $(cat /tmp/remote-$1.pid) 2>/dev/null || true
	cat > /tmp/remote-$1.json <<JSON
{ "inbounds": [ { "listen": "127.0.0.1", "port": $1, "protocol": "vless",
    "settings": { "clients": [ { "id": "$UUID" } ], "decryption": "none" } } ],
  "outbounds": [ { "protocol": "blackhole", "settings": { "response": { "type": "http" } } } ] }
JSON
	xray run -c /tmp/remote-$1.json >/dev/null 2>&1 &
	echo $! > /tmp/remote-$1.pid
}
retry_is() { # delay: one call, during a test the state is failover and there is no retry
	_s=$(ubus call xvpn status); at=$(echo "$_s" | jsonfilter -e @.retry.at)
	[ "$(echo "$_s" | jsonfilter -e @.retry.delay)" = "$1" ] && [ "$at" -ge "$(date +%s)" ]
}
connected_to() { active_is "$1" && [ "$(status @.state)" = connected ]; }
tests_since() { echo $(($(status @.tests) - t0)); }
s0=$(date +%s)
dead 18443; dead 18444
wait_for @.state no_servers 30
t0=$(status @.tests)
wait_cmd 15 retry_is 6
[ "$(tests_since)" = 1 ] || { echo "FAIL: no live servers: $(tests_since) tests until the pause is 6 s"; diag; exit 1; }
test_all
wait_cmd 5 retry_is 3
wait_cmd 20 retry_is 12
# one doubling a run: 3 (by hand) → 6 → 12 is two more
[ "$(tests_since)" = 4 ] || { echo "FAIL: no live servers: $(tests_since) tests until the pause is 12 s again"; diag; exit 1; }
echo "OK: no live servers: the pause grows to retry_max, a test by hand starts it over"
n=$(status @.tests)
kill $(cat /tmp/remote-18444.pid)	# xray binds with reuseport: the blackhole would answer too
remote 18444
wait_cmd 12 connected_to second
[ $((at - $(date +%s))) -ge 3 ] && [ "$(status @.tests)" = "$n" ] && [ -z "$(status @.retry)" ] \
	|| { echo "FAIL: the active server back is not connected by the probe before the next test ($at, tests $n -> $(status @.tests))"; diag; exit 1; }
echo "OK: the active server back is connected before the next test ($(($(date +%s) - s0)) s for #12)"

# servers left out of auto selection (#60). "third" is the fastest: the remotes of the
# others pass requests on in 20-byte pieces 30 ms apart (freedom fragment), ~0.1 s each.
# auto_best with small rank_interval, hysteresis and quarantine for these steps
id_of() { status "@.servers[@.name='$1'].id"; }
auto_of() { status "@.servers[@.name='$1'].auto"; }
set_auto() { # id true|false
	r=$(ubus call luci.xvpn set_auto "{\"id\":\"$1\",\"auto\":$2}")
	[ "$(echo "$r" | jsonfilter -e @.ok)" = true ] || { echo "FAIL: set_auto $1 $2: $r"; exit 1; }
}
select_ok() { [ "$(ubus call xvpn select "{\"id\":\"$1\"}" | jsonfilter -e @.ok)" = true ]; }
# one call: the state and its reason (a dead active one goes through failover again and again)
no_candidates() { s=$(ubus call xvpn status); [ "$(echo "$s" | jsonfilter -e @.state)" = no_servers ] && echo "$s" | jsonfilter -e @.last_error | grep -q 'excluded'; }
not_third() { ! active_is third; }
port_of() { [ "$1" = first ] && echo 18443 || echo 18444; }
slow() { # port
	kill $(cat /tmp/remote-$1.pid) 2>/dev/null || true
	remote $1 '{ "fragment": { "packets": "1-1", "length": "20-20", "interval": "30-30" } }'
}
slow 18443; slow 18444; remote 18449
dp=$(xvpnd_pid)
uci batch <<UCI
add_list xvpn.manual.link='$(link 18449 third)'
set xvpn.health.auto_best=1
set xvpn.health.rank_interval=5
set xvpn.health.hysteresis=40
set xvpn.health.quarantine=5
commit xvpn
UCI
rm -f /var/run/xvpn/state.json	# quarantines left by earlier failovers
reload_config
wait_cmd 30 xvpnd_restarted "$dp"
wait_cmd 30 count_is 3
# auto_best: the daemon goes to the fastest by itself
wait_cmd 30 active_is third
wait_for @.state connected 30
[ "$(latency first)" -ge 60 ] && [ "$(latency second)" -ge 60 ] && [ "$(latency third)" -lt 40 ] && [ ! -e /etc/xvpn/active_manual ] \
	|| { echo "FAIL: slow remotes, third is not the fastest"; ubus call xvpn status; exit 1; }
id3=$(id_of third)
# the main case: the daemon chose it, the user leaves it out: another one at once, the
# daemon is not restarted for it
dp=$(xvpnd_pid)
set_auto "$id3" false
[ "$(uci -q get xvpn.health.no_auto)" = "$id3" ] && [ "$(auto_of third)" = false ] && [ "$(auto_of first)" = true ] \
	|| { echo "FAIL: set_auto: $(uci -q get xvpn.health.no_auto)"; ubus call xvpn status; exit 1; }
wait_cmd 30 not_third
wait_for @.state connected 30
[ "$(xvpnd_pid)" = "$dp" ] || { echo "FAIL: set_auto restarted xvpnd"; exit 1; }
echo "OK: left out while active: another server at once, xvpnd not restarted"
# failover with the faster third alive: the slower server in auto selection
a=$(active_name); o=first; [ "$a" = first ] && o=second
kill $(cat /tmp/remote-$(port_of $a).pid)
wait_cmd 30 active_is $o
wait_for @.state connected 30
echo "OK: failover goes to the slower server in auto selection, not to the faster one left out"
# the only live server is left out: no_servers with the reason, it is not chosen...
kill $(cat /tmp/remote-$(port_of $o).pid)
wait_cmd 30 no_candidates
not_third && [ "$(cat /etc/xvpn/active)" != "$id3" ] || { echo "FAIL: failover chose a server left out"; ubus call xvpn status; exit 1; }
echo "OK: failover does not choose a live server left out of auto selection"
# ...nor at start; the one in auto selection once it is back: a test by hand in no_servers
# chooses it at once (#12), not after the pause
s1=$(date +%s)
/etc/init.d/xvpn stop
rm /etc/xvpn/active
/etc/init.d/xvpn start
wait_cmd 30 no_candidates
sleep 4
[ "$(status @.state)" != connected ] && not_third && [ ! -e /etc/xvpn/active ] \
	|| { echo "FAIL: chosen at start while left out"; ubus call xvpn status; exit 1; }
slow 18443
wait_for @.testing false 10
ubus call xvpn test >/dev/null
wait_cmd 30 active_is first
wait_for @.state connected 30
echo "OK: start does not choose a server left out of auto selection, a test by hand takes the one back ($(($(date +%s) - s1)) s)"
# chosen by hand and left out: auto_best does not leave it for second, fast again; reload_config
# (apply in LuCI, /etc/config/xvpn changed by set_auto) restarts neither xray nor xvpnd;
# back in auto selection it is left. A daemon restart keeps the choice: see "back in the list"
second_fast() { l=$(latency second); [ -n "$l" ] && [ "$l" -ge 0 ] && [ "$l" -lt 40 ]; }
id1=$(id_of first)
wait_cmd 15 select_ok "$id1"	# the active one: the config stays, xray goes on
wait_for @.state connected 30
xp=$(xray_pid); dp=$(xvpnd_pid)
set_auto "$id1" false
reload_config
remote 18444
wait_cmd 20 second_fast	# measured by a rank...
wait_for @.testing false 10	# ...and its decision taken
[ "$(xray_pid)" = "$xp" ] && [ "$(xvpnd_pid)" = "$dp" ] || { echo "FAIL: set_auto or reload_config restarted xray ($xp -> $(xray_pid)) or xvpnd ($dp -> $(xvpnd_pid))"; diag; exit 1; }
active_is first && [ "$(status @.state)" = connected ] && [ "$(cat /etc/xvpn/active_manual)" = "$id1" ] \
	|| { echo "FAIL: auto_best left a server chosen by hand"; ubus call xvpn status; exit 1; }
echo "OK: chosen by hand out of auto selection it stays: auto_best, reload_config"
set_auto "$id1" true
wait_cmd 20 active_is second
echo "OK: auto_best leaves a server in auto selection for a faster one"
# chosen by hand, gone from the list for a while (here: the link, reload_config restarts the
# daemon), back: the daemon returns to it and stays on it out of auto selection; it keeps
# its flag meanwhile (prune waits)
wait_cmd 15 select_ok "$id3"
wait_for @.state connected 30
uci del_list xvpn.manual.link="$(link 18449 third)"; uci commit xvpn
reload_config
wait_cmd 30 count_is 2
wait_cmd 30 active_is second
[ "$(cat /etc/xvpn/active_manual)" = "$id3" ] && [ "$(uci -q get xvpn.health.no_auto)" = "$id3" ] \
	|| { echo "FAIL: the choice by hand or the flag was forgotten"; exit 1; }
uci add_list xvpn.manual.link="$(link 18449 third)"; uci commit xvpn
reload_config
wait_cmd 30 count_is 3
wait_cmd 30 active_is third
wait_for @.state connected 30
sleep 4
active_is third || { echo "FAIL: the server chosen by hand was left after the daemon restarted"; ubus call xvpn status; exit 1; }
echo "OK: back to the server chosen by hand once it is back in the list"
# it fails: the failover goes to a server in auto selection
kill $(cat /tmp/remote-18449.pid)
wait_cmd 30 active_is second
wait_for @.state connected 30
[ ! -e /etc/xvpn/active_manual ] || { echo "FAIL: the failover kept the manual mark"; exit 1; }
echo "OK: failover from a server left out of auto selection"
# back as before: first dead, second live and active, two servers, no test settings
set_auto "$id3" true
[ -z "$(uci -q get xvpn.health.no_auto)" ] && [ "$(auto_of third)" = true ] || { echo "FAIL: set_auto back"; ubus call xvpn status; exit 1; }
[ "$(ubus call luci.xvpn set_auto "{\"id\":\"nope\",\"auto\":false}" | jsonfilter -e @.error)" = 'unknown server' ] \
	|| { echo "FAIL: set_auto of an unknown id"; exit 1; }
kill $(cat /tmp/remote-18443.pid)
uci batch <<UCI
del_list xvpn.manual.link='$(link 18449 third)'
delete xvpn.health.auto_best
delete xvpn.health.rank_interval
delete xvpn.health.hysteresis
delete xvpn.health.quarantine
commit xvpn
UCI
reload_config
wait_cmd 30 count_is 2
wait_for @.state connected 30
active_is second || { echo "FAIL: not back on second"; ubus call xvpn status; exit 1; }
echo "OK: back in auto selection"

# #61: "limited" answers health.url and resets the connections to health.url2 (a whitelist,
# blackhole in its remote). It is the fastest (second is slow), yet the start does not
# choose it; the status says why. url2_cdn is 1: the first live server that fails url2
# makes the daemon ask url2 directly, it answers, so the verdicts go on
limited_of() { status "@.servers[@.name='$1'].limited"; }
slow 18444; remote 18450 '' check2.test
uci add_list xvpn.manual.link="$(link 18450 limited)"; uci commit xvpn
/etc/init.d/xvpn stop
rm -f /etc/xvpn/active /var/run/xvpn/state.json
/etc/init.d/xvpn start
wait_cmd 30 count_is 3
wait_cmd 30 tests_done 1	# the choice at start: its test, not a check of the first active one
wait_for @.state connected 40
[ "$(limited_of limited)" = true ] && [ "$(limited_of second)" = false ] && [ "$(status @.url2)" = http://check2.test/ ] \
	&& [ "$(latency limited)" -ge 0 ] && [ "$(latency limited)" -lt "$(latency second)" ] && [ "$(status "@.servers[@.name='limited'].quarantined")" = false ] \
	|| { echo "FAIL: limited is not marked"; ubus call xvpn status; exit 1; }
active_is second || { echo "FAIL: start chose $(active_name), not second"; ubus call xvpn status; exit 1; }
logread | grep -q '"limited" is limited: http://check2.test/ fails' || { echo "FAIL: no log line about limited"; exit 1; }
echo "OK: a server that fails health.url2 is limited, the start chooses a slower one, not quarantined"
# chosen by hand it stays: the checks go on with health.url, a test does not leave it
lid=$(id_of limited)
wait_cmd 15 select_ok "$lid"
wait_for @.state connected 30
wait_cmd 20 active_is limited
test_all	# its decision is taken as the run ends
active_is limited && [ "$(status @.state)" = connected ] || { echo "FAIL: limited chosen by hand was left"; ubus call xvpn status; exit 1; }
echo "OK: a limited server can be chosen by hand"
# the daemon's choice (as after an update that made it limited): a test leaves it
rm /etc/xvpn/active_manual
test_all
wait_cmd 20 active_is second
wait_for @.state connected 30
status @.last_switch.reason | grep -q 'is limited' || { echo "FAIL: switch reason: $(status @.last_switch.reason)"; exit 1; }
echo "OK: a test leaves a limited server the daemon chose"
# url2 times out through second and directly (its CDN down: DROP of 45.0.0.3 in wan):
# the marks stay as they were, no switch
ip netns exec wan nft -f - <<NFT
table inet dropcdn {
	chain input { type filter hook input priority 0; ip daddr 45.0.0.3 drop; }
}
NFT
test_all
[ "$(limited_of limited)" = true ] && [ "$(limited_of second)" = false ] && active_is second && [ "$(status @.state)" = connected ] \
	&& logread | grep -q 'and directly: its CDN is down' || { echo "FAIL: url2 CDN down"; ubus call xvpn status; exit 1; }
echo "OK: url2 down directly too: its CDN, the marks stay, no switch"
ip netns exec wan nft delete table inet dropcdn
# no live servers (#12 pause), then only the limited one comes back: chosen, connected, the
# reason in last_error, no retry
dead 18444; dead 18450
/etc/init.d/xvpn stop
rm -f /etc/xvpn/active /var/run/xvpn/state.json
/etc/init.d/xvpn start
wait_for @.state no_servers 30
kill $(cat /tmp/remote-18450.pid); remote 18450 '' check2.test
wait_cmd 30 connected_to limited
[ "$(limited_of limited)" = true ] && [ -z "$(status @.retry)" ] && status @.last_error | grep -q 'only limited servers answer' \
	|| { echo "FAIL: only the limited one back"; ubus call xvpn status; exit 1; }
echo "OK: after the pause with no live servers the only limited one is chosen, connected, the reason shown"
kill $(cat /tmp/remote-18450.pid) $(cat /tmp/remote-18444.pid); remote 18444
uci del_list xvpn.manual.link="$(link 18450 limited)"; uci commit xvpn
# not reload_config: its md5 of the configs dates from before the link was added, the same as now
/etc/init.d/xvpn reload
wait_cmd 30 count_is 2
wait_for @.state connected 30
active_is second || { echo "FAIL: not back on second"; ubus call xvpn status; exit 1; }

# subscription over http (curl reports file:// as HTTP 0), busybox has no base64
# LuCI: a new subscription; its servers go before the manual links, so every test
# port shifts (20000 was "second", now it is a dead server)
remote 18446
{ link 18445 sub-dead; link 18446 sub-live; } | ucode -l fs -e 'print(b64enc(fs.stdin.read("all")))' > /www/sub.b64
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

test_all
[ "$(latency sub-dead)" = -1 ] && [ "$(latency first)" = -1 ] \
	&& [ "$(latency sub-live)" -ge 0 ] && [ "$(latency second)" -ge 0 ] \
	|| { echo "FAIL: latencies are attributed to wrong servers"; ubus call xvpn status; logread | grep xvpn; exit 1; }
echo "OK: measurements match the new server list"

kill $(cat /tmp/remote-18444.pid)
sleep 6
wait_cmd 60 active_is sub-live
wait_for @.state connected 30
echo "OK: failover after the update went to the live sub-live"
tunnel || { echo "FAIL: no tunnel through sub-live"; exit 1; }
echo "OK: client goes through the tunnel after the update"

# memory (#7): the status tab starts no xray, stats reads the metrics section over HTTP;
# a reload with the same servers and binary runs no `xray run -test`
printf '#!/bin/sh\necho "$*" >> /tmp/xray-runs\nexec /usr/bin/xray "$@"\n' > /tmp/xray-count; chmod +x /tmp/xray-count
uci set xvpn.main.xray_bin=/tmp/xray-count; uci commit xvpn
/etc/init.d/xvpn reload
wait_for @.state connected 40
[ "$(grep -c -- '-test' /tmp/xray-runs)" = 1 ] || { echo "FAIL: another binary is not tested once: $(cat /tmp/xray-runs)"; exit 1; }
: > /tmp/xray-runs
/etc/init.d/xvpn reload
wait_for @.state connected 40
tunnel || { echo "FAIL: no tunnel with the counting xray"; exit 1; }
for i in 1 2 3; do s=$(ubus call luci.xvpn stats); ubus call luci.xvpn status >/dev/null; done
[ ! -s /tmp/xray-runs ] || { echo "FAIL: xray started by a reload or the status tab: $(cat /tmp/xray-runs)"; exit 1; }
[ "$(echo "$s" | jsonfilter -e "@.traffic['$(status @.active)'].down")" -gt 0 ] \
	|| { echo "FAIL: no traffic of the active server in stats: $s"; exit 1; }
echo "OK: stats from the metrics section, a reload of the same servers runs no xray -test"
# a GOMEMLIMIT Go cannot parse would stop xray at start: the default instead
uci set xvpn.main.gomemlimit=80MB; uci commit xvpn
/etc/init.d/xvpn reload
wait_for @.state connected 40
logread | grep -q "main.gomemlimit '80MB'" && tr '\0' '\n' < /proc/$(xray_pid)/environ | grep -qx GOMEMLIMIT=80MiB \
	|| { echo "FAIL: bad gomemlimit: $(tr '\0' ' ' < /proc/$(xray_pid)/environ)"; exit 1; }
echo "OK: a bad gomemlimit falls back to 80MiB"
uci delete xvpn.main.gomemlimit
uci set xvpn.main.xray_bin=/usr/bin/xray; uci commit xvpn
/etc/init.d/xvpn reload
wait_for @.state connected 40

# reload past the daemon (UCI triggers on wireless/network): ports shift again,
# sub-live moves from 20001 to 20002
{ link 18447 sub-x; link 18448 sub-y; link 18446 sub-live; } | ucode -l fs -e 'print(b64enc(fs.stdin.read("all")))' > /www/sub.b64
ucode /usr/share/xvpn/cli.uc update s1 >/dev/null
/etc/init.d/xvpn reload
wait_cmd 10 count_is 5
switch=$(status @.last_switch.at)
sleep 12
[ "$(status @.state)" = connected ] && [ "$(active_name)" = sub-live ] && [ "$(status @.last_switch.at)" = "$switch" ] \
	|| { echo "FAIL: external reload broke the state"; ubus call xvpn status; logread | grep xvpn | tail -10; exit 1; }
echo "OK: external reload picked up, still connected to sub-live"

# the subscription hands out another host (here: port) of some servers on every
# download (#49): the ids stay, an idle server's new address waits for the next reload
sub() { for l in "$@"; do link ${l%:*} ${l#*:}; done | ucode -l fs -e 'print(b64enc(fs.stdin.read("all")))' > /www/sub.b64; }
ids() { ubus call xvpn status | jsonfilter -e '@.servers[*].id' | tr '\n' ' '; }
update_s1() {
	r=$(ubus call luci.xvpn update '{"sid":"s1"}')
	[ "$(echo "$r" | jsonfilter -e @.ok)" = true ] || { echo "FAIL: luci.xvpn update: $r"; exit 1; }
	wait_for @.updating false 30
}
ids0=$(ids); xp=$(xray_pid)
sub 18452:sub-x 18448:sub-y 18446:sub-live
update_s1
sleep 3
[ -e /var/run/xvpn/stale ] && [ "$(ids)" = "$ids0" ] && [ "$(xray_pid)" = "$xp" ] \
	&& [ "$(active_name)" = sub-live ] && [ "$(status @.last_switch.at)" = "$switch" ] \
	|| { echo "FAIL: rotated host of an idle server"; ubus call xvpn status; ls /var/run/xvpn; exit 1; }
echo "OK: rotated host of an idle server: same ids, no reload"
remote 18451
sub 18452:sub-x 18448:sub-y 18451:sub-live
update_s1
wait_cmd 30 xray_restarted "$xp"
wait_for @.state connected 30
kill $(cat /tmp/remote-18446.pid)
[ "$(ids)" = "$ids0" ] && [ "$(active_name)" = sub-live ] && [ "$(status @.last_switch.at)" = "$switch" ] \
	&& [ ! -e /var/run/xvpn/stale ] && grep -q 18452 /var/etc/xvpn/config.json \
	|| { echo "FAIL: rotated host of the active server"; ubus call xvpn status; exit 1; }
tunnel || { echo "FAIL: no tunnel through the new address of sub-live"; exit 1; }
echo "OK: rotated host of the active server: reload, still on sub-live at its new address"
# the provider renames the active server: another id, the same connection keeps the choice
# (a reload, but the xray config has no names: procd keeps xray running)
sub 18452:sub-x 18448:sub-y 18451:sub-renamed
update_s1
wait_cmd 30 active_is sub-renamed
wait_for @.state connected 30
[ "$(active_name)" = sub-renamed ] && [ "$(status @.last_switch.at)" = "$switch" ] && [ "$(cat /etc/xvpn/active)" = "$(status @.active)" ] \
	|| { echo "FAIL: renamed active server"; ubus call xvpn status; cat /etc/xvpn/active; exit 1; }
echo "OK: renamed active server keeps the choice"

# one update at a time: a live updater holds the lock (a process named cli.uc stands for it)
sh -c 'sleep 30; :' cli.uc & fake=$!
ln -s $fake /var/run/xvpn/updating
[ "$(ubus call luci.xvpn update | jsonfilter -e @.error)" = busy ] || { echo "FAIL: no busy while updating"; exit 1; }
[ "$(ubus call luci.xvpn subscriptions | jsonfilter -e @.updating)" = true ] || { echo "FAIL: updating flag"; exit 1; }
kill $fake
# a lock left by a dead (or reused) pid does not block
[ "$(ubus call luci.xvpn subscriptions | jsonfilter -e @.updating)" = false ] || { echo "FAIL: stale lock counts"; exit 1; }
rm /var/run/xvpn/updating
ln -s 1 /var/run/xvpn/updating	# left behind, cli.uc update must take it over
[ "$(ubus call luci.xvpn subscriptions | jsonfilter -e @.updating)" = false ] || { echo "FAIL: reused pid counts"; exit 1; }
echo "OK: single update lock"

# a subscription added a moment ago (no daemon restart yet) is updated too
uci batch <<UCI
set xvpn.s2=subscription
set xvpn.s2.name=fresh
set xvpn.s2.url=http://127.0.0.1/sub.b64
set xvpn.s2.via_tunnel=0
commit xvpn
UCI
dp=$(xvpnd_pid)
r=$(ubus call luci.xvpn update '{"sid":"s2"}')
[ "$(echo "$r" | jsonfilter -e @.ok)" = true ] || { echo "FAIL: fresh subscription: $r"; exit 1; }
wait_cmd 20 test -s /etc/xvpn/subs/s2.json
[ ! -e /var/run/xvpn/updating ] || { echo "FAIL: lock left after update"; exit 1; }
# the new section changes XVPN_CONF: the next reload restarts xvpnd. Here, not in the middle
# of the next steps (xray_down: the restart of xray reloads the service)
/etc/init.d/xvpn reload
wait_cmd 30 xvpnd_restarted "$dp"
wait_for @.state connected 30
echo "OK: fresh subscription updated"

# xray hangs (killall -STOP xray, but the remotes are xray too): xray_down, no server
# is blamed, the daemon restarts xray
quarantined() { ubus call xvpn status | jsonfilter -e '@.servers[@.quarantined=true].name'; }
no_quarantine() { # what; earlier failovers left their quarantine, nothing new may be added
	for q in $(quarantined); do
		case " $q0 " in *" $q "*) ;; *) echo "FAIL: $q in quarantine ($1)"; ubus call xvpn status; exit 1;; esac
	done
	[ "$(status @.passthrough)" = false ] || { echo "FAIL: passthrough ($1)"; exit 1; }
}
a=$(active_name); n=$(ubus call xvpn status | jsonfilter -e '@.servers[*].name' | wc -l); q0=$(quarantined | tr '\n' ' ')
x=$(xray_pid); kill -STOP $x
wait_for @.state xray_down 30
[ "$(status @.last_error)" = 'xray is stopped' ] || { echo "FAIL: last_error: $(status @.last_error)"; exit 1; }
no_quarantine "xray stopped"
echo "OK: stopped xray is xray_down, no quarantine"
# a test with xray down does not mark the servers dead
test_all
[ "$(latency "$a")" -ge 0 ] || { echo "FAIL: test with xray down wrote -1"; ubus call xvpn status; logread | grep xvpn; exit 1; }
echo "OK: measurements kept while xray is down"
wait_cmd 40 xray_restarted "$x"
wait_for @.state connected 40
active_is "$a" && [ "$(status @.xray_restarts)" = 0 ] || { echo "FAIL: after the xray restart"; ubus call xvpn status; exit 1; }
logread | grep -q 'restarting xray (1/3)' || { echo "FAIL: no restart in the log"; exit 1; }
echo "OK: the daemon restarted the hung xray"

# broken xray_bin, kill switch off: xray_down with what xray says, no passthrough,
# a few restarts, then the daemon gives up
printf '#!/bin/sh\necho "xray: corrupted binary" >&2\nexit 1\n' > /tmp/xray-broken; chmod +x /tmp/xray-broken
uci set xvpn.main.xray_bin=/tmp/xray-broken; uci set xvpn.access.killswitch=0; uci commit xvpn
old=$(xvpnd_pid); reload_config
wait_cmd 30 xvpnd_restarted "$old"
wait_for @.state xray_down 40
status @.last_error | grep -q 'corrupted binary' || { echo "FAIL: last_error: $(status @.last_error)"; exit 1; }
count_is $n || { echo "FAIL: broken xray dropped the servers"; ubus call xvpn status; exit 1; }
no_quarantine "broken xray_bin"
wait_cmd 90 sh -c "ubus -t 5 call xvpn status | jsonfilter -e @.last_error | grep -q 'restarts did not help'"
[ "$(status @.state)" = xray_down ] && [ "$(status @.xray_restarts)" = 3 ] || { echo "FAIL: no give-up"; ubus call xvpn status; exit 1; }
no_quarantine "gave up on xray"
want_mode full full
# kill switch off lets ICMP out, TCP still goes to xray: no passthrough
tunnel && { echo "FAIL: client gets out with xray down"; exit 1; }
echo "OK: broken xray_bin is xray_down, 3 restarts, no passthrough"
# the binary is fixed in place, no UCI change: the daemon notices and tries again
old=$(xvpnd_pid)
printf '#!/bin/sh\nexec /usr/bin/xray "$@"\n' > /tmp/xray-broken
wait_for @.state connected 40
[ "$(xvpnd_pid)" = "$old" ] && active_is "$a" || { echo "FAIL: recovery after the binary fix"; ubus call xvpn status; exit 1; }
echo "OK: recovered from a fixed binary without restarting xvpnd"
uci set xvpn.main.xray_bin=/usr/bin/xray; uci set xvpn.access.killswitch=1; uci commit xvpn
old=$(xvpnd_pid); reload_config
wait_cmd 30 xvpnd_restarted "$old"
wait_for @.state connected 40
active_is "$a" || { echo "FAIL: expected $a after xray is fixed, got $(active_name)"; exit 1; }
echo "OK: connected again once xray_bin is fixed"

# a reload hangs: no progress for reload_idle (15 s here, 60 by default: its processes and
# their CPU time do not change), the daemon kills it with all it started, the status shows
# error, the checks go on and the reload is tried again every reload_retry (5 s, 30)
tested() { ubus call xvpn status | jsonfilter -e "@.servers[@.id='$1'].tested"; }
tested_after() { [ "$(tested $1)" -gt "$2" ]; }
killed() { logread | grep -c 'and was killed'; }
hung_reload() { # what
	[ "$(ubus call xvpn select "{\"id\":\"$id\"}" | jsonfilter -e @.error)" = busy ] || { echo "FAIL: no busy while reloading ($1)"; exit 1; }
	[ "$(status @.state)" = connected ] || { echo "FAIL: state while the reload waits ($1)"; ubus call xvpn status; exit 1; }
	wait_for @.state error 40
	status @.last_error | grep -q 'no progress for 15 s' || { echo "FAIL: last_error ($1): $(status @.last_error)"; exit 1; }
	t=$(date +%s); wait_cmd 15 tested_after "$id" "$t"
	[ "$(ubus call xvpn test | jsonfilter -e @.error)" = busy ] || { echo "FAIL: test after a failed reload ($1)"; exit 1; }
	echo "OK: $1: killed, state error, the active server is still checked"
}
id=$(status @.active)
sed -i 's/^start_service() {$/&\n [ -e \/tmp\/hang-reload ] \&\& sleep 1000/' /etc/init.d/xvpn
grep -q hang-reload /etc/init.d/xvpn || { echo "FAIL: test setup, no sleep in init.d"; exit 1; }
touch /tmp/hang-reload
wait_cmd 15 select_ok "$id"	# busy for the pause after the last reload
wait_cmd 10 sh -c "ps w | grep -q '[s]leep 1000'"
hung=$(ps w | awk '/[s]leep 1000/ { print $1 }')
hung_reload "sleep in start_service"
# this very sleep: the retry after reload_retry may already sleep in a new one
kill -0 $hung 2>/dev/null && { echo "FAIL: the hung reload was not killed"; exit 1; }
rm /tmp/hang-reload
wait_cmd 20 sh -c "logread | grep -q 'trying the reload again'"
wait_for @.state connected 30
active_is "$a" || { echo "FAIL: after the hung reload"; ubus call xvpn status; exit 1; }
sed -i '/hang-reload/d' /etc/init.d/xvpn
echo "OK: the daemon reloaded again and is connected"

# someone holds procd's service lock: the reload waits for it, the same as hung
flock /var/lock/procd_xvpn.lock sleep 1001 & lk=$!
sleep 1
wait_cmd 15 select_ok "$id"	# busy for the pause after the last reload
sleep 2
hung_reload "procd lock held"
kill $lk $(ps w | awk '/[s]leep 1001/ { print $1 }') 2>/dev/null || true
wait_for @.state connected 30
[ -z "$(status @.last_error)" ] && active_is "$a" || { echo "FAIL: after the lock was released"; ubus call xvpn status; exit 1; }
echo "OK: connected once the lock is released"

# a slow xray: every `run -test` takes 4 s and one server is rejected, so generate tests
# them one by one for ~35 s, longer than reload_idle; it makes progress and is not killed
printf '#!/bin/sh\n[ "$2" = -test ] && { sleep 4; grep -q 127.0.0.9 "$4" && exit 1; }\nexec /usr/bin/xray "$@"\n' > /tmp/xray-slow
chmod +x /tmp/xray-slow
uci set xvpn.main.xray_bin=/tmp/xray-slow
uci add_list xvpn.manual.link="vless://$UUID@127.0.0.9:18449?type=tcp&security=none#bad"
uci commit xvpn	# no reload_config: the daemon runs the reload (procd restarts xvpnd at its end: file /etc/config/xvpn)
k=$(killed)
wait_cmd 15 select_ok "$id"	# busy for the pause after the last reload
wait_cmd 90 sh -c "logread | grep -q 'rejected 1 server(s): bad'"
sleep 5	# fw-apply, procd and the pause after the reload
wait_for @.state connected 40
[ "$(killed)" = "$k" ] && count_is $n && active_is "$a" || { echo "FAIL: slow generate"; ubus call xvpn status; logread | grep xvpn | tail -10; exit 1; }
echo "OK: a slow generate (~35 s) is not killed, the rejected server is dropped"

# generate killed midway (OOM, the daemon): the config and the index xray runs with stay
# (without the kept verdicts it tests everything again, slowly)
rm /var/etc/xvpn/tested.json
c=$(md5sum < /var/etc/xvpn/config.json); x=$(md5sum < /var/etc/xvpn/index.json)
ucode /usr/share/xvpn/cli.uc generate >/dev/null 2>&1 & g=$!
sleep 10
kill -9 $g
[ "$(md5sum < /var/etc/xvpn/config.json)" = "$c" ] && [ "$(md5sum < /var/etc/xvpn/index.json)" = "$x" ] \
	|| { echo "FAIL: a killed generate changed the running config"; exit 1; }
echo "OK: a killed generate leaves the running config"
uci set xvpn.main.xray_bin=/usr/bin/xray
uci del_list xvpn.manual.link="vless://$UUID@127.0.0.9:18449?type=tcp&security=none#bad"
# another table and mark (#56): the rules and routes with the previous ones go, IPv4 and IPv6;
# someone's rules (the same mark or table, one more selector) and routes stay. The new table
# has a name in rt_tables: ip prints it instead of the number
ours() { (ip rule; ip -6 rule) | grep -E '^[0-9]+:[[:space:]]+from all fwmark ' | grep -vE 'lookup 300 ?$|0x8000000/'; }
theirs() {
	ip rule | grep -q 'from all fwmark 0x2000000/0x2000000 lookup 300' && ip -6 rule | grep -q 'fwmark 0x2000000/0x2000000 lookup 300' \
		&& ip rule | grep -q 'from 10.99.0.1 fwmark 0x2000000/0x2000000 lookup 100' && ip rule | grep -q 'fwmark 0x8000000/0x8000000 lookup 100' \
		&& ip route show table 100 | grep -q 10.77.0.0 || { echo "FAIL: someone's rule or route removed ($1)"; ip rule; ip -6 rule; ip route show table 100; exit 1; }
}
for f in -4 -6; do ip $f rule add fwmark 0x2000000/0x2000000 table 300; done
ip rule add from 10.99.0.1 fwmark 0x2000000/0x2000000 table 100
ip rule add fwmark 0x8000000/0x8000000 table 100
ip route add 10.77.0.0/16 dev lo table 100
echo '200 xvtest' >> /etc/iproute2/rt_tables
uci set xvpn.main.route_table=200
uci set xvpn.main.tproxy_mark=0x04000000
uci commit xvpn
/etc/init.d/xvpn reload
wait_for @.state connected 40
for f in -4 -6; do
	r=$(ip $f rule | grep -E '^[0-9]+:[[:space:]]+from all fwmark ' | grep -vE 'lookup 300 ?$|0x8000000/')
	[ "$(echo "$r" | grep -cE 'fwmark 0x4000000/0x4000000 lookup xvtest ?$')" = 1 ] && [ "$(echo "$r" | wc -l)" = 1 ] \
		&& ip $f route show table 200 | grep -q '^local default' && ! ip $f route show table 100 | grep -q '^local' \
		|| { echo "FAIL: ip $f rules after a change of route_table and tproxy_mark:"; ip $f rule; ip $f route show table all | grep table; exit 1; }
done
theirs reload
tunnel || { echo "FAIL: no tunnel with route_table 200 and tproxy_mark 0x04000000"; exit 1; }
echo "OK: a new route_table and tproxy_mark: the previous rules and routes are gone, someone's stay, the tunnel works"

/etc/init.d/xvpn stop
no_tproxy "stop with the service enabled"
[ -z "$(ours)" ] && [ -z "$(ip route show table 200; ip -6 route show table 200)" ] \
	|| { echo "FAIL: ip rules or routes left after stop"; ip rule; ip -6 rule; exit 1; }
theirs stop
echo "OK: no ip rules or routes after stop, someone's stay"
in_set inet nets xvpn-ap1 && in_set bridge ports myvpn0 || { echo "FAIL: guard without the SSIDs"; exit 1; }
blocked "stopped, service enabled"

uci set xvpn.main.enabled=0; uci commit xvpn
/etc/init.d/xvpn stop
nft list table inet xvpn >/dev/null 2>&1 && { echo "FAIL: table left after stop with enabled=0"; exit 1; }
direct || { echo "FAIL: client is still blocked with the service turned off"; exit 1; }
echo "OK: rules removed when the service is turned off"

# package removal: default_prerm disables, then stops
uci set xvpn.main.enabled=1; uci commit xvpn
/etc/init.d/xvpn start; sleep 2
[ "$(ours | wc -l)" = 2 ] || { echo "FAIL: no ip rules in full before package removal"; ip rule; ip -6 rule; exit 1; }
/etc/init.d/xvpn disable; /etc/init.d/xvpn stop
nft list table inet xvpn >/dev/null 2>&1 && { echo "FAIL: table left after disable + stop"; exit 1; }
# fw-remove from full: the rules and routes go, IPv4 and IPv6, someone's stay
[ -z "$(ours)" ] && [ -z "$(ip route show table 200; ip -6 route show table 200)" ] && [ ! -e /var/run/xvpn/fw_route ] \
	|| { echo "FAIL: ip rules or routes left after fw-remove"; ip rule; ip -6 rule; exit 1; }
theirs fw-remove
for f in -4 -6; do ip $f rule del fwmark 0x2000000/0x2000000 table 300; done
ip rule del from 10.99.0.1 fwmark 0x2000000/0x2000000 table 100
ip rule del fwmark 0x8000000/0x8000000 table 100
ip route flush table 100
sed -i '/xvtest/d' /etc/iproute2/rt_tables
echo "OK: rules removed on package removal"
sed -n '/^define Package\/luci-app-xvpn\/postrm/,/^endef/p' /src/luci-app-xvpn/Makefile | sed '1d;$d; s/\$\$/$/g' > /tmp/postrm
uci set wireless.homeap.ssid=Staged
sh /tmp/postrm
uci_is wireless.onlyap.ifname xvpn-ap1
grep -q Staged /etc/config/wireless && { echo "FAIL: postrm committed someone's change"; exit 1; }
uci revert wireless
sh /tmp/postrm
uci_is wireless.onlyap.ifname ''
uci_is wireless.onlyap.xvpn_ifname ''
uci_is wireless.ownap.ifname myvpn0
uci -q get firewall.xvpn >/dev/null && { echo "FAIL: postrm left the fw4 include"; exit 1; }
echo "OK: postrm restores the SSID names"
IN
