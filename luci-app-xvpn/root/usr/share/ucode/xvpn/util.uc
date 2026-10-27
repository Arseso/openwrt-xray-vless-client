// SPDX-License-Identifier: MIT
// Shared helpers for xvpn: JSON files, hashing, logging, UCI config.

'use strict';

import { readfile, writefile, rename, mkdir, stat, popen, readlink, lsdir } from 'fs';
import { cursor } from 'uci';

export const ETC_DIR = '/etc/xvpn';
export const SUBS_DIR = '/etc/xvpn/subs';
export const ACTIVE_FILE = '/etc/xvpn/active';
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
// generate ran out of time and kept the running config: the daemon counts the reload failed
export const GENERATE_ERROR_FILE = '/var/run/xvpn/generate_error';

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

// Loads /etc/config/xvpn with defaults applied and numbers converted.
export function load_config(confdir) {
	let c = cursor(confdir);
	c.load('xvpn');

	let m = c.get_all('xvpn', 'main') ?? {};
	let a = c.get_all('xvpn', 'access') ?? {};
	let h = c.get_all('xvpn', 'health') ?? {};
	let man = c.get_all('xvpn', 'manual') ?? {};

	let cfg = {
		main: {
			enabled: bool(m.enabled, false),
			xray_bin: m.xray_bin || '/usr/bin/xray',
			loglevel: m.loglevel || 'warning',
			tproxy_port: num(m.tproxy_port, 12345),
			dns_port: num(m.dns_port, 10853),
			api_port: num(m.api_port, 10085),
			test_port_base: num(m.test_port_base, 20000),
			client_mark: num(m.client_mark, 0x01000000),
			tproxy_mark: num(m.tproxy_mark, 0x02000000),
			route_table: num(m.route_table, 100),
			sniffing: bool(m.sniffing, true),
		},
		access: {
			networks: list(a.network),
			ports: list(a.port),
			wifi: list(a.wifi),
			killswitch: bool(a.killswitch, true),
			ipv6: (a.ipv6 == 'tunnel') ? 'tunnel' : 'block',
			dns_hijack: bool(a.dns_hijack, true),
			dns_server: a.dns_server || 'https://cloudflare-dns.com/dns-query',
		},
		health: {
			url: h.url || 'https://www.gstatic.com/generate_204',
			interval: num(h.interval, 30),
			timeout: num(h.timeout, 5),
			fail_threshold: num(h.fail_threshold, 3),
			rank_interval: num(h.rank_interval, 600),
			auto_best: bool(h.auto_best, false),
			hysteresis: num(h.hysteresis, 150),
			quarantine: num(h.quarantine, 300),
			concurrency: num(h.concurrency, 8),
			// not in the default config, for tests (see DESIGN.md 6.3)
			reload_idle: num(h.reload_idle, 60),
			reload_retry: num(h.reload_retry, 30),
			generate_budget: num(h.generate_budget, 240),
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
