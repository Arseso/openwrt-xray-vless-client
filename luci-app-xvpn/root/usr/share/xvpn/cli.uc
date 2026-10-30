#!/usr/bin/ucode
// SPDX-License-Identifier: MIT
// xvpn command line: generate | ifnames | ifnames-wait | fw-apply [passthrough] | fw-guard | fw-refresh | fw-remove | update [sid...|all] | lists

'use strict';

import { readfile, unlink, access, open, symlink, readlink, rename, stat } from 'fs';
import * as ubus from 'ubus';
import * as uloop from 'uloop';
import {
	load_config, read_json, write_json, write_file, mkdir_p, log, run, shq, is_updater, kill_tree, fnv1a,
	ACTIVE_FILE, MANUAL_FILE, CONFIG_FILE, INDEX_FILE, VAR_DIR, RUN_DIR, UPDATE_LOCK,
	FW_WANT_FILE, FW_MODE_FILE, FW_ERROR_FILE, FW_WARN_FILE, FW_LOCK_FILE, GENERATE_ERROR_FILE, STALE_FILE
} from 'xvpn.util';
import { all_servers, update, prune, list_change } from 'xvpn.subscription';
import { build_index, generate, ports_error } from 'xvpn.xrayconf';
import { host_env } from 'xvpn.host';
import { resolve, apply, remove, fix_ifnames, ifnames_applied } from 'xvpn.firewall';
import { direct_nets, direct_domains, update_lists, prune_lists } from 'xvpn.split';

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
// config passed>, ok: { <outbound key>: bool }, why: { <outbound key>: <xray's reason> } };
// another binary or other settings start anew. In /var: after a boot everything is tested
// once again
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
// why xray rejected the config of the last xray_ok (exit code 23), for the log
let reason = null;

// "Failed to start: main: failed to load config files: [<path>] > infra/conf: failed to
// build outbound config with tag srv-0 > infra/conf: vless without TLS…": the last part
// says what is wrong with the server (a newer xray forbids what the link sets, #14)
function xray_reason(text) {
	let l = match(text ?? '', /Failed to start: ([^\n]*)/)?.[1];
	if (!l)
		return null;
	return substr(replace(pop(split(l, ' > ')), /^[a-z\/]+: /, ''), 0, 300);
}

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
	reason = null;
	let left = GENERATE_BUDGET - (clock(true)[0] - STARTED) - (reserve ?? 0);
	if (left <= 0)
		return null;
	let out = `${VAR_DIR}/xray-ok`, said = `${VAR_DIR}/xray-ok.log`, wait = min(limit, left), hung = false, t;
	unlink(out);
	uloop.init();
	let p = uloop.process('/bin/sh', [ '-c', `${shq(cfg.main.xray_bin)} run -test -c ${shq(path)} >${shq(said)} 2>&1; echo $? > ${shq(out)}` ],
		XRAY_ENV, () => uloop.end());
	if (!p)
		return false;
	t = uloop.timer(wait * 1000, () => {
		hung = true;
		kill_tree(p.pid());
	});
	uloop.run();
	t.cancel();
	let code = readfile(out), text = readfile(said);
	unlink(out);
	unlink(said);
	if (hung && wait < limit)
		return null;
	if (hung)
		log(`${cfg.main.xray_bin} run -test hung for ${limit} s, killed`);
	definite = !hung && code != null && int(code) in [ 0, 23 ];
	if (definite && int(code) == 23)
		reason = xray_reason(text);
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
// Ports and IPv6 come from the index of the config xray runs, not from UCI: a generate that
// failed (a port taken) leaves xray on the previous ones.
function fw(want) {
	let lock = fw_lock();
	want ??= readfile(FW_WANT_FILE);
	if (!MODES[want])
		return true;

	mkdir_p(RUN_DIR);
	write_file(FW_WANT_FILE, want);
	let idx = read_json(INDEX_FILE), rc = cfg;
	if (idx?.ports)
		rc = { ...cfg, main: { ...cfg.main, tproxy_port: idx.ports.tproxy, dns_port: idx.ports.dns } };
	let res = { ...resolve(rc, ubus.connect()), ipv6: idx?.ipv6 };
	let errs = [], mode = want;
	// no config at all (boot with a port taken) or no servers: no xray to send the clients
	// and their DNS to (its ports may be another program's, generate checks them with servers only)
	if (!length(idx?.servers) && want == 'full')
		mode = cfg.access.killswitch ? 'block' : 'passthrough';
	if (length(res.errors)) {
		push(errs, `access points not found: ${join('; ', res.errors)}`);
		log(errs[0]);
		if (want != 'passthrough')
			mode = 'block';
	}

	// split tunneling (#67): only full and passthrough carry the lists
	if (mode in [ 'full', 'passthrough' ])
		res.direct = direct_nets(cfg);
	let err = apply(rc, res, MODES[mode]);
	// a list nft does not take (out of kernel memory, say) must not block the clients:
	// they go through the tunnel without it, the status shows the error
	if (err != null && length([ ...(res.direct?.v4 ?? []), ...(res.direct?.v6 ?? []) ])) {
		let e = `split tunneling list rejected, all traffic goes through the tunnel: ${err}`;
		push(errs, e);
		log(e);
		res.direct = null;
		err = apply(rc, res, MODES[mode]);
	}
	if (err != null) {
		push(errs, `firewall rules failed: ${err}`);
		let tried = mode;
		mode = null;
		for (let m in [ 'block', 'minimal' ])
			if (m != tried && apply(rc, res, MODES[m]) == null) {
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

// the server xray runs (its id and hash) and the one chosen (they differ until a reload
// applies a switch); ids from before #49 are hashes, list_change() matches both
function active_ids() {
	let idx = read_json(INDEX_FILE);
	let e = filter(idx?.servers ?? [], (e) => e.id == idx.active)[0];
	return [ idx?.active, e?.hash, trim(readfile(ACTIVE_FILE) ?? '') ];
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
	// read before the caches: the marker goes once the config is written, unless an update
	// set it again meanwhile
	let stale = readfile(STALE_FILE);
	prune(cfg);
	prune_lists(cfg);
	let all = all_servers(cfg), servers = all;
	let active = trim(readfile(ACTIVE_FILE) ?? ''), prev = read_json(INDEX_FILE);
	// IPv6 and the ports held by others (not by our running xray), once for every index below
	let env = host_env();
	// everything but the servers that goes into the config (ports, DNS, sniffing, listen…)
	// the direct domains (#67) only when set: the key of the configs without them stays as it was
	let domains = direct_domains(cfg);
	let sig = bin_sig(), frame = conf_key(length(domains) ? [ cfg.main, cfg.access, env.ipv6, domains ] : [ cfg.main, cfg.access, env.ipv6 ]), tested = read_json(TESTED_FILE);
	if (type(tested?.ok) != 'object' || tested.bin != sig || tested.frame != frame)
		tested = { bin: sig, frame, full: null, ok: {} };
	tested.why ??= {};
	let verdict = (s) => tested.ok[s.key ??= conf_key(s.outbound)];
	let set_key = (list) => conf_key(sort(map(list, (s) => s.key ?? conf_key(s.outbound))));
	// rejected before: dropped without a test
	// each reason in full went to the log when the server was tested
	let brief = (r) => (length(r) > 80) ? `${substr(r, 0, 79)}…` : r;
	let skipped = map(filter(servers, (s) => verdict(s) === false),
		(s) => tested.why[s.key] ? `${s.name} (${brief(tested.why[s.key])})` : s.name);
	if (length(skipped)) {
		log(`xray rejected ${length(skipped)} server(s) earlier: ${join(', ', skipped)}`);
		servers = filter(servers, (s) => verdict(s) !== false);
	}
	let idx = build_index(cfg, servers, active, prev, env);
	// xray would not start: rather the config it runs, like out of time
	let taken = length(servers) ? ports_error(cfg, env) : null;
	if (taken) {
		log(`xray ports ${taken}`);
		mkdir_p(RUN_DIR);
		write_file(GENERATE_ERROR_FILE, `xray ports ${taken}`);
		exit(5);
	}
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
		let ok = {}, why = {};
		for (let s in all)
			if (verdict(s) != null) {
				ok[s.key] = verdict(s);
				if (!ok[s.key] && tested.why[s.key])
					why[s.key] = tested.why[s.key];
			}
		tested.ok = ok;
		tested.why = why;
		write_json(TESTED_FILE, tested);
	}
	function commit(code) {
		unlink(tmp);
		unlink(GENERATE_ERROR_FILE);
		if (!rename(next, CONFIG_FILE))
			die(`cannot write ${CONFIG_FILE}`);
		write_json(INDEX_FILE, idx);
		if (stale != null && readfile(STALE_FILE) === stale)
			unlink(STALE_FILE);
		// build_index found the chosen server under another id by its hash: keep the choice
		if (idx.moved_from) {
			write_file(ACTIVE_FILE, idx.active);
			if (trim(readfile(MANUAL_FILE) ?? '') == idx.moved_from)
				write_file(MANUAL_FILE, idx.active);
		}
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
		write_json(tmp, generate(cfg, [], build_index(cfg, [], null, null, env)));
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
			if (put(tmp, generate(cfg, [ s ], build_index(cfg, [ s ], s.id, null, env))))
				ok = xray_ok(tmp, TEST_ONE, TEST_FULL);
			if (definite) {
				tested.ok[s.key] = ok;
				if (!ok && reason)
					tested.why[s.key] = reason;
			}
			if (ok == null)
				untested++;
			else if (ok)
				push(good, s);
			else {
				push(bad, s.name);
				// a newer xray forbids what the link sets (vless without TLS, allowInsecure…)
				if (definite && reason)
					log(`xray rejected server "${s.name}": ${reason}`);
			}
		}
		log(`xray rejected ${length(bad)} server(s): ${join(', ', bad)}`);
		if (untested && !length(good))
			out_of_time();	// rather the previous config than none
		if (untested)
			log(`generate ran out of time (${GENERATE_BUDGET} s): ${untested} server(s) not tested, dropped`);
		servers = good;
		idx = build_index(cfg, servers, active, prev, env);
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
	let sids = slice(ARGV, 1), port = active_port(), out = {};
	let all = !length(sids) || ('all' in sids);
	if (!lock_update()) {
		warn('another subscription update is running\n');
		exit(5);
	}
	let before = all_servers(cfg);
	for (let sub in cfg.subscriptions) {
		if (!sub.enabled || !(all || (sub.id in sids)))
			continue;
		let r = update(sub, port);
		out[sub.id] = r;
		log(r.error ? `subscription "${sub.name}": ${r.error}`
			: `subscription "${sub.name}": ${r.count} servers${r.skipped ? `, ${r.skipped} skipped` : ''}${r.changed ? ' (changed)' : ''}`);
	}
	// only addresses of servers xray does not use now changed (hosts rotated, #49): no
	// reload that would drop the clients' connections, the next one applies them
	let need = list_change(before, all_servers(cfg), active_ids());
	if (need == 'stale') {
		mkdir_p(RUN_DIR);
		write_file(STALE_FILE, `${time()} ${SELF}\n`);	// another content each time, see generate
		log('subscriptions changed servers not in use, the next reload applies them');
	}
	unlock_update();
	printf('%J\n', out);
	exit((need == 'reload') ? 0 : 2);
}

// the Russian list of split tunneling (#67): downloaded through the active server, then
// directly; a changed list goes into the rules at once, xray is not restarted.
// 0: changed, 2: unchanged, 1: error
case 'lists': {
	let r = update_lists(cfg, active_port());
	log(r.error ? `split tunneling list: ${r.error}`
		: `split tunneling list: ${r.v4} IPv4 and ${r.v6} IPv6 networks${r.changed ? ' (changed)' : ''}`);
	printf('%J\n', r);
	if (r.error)
		exit(1);
	if (r.changed && readfile(FW_WANT_FILE))
		fw(null);
	exit(r.changed ? 0 : 2);
}

default:
	warn('usage: cli.uc generate | ifnames | ifnames-wait | fw-apply [passthrough] | fw-guard | fw-refresh | fw-remove | update [sid...|all] | lists\n');
	exit(1);
}
