// SPDX-License-Identifier: MIT
// Unit tests: ucode -L 'luci-app-xvpn/root/usr/share/ucode/*.uc' tests/run.uc <fixtures dir> <out dir>

'use strict';

import { readfile, writefile, mkdir } from 'fs';
import { parse_link, parse_subscription } from 'xvpn.links';
import { parse_userinfo } from 'xvpn.subscription';
import { load_config } from 'xvpn.util';
import { build_index, generate } from 'xvpn.xrayconf';
import { render, resolve, fix_ifnames, ifnames_applied } from 'xvpn.firewall';
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
ok('no dns module for an IP', conf.dns == null);
// stats come from the metrics section over loopback HTTP, there is no gRPC API (#7)
eq('metrics', [ conf.metrics, conf.api ], [ { tag: 'metrics' }, null ]);
eq('metrics inbound', filter(conf.inbounds, (i) => i.tag == 'metrics')[0],
	{ tag: 'metrics', listen: '127.0.0.1', port: 10085, protocol: 'dokodemo-door', settings: { address: '127.0.0.1' } });
eq('metrics route', conf.routing.rules[0], { type: 'field', inboundTag: [ 'metrics' ], outboundTag: 'metrics' });
writefile(`${OUT}/config.json`, sprintf('%J', conf));

// dns_server as a URL: queries go through the xray DNS module by domain
cfg.access.dns_server = 'https://cloudflare-dns.com/dns-query';
let dconf = generate(cfg, servers, idx);
eq('doh module', dconf.dns, { tag: 'dns-module', servers: [ 'https://cloudflare-dns.com/dns-query' ], queryStrategy: 'UseIPv4' });
ok('dns-in to dns-out', length(filter(dconf.routing.rules, (r) => r.inboundTag[0] == 'dns-in' && r.outboundTag == 'dns-out')) == 1);
eq('doh route', dconf.routing.rules[length(dconf.routing.rules) - 1],
	{ type: 'field', inboundTag: [ 'tproxy', 'dns-module' ], outboundTag: 'srv-2' });
eq('default outbound with doh', dconf.outbounds[0].tag, 'srv-2');
writefile(`${OUT}/config-doh.json`, sprintf('%J', dconf));
cfg.access.ipv6 = 'tunnel';
eq('doh UseIP with ipv6 tunnel', generate(cfg, servers, idx).dns.queryStrategy, 'UseIP');
cfg.access.ipv6 = 'block';
let nosrv = generate(cfg, [], build_index(cfg, [], null));
eq('doh without servers: blackhole by default', nosrv.outbounds[0].tag, 'block');
ok('doh without servers: no dns-module rule', length(filter(nosrv.routing.rules, (r) => r.inboundTag[0] == 'tproxy')) == 0);
cfg.access.dns_server = '1.1.1.1';

// dns_server schemes that would query from the router directly are replaced
function dns_of(v) {
	mkdir(`${OUT}/dnscfg`);
	writefile(`${OUT}/dnscfg/xvpn`, `config access 'access'\n\toption dns_server '${v}'\n`);
	return load_config(`${OUT}/dnscfg`).access.dns_server;
}
eq('dns_server https kept', dns_of('https://dns.google/dns-query'), 'https://dns.google/dns-query');
eq('dns_server tcp kept', dns_of('tcp://1.1.1.1'), 'tcp://1.1.1.1');
eq('dns_server IP kept', dns_of('9.9.9.9'), '9.9.9.9');
eq('dns_server +local replaced', dns_of('https+local://dns.google/dns-query'), 'https://cloudflare-dns.com/dns-query');
eq('dns_server quic+local replaced', dns_of('quic+local://dns.adguard.com'), 'https://cloudflare-dns.com/dns-query');

// firewall
// SSIDs come with a wildcard (WDS, dynamic VLAN) and may overlap an exact name: nft -c checks it
let res = { nets: [ 'br-guest', 'xvpn-ap1', 'xvpn-ap1.*', 'xvpn-ap1.5' ], ports: [ 'lan2', 'xvpn-ap1', 'xvpn-ap1.*' ] };
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
// a bad port breaks full, but block (its fallback) must still load
let bad = { ...cfg, main: { ...cfg.main, tproxy_port: 99999 } };
let blkbad = render(bad, res, { block: true });
ok('block skips a bad port', index(blkbad, '99999') < 0 && index(blkbad, 'th dport { 10853 }') >= 0);
ok('full keeps the bad port', index(render(bad, res), '99999') >= 0);
writefile(`${OUT}/block-badport.nft`, blkbad);
let dup = render({ ...cfg, main: { ...cfg.main, tproxy_port: 10853 } }, res, { block: true });
ok('block dedups ports', index(dup, 'th dport { 10853 }') >= 0);
writefile(`${OUT}/block-dupport.nft`, dup);
writefile(`${OUT}/block.nft`, blk);
let min = render(cfg, res, { minimal: true });
ok('minimal rejects nets', index(min, 'iifname @nets reject with icmpx type admin-prohibited') >= 0);
ok('minimal is inet only', index(min, 'bridge') < 0 && index(min, 'tproxy') < 0 && index(min, 'mark') < 0);
writefile(`${OUT}/minimal.nft`, min);

// access points: fixed SSID names in a test UCI tree
let confdir = `${OUT}/conf`;
system([ 'mkdir', '-p', confdir, `${OUT}/delta`, `${OUT}/empty-delta` ]);
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

config wifi-iface 'uplink'
	option device 'radio0'
	option network 'wonly'
	option mode 'sta'

config wifi-iface 'gone'
	option device 'radio0'
	option network 'lan'
	option ifname 'xvpn-ap9'
	option xvpn_ifname '1'
`);
let ucur = () => cursor(confdir, `${OUT}/delta`);
let names = (c, list) => map(list, (x) => c.get('wireless', x, 'ifname'));
let wcfg = { access: { networks: [ 'wonly' ], ports: [ 'lan2' ], wifi: [ 'vpn', 'own', 'off' ] } };
eq('fix ifnames changes wireless', fix_ifnames(wcfg, ucur()), { changed: true });
let wl = ucur();
eq('fixed names: free numbers, own and unmarked names kept, Wi-Fi only network without its STA uplink',
	names(wl, [ 'vpn', 'own', 'only', 'off', 'home', 'old', 'uplink', 'gone' ]),
	[ 'xvpn-ap1', 'myvpn0', 'xvpn-ap2', 'xvpn-ap3', null, 'xvpn-ap0', null, null ]);
eq('our names are marked', map([ 'vpn', 'own', 'only', 'old', 'gone' ], (x) => wl.get('wireless', x, 'xvpn_ifname')),
	[ '1', null, '1', null, null ]);
eq('fix ifnames is idempotent', fix_ifnames(wcfg, ucur()), { changed: false });

// no netifd yet (boot guard): names from UCI, SSIDs in both sets with a wildcard for WDS/VLAN
let none = { call: () => null };
let wild = (l) => [ ...l, ...map(l, (n) => `${n}.*`) ];
eq('resolve from UCI', resolve(wcfg, none, ucur()), {
	nets: [ ...wild([ 'xvpn-ap1' ]), ...wild([ 'myvpn0' ]), ...wild([ 'xvpn-ap3' ]), ...wild([ 'xvpn-ap2' ]) ],
	ports: [ 'lan2', ...wild([ 'xvpn-ap1' ]), ...wild([ 'myvpn0' ]), ...wild([ 'xvpn-ap3' ]), ...wild([ 'xvpn-ap2' ]) ],
	errors: [] });

// netifd up: live L3 device of the network, the current SSID name besides the fixed one
let st = { radio0: { interfaces: [ { section: 'vpn', ifname: 'phy0-ap0' }, { section: 'home', ifname: 'phy0-ap1' } ] } };
let up = { call: (o, m) => (o == 'network.wireless') ? st
	: { interface: [ { interface: 'wonly', l3_device: 'xvpn-ap2', device: 'xvpn-ap2' }, { interface: 'alias', l3_device: 'br-lan' } ] } };
let lcfg = { access: { networks: [ 'lan', 'alias' ], ports: [], wifi: [ 'vpn' ] } };
eq('resolve live names', resolve(lcfg, up, ucur()),
	{ nets: [ 'br-lan', ...wild([ 'xvpn-ap1', 'phy0-ap0' ]) ], ports: wild([ 'xvpn-ap1', 'phy0-ap0' ]), errors: [] });
eq('no wildcard for a name with no room for a suffix',
	resolve({ access: { networks: [], ports: [], wifi: [ 'vpn' ] } }, { call: () => ({ radio0: { interfaces: [ { section: 'vpn', ifname: 'phy0-ap0-long1' } ] } }) }, ucur()).ports,
	[ 'xvpn-ap1', 'phy0-ap0-long1', 'xvpn-ap1.*' ]);
ok('fixed name not applied yet', !ifnames_applied(lcfg, up, ucur()));
st.radio0.interfaces[0].ifname = 'xvpn-ap1';
ok('fixed name applied', ifnames_applied(lcfg, up, ucur()));
ok('disabled SSID is not waited for', ifnames_applied({ access: { networks: [], ports: [], wifi: [ 'off' ] } }, up, ucur()));

// deselected: our (marked) names go away, the user's stay
let dcfg = { access: { networks: [], ports: [], wifi: [ 'own' ] } };
eq('deselect changes wireless', fix_ifnames(dcfg, ucur()), { changed: true });
wl = ucur();
eq('deselected names removed', names(wl, [ 'vpn', 'own', 'only', 'off', 'old' ]), [ null, 'myvpn0', null, null, 'xvpn-ap0' ]);
eq('marks removed', map([ 'vpn', 'only', 'off' ], (x) => wl.get('wireless', x, 'xvpn_ifname')), [ null, null, null ]);

// an enabled SSID without a usable name is an error (fail closed), a disabled one is not
wl = ucur();
wl.set('wireless', 'own', 'ifname', 'a-very-long-name0');
wl.commit('wireless');
let ecfg = { access: { networks: [], ports: [], wifi: [ 'own', 'off', 'missing' ] } };
let er = resolve(ecfg, none, ucur());
eq('unresolved SSID is an error', [ er.ports, er.errors ], [ [], [ 'wifi "own" has no interface name' ] ]);
wl = ucur();
wl.set('wireless', 'own', 'disabled', '1');
wl.commit('wireless');
eq('disabled SSID without a name is skipped', resolve(ecfg, none, ucur()).errors, []);

// someone's uncommitted changes: nothing committed, a warning instead
wl = ucur();
wl.set('wireless', 'home', 'ssid', 'Staged');
wl.save('wireless');
let wr = fix_ifnames(wcfg, ucur());
ok('uncommitted changes: warning', !wr.changed && match(wr.warning, /uncommitted/));
ok('uncommitted changes are not committed', ucur().get('wireless', 'vpn', 'ifname') == null
	&& cursor(confdir, `${OUT}/empty-delta`).get('wireless', 'home', 'ssid') == 'Home');
eq('no warning when there is nothing to fix', fix_ifnames(dcfg, ucur()), { changed: false });

eq('resolve drops names over 15 chars', resolve({ access: { networks: [], ports: [ 'lan2', 'a-very-long-port0' ], wifi: [] } }, null, ucur()),
	{ nets: [], ports: [ 'lan2' ], errors: [] });

print(`${passed} passed, ${failed} failed\n`);
exit(failed ? 1 : 0);
