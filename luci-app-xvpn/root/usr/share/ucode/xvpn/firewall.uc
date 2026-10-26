// SPDX-License-Identifier: MIT
// nftables rules (tables inet xvpn / bridge xvpn) and policy routing for TPROXY.

'use strict';

import { cursor } from 'uci';
import { NFT_FILE, VAR_DIR, IFNAMES_FILE, mkdir_p, read_json, write_json, write_file, run, log } from 'xvpn.util';

const BYPASS4 = [
	'0.0.0.0/8', '10.0.0.0/8', '100.64.0.0/10', '127.0.0.0/8', '169.254.0.0/16',
	'172.16.0.0/12', '192.0.0.0/24', '192.0.2.0/24', '192.168.0.0/16', '198.18.0.0/15',
	'198.51.100.0/24', '203.0.113.0/24', '224.0.0.0/4', '240.0.0.0/4',
];
const BYPASS6 = [ '::/128', '::1/128', '64:ff9b:1::/48', 'fc00::/7', 'fe80::/10', 'ff00::/8' ];

function hex32(n) {
	return sprintf('0x%08x', n);
}

function elements(list, quote) {
	if (!length(list))
		return '';
	return sprintf('elements = { %s }; ', join(', ', map(list, (e) => quote ? `"${e}"` : e)));
}

// Resolves access points to device names:
//   networks -> L3 devices (br-guest), wifi sections -> ifnames (phy1-ap0), ports as is.
// A wifi that is not up yet (boot, reconfiguration) gets its last known ifname from
// ifnames_file or the configured one: its clients must not slip past the rules meanwhile.
export function resolve(cfg, ubus_conn, ifnames_file) {
	let nets = [], ports = [ ...cfg.access.ports ];
	let uci = cursor();

	if (length(cfg.access.networks)) {
		let dump = ubus_conn?.call('network.interface', 'dump') ?? {};
		for (let name in cfg.access.networks) {
			let ifc = filter(dump.interface ?? [], (i) => i.interface == name)[0];
			let dev = ifc?.l3_device ?? ifc?.device ?? uci.get('network', name, 'device');
			if (dev)
				push(nets, dev);
			else
				log(`network "${name}" has no device, skipped`);
		}
	}

	if (length(cfg.access.wifi)) {
		let st = ubus_conn?.call('network.wireless', 'status') ?? {};
		let file = ifnames_file ?? IFNAMES_FILE;
		let known = read_json(file) ?? {}, next = {}, fresh = false;
		for (let section in cfg.access.wifi) {
			let found = null;
			for (let radio, r in st)
				for (let i in (r.interfaces ?? []))
					if (i.section == section && i.ifname)
						found = i.ifname;
			fresh ||= !!found;
			found ??= known[section] ?? uci.get('wireless', section, 'ifname');
			if (found) {
				push(ports, found);
				next[section] = found;
			}
			else
				log(`wifi "${section}" is not up, skipped`);
		}
		// flash is written only when a name changes
		if (fresh)
			try {
				write_json(file, next);
			}
			catch (e) {
				log(`cannot save ${file}`);
			}
	}

	return { nets: uniq(nets), ports: uniq(ports) };
};

// opts.passthrough: keep marking but do not intercept (kill switch off and no live server).
// opts.block: no interception, clients get neither internet nor DNS (service not started
// yet or stopped, failed fw-apply); needs no tproxy, fib or nat support.
export function render(cfg, res, opts) {
	let m = cfg.main, a = cfg.access;
	let cm = hex32(m.client_mark), tm = hex32(m.tproxy_mark), both = hex32(m.client_mark | m.tproxy_mark);
	let block = !!opts?.block;
	let intercept = !opts?.passthrough && !block;
	let hijack = intercept && a.dns_hijack;
	let r = [];

	push(r,
		'table inet xvpn',
		'delete table inet xvpn',
		'table inet xvpn {',
		`\tset nets { type ifname; ${elements(res.nets, true)}}`,
		`\tset bypass4 { type ipv4_addr; flags interval; auto-merge; ${elements(BYPASS4)}}`,
		`\tset bypass6 { type ipv6_addr; flags interval; auto-merge; ${elements(BYPASS6)}}`,
		'',
		'\tchain mark_clients {',
		'\t\ttype filter hook prerouting priority mangle - 10; policy accept;',
		`\t\tiifname @nets meta mark set meta mark | ${cm}`,
		'\t}', '');
	if (!block) {
		push(r,
			'\tchain intercept {',
			'\t\ttype filter hook prerouting priority mangle; policy accept;',
			`\t\tmeta mark & ${cm} != ${cm} return`,
			'\t\tfib daddr type local return');
		if (hijack)
			push(r, '\t\tmeta l4proto { tcp, udp } th dport 53 return');
		push(r,
			'\t\tip daddr @bypass4 return',
			'\t\tip6 daddr @bypass6 return');
		if (intercept) {
			push(r, `\t\tmeta nfproto ipv4 meta l4proto { tcp, udp } meta mark set meta mark | ${tm} tproxy ip to :${m.tproxy_port} accept`);
			if (a.ipv6 == 'tunnel')
				push(r, `\t\tmeta nfproto ipv6 meta l4proto { tcp, udp } meta mark set meta mark | ${tm} tproxy ip6 to :${m.tproxy_port} accept`);
		}
		push(r, '\t}', '',
			'\tchain dns_hijack {',
			'\t\ttype nat hook prerouting priority dstnat - 5; policy accept;');
		if (hijack)
			push(r, `\t\tmeta mark & ${cm} == ${cm} meta l4proto { tcp, udp } th dport 53 redirect to :${m.dns_port}`);
		push(r, '\t}', '');
	}
	push(r,
		'\tchain guard_forward {',
		'\t\ttype filter hook forward priority filter - 5; policy accept;',
		`\t\tmeta mark & ${cm} != ${cm} return`,
		'\t\tip daddr @bypass4 return',
		'\t\tip6 daddr @bypass6 return');
	if (block || (intercept && a.killswitch))
		push(r, '\t\treject with icmpx type admin-prohibited');
	else if (a.ipv6 == 'block')
		push(r, '\t\tmeta nfproto ipv6 reject with icmpx type admin-prohibited');
	push(r, '\t}', '',
		'\tchain guard_input {',
		'\t\ttype filter hook input priority filter - 5; policy accept;',
		`\t\tmeta l4proto { tcp, udp } th dport { ${m.tproxy_port}, ${m.dns_port} } meta mark & ${both} == 0 drop`);
	// the router's dnsmasq would resolve for them via the provider
	if (block)
		push(r, `\t\tmeta mark & ${cm} == ${cm} meta l4proto { tcp, udp } th dport 53 reject`);
	push(r,
		'\t}',
		'}', '');

	push(r, 'table bridge xvpn', 'delete table bridge xvpn');
	if (length(res.ports))
		push(r,
			'table bridge xvpn {',
			`\tset ports { type ifname; ${elements(res.ports, true)}}`,
			'',
			'\tchain mark_ports {',
			'\t\ttype filter hook prerouting priority filter - 10; policy accept;',
			`\t\tiifname @ports meta mark set meta mark | ${cm}`,
			'\t}',
			'}', '');

	return join('\n', r);
};

function routing(cfg, add) {
	let m = cfg.main, tm = hex32(m.tproxy_mark), t = m.route_table;
	for (let fam in [ '-4', '-6' ]) {
		// drop duplicates left from an unclean stop
		for (let i = 0; i < 4; i++)
			if (run(`ip ${fam} rule del fwmark ${tm}/${tm} table ${t} 2>/dev/null`).code != 0)
				break;
		if (add) {
			run(`ip ${fam} rule add fwmark ${tm}/${tm} table ${t}`);
			run(`ip ${fam} route replace local default dev lo table ${t}`);
		}
		else
			run(`ip ${fam} route flush table ${t} 2>/dev/null`);
	}
}

// Returns null on success, nft's error otherwise (the previous rules stay: nft -f is atomic).
export function apply(cfg, res, opts) {
	mkdir_p(VAR_DIR);
	write_file(NFT_FILE, render(cfg, res, opts));
	let r = run(`nft -f ${NFT_FILE} 2>&1`);
	if (r.code != 0) {
		let err = trim(r.out) || `nft exited with ${r.code}`;
		log(`nft failed: ${err}`);
		return err;
	}
	routing(cfg, true);
	return null;
};

export function remove(cfg) {
	run('nft delete table inet xvpn 2>/dev/null');
	run('nft delete table bridge xvpn 2>/dev/null');
	routing(cfg, false);
};
