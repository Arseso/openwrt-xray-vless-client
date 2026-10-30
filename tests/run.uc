// SPDX-License-Identifier: MIT
// Unit tests: ucode -L 'luci-app-xvpn/root/usr/share/ucode/*.uc' tests/run.uc <fixtures dir> <out dir>

'use strict';

import { readfile, writefile, mkdir, stat } from 'fs';
import { parse_link, parse_subscription } from 'xvpn.links';
import { parse_userinfo, assign_ids, list_change, known_ids, prune_no_auto, NO_AUTO_GRACE } from 'xvpn.subscription';
import { load_config, fastest, auto_pick, retry_delay, no_auto_ids, set_no_auto, mkdir_p, read_json, SUBS_DIR } from 'xvpn.util';
import { build_index, generate, ports_error, config_key, set_active } from 'xvpn.xrayconf';
import { render, resolve, fix_ifnames, ifnames_applied, table_names, rule_prefs, stale_routes } from 'xvpn.firewall';
import { ipv6_up, busy_ports } from 'xvpn.host';
import { cidr, parse_nets, domain_rule, direct_domains, direct_nets, lists_due_in } from 'xvpn.split';
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
eq('allowInsecure kept (xray 26 rejects the server, #14)', p[13].outbound.streamSettings.tlsSettings,
	{ serverName: 'ins.example.com', allowInsecure: true });
eq('pcs and vcn', p[14].outbound.streamSettings.tlsSettings, { serverName: 'pin.example.com',
	pinnedPeerCertSha256: '7b2d8f0c3a6e9b14d5f8a2c7e0b3d6f9a1c4e7b0d3f6a9c2e5b8d1f4a7c0e3b6', verifyPeerCertByName: 'pin.example.com' });
eq('vmess pcs and vcn', p[15].outbound.streamSettings.tlsSettings, { serverName: 'vp.example.com',
	pinnedPeerCertSha256: '7b2d8f0c3a6e9b14d5f8a2c7e0b3d6f9a1c4e7b0d3f6a9c2e5b8d1f4a7c0e3b6', verifyPeerCertByName: 'vp.example.com' });
ok('hashes unique', length(uniq(map(filter(p, (s) => !s.error), (s) => s.hash))) == 12);
eq('hash stable', parse_link(lines[0]).hash, p[0].hash);

// subscriptions
let b = parse_subscription(readfile(`${FIX}/sub-base64.txt`));
eq('base64 sub', [ b.format, length(b.servers), b.skipped ], [ 'base64', 9, 4 ]);
let pl = parse_subscription(readfile(`${FIX}/links.txt`));
eq('plain sub', [ pl.format, length(pl.servers) ], [ 'plain', 12 ]);
let xj = parse_subscription(readfile(`${FIX}/sub-xray.json`));
eq('xray json sub', [ xj.format, length(xj.servers), xj.skipped, xj.servers[0].name ], [ 'xray-json', 1, 1, '🇫🇮 Finland' ]);
ok('xray json drops sockopt', xj.servers[0].outbound.streamSettings.sockopt == null);
ok('clash rejected', match(parse_subscription('mixed-port: 7890\nproxies:\n').errors[0], /Clash/));
ok('html rejected', match(parse_subscription('<html></html>').errors[0], /HTML/));
eq('userinfo', parse_userinfo('upload=1; download=2; total=10737418240; expire=1798761600'),
	{ upload: 1, download: 2, total: 10737418240, expire: 1798761600 });

// stable ids (#49): the subscription hands out another host of some servers on every download
function vless(uuid, host, port, name) {
	return `vless://${uuid}@${host}:${port}?type=tcp&security=tls&sni=sni.example.com&fp=chrome#${name}`;
}
const U1 = '11111111-2222-3333-4444-555555555555', U2 = '66666666-7777-8888-9999-000000000000';
let v1 = assign_ids(parse_subscription(join('\n', [
	vless(U1, 'ee24.example.com', 443, '⚡ Estonia'),
	vless(U1, 'nl.example.com', 443, 'Netherlands'),
	vless(U1, 'de1.example.com', 443, 'Germany'),
	vless(U1, 'de2.example.com', 443, 'Germany'),
])).servers, 's1');
let v2 = assign_ids(parse_subscription(join('\n', [
	vless(U1, 'ee23.example.com', 8443, '⚡ Estonia'),
	vless(U1, 'nl.example.com', 443, 'Netherlands'),
	vless(U1, 'de1.example.com', 443, 'Germany'),
	vless(U1, 'de2.example.com', 443, 'Germany'),
])).servers, 's1');
eq('ids survive rotated hosts', map(v2, (s) => s.id), map(v1, (s) => s.id));
ok('rotated host changes the hash', v1[0].hash != v2[0].hash);
eq('rotated host reaches the outbound', v2[0].outbound.settings.vnext[0].address, 'ee23.example.com');
ok('same name and uuid: told apart by order', v1[2].id != v1[3].id);
ok('ids unique', length(uniq(map(v1, (s) => s.id))) == 4);
ok('id depends on the source', assign_ids([ v1[0] ], 's2')[0].id != v1[0].id);
eq('assign_ids keeps the hash of a cache from before #49', assign_ids([ { ...v1[1], hash: null, id: 'abcd0123' } ], 's1')[0].hash, 'abcd0123');
eq('nothing changed', list_change(v1, v1, [ v1[1].id ]), null);
eq('rotated host of the active server known by its hash (before #49): reload', list_change(v1, v2, [ v1[0].hash, null ]), 'reload');
let legacy = map(v1, (x) => ({ id: x.hash, name: x.name, proto: x.proto, address: x.address, port: x.port, outbound: x.outbound }));
eq('cache from before #49 (key order, id = hash): same entries', assign_ids(legacy, 's1'), v1);
let anon = assign_ids(parse_subscription(join('\n', [
	`vless://${U1}@a1.example.com:443?type=tcp&security=tls`, `vless://${U1}@a2.example.com:443?type=tcp&security=tls`,
])).servers, 's1');
let anon2 = assign_ids(parse_subscription(join('\n', [
	`vless://${U1}@b1.example.com:443?type=tcp&security=tls`, `vless://${U1}@b2.example.com:443?type=tcp&security=tls`,
])).servers, 's1');
eq('links without a name: named by address, ids by order', [ anon[0].name, map(anon2, (x) => x.id) ], [ 'a1.example.com:443', map(anon, (x) => x.id) ]);
eq('rotated host of an idle server: no reload', list_change(v1, v2, [ v1[1].id, '' ]), 'stale');
eq('rotated host of the active server: reload', list_change(v1, v2, [ v1[1].id, v1[0].id ]), 'reload');
eq('rotated host, xray runs another server than chosen: reload', list_change(v1, v2, [ v1[0].id, v1[1].id ]), 'reload');
let v3 = assign_ids(parse_subscription(join('\n', [
	vless(U1, 'ee23.example.com', 8443, '⚡ Estonia'),
	vless(U2, 'nl.example.com', 443, 'Netherlands'),
	vless(U1, 'de1.example.com', 443, 'Germany'),
	vless(U1, 'de2.example.com', 443, 'Germany'),
])).servers, 's1');
ok('new uuid: new id', v3[1].id != v2[1].id);
eq('new uuid: reload', list_change(v2, v3, [ v2[0].id ]), 'reload');
eq('new server: reload', list_change(v2, [ ...v2, ...assign_ids([ p[5] ], 's2') ], [ v2[0].id ]), 'reload');
eq('server gone: reload', list_change(v2, slice(v2, 0, 3), [ v2[0].id ]), 'reload');
eq('new order: no reload', list_change(v2, [ v2[1], v2[0], v2[2], v2[3] ], [ v2[0].id ]), 'stale');

// config generation
let cfg = {
	main: { tproxy_port: 12345, dns_port: 10853, api_port: 10085, control_port: 10086, test_port_base: 20000, loglevel: 'warning', sniffing: false,
		client_mark: 0x01000000, tproxy_mark: 0x02000000, route_table: 100,
		block_bittorrent: false, handshake: 4, conn_idle: 120, uplink_only: 2, downlink_only: 5, buffer_size: null },
	access: { dns_server: '1.1.1.1', killswitch: true, ipv6: 'block', dns_hijack: true },
};
let servers = [ ...assign_ids(b.servers, 's1'), ...assign_ids(xj.servers, 's2') ];
let idx = build_index(cfg, servers, servers[2].id);
eq('index active', idx.active, servers[2].id);
let mv = build_index(cfg, servers, servers[3].hash);
eq('index active by the hash (id before #49)', [ mv.active, mv.moved_from ], [ servers[3].id, servers[3].hash ]);
eq('index active found by id: not moved', build_index(cfg, servers, servers[3].id, idx).moved_from, null);
// renamed (or its subscription added again): another id, the hash from the running index
let renamed = [ ...servers ];
renamed[2] = { ...servers[2], id: 'feedf00d', name: 'renamed' };
let ri = build_index(cfg, renamed, servers[2].id, idx);
eq('index active renamed: found by the hash of the running index', [ ri.active, ri.moved_from ], [ 'feedf00d', servers[2].id ]);
eq('index active gone: first server, not moved', [ build_index(cfg, slice(servers, 3), servers[2].id, idx).active, build_index(cfg, slice(servers, 3), servers[2].id, idx).moved_from ], [ servers[3].id, null ]);
eq('index entries carry the hash', idx.servers[2].hash, servers[2].hash);
eq('index ports', [ idx.servers[0].test_port, idx.servers[9].test_port ], [ 20000, 20009 ]);
eq('index fallback active', build_index(cfg, servers, 'nope').active, servers[0].id);
let conf = generate(cfg, servers, idx);
// unmatched traffic goes nowhere; the clients reach the active server through the balancer,
// which the daemon points at another one without a restart (#13)
eq('default outbound is blackhole', conf.outbounds[0].tag, 'block');
eq('tags: no prefix of another', [ idx.servers[1].tag, idx.servers[2].tag ], [ 'srv-1.', 'srv-2.' ]);
eq('balancer of the active server', conf.routing.balancers, [ { tag: 'active', selector: [ 'srv-2.' ] } ]);
eq('tproxy route', conf.routing.rules[length(conf.routing.rules) - 1],
	{ type: 'field', inboundTag: [ 'tproxy', 'dns-in', 'udp-test' ], balancerTag: 'active' });
eq('inbounds', length(conf.inbounds), 4 + length(servers));
ok('no dns module for an IP', conf.dns == null);
// stats come from the metrics section over loopback HTTP (#7); the gRPC API only for the balancer
eq('metrics', conf.metrics, { tag: 'metrics' });
eq('api', conf.api, { tag: 'api', listen: '127.0.0.1:10086', services: [ 'RoutingService' ] });
// the UDP check (#10): the DNS server of the clients when it is an IP
eq('udp-test inbound', filter(conf.inbounds, (i) => i.tag == 'udp-test')[0],
	{ tag: 'udp-test', listen: '127.0.0.1', port: 10086, protocol: 'dokodemo-door', settings: { address: '1.1.1.1', port: 53, network: 'udp' } });
// another active server: the same key, no restart of xray; anything else: another key
let conf3 = generate(cfg, servers, build_index(cfg, servers, servers[3].id));
eq('balancer of another active server', conf3.routing.balancers[0].selector, [ 'srv-3.' ]);
eq('config key without the active server', config_key(conf3), config_key(conf));
ok('config key: the selector is kept', conf3.routing.balancers[0].selector[0] == 'srv-3.');
ok('config key with another server list', config_key(generate(cfg, slice(servers, 1), build_index(cfg, slice(servers, 1), servers[3].id))) != config_key(conf));
set_active(conf3, 'srv-2.');
eq('set_active', conf3, conf);
eq('metrics inbound', filter(conf.inbounds, (i) => i.tag == 'metrics')[0],
	{ tag: 'metrics', listen: '127.0.0.1', port: 10085, protocol: 'dokodemo-door', settings: { address: '127.0.0.1' } });
eq('metrics route', conf.routing.rules[0], { type: 'field', inboundTag: [ 'metrics' ], outboundTag: 'metrics' });
// session timeouts of level 0, the level of all inbounds (#15); bufferSize: xray's own
eq('policy level 0', conf.policy.levels['0'], { handshake: 4, connIdle: 120, uplinkOnly: 2, downlinkOnly: 5 });
ok('policy: inbounds of level 0', length(filter(conf.inbounds, (i) => i.settings?.userLevel)) == 0);
eq('policy: stats kept', conf.policy.system, { statsOutboundUplink: true, statsOutboundDownlink: true });
ok('no bittorrent block by default', length(filter(conf.routing.rules, (r) => r.protocol)) == 0);
eq('sniffing off', conf.inbounds[0].sniffing, { enabled: false });
writefile(`${OUT}/config.json`, sprintf('%J', conf));
// BitTorrent to blackhole before the route to the server; without sniffing the protocol is
// still detected, the IP is kept
cfg.main.block_bittorrent = true;
cfg.main.buffer_size = 4;
let bt = generate(cfg, servers, idx);
eq('bittorrent rule', bt.routing.rules[length(bt.routing.rules) - 2],
	{ type: 'field', inboundTag: [ 'tproxy' ], protocol: [ 'bittorrent' ], outboundTag: 'block' });
eq('bittorrent: route to the server last', bt.routing.rules[length(bt.routing.rules) - 1].balancerTag, 'active');
eq('bittorrent without sniffing: protocol only', bt.inbounds[0].sniffing, { enabled: true, destOverride: [] });
eq('buffer_size', bt.policy.levels['0'].bufferSize, 4);
cfg.main.sniffing = true;
eq('bittorrent with sniffing: domains as before', generate(cfg, servers, idx).inbounds[0].sniffing,
	{ enabled: true, destOverride: [ 'http', 'tls', 'quic' ], routeOnly: false });
writefile(`${OUT}/config-bt.json`, sprintf('%J', bt));
cfg.main.sniffing = false;
cfg.main.block_bittorrent = false;
cfg.main.buffer_size = null;

// dns_server as a URL: queries go through the xray DNS module by domain
cfg.access.dns_server = 'https://cloudflare-dns.com/dns-query';
let dconf = generate(cfg, servers, idx);
eq('doh module', dconf.dns, { tag: 'dns-module', servers: [ 'https://cloudflare-dns.com/dns-query' ], queryStrategy: 'UseIPv4' });
ok('dns-in to dns-out', length(filter(dconf.routing.rules, (r) => r.inboundTag[0] == 'dns-in' && r.outboundTag == 'dns-out')) == 1);
eq('doh route', dconf.routing.rules[length(dconf.routing.rules) - 1],
	{ type: 'field', inboundTag: [ 'tproxy', 'dns-module', 'udp-test' ], balancerTag: 'active' });
eq('default outbound with doh', dconf.outbounds[0].tag, 'block');
eq('doh: udp-test to a public DNS server', filter(dconf.inbounds, (i) => i.tag == 'udp-test')[0].settings.address, '1.1.1.1');
writefile(`${OUT}/config-doh.json`, sprintf('%J', dconf));
cfg.access.ipv6 = 'tunnel';
eq('doh UseIP with ipv6 tunnel', generate(cfg, servers, idx).dns.queryStrategy, 'UseIP');
cfg.access.ipv6 = 'block';
let nosrv = generate(cfg, [], build_index(cfg, [], null));
eq('doh without servers: blackhole by default', nosrv.outbounds[0].tag, 'block');
eq('without servers: no balancer', nosrv.routing.balancers, []);
ok('doh without servers: no dns-module rule', length(filter(nosrv.routing.rules, (r) => r.inboundTag[0] == 'tproxy')) == 0);
cfg.access.dns_server = '1.1.1.1';

// IPv6 off on the router: the inbounds listen on 0.0.0.0 (a kernel without IPv6 refuses ::)
let v4idx = build_index(cfg, servers, p[2].id, null, { ipv6: false, busy: { tcp: {}, udp: {} } });
let v4 = generate(cfg, servers, v4idx);
eq('no ipv6: tproxy and dns-in on 0.0.0.0', map(filter(v4.inbounds, (i) => i.tag in [ 'tproxy', 'dns-in' ]), (i) => i.listen),
	[ '0.0.0.0', '0.0.0.0' ]);
ok('no ipv6: nothing on ::', length(filter(v4.inbounds, (i) => index(i.listen, ':') >= 0)) == 0);
eq('ipv6 on: tproxy on ::', conf.inbounds[0].listen, '::');
ok('no ipv6, ipv6 block: no config error', v4idx.config_error == null);
cfg.access.ipv6 = 'tunnel';
ok('no ipv6, ipv6 tunnel: config error', match(build_index(cfg, servers, null, null, { ipv6: false }).config_error ?? '', /IPv6 is off/));
ok('ipv6 on, tunnel: no config error', build_index(cfg, servers, null, null, { ipv6: true }).config_error == null);
cfg.access.dns_server = 'https://cloudflare-dns.com/dns-query';
eq('no ipv6: doh UseIPv4 even with tunnel', generate(cfg, servers, v4idx).dns.queryStrategy, 'UseIPv4');
cfg.access.dns_server = '1.1.1.1';
let nft6 = render(cfg, { nets: [ 'br-guest' ], ports: [], ipv6: false });
ok('no ipv6, tunnel: no tproxy ip6', index(nft6, 'tproxy ip6') < 0);
ok('ipv6 on, tunnel: tproxy ip6', index(render(cfg, { nets: [], ports: [], ipv6: true }), 'tproxy ip6') >= 0);
writefile(`${OUT}/tunnel-noipv6.nft`, nft6);
cfg.access.killswitch = false;
ok('no ipv6, tunnel: ipv6 rejected like block', index(render(cfg, { nets: [], ports: [], ipv6: false }), 'meta nfproto ipv6 reject') >= 0);
cfg.access.killswitch = true;
cfg.access.ipv6 = 'block';
writefile(`${OUT}/config-noipv6.json`, sprintf('%J', v4));

// ports taken by other programs: test ports are skipped, the index keeps the real ones
let taken = { tcp: { '20000': true, '20002': true }, udp: { '20001': true } };
let pidx = build_index(cfg, servers, null, null, { ipv6: true, busy: taken });
eq('busy test ports skipped', map(slice(pidx.servers, 0, 3), (e) => e.test_port), [ 20001, 20003, 20004 ]);
eq('ports stay unique', length(uniq(map(pidx.servers, (e) => e.test_port))), length(servers));
eq('index keeps the main ports for the rules', pidx.ports, { tproxy: 12345, dns: 10853, api: 10085, control: 10086 });
eq('generate uses the index ports', map(filter(generate(cfg, servers, pidx).inbounds, (i) => i.tag == 'test-0'), (i) => i.port), [ 20001 ]);
let low = { ...cfg, main: { ...cfg.main, test_port_base: 10084 } };
eq('main ports skipped', map(slice(build_index(low, servers, null, null).servers, 0, 3), (e) => e.test_port), [ 10084, 10087, 10088 ]);
ok('main ports free', ports_error(cfg, { busy: taken }) == null);
ok('tproxy port taken (udp)', match(ports_error(cfg, { busy: { tcp: {}, udp: { '12345': true } } }) ?? '', /tproxy_port 12345/));
eq('api port: udp does not count', ports_error(cfg, { busy: { tcp: {}, udp: { '10085': true } } }), null);
ok('control port taken (udp)', match(ports_error(cfg, { busy: { tcp: {}, udp: { '10086': true } } }) ?? '', /control_port 10086/));
ok('api and dns taken', match(ports_error(cfg, { busy: { tcp: { '10085': true, '10853': true }, udp: {} } }) ?? '', /dns_port 10853, api_port 10085/));

// /proc as host.uc reads it
let proc = `${OUT}/proc`;
system([ 'mkdir', '-p', `${proc}/net`, `${proc}/sys/net/ipv6/conf/all`, `${proc}/100/fd`, `${proc}/200/fd` ]);
writefile(`${proc}/net/if_inet6`, '');
writefile(`${proc}/sys/net/ipv6/conf/all/disable_ipv6`, '0\n');
ok('no ipv6 address: off', !ipv6_up(proc));
writefile(`${proc}/net/if_inet6`, '00000000000000000000000000000001 01 80 10 80       lo\n');
ok('::1 on lo: on', ipv6_up(proc));
writefile(`${proc}/sys/net/ipv6/conf/all/disable_ipv6`, '1\n');
ok('disable_ipv6=1: off', !ipv6_up(proc));
ok('no if_inet6 (no IPv6 in the kernel): off', !ipv6_up(`${OUT}/nonexistent`));
let hdr = '  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode\n';
writefile(`${proc}/net/tcp`, hdr +
	'   0: 00000000:4E20 00000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 1001 1 0 100 0 0 10 0\n' +
	'   1: 0100007F:4E21 0100007F:9C40 01 00000000:00000000 00:00000000 00000000     0        0 1002 1 0 20 4 30 10 -1\n' +
	'   2: 00000000:3039 00000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 2001 1 0 100 0 0 10 0\n');
writefile(`${proc}/net/tcp6`, hdr +
	'   0: 00000000000000000000000000000000:4E22 00000000000000000000000000000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 1003 1 0 100 0 0 10 0\n');
writefile(`${proc}/net/udp`, hdr +
	'  10: 00000000:2A45 00000000:0000 07 00000000:00000000 00:00000000 00000000     0        0 2002 2 0 0\n');
// pid 200 is our xray (procd's `xray run -c /var/etc/xvpn/config.json`), 100 someone else
writefile(`${proc}/100/cmdline`, 'nc\0-l\0-p\x0020000\0');
writefile(`${proc}/200/cmdline`, '/usr/bin/xray\0run\0-c\0/var/etc/xvpn/config.json\0');
system([ 'ln', '-s', 'socket:[2001]', `${proc}/200/fd/3` ]);
system([ 'ln', '-s', 'socket:[2002]', `${proc}/200/fd/4` ]);
system([ 'ln', '-s', '/dev/null', `${proc}/200/fd/0` ]);
system([ 'ln', '-s', 'socket:[1001]', `${proc}/100/fd/3` ]);
eq('busy ports from /proc', busy_ports(proc), { tcp: { '20000': true, '20002': true }, udp: {} });

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

// ip rules: busybox prints them all, the mark without leading zeros, a trailing space and
// the table name from rt_tables; only `from all` with the exact pair is ours
let rules = '0:\tfrom all lookup local \n32760:\tfrom all fwmark 0x2000000/0x2000000 lookup 1000 \n' +
	'32761:\tfrom all fwmark 0x2000000/0x2000000 lookup 200 \n32762:\tfrom all fwmark 0x2000000/0x2000000 lookup 100 \n' +
	'32763:\tfrom 192.168.1.5 fwmark 0x2000000/0x2000000 lookup 100 \n32764:\tfrom all iif br-lan fwmark 0x2000000/0x2000000 lookup 100 \n' +
	'32765:\tfrom all fwmark 0x2000000/0x2000000 lookup 100\n32766:\tfrom all fwmark 0x2000000 lookup 100 \n' +
	'32767:\tfrom all fwmark 0x12000000/0x12000000 lookup 100 \n32768:\tfrom all fwmark 0x2000000/0x2000000 lookup xv.t \n';
eq('rule_prefs: ours and its duplicate, not someone\'s with more selectors', rule_prefs(rules, 0x02000000, [ '100' ]), [ 32762, 32765 ]);
eq('rule_prefs: table 1000 is not 100', rule_prefs(rules, 0x02000000, [ '200' ]), [ 32761 ]);
eq('rule_prefs: none', [ rule_prefs(rules, 0x04000000, [ '100' ]), rule_prefs('', 0x02000000, [ '100' ]), rule_prefs(null, 1, [ '1' ]) ], [ [], [], [] ]);
eq('rule_prefs: a named table', rule_prefs(rules, 0x02000000, [ '300', 'xv.t' ]), [ 32768 ]);
eq('rule_prefs: the dot is not any character', rule_prefs('1:\tfrom all fwmark 0x1/0x1 lookup xvxt ', 1, [ 'xv.t' ]), []);
let rt = '#\n# reserved values\n#\n255\tlocal\n254\tmain\n100 xvpn  # ours\n100\talias\n300 xv.t\n301 bad$name\n';
eq('table_names', [ table_names(rt, 100), table_names(rt, 300), table_names(rt, 301), table_names(null, 7) ],
	[ [ '100', 'xvpn', 'alias' ], [ '300', 'xv.t' ], [ '301' ], [ '7' ] ]);
let c100 = { mark: 0x02000000, table: 100 }, c200 = { mark: 0x02000000, table: 200 }, m4 = { mark: 0x04000000, table: 100 };
eq('stale: nothing applied', [ stale_routes(null, c100, true), stale_routes([ c100 ], c100, true) ], [ [], [] ]);
eq('stale: table changed', stale_routes([ c100 ], c200, true), [ { ...c100, route: true } ]);
eq('stale: mark changed, the table stays in use', stale_routes([ c100 ], m4, true), [ { ...c100, route: false } ]);
eq('stale: interrupted run, both', stale_routes([ c200, c100, m4 ], c200, true), [ { ...c100, route: true }, { ...m4, route: true } ]);
eq('stale: remove takes cur and the applied', stale_routes([ c200 ], c100, false), [ { ...c200, route: true }, { ...c100, route: true } ]);
eq('stale: remove without the file, duplicates once', [ stale_routes(null, c100, false), stale_routes([ c100 ], c100, false) ],
	[ [ { ...c100, route: true } ], [ { ...c100, route: true } ] ]);
eq('stale: a broken file is ignored', [ stale_routes({ mark: 1 }, c100, true), stale_routes([ { mark: '1', table: 2 }, 5 ], c100, true) ], [ [], [] ]);

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

// servers left out of auto selection (#60): best() in xvpnd skips them like the quarantined
let lat = { a: { ms: 300 }, b: { ms: 100 }, c: { ms: 200 }, d: { ms: -1 } };
let five = map([ 'a', 'b', 'c', 'd', 'e' ], (id) => ({ id }));
let skip = (off) => (e) => off[e.id];
eq('fastest', fastest(five, lat)?.id, 'b');
eq('fastest skips no_auto', fastest(five, lat, skip({ b: true }))?.id, 'c');
eq('fastest: dead and unmeasured are no candidates', fastest(five, lat, skip({ a: true, b: true, c: true })), null);

// limited servers (#61): left while there are others, quarantine weighs more than limited
let pk = (off, q, lim) => { let r = auto_pick(five, lat, off, q, lim); return r ? [ r.server.id, r.limited ] : null; };
eq('auto_pick: the fastest', pk({}, {}, {}), [ 'b', false ]);
eq('auto_pick skips limited', pk({}, {}, { b: 1 }), [ 'c', false ]);
eq('auto_pick: quarantined before limited', pk({}, { c: true }, { b: 1, a: 1 }), [ 'c', false ]);
eq('auto_pick: only limited ones answer: the fastest of them', pk({}, {}, { a: 1, b: 1, c: 1 }), [ 'b', true ]);
eq('auto_pick: limited out of quarantine first', pk({}, { b: true }, { a: 1, b: 1, c: 1 }), [ 'c', true ]);
eq('auto_pick: no_auto stays out', pk({ b: true, c: true }, {}, { a: 1 }), [ 'a', true ]);
eq('auto_pick: none', pk({ a: true, b: true, c: true }, {}, {}), null);
for (let v in [ [ null, 'https://cp.cloudflare.com/generate_204' ], [ 'off', null ], [ 'http://check2.test/', 'http://check2.test/' ] ]) {
	writefile(`${OUT}/dnscfg/xvpn`, "config health 'health'\n" + (v[0] ? `\toption url2 '${v[0]}'\n` : ''));
	eq(`url2 ${v[0]}`, load_config(`${OUT}/dnscfg`).health.url2, v[1]);
}
eq('url2_cdn by default', load_config(`${OUT}/dnscfg`).health.url2_cdn, 3);
// #11: the download check and the direct internet by several URLs
let hd = load_config(`${OUT}/dnscfg`).health;
eq('dl_url by default', [ hd.dl_url, hd.dl_interval, hd.dl_timeout ], [ 'https://speed.cloudflare.com/__down?bytes=65536', 300, 15 ]);
eq('wan_url by default: the check URL first', hd.wan_url,
	[ 'https://www.gstatic.com/generate_204', 'https://cp.cloudflare.com/generate_204', 'http://detectportal.firefox.com/success.txt' ]);
writefile(`${OUT}/dnscfg/xvpn`, "config health 'health'\n\toption dl_url 'off'\n\toption url 'https://cp.cloudflare.com/generate_204'\n\tlist wan_url 'http://a.test/'\n");
hd = load_config(`${OUT}/dnscfg`).health;
eq('dl_url off, wan_url set', [ hd.dl_url, hd.wan_url ], [ null, [ 'http://a.test/' ] ]);
writefile(`${OUT}/dnscfg/xvpn`, "config health 'health'\n\toption url 'https://cp.cloudflare.com/generate_204'\n");
eq('wan_url: no duplicates', length(load_config(`${OUT}/dnscfg`).health.wan_url), 2);
writefile(`${OUT}/dnscfg/xvpn`, "config health 'health'\n");
// policy (#15): hidden options, defaults without them
writefile(`${OUT}/dnscfg/xvpn`, "config general 'main'\n");
let pm = load_config(`${OUT}/dnscfg`).main;
eq('policy defaults', [ pm.handshake, pm.conn_idle, pm.uplink_only, pm.downlink_only, pm.buffer_size, pm.block_bittorrent ],
	[ 4, 120, 2, 5, null, false ]);
writefile(`${OUT}/dnscfg/xvpn`, "config general 'main'\n\toption conn_idle '30'\n\toption buffer_size '0'\n\toption block_bittorrent '1'\n");
pm = load_config(`${OUT}/dnscfg`).main;
eq('policy options', [ pm.conn_idle, pm.buffer_size, pm.block_bittorrent ], [ 30, 0, true ]);
writefile(`${OUT}/dnscfg/xvpn`, "config general 'main'\n\toption buffer_size 'big'\n");
eq('buffer_size not a number: xray default', load_config(`${OUT}/dnscfg`).main.buffer_size, null);

// no live servers (#12): the pause between tests of all servers doubles up to retry_max
let pauses = [], d = null;
for (let i = 0; i < 7; i++)
	push(pauses, d = retry_delay(d, 30, 600));
eq('retry_delay doubles up to the max', pauses, [ 30, 60, 120, 240, 480, 600, 600 ]);
eq('retry_delay: a max below interval is interval', [ retry_delay(null, 30, 10), retry_delay(30, 30, 10) ], [ 30, 30 ]);
eq('retry_delay: a smaller max is applied at once', retry_delay(480, 30, 120), 120);

writefile(`${confdir}/xvpn`, `
config health 'health'
	option interval '30'
	list no_auto 'gone1'
	list no_auto '${servers[0].id}'
	list no_auto 'gone2'

config manual 'manual'
	list link '${lines[0]}'
`);
let xcur = () => cursor(confdir, `${OUT}/delta`);
eq('no_auto read', no_auto_ids(xcur()), [ 'gone1', servers[0].id, 'gone2' ]);
let mcfg = load_config(confdir);
let man = known_ids({ subscriptions: [ { id: 'nocache' } ], manual: mcfg.manual });
eq('known ids: the manual links, a subscription without a cache has none',
	keys(man), [ assign_ids([ parse_link(lines[0]) ], 'manual')[0].id ]);
// the cache of a disabled subscription with filters that match nothing: its servers are still known
mkdir_p(SUBS_DIR);
writefile(`${SUBS_DIR}/xvpntest.json`, sprintf('%J', { servers: b.servers }));
let off_sub = known_ids({ subscriptions: [ { id: 'xvpntest', enabled: false, include: 'nothing', exclude: '.' } ], manual: [] });
system([ 'rm', '-f', `${SUBS_DIR}/xvpntest.json` ]);
eq('known ids: a disabled subscription, before include/exclude', sort(keys(off_sub)), sort(map(assign_ids(b.servers, 'xvpntest'), (s) => s.id)));

// a server gone from the subscriptions keeps its flag NO_AUTO_GRACE: a stub list for a while
let gone = `${OUT}/no_auto_gone.json`, T = 1800000000;
let known = { ...man, [servers[0].id]: true };
let ino = () => stat(`${confdir}/xvpn`).inode;
let i0 = ino();
eq('gone: nothing dropped at once', prune_no_auto(xcur(), known, gone, T), []);
eq('gone: since when', [ no_auto_ids(xcur()), read_json(gone) ], [ [ 'gone1', servers[0].id, 'gone2' ], { gone1: T, gone2: T } ]);
ok('gone: no commit', ino() == i0);
eq('back in the list: its time goes', [ prune_no_auto(xcur(), { ...known, gone2: true }, gone, T + 100), read_json(gone) ], [ [], { gone1: T } ]);
eq('a clock set back starts over', [ prune_no_auto(xcur(), known, gone, T - 100), read_json(gone) ], [ [], { gone1: T - 100, gone2: T - 100 } ]);
eq('gone for the grace: dropped', prune_no_auto(xcur(), known, gone, T - 100 + NO_AUTO_GRACE), [ 'gone1', 'gone2' ]);
eq('prune keeps the ids that are there', [ no_auto_ids(xcur()), read_json(gone) ], [ [ servers[0].id ], null ]);
i0 = ino();
eq('nothing to prune', prune_no_auto(xcur(), known, gone, T), []);
ok('nothing to prune: no commit', ino() == i0);
eq('other options stay', xcur().get('xvpn', 'health', 'interval'), '30');
let xc = xcur();
xc.set('xvpn', 'health', 'interval', '60');
xc.save('xvpn');
eq('uncommitted changes: no commit', [ set_no_auto(xcur(), []), cursor(confdir, `${OUT}/empty-delta`).get('xvpn', 'health', 'no_auto') ],
	[ 'xvpn has uncommitted changes', [ servers[0].id ] ]);
eq('uncommitted changes: nothing pruned, the time kept', [ prune_no_auto(xcur(), {}, gone, T), prune_no_auto(xcur(), {}, gone, T + NO_AUTO_GRACE), read_json(gone) ],
	[ [], [], { [servers[0].id]: T } ]);
system([ 'rm', '-f', `${OUT}/delta/xvpn`, gone ]);	// the change is dropped
eq('the last id goes: the option goes', [ set_no_auto(xcur(), []), xcur().get('xvpn', 'health', 'no_auto') ], [ null, null ]);
writefile(`${confdir}/xvpn`, "config manual 'manual'\n");
eq('no health section: it is made', [ set_no_auto(xcur(), [ 'x' ]), no_auto_ids(xcur()) ], [ null, [ 'x' ] ]);

// split tunneling (#67)
eq('cidr: host bits cleared', [ cidr('10.1.2.3/8'), cidr('203.0.113.7'), cidr(' 2001:db8::1/32 '), cidr('2001:db8::1') ],
	[ { v6: false, net: '10.0.0.0/8' }, { v6: false, net: '203.0.113.7' }, { v6: true, net: '2001:db8::/32' }, { v6: true, net: '2001:db8::1' } ]);
eq('cidr: odd prefix', cidr('192.168.255.255/17'), { v6: false, net: '192.168.128.0/17' });
eq('cidr: bad ones', map([ '1.2.3', '1.2.3.4/33', '0.0.0.0/0', '::/0', '1.2.3.4/', 'example.ru', '1.2.3.256', '', null, 'fe80::1/129', '1.2.3.4/24/1' ], cidr),
	[ null, null, null, null, null, null, null, null, null, null, null ]);
eq('parse_nets: comments, blanks, CRLF, bad', parse_nets('# ipdeny\r\n2.60.0.0/16\r\n\n5.3.0.0/16 ; x\n2a00:1fa0::/29\n<html>\n'),
	{ v4: [ '2.60.0.0/16', '5.3.0.0/16' ], v6: [ '2a00:1fa0::/29' ], bad: 1 });
eq('domain_rule', map([ 'Example.RU', 'ru', 'full:www.example.ru', 'domain:ya.ru', '*.vk.com', '.ok.ru', 'xn--p1ai' ], domain_rule),
	[ 'domain:example.ru', 'domain:ru', 'full:www.example.ru', 'domain:ya.ru', 'domain:vk.com', 'domain:ok.ru', 'domain:xn--p1ai' ]);
eq('domain_rule: bad ones', map([ 'regexp:.*', 'keyword:ya', 'exa mple.ru', 'ex_ample.ru', '-a.ru', 'a..ru', 'пример.рф', '', 'full:' ], domain_rule),
	[ null, null, null, null, null, null, null, null, null ]);
let scfg = { ...cfg, access: { ...cfg.access, ipv6: 'block', killswitch: true, dns_server: '1.1.1.1' },
	split: { ip: [ '45.0.0.4', '45.0.0.4/32', 'bad', '2001:db8::/32' ], domain: [ 'example.ru', 'EXAMPLE.ru', 'bad domain', 'full:www.ya.ru' ], ru: true, ru_interval: 168, ru_url: [] } };
eq('direct_domains: normalized, no duplicates, bad skipped', direct_domains(scfg), [ 'domain:example.ru', 'full:www.ya.ru' ]);
writefile(`${OUT}/ru.txt`, '2.60.0.0/16\n45.0.0.4\n2a00:1fa0::/29\n');
eq('direct_nets: own list and the cache', direct_nets(scfg, `${OUT}/ru.txt`),
	{ v4: [ '45.0.0.4', '2.60.0.0/16' ], v6: [ '2001:db8::/32', '2a00:1fa0::/29' ] });
eq('direct_nets: list off, no cache read', direct_nets({ split: { ...scfg.split, ru: false } }, `${OUT}/ru.txt`),
	{ v4: [ '45.0.0.4' ], v6: [ '2001:db8::/32' ] });
eq('direct_nets: no cache yet', direct_nets({ split: { ip: [], ru: true } }, `${OUT}/none.txt`), { v4: [], v6: [] });
eq('load_config: split defaults', load_config(`${OUT}/dnscfg`).split, { ip: [], domain: [], ru: false, ru_interval: 168, ru_url: [] });
let T0 = time();
ok('lists due: off', lists_due_in({ split: { ru: false } }, {}) == null);
ok('lists due: never downloaded', lists_due_in(scfg, {}) <= 0);
ok('lists due: fresh', lists_due_in(scfg, { last_ok: T0 - 3600 }) > 0);
ok('lists due: old', lists_due_in(scfg, { last_ok: T0 - 169 * 3600 }) <= 0);
ok('lists due: failed, retry later', lists_due_in(scfg, { last_ok: T0 - 169 * 3600, last_attempt: T0 - 60, error: 'x' }) > 0);
ok('lists due: failed long ago', lists_due_in(scfg, { last_attempt: T0 - 3600, error: 'x' }) <= 0);

let sres = { nets: [ 'br-guest' ], ports: [ 'lan2' ], ipv6: true, direct: direct_nets(scfg, `${OUT}/ru.txt`) };
let snft = render(scfg, sres);
let chain = (t, name) => {
	let c = substr(t, index(t, `chain ${name} {`));
	return substr(c, 0, index(c, '\n\t}'));
};
ok('split: sets filled', index(snft, 'set direct4 { type ipv4_addr; flags interval; auto-merge; elements = { 45.0.0.4, 2.60.0.0/16 }; }') >= 0
	&& index(snft, 'elements = { 2001:db8::/32, 2a00:1fa0::/29 }') >= 0);
let icp = chain(snft, 'intercept');
ok('split: direct before tproxy', index(icp, 'ip daddr @direct4 return') > 0 && index(icp, 'ip daddr @direct4 return') < index(icp, 'tproxy ip to'));
ok('split: dns hijack before direct', index(icp, 'th dport 53 return') < index(icp, '@direct4'));
let gfw = chain(snft, 'guard_forward');
ok('split: kill switch lets direct through', index(gfw, 'ip daddr @direct4 return') > 0 && index(gfw, 'ip6 daddr @direct6 return') > 0
	&& index(gfw, '@direct6') < index(gfw, 'reject'));
writefile(`${OUT}/split.nft`, snft);
let spass = render(scfg, sres, { passthrough: true });
ok('split passthrough: direct6 before the IPv6 reject', index(chain(spass, 'guard_forward'), '@direct6') < index(chain(spass, 'guard_forward'), 'meta nfproto ipv6 reject'));
writefile(`${OUT}/split-passthrough.nft`, spass);
let sblk = render(scfg, sres, { block: true });
ok('split block: no lists', index(sblk, 'direct') < 0);
ok('split minimal: no lists', index(render(scfg, sres, { minimal: true }), 'direct') < 0);
let snone = render(scfg, { ...sres, direct: { v4: [], v6: [] } });
ok('split: empty lists, sets but no rules', index(snone, 'set direct4') >= 0 && index(snone, '@direct') < 0);
// a country-sized list: nft -c takes it and the time it needs is seen in the test log
let big = [];
for (let i = 0; i < 12000; i++)
	push(big, sprintf('%d.%d.%d.0/24', 1 + (i >> 16), (i >> 8) & 255, i & 255));
writefile(`${OUT}/split-big.nft`, render(scfg, { ...sres, direct: { v4: big, v6: [ '2a00::/12' ] } }));

let sconf = generate(scfg, servers, idx);
let srule = filter(sconf.routing.rules, (r) => r.outboundTag == 'direct');
eq('split xray: domain rule', srule, [ { type: 'field', inboundTag: [ 'tproxy' ], domain: [ 'domain:example.ru', 'full:www.ya.ru' ], outboundTag: 'direct' } ]);
eq('split xray: freedom AsIs', filter(sconf.outbounds, (o) => o.tag == 'direct'), [ { tag: 'direct', protocol: 'freedom' } ]);
let rtags = map(sconf.routing.rules, (r) => r.outboundTag);
ok('split xray: before the rule of the active server', index(rtags, 'direct') == length(rtags) - 2 && sconf.routing.rules[-1].balancerTag == 'active');
writefile(`${OUT}/config-split.json`, sprintf('%J', sconf));
let nodom = generate({ ...scfg, split: { ...scfg.split, domain: [] } }, servers, idx);
ok('split xray: no domains, no direct outbound', !length(filter(nodom.outbounds, (o) => o.tag == 'direct')));

print(`${passed} passed, ${failed} failed\n`);
exit(failed ? 1 : 0);
