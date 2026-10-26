// SPDX-License-Identifier: MIT
// Builds the xray config: one outbound per server with its own loopback SOCKS
// test inbound; tproxy and DNS inbounds are routed to the active server.

'use strict';

export function build_index(cfg, servers, active_id) {
	let index = [];
	for (let i, s in servers)
		push(index, {
			id: s.id, name: s.name, proto: s.proto, address: s.address, port: s.port,
			sub: s.sub, sub_name: s.sub_name,
			tag: `srv-${i}`, test_port: cfg.main.test_port_base + i,
		});

	let active = filter(index, (e) => e.id == active_id)[0] ?? index[0];
	return { active: active?.id, servers: index };
};

export function generate(cfg, servers, index) {
	let m = cfg.main;
	let active = filter(index.servers, (e) => e.id == index.active)[0];

	let inbounds = [
		{
			tag: 'tproxy', listen: '::', port: m.tproxy_port, protocol: 'dokodemo-door',
			settings: { network: 'tcp,udp', followRedirect: true },
			streamSettings: { sockopt: { tproxy: 'tproxy' } },
			sniffing: m.sniffing
				? { enabled: true, destOverride: [ 'http', 'tls', 'quic' ], routeOnly: false }
				: { enabled: false },
		},
		{
			tag: 'dns-in', listen: '::', port: m.dns_port, protocol: 'dokodemo-door',
			settings: { address: cfg.access.dns_server, port: 53, network: 'tcp,udp' },
		},
		{
			tag: 'api', listen: '127.0.0.1', port: m.api_port, protocol: 'dokodemo-door',
			settings: { address: '127.0.0.1' },
		},
	];

	let outbounds = [];
	let rules = [ { type: 'field', inboundTag: [ 'api' ], outboundTag: 'api' } ];

	for (let i, e in index.servers) {
		push(inbounds, {
			tag: `test-${i}`, listen: '127.0.0.1', port: e.test_port, protocol: 'socks',
			settings: { auth: 'noauth', udp: false },
		});
		push(outbounds, { ...servers[i].outbound, tag: e.tag });
		push(rules, { type: 'field', inboundTag: [ `test-${i}` ], outboundTag: e.tag });
	}

	// unmatched traffic never leaves directly
	push(outbounds, { tag: 'block', protocol: 'blackhole' });
	if (active) {
		push(rules, { type: 'field', inboundTag: [ 'tproxy', 'dns-in' ], outboundTag: active.tag });
		// the first outbound is the default one
		let pos = filter(outbounds, (o) => o.tag == active.tag)[0];
		outbounds = [ pos, ...filter(outbounds, (o) => o.tag != active.tag) ];
	}

	return {
		log: { loglevel: m.loglevel, access: 'none' },
		api: { tag: 'api', services: [ 'StatsService' ] },
		stats: {},
		policy: { system: { statsOutboundUplink: true, statsOutboundDownlink: true } },
		inbounds,
		outbounds,
		routing: { domainStrategy: 'AsIs', rules },
	};
};
