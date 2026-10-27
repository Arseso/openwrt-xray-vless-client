// SPDX-License-Identifier: MIT
// Builds the xray config: one outbound per server with its own loopback SOCKS
// test inbound; tproxy and DNS inbounds are routed to the active server.

'use strict';

// env (host.uc host_env(); null: IPv6 on, all ports free): { ipv6, busy }.
// Test ports taken by other programs (or by our main ports) are skipped: each server keeps
// the port it got in the index. ipv6: false makes the inbounds listen on 0.0.0.0, a bind
// on :: would fail; with ipv6 = tunnel that is a config error the status shows.
export function build_index(cfg, servers, active_id, env) {
	let m = cfg.main, busy = env?.busy?.tcp ?? {}, port = m.test_port_base, index = [];
	let main = { [m.tproxy_port]: true, [m.dns_port]: true, [m.api_port]: true };
	for (let i, s in servers) {
		while (busy[port] || main[port])
			port++;
		push(index, {
			id: s.id, name: s.name, proto: s.proto, address: s.address, port: s.port,
			sub: s.sub, sub_name: s.sub_name,
			tag: `srv-${i}`, test_port: port++,
		});
	}

	let active = filter(index, (e) => e.id == active_id)[0] ?? index[0];
	// the rules (fw-apply), the daemon and rpcd go by the ports and IPv6 of the config xray runs
	let r = {
		active: active?.id, servers: index, ipv6: env?.ipv6 ?? true,
		ports: { tproxy: m.tproxy_port, dns: m.dns_port, api: m.api_port },
	};
	if (!r.ipv6 && cfg.access.ipv6 == 'tunnel')
		r.config_error = 'ipv6 is set to tunnel, but IPv6 is off on the router (disable_ipv6 or no IPv6 address): set ipv6 to block or turn IPv6 on';
	return r;
};

// The main ports xray needs, taken by other programs: an error for the status
// (xray could not start with them), null when they are free.
export function ports_error(cfg, env) {
	let m = cfg.main, tcp = env?.busy?.tcp ?? {}, udp = env?.busy?.udp ?? {}, taken = [];
	for (let p in [ [ 'tproxy_port', true ], [ 'dns_port', true ], [ 'api_port', false ] ]) {
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
			sniffing: m.sniffing
				? { enabled: true, destOverride: [ 'http', 'tls', 'quic' ], routeOnly: false }
				: { enabled: false },
		},
		{
			tag: 'dns-in', listen, port: m.dns_port, protocol: 'dokodemo-door',
			// with the DNS module the address is a placeholder: dns-out answers A/AAAA itself
			settings: { address: doh ? '1.1.1.1' : cfg.access.dns_server, port: 53, network: 'tcp,udp' },
		},
		{
			tag: 'api', listen: '127.0.0.1', port: m.api_port, protocol: 'dokodemo-door',
			settings: { address: '127.0.0.1' },
		},
	];

	let outbounds = [];
	let rules = [ { type: 'field', inboundTag: [ 'api' ], outboundTag: 'api' } ];

	for (let i, e in idx.servers) {
		push(inbounds, {
			tag: `test-${i}`, listen: '127.0.0.1', port: e.test_port, protocol: 'socks',
			settings: { auth: 'noauth', udp: false },
		});
		push(outbounds, { ...servers[i].outbound, tag: e.tag });
		push(rules, { type: 'field', inboundTag: [ `test-${i}` ], outboundTag: e.tag });
	}

	// unmatched traffic never leaves directly
	push(outbounds, { tag: 'block', protocol: 'blackhole' });
	if (doh) {
		// other query types (TXT, HTTPS…) would go to an IP: drop them; never 'skip' —
		// dns-out would send them to the placeholder address itself, around the tunnel
		push(outbounds, { tag: 'dns-out', protocol: 'dns', settings: { nonIPQuery: 'drop' } });
		push(rules, { type: 'field', inboundTag: [ 'dns-in' ], outboundTag: 'dns-out' });
	}
	if (active) {
		push(rules, { type: 'field', inboundTag: doh ? [ 'tproxy', 'dns-module' ] : [ 'tproxy', 'dns-in' ],
			outboundTag: active.tag });
		// the first outbound is the default one
		let pos = filter(outbounds, (o) => o.tag == active.tag)[0];
		outbounds = [ pos, ...filter(outbounds, (o) => o.tag != active.tag) ];
	}

	let conf = {
		log: { loglevel: m.loglevel, access: 'none' },
		api: { tag: 'api', services: [ 'StatsService' ] },
		stats: {},
		policy: { system: { statsOutboundUplink: true, statsOutboundDownlink: true } },
		inbounds,
		outbounds,
		routing: { domainStrategy: 'AsIs', rules },
	};
	if (doh)
		conf.dns = {
			tag: 'dns-module', servers: [ cfg.access.dns_server ],
			// without IPv6 on the router AAAA answers are of no use to the clients
			queryStrategy: (cfg.access.ipv6 == 'block' || !(idx.ipv6 ?? true)) ? 'UseIPv4' : 'UseIP',
		};
	return conf;
};
