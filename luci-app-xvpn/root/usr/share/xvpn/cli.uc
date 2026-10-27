#!/usr/bin/ucode
// SPDX-License-Identifier: MIT
// xvpn command line: generate | ifnames | ifnames-wait | fw-apply [passthrough] | fw-guard | fw-refresh | fw-remove | update [sid...|all]

'use strict';

import { readfile, unlink, access, open, symlink, readlink, rename, stat } from 'fs';
import * as ubus from 'ubus';
import * as uloop from 'uloop';
import {
	load_config, read_json, write_json, write_file, mkdir_p, log, run, shq, is_updater, kill_tree, fnv1a,
	ACTIVE_FILE, CONFIG_FILE, INDEX_FILE, VAR_DIR, RUN_DIR, UPDATE_LOCK,
	FW_WANT_FILE, FW_MODE_FILE, FW_ERROR_FILE, FW_WARN_FILE, FW_LOCK_FILE, GENERATE_ERROR_FILE
} from 'xvpn.util';
import { all_servers, update, prune } from 'xvpn.subscription';
import { build_index, generate } from 'xvpn.xrayconf';
import { resolve, apply, remove, fix_ifnames, ifnames_applied } from 'xvpn.firewall';

const cfg = load_config();

// generate runs in init.d under procd's service lock, the daemon kills a reload that makes
// no progress for 60 s: a test of the whole config may take long with hundreds of outbounds,
// of one server or none it is short; all the tests together fit in GENERATE_BUDGET
const TEST_FULL = 40, TEST_ONE = 15, GENERATE_BUDGET = cfg.health.generate_budget;
const STARTED = clock(true)[0];

// xray's verdicts are kept (#7): `run -test` is a second xray beside the running one, with
// hundreds of outbounds it takes as much memory. A reload that only selects a server or
// follows a wifi change tests nothing; a changed server list is tested once (one test of the
// whole config while xray accepts it; one by one only the servers it has not judged yet).
// { bin: bin_sig(), frame: <main and access settings>, full: <the server set whose whole
// config passed>, ok: { <outbound key>: bool } }; another binary or other settings start
// anew. In /var: after a boot everything is tested once again
const TESTED_FILE = `${VAR_DIR}/tested.json`;

// another binary (an upgrade, xray_bin changed or fixed in place) may judge otherwise
function bin_sig() {
	let s = stat(cfg.main.xray_bin);
	return s ? `${s.inode}:${s.size}:${s.mtime}` : null;
}

function conf_key(o) {
	let j = sprintf('%J', o);
	return `${fnv1a(j)}-${length(j)}`;
}

// init.d passes xray's GC settings (GOMEMLIMIT, GOGC) to the tests too
const XRAY_ENV = { PATH: '/usr/sbin:/usr/bin:/sbin:/bin' };
for (let k in [ 'GOMEMLIMIT', 'GOGC' ])
	if (getenv(k))
		XRAY_ENV[k] = getenv(k);

// the last xray_ok was xray's own verdict on the config, so it may be kept: accepted, or
// exit code 23 (config error); not hung, not killed (OOM), not a Go runtime error (2)
let definite = false;

// write_json that checks the file is whole: on a full tmpfs xray would reject a truncated
// config with the same 23
function put(path, obj) {
	let text = sprintf('%J\n', obj);
	write_file(path, text);
	return readfile(path) === text;
}

// true: xray accepts the config; false: rejects it, hung or was killed (OOM); null: out of
// time, reserve seconds of the budget kept for later. uloop.process reports a killed
// process as exit code 0: sh writes xray's own code.
function xray_ok(path, limit, reserve) {
	definite = false;
	let left = GENERATE_BUDGET - (clock(true)[0] - STARTED) - (reserve ?? 0);
	if (left <= 0)
		return null;
	let out = `${VAR_DIR}/xray-ok`, wait = min(limit, left), hung = false, t;
	unlink(out);
	uloop.init();
	let p = uloop.process('/bin/sh', [ '-c', `${shq(cfg.main.xray_bin)} run -test -c ${shq(path)} >/dev/null 2>&1; echo $? > ${shq(out)}` ],
		XRAY_ENV, () => uloop.end());
	if (!p)
		return false;
	t = uloop.timer(wait * 1000, () => {
		hung = true;
		kill_tree(p.pid());
	});
	uloop.run();
	t.cancel();
	let code = readfile(out);
	unlink(out);
	if (hung && wait < limit)
		return null;
	if (hung)
		log(`${cfg.main.xray_bin} run -test hung for ${limit} s, killed`);
	definite = !hung && code != null && int(code) in [ 0, 23 ];
	return !hung && code != null && int(code) == 0;
}

const MODES = { full: {}, passthrough: { passthrough: true }, block: { block: true }, minimal: { minimal: true } };

// hotplug, init.d and the daemon run fw-* concurrently: one at a time, the lock is
// released when the process exits
function fw_lock() {
	mkdir_p(substr(FW_LOCK_FILE, 0, rindex(FW_LOCK_FILE, '/')));
	let f = open(FW_LOCK_FILE, 'w');
	f?.lock('x');
	return f;
}

// Applies the wanted mode (full | passthrough | block; null: the last wanted one, fw-refresh).
// When nft rejects it, falls back to block, then minimal (fail closed); FW_MODE_FILE gets
// what is applied and FW_ERROR_FILE the error until the wanted mode applies.
// An SSID that has no device name cannot be in the rules: its clients would go around the
// tunnel, so all VPN clients are blocked (passthrough lets them out anyway) and it is an error.
function fw(want) {
	let lock = fw_lock();
	want ??= readfile(FW_WANT_FILE);
	if (!MODES[want])
		return true;

	mkdir_p(RUN_DIR);
	write_file(FW_WANT_FILE, want);
	let res = resolve(cfg, ubus.connect());
	let errs = [], mode = want;
	if (length(res.errors)) {
		push(errs, `access points not found: ${join('; ', res.errors)}`);
		log(errs[0]);
		if (want != 'passthrough')
			mode = 'block';
	}

	let err = apply(cfg, res, MODES[mode]);
	if (err != null) {
		push(errs, `firewall rules failed: ${err}`);
		let tried = mode;
		mode = null;
		for (let m in [ 'block', 'minimal' ])
			if (m != tried && apply(cfg, res, MODES[m]) == null) {
				mode = m;
				break;
			}
	}
	if (mode)
		write_file(FW_MODE_FILE, mode);
	if (!length(errs)) {
		unlink(FW_ERROR_FILE);
		return true;
	}
	if (mode && mode != want)
		log(`VPN clients are blocked (${mode}) until the firewall rules are fixed`);
	write_file(FW_ERROR_FILE, join('\n', errs));
	return false;
}

function active_port() {
	let idx = read_json(INDEX_FILE);
	return filter(idx?.servers ?? [], (e) => e.id == idx.active)[0]?.test_port;
}

const SELF = readlink('/proc/self');

// symlink() is atomic: of two concurrent updates only one gets the lock
function lock_update() {
	mkdir_p(RUN_DIR);
	for (let i = 0; i < 3; i++) {
		if (symlink(SELF, UPDATE_LOCK))
			return true;
		let held = readlink(UPDATE_LOCK);
		if (is_updater(held))
			return false;
		// left by an update that died: remove that one, not a lock taken meanwhile
		if (held && readlink(UPDATE_LOCK) == held)
			unlink(UPDATE_LOCK);
	}
	return false;
}

function unlock_update() {
	if (readlink(UPDATE_LOCK) == SELF)
		unlink(UPDATE_LOCK);
}

switch (ARGV[0]) {
case 'generate': {
	prune(cfg);
	let all = all_servers(cfg), servers = all;
	let active = trim(readfile(ACTIVE_FILE) ?? '');
	// everything but the servers that goes into the config (ports, DNS, sniffing…)
	let sig = bin_sig(), frame = conf_key([ cfg.main, cfg.access ]), tested = read_json(TESTED_FILE);
	if (type(tested?.ok) != 'object' || tested.bin != sig || tested.frame != frame)
		tested = { bin: sig, frame, full: null, ok: {} };
	let verdict = (s) => tested.ok[s.key ??= conf_key(s.outbound)];
	let set_key = (list) => conf_key(sort(map(list, (s) => s.key ?? conf_key(s.outbound))));
	// rejected before: dropped without a test
	let skipped = map(filter(servers, (s) => verdict(s) === false), (s) => s.name);
	if (length(skipped)) {
		log(`xray rejected ${length(skipped)} server(s) earlier: ${join(', ', skipped)}`);
		servers = filter(servers, (s) => verdict(s) !== false);
	}
	let idx = build_index(cfg, servers, active);
	// xray and the daemon keep the running config until the end: a generate killed
	// midway changes nothing
	let next = `${VAR_DIR}/config.new.json`, tmp = `${VAR_DIR}/check.json`;	// xray goes by the extension
	mkdir_p(VAR_DIR);
	write_json(next, generate(cfg, servers, idx));

	// the verdicts got so far are kept whatever the end: they are xray's own
	function keep(passed) {
		if (passed) {
			tested.full = set_key(servers);
			for (let s in servers)
				tested.ok[s.key] = true;
		}
		// the servers gone from the subscriptions go from the file too
		let ok = {};
		for (let s in all)
			if (verdict(s) != null)
				ok[s.key] = verdict(s);
		tested.ok = ok;
		write_json(TESTED_FILE, tested);
	}
	function commit(code) {
		unlink(tmp);
		unlink(GENERATE_ERROR_FILE);
		if (!rename(next, CONFIG_FILE))
			die(`cannot write ${CONFIG_FILE}`);
		write_json(INDEX_FILE, idx);
		if (code == 4)
			log(`xray does not work, check: ${cfg.main.xray_bin} run -test -c ${CONFIG_FILE}`);
		else
			print(`${length(servers)} servers, active ${idx.active ?? 'none'}\n`);
		exit(code ?? (length(servers) ? 0 : 3));
	}
	function out_of_time() {
		keep(false);
		unlink(tmp);
		unlink(next);
		let err = `generate ran out of time (${GENERATE_BUDGET} s), xray goes on with the previous config`;
		log(err);
		mkdir_p(RUN_DIR);
		write_file(GENERATE_ERROR_FILE, err);
		exit(5);
	}
	function check(path, limit) {
		let ok = xray_ok(path, limit);
		if (ok == null)
			out_of_time();
		return ok;
	}

	// one malformed server must not take the whole VPN down: drop the ones xray rejects
	// the same servers with the same settings were accepted by this binary before: no test
	let known = (tested.full == set_key(servers));
	let testing = length(servers) && !known && access(cfg.main.xray_bin, 'x');
	if (testing && !check(next, TEST_FULL)) {
		let good = [], bad = [];
		// xray that rejects a config without servers is broken itself: keep the servers,
		// the daemon reports xray_down rather than "no servers"
		write_json(tmp, generate(cfg, [], build_index(cfg, [], null)));
		if (!check(tmp, TEST_ONE))
			commit(4);
		// out of time (a slow router, a big subscription): the servers not tested yet are
		// dropped, a test of the whole config stays in the budget
		let untested = 0;
		for (let s in servers) {
			if (verdict(s) === true) {
				push(good, s);
				continue;
			}
			if (untested) {
				untested++;
				continue;
			}
			let ok = false;
			definite = false;
			if (put(tmp, generate(cfg, [ s ], build_index(cfg, [ s ], s.id))))
				ok = xray_ok(tmp, TEST_ONE, TEST_FULL);
			if (definite)
				tested.ok[s.key] = ok;
			if (ok == null)
				untested++;
			else if (ok)
				push(good, s);
			else
				push(bad, s.name);
		}
		log(`xray rejected ${length(bad)} server(s): ${join(', ', bad)}`);
		if (untested && !length(good))
			out_of_time();	// rather the previous config than none
		if (untested)
			log(`generate ran out of time (${GENERATE_BUDGET} s): ${untested} server(s) not tested, dropped`);
		servers = good;
		idx = build_index(cfg, servers, active);
		write_json(next, generate(cfg, servers, idx));
		if (length(servers) && !check(next, TEST_FULL)) {
			log(`xray rejects the generated config`);
			keep(false);
			commit(4);
		}
	}
	if (testing)
		keep(true);
	commit(null);
}

case 'fw-apply':
	exit(fw(ARGV[1] == 'passthrough' ? 'passthrough' : 'full') ? 0 : 1);

// xray is not running (boot, stop with the service enabled): clients do not go around the VPN
case 'fw-guard':
	exit(fw(cfg.access.killswitch ? 'block' : 'passthrough') ? 0 : 1);

// devices changed (a wifi or a network came up) or fw4 flushed the tables: the wanted mode again
case 'fw-refresh':
	exit(fw(null) ? 0 : 1);

// before the rules (init.d): fixed names for the VPN SSIDs; the rules match both the fixed
// and the current name until netifd applies them
case 'ifnames': {
	let r = fix_ifnames(cfg);
	mkdir_p(RUN_DIR);
	if (r.warning)
		write_file(FW_WARN_FILE, r.warning);
	else
		unlink(FW_WARN_FILE);
	if (r.changed) {
		run('ubus call network reload');
		// hostapd usually renames the interfaces in place (kernel "move", not "add"): another
		// SSID may now have the name the VPN SSID had, so refresh once the fixed names are on
		// without fd 1000 of init.d: procd's service lock, it would hold the next reload
		system('/usr/bin/ucode /usr/share/xvpn/cli.uc ifnames-wait >/dev/null 2>&1 </dev/null 1000>&- &');
	}
	exit(0);
}

case 'ifnames-wait': {
	let conn = ubus.connect();
	for (let i = 0; i < 30 && !ifnames_applied(cfg, conn); i++)
		system('sleep 1');
	exit(fw(null) ? 0 : 1);
}

case 'fw-remove': {
	let lock = fw_lock();
	remove(cfg);
	unlink(FW_WANT_FILE);
	unlink(FW_MODE_FILE);
	unlink(FW_ERROR_FILE);
	unlink(FW_WARN_FILE);
	exit(0);
}

case 'update': {
	let sids = slice(ARGV, 1), port = active_port(), out = {}, changed = false;
	let all = !length(sids) || ('all' in sids);
	if (!lock_update()) {
		warn('another subscription update is running\n');
		exit(5);
	}
	for (let sub in cfg.subscriptions) {
		if (!sub.enabled || !(all || (sub.id in sids)))
			continue;
		let r = update(sub, port);
		out[sub.id] = r;
		changed ||= r.changed;
		log(r.error ? `subscription "${sub.name}": ${r.error}`
			: `subscription "${sub.name}": ${r.count} servers${r.skipped ? `, ${r.skipped} skipped` : ''}${r.changed ? ' (changed)' : ''}`);
	}
	unlock_update();
	printf('%J\n', out);
	exit(changed ? 0 : 2);
}

default:
	warn('usage: cli.uc generate | ifnames | ifnames-wait | fw-apply [passthrough] | fw-guard | fw-refresh | fw-remove | update [sid...|all]\n');
	exit(1);
}
