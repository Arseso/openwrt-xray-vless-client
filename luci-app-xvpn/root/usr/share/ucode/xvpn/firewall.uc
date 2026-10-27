// SPDX-License-Identifier: MIT
// nftables rules (tables inet xvpn / bridge xvpn) and policy routing for TPROXY.

'use strict';

import { cursor } from 'uci';
import { NFT_FILE, VAR_DIR, mkdir_p, write_file, run, log } from 'xvpn.util';
import { ipv6_up } from 'xvpn.host';

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

// Our fixed names for the SSIDs in the rules: known before the radio is up and do not move
// to another SSID when the radio restarts (phy1-ap0 / phy1-ap1 are given out in order).
// Sections that got one from us are marked with option xvpn_ifname '1'.
const IFNAME_PREFIX = 'xvpn-ap';
const OUR_IFNAME = /^xvpn-ap[0-9]+$/;

// longer names do not exist (IFNAMSIZ) and make nft reject the whole file
function valid(dev) {
	if (length(dev) <= 15)
		return true;
	log(`device name "${dev}" is longer than 15 characters, skipped`);
	return false;
}

function words(v) {
	return filter(split(type(v) == 'array' ? join(' ', v) : (v ?? ''), /[ \t]+/), (w) => w != '');
}

// access point wifi-iface sections attached to the given networks (not a STA uplink)
function wifi_of(uci, networks) {
	let r = [];
	uci.foreach('wireless', 'wifi-iface', (s) => {
		if (s.mode && s.mode != 'ap')
			return;
		for (let n in words(s.network))
			if (n in networks)
				push(r, s['.name']);
	});
	return r;
}

// SSIDs that need their own name in the rules: the selected ones and those of selected
// networks without a device (Wi-Fi only network: the SSID itself is the L3 device)
function wifi_sections(cfg, uci) {
	let nodev = filter(cfg.access.networks,
		(n) => uci.get('network', n) == 'interface' && !uci.get('network', n, 'device'));
	return uniq([ ...cfg.access.wifi, ...(length(nodev) ? wifi_of(uci, nodev) : []) ]);
}

function wifi_disabled(uci, s) {
	return s.disabled == '1' || uci.get('wireless', s.device, 'disabled') == '1';
}

// Gives the SSIDs of wifi_sections() a fixed ifname (xvpn-apN) in /etc/config/wireless; a name
// set by the user stays as is. Our names are removed from SSIDs that are no longer needed.
// Returns { changed: wireless was committed, warning: the names could not be fixed }.
export function fix_ifnames(cfg, uci) {
	uci ??= cursor();
	let need = wifi_sections(cfg, uci), used = {}, add = [], drop = [];
	uci.foreach('wireless', 'wifi-iface', (s) => {
		if (s.ifname)
			used[s.ifname] = true;
		if (s['.name'] in need) {
			if (!s.ifname)
				push(add, s['.name']);
		}
		else if (s.xvpn_ifname == '1')
			push(drop, s);
	});
	if (!length(add) && !length(drop))
		return { changed: false };
	// committing would commit someone's unfinished `uci set wireless...` too
	if (length(uci.changes('wireless') ?? {})) {
		let warning = 'wireless has uncommitted changes, VPN SSID names are not fixed until they are committed';
		log(warning);
		return { changed: false, warning };
	}
	for (let sec in add) {
		let n = 0;
		while (used[IFNAME_PREFIX + n])
			n++;
		used[IFNAME_PREFIX + n] = true;
		uci.set('wireless', sec, 'ifname', IFNAME_PREFIX + n);
		uci.set('wireless', sec, 'xvpn_ifname', '1');
		log(`wifi "${sec}" gets the fixed name ${IFNAME_PREFIX + n}`);
	}
	for (let s in drop) {
		// a name the user changed after us is theirs
		if (match(s.ifname ?? '', OUR_IFNAME))
			uci.delete('wireless', s['.name'], 'ifname');
		uci.delete('wireless', s['.name'], 'xvpn_ifname');
		log(`wifi "${s['.name']}" is not a VPN access point any more, its name is restored`);
	}
	uci.commit('wireless');
	return { changed: true };
};

// All enabled SSIDs of wifi_sections() that have a fixed name carry it in netifd's status.
export function ifnames_applied(cfg, ubus_conn, uci) {
	uci ??= cursor();
	let st = ubus_conn?.call('network.wireless', 'status') ?? {};
	for (let section in wifi_sections(cfg, uci)) {
		let s = uci.get_all('wireless', section);
		if (!s?.ifname || wifi_disabled(uci, s))
			continue;
		let up = false;
		for (let radio, r in st)
			for (let i in (r.interfaces ?? []))
				up ||= (i.section == section && i.ifname == s.ifname);
		if (!up)
			return false;
	}
	return true;
};

// Resolves access points to device names:
//   networks -> L3 devices (br-guest): from netifd when up, from UCI before (boot guard);
//   SSIDs -> the fixed ifname from UCI and the current one from netifd, into both sets:
//   a bridged SSID is seen by the bridge table, an SSID that is a network itself only by inet;
//   each also as a "name.*" wildcard: WDS stations (name.staN) and dynamic VLANs (name.VID)
//   are interfaces of their own and would go around the rules;
//   ports as is.
// errors: enabled SSIDs that have no name at all, the rules cannot cover their clients.
export function resolve(cfg, ubus_conn, uci) {
	let nets = [], ports = [ ...cfg.access.ports ], errors = [];
	uci ??= cursor();

	if (length(cfg.access.networks)) {
		let dump = ubus_conn?.call('network.interface', 'dump') ?? {};
		for (let name in cfg.access.networks) {
			let ifc = filter(dump.interface ?? [], (i) => i.interface == name)[0];
			let devs = filter([ ifc?.l3_device, ifc?.device, uci.get('network', name, 'device') ],
				(d) => d && substr(d, 0, 1) != '@');
			if (length(devs))
				push(nets, ...devs);
			else if (!length(wifi_of(uci, [ name ])))
				log(`network "${name}" has no device, skipped`);
		}
	}

	let wifi = wifi_sections(cfg, uci);
	if (length(wifi)) {
		let st = ubus_conn?.call('network.wireless', 'status') ?? {};
		for (let section in wifi) {
			let s = uci.get_all('wireless', section);
			if (!s) {
				log(`wifi "${section}" does not exist, skipped`);
				continue;
			}
			let names = s.ifname ? [ s.ifname ] : [];
			for (let radio, r in st)
				for (let i in (r.interfaces ?? []))
					if (i.section == section && i.ifname)
						push(names, i.ifname);
			names = filter(uniq(names), valid);
			if (length(names)) {
				// longer prefixes leave no room for a sub-interface name
				let subs = map(filter(names, (n) => length(n) <= 13), (n) => `${n}.*`);
				push(nets, ...names, ...subs);
				push(ports, ...names, ...subs);
			}
			else if (wifi_disabled(uci, s))
				log(`wifi "${section}" is disabled, skipped`);
			else
				push(errors, `wifi "${section}"${s.ssid ? ` (SSID "${s.ssid}")` : ''} has no interface name`);
		}
	}

	return { nets: filter(uniq(nets), valid), ports: filter(uniq(ports), valid), errors };
};

// res.ipv6: false when IPv6 was off on the router at generate (from the index; apply()
// checks it when there is no index).
// opts.passthrough: keep marking but do not intercept (kill switch off and no live server).
// opts.block: no interception, clients get neither internet nor DNS (service not started
// yet or stopped, failed fw-apply); needs no tproxy, fib or nat support.
// opts.minimal: last resort when even block is rejected (no bridge support): inet only,
// VPN networks get no forwarding at all, single ports and SSIDs are not covered.
export function render(cfg, res, opts) {
	let m = cfg.main, a = cfg.access;
	if (opts?.minimal)
		return join('\n', [
			'table inet xvpn',
			'delete table inet xvpn',
			'table inet xvpn {',
			`\tset nets { type ifname; flags interval; auto-merge; ${elements(res.nets, true)}}`,
			'',
			'\tchain guard_forward {',
			'\t\ttype filter hook forward priority filter - 5; policy accept;',
			'\t\tiifname @nets reject with icmpx type admin-prohibited',
			'\t}',
			'}', '' ]);

	let cm = hex32(m.client_mark), tm = hex32(m.tproxy_mark), both = hex32(m.client_mark | m.tproxy_mark);
	let block = !!opts?.block;
	let intercept = !opts?.passthrough && !block;
	let hijack = intercept && a.dns_hijack;
	// IPv6 off on the router: there is no IPv6 to tunnel and xray listens on 0.0.0.0 only,
	// so no tproxy ip6 (nor its ip -6 route, which the kernel refuses); tunnel is a config error then
	let v6 = (a.ipv6 == 'tunnel' && res.ipv6 !== false) ? 'tunnel' : 'block';
	let r = [];

	push(r,
		'table inet xvpn',
		'delete table inet xvpn',
		'table inet xvpn {',
		`\tset nets { type ifname; flags interval; auto-merge; ${elements(res.nets, true)}}`,
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
			if (v6 == 'tunnel')
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
	else if (v6 == 'block')
		push(r, '\t\tmeta nfproto ipv6 reject with icmpx type admin-prohibited');
	// block must not fail on a bad port in the config: it is the fallback for a failed full,
	// and minimal leaves single ports and SSIDs open
	let lports = uniq(filter([ m.tproxy_port, m.dns_port ], (p) => !block || (type(p) == 'int' && p > 0 && p < 65536)));
	push(r, '\t}', '',
		'\tchain guard_input {',
		'\t\ttype filter hook input priority filter - 5; policy accept;');
	if (length(lports))
		push(r, `\t\tmeta l4proto { tcp, udp } th dport { ${join(', ', lports)} } meta mark & ${both} == 0 drop`);
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
			`\tset ports { type ifname; flags interval; auto-merge; ${elements(res.ports, true)}}`,
			'',
			'\tchain mark_ports {',
			'\t\ttype filter hook prerouting priority filter - 10; policy accept;',
			`\t\tiifname @ports meta mark set meta mark | ${cm}`,
			'\t}',
			'}', '');

	return join('\n', r);
};

// v6: false skips adding the IPv6 rule and route (IPv6 is off, ip -6 would fail)
function routing(cfg, add, v6) {
	let m = cfg.main, tm = hex32(m.tproxy_mark), t = m.route_table;
	// ip prints the mark without leading zeros; busybox ip has no selectors in `rule list`
	let mk = sprintf('0x%x', m.tproxy_mark), re = regexp(`fwmark ${mk}/${mk} lookup ${t}( |$)`);
	for (let fam in [ '-4', '-6' ]) {
		if (add && fam == '-6' && v6 === false)
			continue;
		let n = length(filter(split(run(`ip ${fam} rule list 2>/dev/null`).out, '\n'), (l) => match(l, re)));
		// the rule is added before duplicates left from an unclean stop are dropped:
		// no moment without it
		if (add && !n) {
			run(`ip ${fam} rule add fwmark ${tm}/${tm} table ${t}`);
			n = 1;
		}
		for (; n > (add ? 1 : 0); n--)
			run(`ip ${fam} rule del fwmark ${tm}/${tm} table ${t} 2>/dev/null`);
		if (add)
			run(`ip ${fam} route replace local default dev lo table ${t}`);
		else
			run(`ip ${fam} route flush table ${t} 2>/dev/null`);
	}
}

// Returns null on success, nft's error otherwise (the previous rules stay: nft -f is atomic).
export function apply(cfg, res, opts) {
	res = { ...res, ipv6: res.ipv6 ?? ipv6_up() };
	mkdir_p(VAR_DIR);
	write_file(NFT_FILE, render(cfg, res, opts));
	// only tproxy needs the route; at boot (fw-guard, block) lo is still down and ip
	// would fail with "Nexthop device is not up". For full it goes first: no moment
	// with tproxy marks but no route (a route without marks is harmless)
	let tproxy = !opts?.passthrough && !opts?.block && !opts?.minimal;
	if (tproxy)
		routing(cfg, true, res.ipv6);
	let r = run(`nft -f ${NFT_FILE} 2>&1`);
	if (r.code != 0) {
		let err = trim(r.out) || `nft exited with ${r.code}`;
		log(`nft failed: ${err}`);
		return err;
	}
	if (!tproxy)
		routing(cfg, false);
	return null;
};

export function remove(cfg) {
	run('nft delete table inet xvpn 2>/dev/null');
	run('nft delete table bridge xvpn 2>/dev/null');
	routing(cfg, false);
};
