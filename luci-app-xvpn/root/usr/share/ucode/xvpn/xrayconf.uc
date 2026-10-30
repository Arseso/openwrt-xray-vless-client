// SPDX-License-Identifier: MIT
// Builds the xray config: one outbound per server with its own loopback SOCKS
// test inbound; tproxy and DNS inbounds are routed to the active server through the
// balancer "active", which the daemon points at another server without a restart (#13).

'use strict';

import { direct_domains } from 'xvpn.split';

// prev: the index of the running config. The chosen server keeps the choice when its id
// changes but the connection (hash) does not: renamed, its subscription removed and added
// again, or the subscription disabled while another lists the same server. active_id
// itself may be a hash too: ids from before #49 were the hash. moved_from: the id the
// choice was found for that way (cli.uc generate and the daemon move the choice over).
// env (host.uc host_env(); null: IPv6 on, all ports free): { ipv6, busy }.
// Test ports taken by other programs (or by our main ports) are skipped: each server keeps
// the port it got in the index. ipv6: false makes the inbounds listen on 0.0.0.0 (a kernel
// without IPv6 refuses ::); with ipv6 = tunnel that is a config error the status shows.
export function build_index(cfg, servers, active_id, prev, env) {
	let m = cfg.main, busy = env?.busy?.tcp ?? {}, port = m.test_port_base, index = [];
	let main = { [m.tproxy_port]: true, [m.dns_port]: true, [m.api_port]: true, [m.control_port]: true };
	for (let i, s in servers) {
		while (busy[port] || main[port])
			port++;
		push(index, {
			id: s.id, hash: s.hash, name: s.name, proto: s.proto, address: s.address, port: s.port,
			sub: s.sub, sub_name: s.sub_name,
			// the balancer selects by prefix: "srv-1." is no prefix of "srv-10."
			tag: `srv-${i}.`, test_port: port++,
		});
	}

	let active = filter(index, (e) => e.id == active_id)[0], moved_from = null;
	if (!active && active_id) {
		let hash = filter(prev?.servers ?? [], (e) => e.id == active_id)[0]?.hash ?? active_id;
		active = filter(index, (e) => e.hash == hash)[0];
		if (active)
			moved_from = active_id;
	}
	active ??= index[0];
	// the rules (fw-apply), the daemon and rpcd go by the ports and IPv6 of the config xray runs
	let r = {
		active: active?.id, moved_from, servers: index, ipv6: env?.ipv6 ?? true,
		ports: { tproxy: m.tproxy_port, dns: m.dns_port, api: m.api_port, control: m.control_port },
	};
	if (!r.ipv6 && cfg.access.ipv6 == 'tunnel')
		r.config_error = 'ipv6 is set to tunnel, but IPv6 is off on the router (disable_ipv6 or no IPv6 address): set ipv6 to block or turn IPv6 on';
	return r;
};

// The main ports xray needs, taken by other programs: an error for the status
// (xray could not start with them), null when they are free.
export function ports_error(cfg, env) {
	let m = cfg.main, tcp = env?.busy?.tcp ?? {}, udp = env?.busy?.udp ?? {}, taken = [];
	for (let p in [ [ 'tproxy_port', true ], [ 'dns_port', true ], [ 'api_port', false ], [ 'control_port', true ] ]) {
		let n = m[p[0]];
		if (tcp[n] || (p[1] && udp[n]))
			push(taken, `${p[0]} ${n}`);
	}
	return length(taken)
		? `taken by another program: ${join(', ', taken)}; free it or change the port in the settings`
		: null;
};

// a URL (https://, tcp://; load_config drops the others) is resolved by the xray DNS
// module: its queries reach the server by domain, so they pass servers that refuse
// IP destinations
export function dns_via_module(cfg) {
	return index(cfg.access.dns_server, '://') > 0;
};

// Where the UDP check sends its DNS query (#10): the DNS server of the clients when it is
// an IP (their queries go there over UDP through the tunnel), else a public one
export function udp_target(cfg) {
	return dns_via_module(cfg) ? '1.1.1.1' : cfg.access.dns_server;
};

// Points the balancer at the server with tag: generate, and the daemon on a switch
// without a restart (it changes the running xray with `xray api bo` and the file for the
// next start). The config key (see config_key()) leaves this out.
export function set_active(conf, tag) {
	for (let b in conf.routing?.balancers ?? [])
		if (b.tag == 'active')
			b.selector = [ tag ];
};

// What a restart of xray depends on: the config without the server the balancer points at
export function config_key(conf) {
	let b = filter(conf.routing?.balancers ?? [], (b) => b.tag == 'active')[0], sel = b?.selector;
	if (b)
		b.selector = [];
	let s = sprintf('%J', conf);
	if (b)
		b.selector = sel;
	return s;
};

export function generate(cfg, servers, idx) {
	let m = cfg.main;
	let active = filter(idx.servers, (e) => e.id == idx.active)[0];
	let doh = dns_via_module(cfg);
	let listen = (idx.ipv6 ?? true) ? '::' : '0.0.0.0';

	let inbounds = [
		{
			tag: 'tproxy', listen, port: m.tproxy_port, protocol: 'dokodemo-door',
			settings: { network: 'tcp,udp', followRedirect: true },
			streamSettings: { sockopt: { tproxy: 'tproxy' } },
			// without sniffing a BitTorrent block still needs the protocol: detected, IP kept
			sniffing: m.sniffing
				? { enabled: true, destOverride: [ 'http', 'tls', 'quic' ], routeOnly: false }
				: (m.block_bittorrent ? { enabled: true, destOverride: [] } : { enabled: false }),
		},
		{
			tag: 'dns-in', listen, port: m.dns_port, protocol: 'dokodemo-door',
			// with the DNS module the address is a placeholder: dns-out answers A/AAAA itself
			settings: { address: doh ? '1.1.1.1' : cfg.access.dns_server, port: 53, network: 'tcp,udp' },
		},
		// HTTP of the metrics section (/debug/vars: traffic counters), read by rpcd stats without
		// starting xray; xray 25.1.30 has no metrics.listen, the inbound is the only way
		{
			tag: 'metrics', listen: '127.0.0.1', port: m.api_port, protocol: 'dokodemo-door',
			settings: { address: '127.0.0.1' },
		},
		// the UDP check of the daemon (#10): a DNS query over UDP through the active server;
		// the same number as the gRPC API (TCP) below
		{
			tag: 'udp-test', listen: '127.0.0.1', port: m.control_port, protocol: 'dokodemo-door',
			settings: { address: udp_target(cfg), port: 53, network: 'udp' },
		},
	];

	let outbounds = [];
	let rules = [ { type: 'field', inboundTag: [ 'metrics' ], outboundTag: 'metrics' } ];

	for (let i, e in idx.servers) {
		push(inbounds, {
			tag: `test-${i}`, listen: '127.0.0.1', port: e.test_port, protocol: 'socks',
			settings: { auth: 'noauth', udp: false },
		});
		push(outbounds, { ...servers[i].outbound, tag: e.tag });
		push(rules, { type: 'field', inboundTag: [ `test-${i}` ], outboundTag: e.tag });
	}

	// unmatched traffic never leaves directly: blackhole is the first outbound, the default
	unshift(outbounds, { tag: 'block', protocol: 'blackhole' });
	if (doh) {
		// other query types (TXT, HTTPS…) would go to an IP: drop them; never 'skip' —
		// dns-out would send them to the placeholder address itself, around the tunnel
		push(outbounds, { tag: 'dns-out', protocol: 'dns', settings: { nonIPQuery: 'drop' } });
		push(rules, { type: 'field', inboundTag: [ 'dns-in' ], outboundTag: 'dns-out' });
	}
	if (m.block_bittorrent)
		push(rules, { type: 'field', inboundTag: [ 'tproxy' ], protocol: [ 'bittorrent' ], outboundTag: 'block' });
	// split tunneling (#67): clients' connections to these domains (found by sniffing) go out
	// from the router without the tunnel; freedom resolves them AsIs, with the router's
	// resolver, like a router without VPN: the connection is direct anyway, and the provider's
	// DNS gives its nearby CDN. The clients' own DNS still goes through the tunnel
	let direct = direct_domains(cfg);
	if (length(direct)) {
		push(outbounds, { tag: 'direct', protocol: 'freedom' });
		push(rules, { type: 'field', inboundTag: [ 'tproxy' ], domain: direct, outboundTag: 'direct' });
	}
	let balancers = [];
	if (active) {
		// "active" selects that one server; the daemon overrides the choice (`xray api bo`), and
		// the connections already open go on through the server they went to (#13)
		push(balancers, { tag: 'active', selector: [ active.tag ] });
		push(rules, { type: 'field', inboundTag: doh ? [ 'tproxy', 'dns-module', 'udp-test' ] : [ 'tproxy', 'dns-in', 'udp-test' ],
			balancerTag: 'active' });
	}

	// all inbounds are of level 0 (xray's default userLevel); a torrent client behind the
	// router opens thousands of sessions, each held until connIdle (#15, DESIGN.md 6.4)
	let level = {
		handshake: m.handshake, connIdle: m.conn_idle, uplinkOnly: m.uplink_only, downlinkOnly: m.downlink_only,
	};
	if (m.buffer_size != null)
		level.bufferSize = m.buffer_size;

	let conf = {
		log: { loglevel: m.loglevel, access: 'none' },
		metrics: { tag: 'metrics' },
		stats: {},
		policy: { levels: { '0': level }, system: { statsOutboundUplink: true, statsOutboundDownlink: true } },
		// RoutingService for the balancer override, only on 127.0.0.1
		api: { tag: 'api', listen: `127.0.0.1:${m.control_port}`, services: [ 'RoutingService' ] },
		inbounds,
		outbounds,
		routing: { domainStrategy: 'AsIs', rules, balancers },
	};
	if (doh)
		conf.dns = {
			tag: 'dns-module', servers: [ cfg.access.dns_server ],
			// without IPv6 on the router AAAA answers are of no use to the clients
			queryStrategy: (cfg.access.ipv6 == 'block' || !(idx.ipv6 ?? true)) ? 'UseIPv4' : 'UseIP',
		};
	return conf;
};
