// SPDX-License-Identifier: MIT
// Unit tests: ucode -L 'luci-app-xvpn/root/usr/share/ucode/*.uc' tests/run.uc <fixtures dir> <out dir>

'use strict';

import { readfile, writefile } from 'fs';
import { parse_link, parse_subscription } from 'xvpn.links';
import { parse_userinfo } from 'xvpn.subscription';
import { build_index, generate } from 'xvpn.xrayconf';
import { render, resolve, fix_ifnames } from 'xvpn.firewall';
import { cursor } from 'uci';

const FIX = ARGV[0] ?? 'tests/fixtures';
const OUT = ARGV[1] ?? '/tmp';
let failed = 0, passed = 0;

function eq(name, got, want) {
	if (sprintf('%J', got) == sprintf('%J', want))
		passed++;
	else {
		failed++;
		warn(`FAIL ${name}\n  got:  ${sprintf('%J', got)}\n  want: ${sprintf('%J', want)}\n`);
	}
}

function ok(name, cond) {
	eq(name, !!cond, true);
}

let lines = filter(split(readfile(`${FIX}/links.txt`), '\n'), (l) => l != '');
let p = map(lines, (l) => parse_link(l));

// vless reality vision
eq('vless name utf8', p[0].name, '🇳🇱 Netherlands');
eq('vless reality', p[0].outbound.streamSettings, {
	network: 'tcp', security: 'reality',
	realitySettings: { serverName: 'www.microsoft.com', fingerprint: 'chrome', publicKey: 'Z84J2IelR9ch3k8VtlVhhs5ycBUlXA7wHBWcBrjqnAw', shortId: '6ba85179e30d4fc2' },
});
eq('vless flow', p[0].outbound.settings.vnext[0].users[0].flow, 'xtls-rprx-vision');
eq('vless xhttp', p[1].outbound.streamSettings.xhttpSettings, { path: '/xh', mode: 'auto' });
eq('vless ws', p[2].outbound.streamSettings.wsSettings, { path: '/ws?ed=2048', host: 'cdn.example.com' });
eq('vless alpn', p[2].outbound.streamSettings.tlsSettings.alpn, [ 'h2', 'http/1.1' ]);
eq('vless v6 address', [ p[3].address, p[3].port ], [ '2001:db8::1', 8443 ]);
eq('vless grpc', p[3].outbound.streamSettings.grpcSettings, { serviceName: 'grpcsvc', multiMode: true });
eq('vless httpupgrade', p[4].outbound.streamSettings, { network: 'httpupgrade', security: 'none', httpupgradeSettings: { path: '/up', host: 'hu.example.com' } });
eq('vmess', [ p[5].name, p[5].outbound.protocol, p[5].outbound.streamSettings.network, p[5].outbound.streamSettings.tlsSettings.serverName ],
	[ 'VMess WS', 'vmess', 'ws', 'vm.example.com' ]);
eq('trojan', [ p[6].outbound.settings.servers[0].password, p[6].outbound.streamSettings.security ], [ 'p@ss', 'tls' ]);
eq('ss 2022', p[7].outbound.settings.servers[0], { address: 'ss.example.com', port: 8388, method: '2022-blake3-aes-256-gcm', password: 'MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY=' });
eq('ss legacy', [ p[8].name, p[8].address, p[8].port, p[8].outbound.settings.servers[0].password ], [ 'Legacy SS', '1.2.3.4', 8443, 'pass' ]);
ok('hysteria2 unsupported', p[9].error);
ok('h2 unsupported', p[10].error);
ok('vless encryption unsupported', p[11].error);
ok('ss 2022 bad key', p[12].error);
ok('ids unique', length(uniq(map(filter(p, (s) => !s.error), (s) => s.id))) == 9);
eq('id stable', parse_link(lines[0]).id, p[0].id);

// subscriptions
let b = parse_subscription(readfile(`${FIX}/sub-base64.txt`));
eq('base64 sub', [ b.format, length(b.servers), b.skipped ], [ 'base64', 9, 4 ]);
let pl = parse_subscription(readfile(`${FIX}/links.txt`));
eq('plain sub', [ pl.format, length(pl.servers) ], [ 'plain', 9 ]);
let xj = parse_subscription(readfile(`${FIX}/sub-xray.json`));
eq('xray json sub', [ xj.format, length(xj.servers), xj.skipped, xj.servers[0].name ], [ 'xray-json', 1, 1, '🇫🇮 Finland' ]);
ok('xray json drops sockopt', xj.servers[0].outbound.streamSettings.sockopt == null);
ok('clash rejected', match(parse_subscription('mixed-port: 7890\nproxies:\n').errors[0], /Clash/));
ok('html rejected', match(parse_subscription('<html></html>').errors[0], /HTML/));
eq('userinfo', parse_userinfo('upload=1; download=2; total=10737418240; expire=1798761600'),
	{ upload: 1, download: 2, total: 10737418240, expire: 1798761600 });

// config generation
let cfg = {
	main: { tproxy_port: 12345, dns_port: 10853, api_port: 10085, test_port_base: 20000, loglevel: 'warning', sniffing: false,
		client_mark: 0x01000000, tproxy_mark: 0x02000000, route_table: 100 },
	access: { dns_server: '1.1.1.1', killswitch: true, ipv6: 'block', dns_hijack: true },
};
let servers = [ ...b.servers, ...xj.servers ];
let idx = build_index(cfg, servers, p[2].id);
eq('index active', idx.active, p[2].id);
eq('index ports', [ idx.servers[0].test_port, idx.servers[9].test_port ], [ 20000, 20009 ]);
eq('index fallback active', build_index(cfg, servers, 'nope').active, servers[0].id);
let conf = generate(cfg, servers, idx);
eq('default outbound is active', conf.outbounds[0].tag, 'srv-2');
eq('tproxy route', conf.routing.rules[-1] ?? conf.routing.rules[length(conf.routing.rules) - 1],
	{ type: 'field', inboundTag: [ 'tproxy', 'dns-in' ], outboundTag: 'srv-2' });
eq('inbounds', length(conf.inbounds), 3 + length(servers));
writefile(`${OUT}/config.json`, sprintf('%J', conf));

// firewall
let res = { nets: [ 'br-guest' ], ports: [ 'lan2', 'phy1-ap1' ] };
let nft = render(cfg, res);
ok('nft tproxy', index(nft, 'tproxy ip to :12345') >= 0);
ok('nft no tproxy6 in block mode', index(nft, 'tproxy ip6') < 0);
ok('nft killswitch', index(nft, 'reject with icmpx type admin-prohibited') >= 0);
ok('nft bridge', index(nft, 'iifname @ports meta mark set meta mark | 0x01000000') >= 0);
writefile(`${OUT}/full.nft`, nft);
cfg.access.ipv6 = 'tunnel';
cfg.access.killswitch = false;
writefile(`${OUT}/tunnel.nft`, render(cfg, { nets: [], ports: [] }));
writefile(`${OUT}/passthrough.nft`, render(cfg, res, { passthrough: true }));
ok('passthrough has no tproxy', index(render(cfg, res, { passthrough: true }), 'tproxy ip') < 0);

// fail-closed table: blocks even with kill switch off, needs no tproxy/fib/nat
let blk = render(cfg, res, { block: true });
ok('block rejects forward', index(blk, '\t\treject with icmpx type admin-prohibited') >= 0);
ok('block rejects dns', index(blk, 'th dport 53 reject') >= 0);
ok('block marks ports', index(blk, 'iifname @ports meta mark set meta mark | 0x01000000') >= 0);
ok('block needs no tproxy', index(blk, 'tproxy') < 0 && index(blk, 'fib ') < 0 && index(blk, 'redirect') < 0);
ok('full has no dns reject', index(nft, 'th dport 53 reject') < 0);
writefile(`${OUT}/block.nft`, blk);
let min = render(cfg, res, { minimal: true });
ok('minimal rejects nets', index(min, 'iifname @nets reject with icmpx type admin-prohibited') >= 0);
ok('minimal is inet only', index(min, 'bridge') < 0 && index(min, 'tproxy') < 0 && index(min, 'mark') < 0);
writefile(`${OUT}/minimal.nft`, min);

// access points: fixed SSID names in a test UCI tree
let confdir = `${OUT}/conf`;
system([ 'mkdir', '-p', confdir, `${OUT}/delta` ]);
writefile(`${confdir}/network`, `
config interface 'lan'
	option device 'br-lan'

config interface 'wonly'
	option proto 'static'

config interface 'alias'
	option device '@lan'
`);
writefile(`${confdir}/wireless`, `
config wifi-device 'radio0'
	option band '2g'

config wifi-device 'radio1'
	option band '5g'
	option disabled '1'

config wifi-iface 'vpn'
	option device 'radio0'
	option network 'lan'
	option ssid 'VPN'

config wifi-iface 'home'
	option device 'radio0'
	option network 'lan'
	option ssid 'Home'

config wifi-iface 'own'
	option device 'radio0'
	option network 'lan'
	option ifname 'myvpn0'

config wifi-iface 'only'
	option device 'radio0'
	option network 'wonly'

config wifi-iface 'off'
	option device 'radio1'
	option network 'lan'

config wifi-iface 'old'
	option device 'radio0'
	option network 'lan'
	option ifname 'xvpn-ap0'
`);
let ucur = () => cursor(confdir, `${OUT}/delta`);
let wcfg = { access: { networks: [ 'wonly' ], ports: [ 'lan2' ], wifi: [ 'vpn', 'own', 'off' ] } };
ok('fix ifnames changes wireless', fix_ifnames(wcfg, ucur()));
let wl = ucur();
eq('fixed names: free numbers, own name kept, Wi-Fi only network included',
	map([ 'vpn', 'own', 'only', 'off', 'home', 'old' ], (x) => wl.get('wireless', x, 'ifname')),
	[ 'xvpn-ap1', 'myvpn0', 'xvpn-ap2', 'xvpn-ap3', null, null ]);
ok('fix ifnames is idempotent', !fix_ifnames(wcfg, ucur()));

// no netifd yet (boot guard): names from UCI, SSIDs in both sets
let none = { call: () => null };
eq('resolve from UCI', resolve(wcfg, none, ucur()), {
	nets: [ 'xvpn-ap1', 'myvpn0', 'xvpn-ap3', 'xvpn-ap2' ],
	ports: [ 'lan2', 'xvpn-ap1', 'myvpn0', 'xvpn-ap3', 'xvpn-ap2' ], errors: [] });

// netifd up: live L3 device of the network, the current SSID name besides the fixed one
let up = { call: (o, m) => (o == 'network.wireless')
	? { radio0: { interfaces: [ { section: 'vpn', ifname: 'phy0-ap0' }, { section: 'home', ifname: 'phy0-ap1' } ] } }
	: { interface: [ { interface: 'wonly', l3_device: 'xvpn-ap2', device: 'xvpn-ap2' }, { interface: 'alias', l3_device: 'br-lan' } ] } };
let lcfg = { access: { networks: [ 'lan', 'alias' ], ports: [], wifi: [ 'vpn' ] } };
eq('resolve live names', resolve(lcfg, up, ucur()),
	{ nets: [ 'br-lan', 'xvpn-ap1', 'phy0-ap0' ], ports: [ 'xvpn-ap1', 'phy0-ap0' ], errors: [] });

// deselected: our name goes away, the user's stays
let dcfg = { access: { networks: [], ports: [], wifi: [ 'own' ] } };
ok('deselect changes wireless', fix_ifnames(dcfg, ucur()));
wl = ucur();
eq('deselected names removed', map([ 'vpn', 'own', 'only', 'off' ], (x) => wl.get('wireless', x, 'ifname')),
	[ null, 'myvpn0', null, null ]);

// an enabled SSID without a usable name is an error (fail closed), a disabled one is not
wl = ucur();
wl.set('wireless', 'own', 'ifname', 'a-very-long-name0');
wl.commit('wireless');
let ecfg = { access: { networks: [], ports: [], wifi: [ 'own', 'off', 'gone' ] } };
let er = resolve(ecfg, none, ucur());
eq('unresolved SSID is an error', [ er.ports, er.errors ], [ [], [ 'wifi "own" has no interface name' ] ]);
wl = ucur();
wl.set('wireless', 'own', 'disabled', '1');
wl.commit('wireless');
eq('disabled SSID without a name is skipped', resolve(ecfg, none, ucur()).errors, []);
ok('user changes in wireless are not committed', (() => {
	let c = ucur();
	c.set('wireless', 'home', 'ssid', 'Staged');
	c.save('wireless');
	return !fix_ifnames(wcfg, ucur()) && ucur().get('wireless', 'vpn', 'ifname') == null;
})());

eq('resolve drops names over 15 chars', resolve({ access: { networks: [], ports: [ 'lan2', 'a-very-long-port0' ], wifi: [] } }, null, ucur()),
	{ nets: [], ports: [ 'lan2' ], errors: [] });

print(`${passed} passed, ${failed} failed\n`);
exit(failed ? 1 : 0);
