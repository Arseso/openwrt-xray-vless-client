#!/bin/sh
# Starts LuCI with luci-app-xvpn in an OpenWrt 24.10 container for checking the
# web UI by hand: two local VLESS "remote" servers (one live, one dead) as manual
# links and a subscription with subscription-userinfo served by uhttpd.
#
#   sh scripts/luci.sh        start, LuCI at http://127.0.0.1:$PORT/ (root / $PASS)
#   sh scripts/luci.sh sync   copy the package files into the running container again
#   sh scripts/luci.sh stop   remove the container
#
# The password is a test value for this local container only.
set -e
cd "$(dirname "$0")/.."
DOCKER="${DOCKER:-docker --context default}"
IMAGE="${IMAGE:-openwrt/rootfs:x86-64-24.10.4}"
NAME=${NAME:-xvpn-luci}
PORT=${PORT:-8019}
PASS=${PASS:-xvpn-luci-test}
# docker copies the DNS of the host, often its router at 192.168.1.1: the very address of
# br-lan in the container, so the stand would ask itself
DNS=${DNS:-1.1.1.1}

sync() {
	$DOCKER exec $NAME sh -ec '
		# keep the test configuration
		[ ! -f /etc/config/xvpn ] || cp /etc/config/xvpn /tmp/xvpn.uci
		cp -a /src/luci-app-xvpn/root/. /
		[ ! -f /tmp/xvpn.uci ] || mv /tmp/xvpn.uci /etc/config/xvpn
		mkdir -p /www/luci-static/resources
		cp -a /src/luci-app-xvpn/htdocs/. /www/
		rm -rf /tmp/luci-indexcache* /tmp/luci-modulecache
	'
}

case "$1" in
stop) $DOCKER rm -f $NAME >/dev/null; exit 0 ;;
sync) sync; $DOCKER exec $NAME /etc/init.d/rpcd restart; exit 0 ;;
esac

$DOCKER rm -f $NAME >/dev/null 2>&1 || true
# --privileged: S11sysctl in the container would write the sysctls of the host
$DOCKER run -d --name $NAME --privileged --dns "$DNS" -p 127.0.0.1:$PORT:80 -v "$PWD:/src:ro" "$IMAGE" \
	sh -c 'rm -f /etc/rc.d/S11sysctl; exec /sbin/init' >/dev/null
sleep 5
NET=$($DOCKER inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}/{{.IPPrefixLen}} {{.Gateway}}{{end}}' $NAME)

$DOCKER exec -i -e NET="$NET" -e PASS="$PASS" -e DNS="$DNS" $NAME sh -e <<'IN'
UUID=11111111-2222-3333-4444-555555555555
mkdir -p /var/lock
i=0; until logread 2>/dev/null | grep -q 'init complete'; do [ $i -lt 30 ] || break; sleep 1; i=$((i+1)); done
# netifd puts eth0 into br-lan and drops the docker address: give it back as wan.
# docker passes on the host's DNS server, often a home router at 192.168.1.1: the
# default LAN address would take it over and DNS would end at our own dnsmasq
set -- $NET
uci batch <<UCI
set network.lan.ipaddr=192.168.199.1
del_list network.@device[0].ports=eth0
set network.@device[0].bridge_empty=1
set network.wan=interface
set network.wan.device=eth0
set network.wan.proto=static
set network.wan.ipaddr=$1
set network.wan.gateway=$2
set network.wan.dns=$DNS
commit network
set firewall.@zone[1].input=ACCEPT
commit firewall
UCI
/etc/init.d/network restart
/etc/init.d/firewall restart
sleep 3
# downloads.openwrt.org may fail right after the network restart (wget returned 4):
# tried again, as in itest.sh
i=0; until opkg update >/dev/null; do i=$((i+1)); [ $i -lt 5 ] || exit 1; sleep 5; done
i=0; until opkg install luci ucode-mod-uloop ucode-mod-socket xray-core curl >/dev/null; do i=$((i+1)); [ $i -lt 5 ] || exit 1; sleep 5; done
printf '%s\n%s\n' "$PASS" "$PASS" | passwd root >/dev/null 2>&1
IN
sync
$DOCKER exec -i $NAME sh -e <<'IN'
UUID=11111111-2222-3333-4444-555555555555
/etc/uci-defaults/80_luci-xvpn
/etc/init.d/rpcd restart

for p in 18443 18445; do
	cat > /tmp/remote-$p.json <<JSON
{ "inbounds": [ { "listen": "127.0.0.1", "port": $p, "protocol": "vless",
    "settings": { "clients": [ { "id": "$UUID" } ], "decryption": "none" } } ],
  "outbounds": [ { "protocol": "freedom" } ] }
JSON
	start-stop-daemon -S -b -m -p /var/run/remote-$p.pid -x /usr/bin/xray -- run -c /tmp/remote-$p.json
done
link() { echo "vless://$UUID@127.0.0.1:$1?type=tcp&security=none#$2"; }

# subscription: 12.3 GB of 100 GB used, expires in 20 days
link 18445 sub-live | ucode -l fs -e 'print(b64enc(fs.stdin.read("all")))' > /www/sub.b64
cat > /www/cgi-bin/xvpn-sub <<SH
#!/bin/sh
echo 'Content-Type: text/plain'
echo 'subscription-userinfo: upload=1300000000; download=11000000000; total=100000000000; expire=$(( $(date +%s) + 20 * 86400 ))'
echo
cat /www/sub.b64
SH
chmod +x /www/cgi-bin/xvpn-sub

uci batch <<UCI
set xvpn.main.enabled=1
add_list xvpn.manual.link='$(link 18443 manual-live)'
add_list xvpn.manual.link='$(link 18444 manual-dead)'
add xvpn subscription
set xvpn.@subscription[-1].name='Test subscription'
set xvpn.@subscription[-1].enabled=1
set xvpn.@subscription[-1].url=http://127.0.0.1/cgi-bin/xvpn-sub
set xvpn.@subscription[-1].via_tunnel=0
commit xvpn
UCI
/etc/init.d/xvpn enable
/etc/init.d/xvpn start
IN
echo "LuCI: http://127.0.0.1:$PORT/cgi-bin/luci/admin/services/xvpn (root / $PASS)"
