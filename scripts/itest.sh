#!/bin/sh
# Integration test: runs the service under procd in an OpenWrt container with two
# local VLESS "remote" servers, checks server selection, failover, subscription update and
# that a VPN client (network namespace behind a bridge port) never reaches the "internet"
# (another namespace) directly: boot guard, restart, stop, broken fw-apply, fw4 flush;
# fixed SSID names in /etc/config/wireless, fail closed for an SSID without a name;
# subscription update from LuCI through the daemon and by a reload past it; a hung xray
# and a broken xray_bin are xray_down, not dead servers; a hung reload (sleep in init.d,
# procd lock held) does not stop the health checks, a slow generate is not killed and a
# killed one leaves the running config; before NTP sets the clock no server goes to quarantine.
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
	echo "--- logread"; logread | grep -E 'xvpn|xray|procd' | tail -30
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
set xvpn.health.timeout=4
set xvpn.health.fail_threshold=2
set xvpn.health.reload_idle=15
set xvpn.health.reload_retry=5
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
# time. The image has no system.ntp, so sysntpd does not run; the hotplug event is sent by hand.
not_quarantined() { # what
	ubus call xvpn status | grep -q '"quarantined": true' && { echo "FAIL: quarantine while waiting for the time ($1)"; ubus call xvpn status; exit 1; }
	return 0
}
# /etc/config/system is put back byte for byte: reload_config below would reload log and sysntpd
cp /etc/config/system /tmp/system.orig
uci batch <<UCI
set system.ntp=timeserver
add_list system.ntp.server=127.0.0.1
commit system
set xvpn.health.time_wait=20
commit xvpn
UCI
kill $(cat /tmp/remote-18443.pid)
rm -f /var/run/xvpn/time_synced
/etc/init.d/xvpn restart
wait_for @.state waiting_time 15
env -i ACTION=stratum stratum=16 /sbin/hotplug-call ntp
sleep 9	# 3 checks
[ "$(status @.state)" = waiting_time ] && [ "$(status @.passthrough)" = false ] || { echo "FAIL: waiting for the time"; ubus call xvpn status; exit 1; }
not_quarantined "kill switch"
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
rm -f /var/run/xvpn/time_synced
/etc/init.d/xvpn restart
wait_for @.state waiting_time 15
wait_for @.passthrough true 15
direct || { echo "FAIL: no passthrough while waiting for the time, kill switch off"; exit 1; }
not_quarantined "kill switch off"
remote 18443
wait_cmd 30 sh -c "logread | grep -q 'no NTP sync in 20 s'"
wait_for @.state connected 15
wait_for @.passthrough false 10
active_is first && tunnel || { echo "FAIL: after the time wait ran out"; ubus call xvpn status; exit 1; }
echo "OK: passthrough while waiting for the time, going on after time_wait"
uci set xvpn.access.killswitch=1; uci delete xvpn.health.time_wait; uci commit xvpn
cp /tmp/system.orig /etc/config/system
/etc/init.d/xvpn restart
wait_for @.state connected 40

# failover: kill the active remote, start the other one
kill $(cat /tmp/remote-18443.pid); remote 18444
sleep 8
wait_for @.state connected 60
[ "$(active_name)" = second ] || { echo "FAIL: failover expected second, got $(active_name)"; exit 1; }
echo "OK: failover to the other server"
logread | grep xvpn | grep -E 'switching|state' | tail -5

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
r=$(ubus call luci.xvpn update '{"sid":"s2"}')
[ "$(echo "$r" | jsonfilter -e @.ok)" = true ] || { echo "FAIL: fresh subscription: $r"; exit 1; }
wait_cmd 20 test -s /etc/xvpn/subs/s2.json
[ ! -e /var/run/xvpn/updating ] || { echo "FAIL: lock left after update"; exit 1; }
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
select_ok() { [ "$(ubus call xvpn select "{\"id\":\"$1\"}" | jsonfilter -e @.ok)" = true ]; }
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
hung_reload "sleep in start_service"
ps w | grep -q '[s]leep 1000' && { echo "FAIL: the hung reload was not killed"; exit 1; }
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
c=$(md5sum < /var/etc/xvpn/config.json); x=$(md5sum < /var/etc/xvpn/index.json)
ucode /usr/share/xvpn/cli.uc generate >/dev/null 2>&1 & g=$!
sleep 10
kill -9 $g
[ "$(md5sum < /var/etc/xvpn/config.json)" = "$c" ] && [ "$(md5sum < /var/etc/xvpn/index.json)" = "$x" ] \
	|| { echo "FAIL: a killed generate changed the running config"; exit 1; }
echo "OK: a killed generate leaves the running config"
uci set xvpn.main.xray_bin=/usr/bin/xray
uci del_list xvpn.manual.link="vless://$UUID@127.0.0.9:18449?type=tcp&security=none#bad"
uci commit xvpn
/etc/init.d/xvpn reload
wait_for @.state connected 40

/etc/init.d/xvpn stop
no_tproxy "stop with the service enabled"
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
/etc/init.d/xvpn disable; /etc/init.d/xvpn stop
nft list table inet xvpn >/dev/null 2>&1 && { echo "FAIL: table left after disable + stop"; exit 1; }
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
