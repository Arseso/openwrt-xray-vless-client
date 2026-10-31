// SPDX-License-Identifier: MIT
// Shared helpers for xvpn: JSON files, hashing, logging, UCI config.

'use strict';

import { readfile, writefile, rename, mkdir, stat, popen, readlink, lsdir } from 'fs';
import { cursor } from 'uci';

export const ETC_DIR = '/etc/xvpn';
export const SUBS_DIR = '/etc/xvpn/subs';
export const ACTIVE_FILE = '/etc/xvpn/active';
// the id of ACTIVE_FILE when the user chose it (select), not the daemon: kept out of auto selection
export const MANUAL_FILE = '/etc/xvpn/active_manual';
export const VAR_DIR = '/var/etc/xvpn';
export const RUN_DIR = '/var/run/xvpn';
export const CONFIG_FILE = '/var/etc/xvpn/config.json';
export const INDEX_FILE = '/var/etc/xvpn/index.json';
export const NFT_FILE = '/var/etc/xvpn/xvpn.nft';
export const STATE_FILE = '/var/run/xvpn/state.json';
// symlink to the pid of the running `cli.uc update`: the only "update in progress" flag
export const UPDATE_LOCK = '/var/run/xvpn/updating';
export const FW_WANT_FILE = '/var/run/xvpn/fw_want';
export const FW_MODE_FILE = '/var/run/xvpn/fw_mode';
export const FW_ERROR_FILE = '/var/run/xvpn/fw_error';
// VPN SSID names could not be fixed (uncommitted changes to wireless)
export const FW_WARN_FILE = '/var/run/xvpn/fw_warn';
export const FW_LOCK_FILE = '/var/lock/xvpn-fw';
// mark/table pairs whose ip rule and route may be in place (firewall.uc route_add(), route_prune())
export const FW_ROUTE_FILE = '/var/run/xvpn/fw_route';
// generate ran out of time and kept the running config: the daemon counts the reload failed
export const GENERATE_ERROR_FILE = '/var/run/xvpn/generate_error';
// an update changed servers xray does not use now: the next reload (generate) applies them
export const STALE_FILE = '/var/run/xvpn/stale';

export function read_json(path) {
	let s = readfile(path);
	if (s == null)
		return null;
	try {
		return json(s);
	}
	catch (e) {
		return null;
	}
};

export function mkdir_p(path) {
	let cur = '';
	for (let part in split(path, '/')) {
		if (part == '')
			continue;
		cur += '/' + part;
		if (!stat(cur))
			mkdir(cur, 0755);
	}
};

// Atomic write via rename; skips the write when content is unchanged so that
// files on NAND are not rewritten needlessly. Returns true if file changed.
export function write_file(path, text) {
	if (readfile(path) === text)
		return false;
	let tmp = path + '.tmp';
	if (writefile(tmp, text) == null || !rename(tmp, path))
		die(`cannot write ${path}`);
	return true;
};

export function write_json(path, obj) {
	return write_file(path, sprintf('%J\n', obj));
};

// Running processes: { pid: { ppid, cpu (utime + stime ticks), cmd } }.
export function procs() {
	let ps = {};
	for (let d in lsdir('/proc') ?? []) {
		if (!match(d, /^[0-9]+$/))
			continue;
		// the name in parentheses may contain spaces and ')'
		let f = split(replace(readfile(`/proc/${d}/stat`) ?? '', /^.*\) /, ''), ' ');
		if (length(f) < 13)
			continue;
		ps[d] = { ppid: f[1], cpu: int(f[11]) + int(f[12]), cmd: replace(readfile(`/proc/${d}/cmdline`) ?? '', /\0/g, ' ') };
	}
	return ps;
};

// pid and all its descendants in ps.
export function tree(pid, ps) {
	let kids = {}, pids = [ `${pid}` ];
	for (let p, e in ps)
		push(kids[e.ppid] ??= [], p);
	for (let i = 0; i < length(pids); i++)
		push(pids, ...(kids[pids[i]] ?? []));
	return pids;
};

// Kills pid with everything it started: stopped first, so that none forks behind the
// walk (a child left alive keeps procd's service lock, fd 1000 of init.d scripts).
export function kill_tree(pid) {
	let seen = {}, all = [];
	for (let i = 0; i < 5; i++) {
		let fresh = filter(tree(pid, procs()), (p) => !seen[p]);
		if (!length(fresh))
			break;
		for (let p in fresh)
			seen[p] = push(all, p);
		system(`/bin/kill -STOP ${join(' ', fresh)} 2>/dev/null`);
	}
	system(`/bin/kill -9 ${join(' ', all)} 2>/dev/null`);
};

// The pid is alive and still is `cli.uc` (pids get reused).
export function is_updater(pid) {
	return !!pid && index(readfile(`/proc/${pid}/cmdline`) ?? '', 'cli.uc') >= 0;
};

// Pid of the running subscription update, or null.
export function update_running() {
	let pid = readlink(UPDATE_LOCK);
	return is_updater(pid) ? int(pid) : null;
};

// 32-bit FNV-1a, hex encoded.
export function fnv1a(s) {
	let h = 0x811c9dc5;
	for (let i = 0; i < length(s); i++) {
		h = h ^ ord(s, i);
		h = (h * 0x01000193) & 0xffffffff;
	}
	return sprintf('%08x', h);
};

export function shq(s) {
	return "'" + replace(`${s}`, "'", "'\\''") + "'";
};

// Runs a shell command, returns { code, out }.
export function run(cmd) {
	let p = popen(cmd, 'r');
	if (!p)
		return { code: -1, out: '' };
	let out = p.read('all') ?? '';
	let code = p.close();
	return { code, out };
};

export function log(msg) {
	system([ '/usr/bin/logger', '-t', 'xvpn', msg ]);
};

function bool(v, def) {
	if (v == null || v == '')
		return def;
	return v in [ '1', 'true', 'yes', 'on', 'enabled' ];
}

function num(v, def) {
	let n = (v == null || v == '') ? null : (match(`${v}`, /^0[xX]/) ? hex(v) : int(v));
	return (n == null || n != n) ? def : n;
}

function list(v) {
	if (v == null)
		return [];
	return type(v) == 'array' ? v : [ v ];
}

const DEFAULT_DNS = 'https://cloudflare-dns.com/dns-query';

// An IP/host goes as <dns_server>:53 through the tunnel, https:// and tcp:// through the
// xray DNS module. Other xray schemes (https+local://, quic+local://, …) would query
// from the router directly, around the tunnel: the default instead.
function dns_server(v) {
	if (!v)
		return DEFAULT_DNS;
	if (index(v, '://') < 0 || match(v, /^(https|tcp):\/\/[^\/]/))
		return v;
	log(`dns_server ${v}: only https:// and tcp:// go through the tunnel, using ${DEFAULT_DNS}`);
	return DEFAULT_DNS;
}

// Loads /etc/config/xvpn with defaults applied and numbers converted.
export function load_config(confdir) {
	let c = cursor(confdir);
	c.load('xvpn');

	let m = c.get_all('xvpn', 'main') ?? {};
	let a = c.get_all('xvpn', 'access') ?? {};
	let h = c.get_all('xvpn', 'health') ?? {};
	let man = c.get_all('xvpn', 'manual') ?? {};
	let sp = c.get_all('xvpn', 'split') ?? {};

	let cfg = {
		main: {
			enabled: bool(m.enabled, false),
			xray_bin: m.xray_bin || '/usr/bin/xray',
			loglevel: m.loglevel || 'warning',
			tproxy_port: num(m.tproxy_port, 12345),
			dns_port: num(m.dns_port, 10853),
			api_port: num(m.api_port, 10085),
			// gRPC API of xray (TCP: the switch without a restart, #13) and the UDP check (#10)
			control_port: num(m.control_port, 10086),
			test_port_base: num(m.test_port_base, 20000),
			client_mark: num(m.client_mark, 0x01000000),
			tproxy_mark: num(m.tproxy_mark, 0x02000000),
			route_table: num(m.route_table, 100),
			sniffing: bool(m.sniffing, true),
			// BitTorrent (sniffed from the first packets) goes to blackhole (#15)
			block_bittorrent: bool(m.block_bittorrent, false),
			// xray policy level 0 in s (#15, DESIGN.md 6.4); not in the default config.
			// conn_idle 120 instead of xray's 300: a torrent client keeps fewer sessions open
			handshake: num(m.handshake, 4),
			conn_idle: num(m.conn_idle, 120),
			uplink_only: num(m.uplink_only, 2),
			downlink_only: num(m.downlink_only, 5),
			// KB a connection; null: xray's own (4 on arm64, 512 on amd64)
			buffer_size: num(m.buffer_size, null),
			// s between reads of the tunnel counters for the speed in status (#83), 0: off;
			// not in the default config
			speed_interval: num(m.speed_interval, 3),
		},
		access: {
			networks: list(a.network),
			ports: list(a.port),
			wifi: list(a.wifi),
			killswitch: bool(a.killswitch, true),
			ipv6: (a.ipv6 == 'tunnel') ? 'tunnel' : 'block',
			dns_hijack: bool(a.dns_hijack, true),
			dns_server: dns_server(a.dns_server),
		},
		health: {
			url: h.url || 'https://www.gstatic.com/generate_204',
			// tests and choices also check it through the servers that answer url (#61):
			// another CDN, by domain; 'off' turns it off
			url2: (h.url2 == 'off' || h.url2 == '0') ? null : (h.url2 || 'https://cp.cloudflare.com/generate_204'),
			interval: num(h.interval, 30),
			timeout: num(h.timeout, 5),
			fail_threshold: num(h.fail_threshold, 3),
			rank_interval: num(h.rank_interval, 600),
			auto_best: bool(h.auto_best, false),
			hysteresis: num(h.hysteresis, 150),
			quarantine: num(h.quarantine, 300),
			// parallel curl in a test, each with its connection in xray: 1..8 on 256 MB (#7)
			concurrency: min(max(num(h.concurrency, 4), 1), 8),
			// not in the default config, for tests (see DESIGN.md 6.3)
			reload_idle: num(h.reload_idle, 60),
			reload_retry: num(h.reload_retry, 30),
			generate_budget: num(h.generate_budget, 240),
			time_wait: num(h.time_wait, 120),
			// live servers in a row that fail url2 before it is asked directly (#61)
			url2_cdn: max(1, num(h.url2_cdn, 3)),
			retry_max: num(h.retry_max, 600),
			// the active server: a download that must not stall (#11, DPI lets the handshake
			// through and freezes the stream after ~16-20 KB); 'off' turns it off
			dl_url: (h.dl_url == 'off' || h.dl_url == '0') ? null : (h.dl_url || 'https://speed.cloudflare.com/__down?bytes=65536'),
			dl_interval: num(h.dl_interval, 300),
			dl_timeout: num(h.dl_timeout, 15),
			// direct internet: down only when none of them answers (#11)
			wan_url: length(list(h.wan_url)) ? list(h.wan_url)
				: uniq([ h.url || 'https://www.gstatic.com/generate_204', 'https://cp.cloudflare.com/generate_204', 'http://detectportal.firefox.com/success.txt' ]),
			// DNS of the clients through the active server (#10): DoH through its test port,
			// a DNS server given as an IP over UDP; the UDP check runs with the DNS one
			dns_check: bool(h.dns_check, true),
		},
		// split tunneling (#67): checked and normalized by split.uc
		split: {
			ip: list(sp.ip),
			domain: list(sp.domain),
			ru: bool(sp.ru, false),
			// hours between downloads of the Russian list
			ru_interval: max(1, num(sp.ru_interval, 168)),
			// not in the default config: other sources of the list (split.uc RU_URLS)
			ru_url: list(sp.ru_url),
		},
		subscriptions: [],
		manual: list(man.link),
	};

	c.foreach('xvpn', 'subscription', (s) => {
		push(cfg.subscriptions, {
			id: s['.name'],
			name: s.name || s['.name'],
			enabled: bool(s.enabled, true),
			url: s.url,
			user_agent: s.user_agent || 'v2rayN/7.0',
			update_interval: num(s.update_interval, 0),
			include: s.include || '',
			exclude: s.exclude || '',
			via_tunnel: bool(s.via_tunnel, true),
		});
	});

	return cfg;
};

// health.no_auto (#60): ids of the servers the daemon never chooses by itself (start,
// failover, auto_best); a manual choice and the tests still take them. The daemon reads
// it while it runs: init.d leaves it out of what restarts the daemon, xray does not see it.
export function no_auto_ids(c) {
	c ??= cursor();
	c.load('xvpn');
	return list(c.get('xvpn', 'health', 'no_auto'));
};

// Writes health.no_auto; an error message when it cannot. c: a uci cursor.
export function set_no_auto(c, ids) {
	c.load('xvpn');
	// committing would commit someone's unfinished `uci set xvpn...` too
	if (length(c.changes('xvpn') ?? {}))
		return 'xvpn has uncommitted changes';
	if (c.get('xvpn', 'health') == null)
		c.set('xvpn', 'health', 'health');
	if (length(ids))
		c.set('xvpn', 'health', 'no_auto', ids);
	else
		c.delete('xvpn', 'health', 'no_auto');
	c.commit('xvpn');
	return null;
};

// The fastest server with a working latency, null when none. skip(e): left out.
export function fastest(servers, latency, skip) {
	let b = null;
	for (let e in servers) {
		let l = latency[e.id];
		if (!l || l.ms < 0 || skip?.(e))
			continue;
		if (!b || l.ms < latency[b.id].ms)
			b = e;
	}
	return b;
};

// The server the daemon chooses by itself: the fastest in auto selection (off: { id: true },
// no_auto) out of quarantine (q) and not limited (#61: url2 fails through it). Else one
// in quarantine that answered since, else a limited one: url2 failing everywhere is
// likely its CDN, and a server with some sites beats none. { server, limited } or null.
export function auto_pick(servers, latency, off, q, limited) {
	for (let skip in [ [ q, limited ], [ limited ], [ q ], [] ]) {
		let b = fastest(servers, latency, (e) => off[e.id] || length(filter(skip, (s) => s[e.id])) > 0);
		if (b)
			return { server: b, limited: !!limited[b.id] };
	}
	return null;
};

// The pause before the next test of all servers while none is alive (#12): interval at
// first, then twice the last one (prev), at most max_ (not less than interval).
export function retry_delay(prev, interval, max_) {
	return min(prev ? prev * 2 : interval, max(max_, interval));
};
