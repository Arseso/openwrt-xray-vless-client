#!/usr/bin/ucode
// SPDX-License-Identifier: MIT
// xvpnd: health checks, failover to the fastest server by HTTP ping,
// subscription auto-update. Publishes the ubus object "xvpn".

'use strict';

import * as uloop from 'uloop';
import * as ubus from 'ubus';
import { readfile, unlink, access, stat } from 'fs';
import {
	load_config, read_json, write_json, write_file, mkdir_p, shq, update_running, procs, tree, kill_tree,
	ETC_DIR, RUN_DIR, CONFIG_FILE, INDEX_FILE, ACTIVE_FILE, STATE_FILE, FW_ERROR_FILE
} from 'xvpn.util';
import { due_in } from 'xvpn.subscription';

const CLI = '/usr/share/xvpn/cli.uc';
const SUB_CHECK = 300;
const XRAY_GRACE = 10;		// s xray may be down before it counts: start, procd respawn
const XRAY_RETRY = 15;		// s between our restarts of xray
const XRAY_RESTARTS = 3;
const XRAY_BACKOFF = 600;	// s between tries once the restarts did not help
const XRAY_UNKNOWN = 'unknown';	// procd does not answer: neither xray nor the server is blamed
const RELOAD_IDLE = 60;		// s a reload may make no progress before it is killed, see watch_reload()
const RELOAD_MAX = 360;		// s at most for a reload; generate gives up after 240
const RELOAD_RETRY = 30;	// s between a failed reload and the next try

const cfg = load_config();
const H = cfg.health;
const STALL = 3 * H.interval + RELOAD_MAX + 30;	// s without health checks: see watchdog()

let index = { servers: [] }, index_raw = null;
let prev = read_json(STATE_FILE) ?? {};

let st = {
	state: 'starting',
	active: null,
	since: time(),
	fails: 0,
	gen: 0,			// index generation, see load_index()
	testing: false,
	updating: false,
	reloading: false,	// a reload is running or xray is settling after one
	reload_pending: false,
	reload_error: null,	// the last reload hung or failed: status shows error until one goes through
	choose_pending: null,	// choose_best() decision put off until the reload settles
	passthrough: false,
	last_error: null,
	last_switch: prev.last_switch,
	last_test: prev.last_test,
	latency: prev.latency ?? {},
	quarantine: prev.quarantine ?? {},
	xray: {},	// see xray_down()
	xray_choose: null,	// choose_best() decision put off while xray does not work
	xray_choose_code: null,	// 7: the aborted test saw a refused test port, see test_abort
};
let test_waiters = [], testq = null, test_resume = null, test_abort = null;
let timers = {}, settling = false, reload = null;
let probe_seq = 0;
let conn;
// ucode does not hoist functions: these call each other in a cycle, defined below
let reload_service, reindex, choose_best, check;

// The daemon must not wait for logd (logger and logread do): messages go to one logger
// at a time in the background, at most LOG_QUEUE wait meanwhile. A logger stuck with logd
// is not killed: that would lose its messages, they arrive once logd is back.
const LOG_QUEUE = 100;
let logq = [], logging = false, log_dropped = 0;

function flush_log() {
	let batch = logq, p;
	logq = [];
	if (log_dropped)
		push(batch, `${log_dropped} log messages dropped, logd is stuck`);
	log_dropped = 0;
	logging = true;
	p = uloop.process('/bin/sh', [ '-c', 'printf "%s\\n" "$@" | /usr/bin/logger -t xvpn', 'sh', ...batch ],
		{ PATH: '/usr/sbin:/usr/bin:/sbin:/bin' }, () => {
			logging = false;
			if (length(logq))
				flush_log();
		});
	if (!p)
		logging = false;	// out of memory: these are lost
}

function log(msg) {
	if (length(logq) >= LOG_QUEUE) {
		shift(logq);
		log_dropped++;
	}
	push(logq, msg);
	if (!logging)
		flush_log();
}

function server(id) {
	return filter(index.servers, (e) => e.id == id)[0];
}

// Re-reads the index when it changed on disk. Test ports are positional, so each
// change starts a new generation: measurements started before it went through
// the old config and are dropped (see valid()).
function load_index() {
	let raw = readfile(INDEX_FILE), idx = null;
	if (raw == index_raw)
		return false;
	index_raw = raw;
	try {
		idx = raw ? json(raw) : null;
	}
	catch (e) { }
	index = idx ?? { servers: [] };
	st.gen++;

	let ids = {};
	for (let e in index.servers)
		ids[e.id] = true;
	for (let id in keys(st.latency))
		if (!ids[id])
			delete st.latency[id];
	for (let id in keys(st.quarantine))
		if (!ids[id])
			delete st.quarantine[id];
	// a running test also covers servers that have just appeared
	if (testq)
		for (let e in index.servers)
			if (!testq.seen[e.id]) {
				testq.seen[e.id] = true;
				push(testq.queue, e.id);
			}
	return true;
}

// A measurement is trusted only if no reload happened since it started.
function valid(gen) {
	return gen == st.gen && !st.reloading;
}

function save() {
	mkdir_p(RUN_DIR);
	write_json(STATE_FILE, {
		last_switch: st.last_switch, last_test: st.last_test,
		latency: st.latency, quarantine: st.quarantine,
	});
}

function set_state(s, err) {
	if (st.state != s)
		log(`state: ${st.state} -> ${s}${err ? ` (${err})` : ''}`);
	st.state = s;
	st.last_error = err;
}

// When the process cannot be started (out of memory), cb gets -1 a second later.
function spawn(cmd, args, cb) {
	let p = uloop.process(cmd, args, { PATH: '/usr/sbin:/usr/bin:/sbin:/bin' }, cb ?? (() => null));
	if (!p) {
		log(`cannot start ${cmd}`);
		if (cb)
			uloop.timer(1000, () => cb(-1));
	}
	return p;
}


// HTTP ping through a SOCKS test port (or direct when port is null).
// Calls cb(ms, code), ms < 0 on failure, code is the curl exit code (-1: curl did not start).
function probe(port, cb) {
	let out = `${RUN_DIR}/probe-${++probe_seq}`;
	let cmd = sprintf("/usr/bin/curl -s -o /dev/null --connect-timeout %d --max-time %d -w '%%{http_code} %%{time_starttransfer}' %s %s > %s 2>/dev/null",
		H.timeout, H.timeout, port ? `-x socks5h://127.0.0.1:${port}` : '', shq(H.url), shq(out));

	spawn('/bin/sh', [ '-c', cmd ], (code) => {
		if (code < 0)
			return cb(-1, -1);
		let r = split(trim(readfile(out) ?? ''), ' ');
		unlink(out);
		let http = int(r[0]);
		let ok = (code == 0 && (http == 204 || http == 200));
		cb(ok ? int(+r[1] * 1000) : -1, code);
	});
}

// Monotonic: grace and retries must not jump with the clock set by NTP at boot.
function now() {
	return clock(true)[0];
}

// Health checks are going on: see watchdog().
function alive() {
	st.alive = now();
}

// procd's xray instance; null when there is none, false when procd does not answer.
function xray_instance() {
	let r = conn.call('service', 'list', { name: 'xvpn' });
	return (r == null) ? false : r.xvpn?.instances?.xray;
}

function bin_sig() {
	let s = stat(cfg.main.xray_bin);
	return s ? `${s.inode}:${s.size}:${s.mtime}` : '';
}

// Log lines without timestamps, the banner and the usual warnings, the last three.
function tidy(lines) {
	lines = filter(map(lines, (l) => trim(replace(l, /^[0-9\/]+ [0-9:.]+ /, ''))),
		(l) => l != '' && !match(l, /^Xray [0-9]|^A unified platform|^\[Info\]|core: Xray .* started|deprecated/));
	return substr(join('; ', slice(lines, -3)), 0, 400);
}

// procd logs xray's stdout and stderr under the binary name: the lines of pid or,
// when it is not running (respawn), of the latest process with that name.
function xray_lines(raw, pid) {
	let tag = replace(cfg.main.xray_bin, /.*\//, ''), lines = [], last = null;
	for (let l in split(raw, '\n')) {
		let m = match(l, / daemon\.[a-z]+ ([^ []+)\[([0-9]+)\]: (.*)$/);
		if (!m || m[1] != tag || (pid && m[2] != `${pid}`))
			continue;
		if (m[2] != last) {
			last = m[2];
			lines = [];
		}
		push(lines, m[3]);
	}
	return lines;
}

function xray_err() {
	let x = st.xray, err = x.problem + (x.why ? `: ${x.why}` : '');
	if (x.restarts >= XRAY_RESTARTS)
		err += ` (${XRAY_RESTARTS} restarts did not help, next try in ${XRAY_BACKOFF / 60} min or when ${cfg.main.xray_bin} changes)`;
	return err;
}

// Async like xray_test(): logread waits for logd, a stuck one is killed after 5 s.
// The lines land in x.log, the state is updated once they are there.
function xray_log(pid) {
	let x = st.xray, out = `${RUN_DIR}/xray-log-${++probe_seq}`, p, t;
	if (x.reading)
		return;
	x.reading = true;
	p = spawn('/bin/sh', [ '-c', `exec /sbin/logread -l 300 > ${shq(out)} 2>/dev/null` ], () => {
		t?.cancel();
		let raw = readfile(out) ?? '';
		unlink(out);
		x.reading = false;
		if (st.xray !== x)
			return;
		x.log = tidy(xray_lines(raw, pid)) || null;
		if (st.state == 'xray_down' && x.problem && x.from_log) {
			x.why = x.log;
			set_state('xray_down', xray_err());
		}
	});
	if (p)
		t = uloop.timer(5000, () => system([ '/bin/kill', '-9', `${p.pid()}` ]));
}

// What `xray run -test` says about the config cli.uc did not start xray with. Async:
// a hung binary is killed after 5 s; the result is kept until the next restart.
function xray_test() {
	let x = st.xray, out = `${RUN_DIR}/xray-test-${++probe_seq}`, p, t;
	if (x.testing)
		return;
	x.testing = true;
	p = spawn('/bin/sh', [ '-c', `exec ${shq(cfg.main.xray_bin)} run -test -c ${shq(CONFIG_FILE)} > ${shq(out)} 2>&1` ], () => {
		t?.cancel();
		let why = tidy(split(readfile(out) ?? '', '\n'));
		unlink(out);
		x.testing = false;
		if (st.xray !== x || why == '')
			return;
		x.test = why;
		if (st.state == 'xray_down' && x.problem) {
			x.why = why;
			set_state('xray_down', xray_err());
		}
	});
	if (p)
		t = uloop.timer(5000, () => system([ '/bin/kill', '-9', `${p.pid()}` ]));
}

// Why xray does not work, for last_error: a missing binary; when cli.uc did not start
// it, `xray run -test`; when it is not running or not listening, its last log lines.
// Stopped and hung ones have nothing useful in the log.
function xray_why(problem, inst) {
	let bin = cfg.main.xray_bin;
	st.xray.from_log = false;
	if (!access(bin, 'x'))
		return `${bin} is missing or not executable`;
	if (problem == 'xray is stopped' || problem == 'xray does not respond')
		return null;
	if (!inst) {
		if (st.xray.test == null)
			xray_test();
		return st.xray.test;
	}
	st.xray.from_log = true;
	xray_log(inst.running ? inst.pid : null);
	return st.xray.log;
}

// Tells "xray does not work" from "the server is down": the instance runs under procd,
// is not stopped and answers on its api port, which needs no server. code: curl exit
// code of the failed probe, 7 = the test port refused the connection.
// Calls cb(problem, inst): null when xray works, XRAY_UNKNOWN when procd does not answer.
function xray_check(code, cb) {
	let inst = xray_instance();
	if (inst === false)
		return cb(XRAY_UNKNOWN);
	if (!inst?.running)
		return cb('xray is not running', inst);
	if (match(readfile(`/proc/${inst.pid}/stat`) ?? '', /\) T /))
		return cb('xray is stopped', inst);
	spawn('/usr/bin/curl', [ '-s', '-o', '/dev/null', '--max-time', '3', `http://127.0.0.1:${cfg.main.api_port}/` ], (c) => {
		if (c < 0)
			cb(XRAY_UNKNOWN);
		else if (c == 7 || c == 28)
			cb(c == 7 ? 'xray does not accept connections' : 'xray does not respond', inst);
		else if (code == 7)
			cb('xray does not accept connections on the test port', inst);
		else
			cb(null);
	});
}

function xray_up() {
	st.xray = {};
}

function restart_xray(inst) {
	let x = st.xray;
	x.restarts = (x.restarts ?? 0) + 1;
	x.at = now();
	x.sig = bin_sig();
	x.test = null;	// the binary or the config may be fixed by now
	log(x.restarts <= XRAY_RESTARTS ? `restarting xray (${x.restarts}/${XRAY_RESTARTS})`
		: `restarting xray again (try ${x.restarts})`);
	if (inst?.running) {
		// hung or stopped: procd starts it again after the kill
		st.gen++;
		conn.call('service', 'signal', { name: 'xvpn', instance: 'xray', signal: 9 });
	}
	else
		reload_service();	// in procd's respawn delay, or cli.uc did not start it
}

// xray does not work: no server is to blame, so none goes to quarantine and
// passthrough stays as it is. After XRAY_GRACE the state is xray_down, then up to
// XRAY_RESTARTS restarts XRAY_RETRY apart, then one every XRAY_BACKOFF or as soon as
// the binary changes. reason: a choose_best() decision to take once xray works again.
function xray_down(problem, inst, reason) {
	let x = st.xray, t = now();
	if (reason)
		st.xray_choose = reason;
	if (st.active)
		delete st.quarantine[st.active];
	x.since ??= t;
	if (t - x.since < XRAY_GRACE)
		return;
	x.problem = problem;
	x.why = xray_why(problem, inst);
	set_state('xray_down', xray_err());
	let restarts = x.restarts ?? 0;
	if (restarts < XRAY_RESTARTS ? t - (x.at ?? x.since) >= XRAY_RETRY
			: (t - x.at >= XRAY_BACKOFF || bin_sig() != x.sig))
		restart_xray(inst);
}

function quarantined(id) {
	return (st.quarantine[id] ?? 0) > time();
}

function best(ignore_quarantine) {
	let b = null;
	for (let e in index.servers) {
		let l = st.latency[e.id];
		if (!l || l.ms < 0 || (!ignore_quarantine && quarantined(e.id)))
			continue;
		if (!b || l.ms < st.latency[b.id].ms)
			b = e;
	}
	return b;
}

function test_all(cb) {
	if (cb)
		push(test_waiters, cb);
	if (st.testing)
		return;

	reindex(false);
	st.testing = true;
	// testq is this run's until done(): callbacks of an aborted run see another one or null
	let q = testq = { queue: [], seen: {}, failed: {}, refused: false };
	for (let e in index.servers) {
		q.seen[e.id] = true;
		push(q.queue, e.id);
	}
	let running = 0;

	function done(problem, inst) {
		st.testing = false;
		testq = test_resume = test_abort = null;
		st.last_test = time();
		save();
		let w = test_waiters;
		test_waiters = [];
		for (let f in w)
			f(problem, inst);
	}

	// failures count only when xray works: with xray down every server would look dead
	function finish() {
		if (!length(q.failed) && !q.refused)
			return done(null);
		q.finishing = true;
		let gen = st.gen;
		xray_check(q.refused ? 7 : null, (problem, inst) => {
			if (testq !== q)
				return;
			if (!valid(gen)) {
				// a reload during the check: the failures went through the old config
				q.finishing = false;
				for (let id in keys(q.failed))
					if (server(id))
						push(q.queue, id);
				q.failed = {};
				q.refused = false;
				return next();
			}
			if (!problem)
				for (let id, at in q.failed)
					if (server(id))
						st.latency[id] = { ms: -1, at };
			done(problem, inst);
		});
	}

	// the port is looked up by id at start: the queue survives index changes
	function next() {
		// nothing is measured while xray restarts: settle() resumes the test
		if (testq !== q || q.finishing)
			return;
		while (!st.reloading && running < H.concurrency && length(q.queue)) {
			let id = shift(q.queue), e = server(id), gen = st.gen;
			if (!e)
				continue;	// gone from the list meanwhile
			running++;
			probe(e.test_port, (ms, code) => {
				running--;
				if (testq !== q)
					return;
				alive();
				if (code < 0)
					;	// curl did not start: no verdict on the server
				else if (!valid(gen)) {
					if (server(id))
						push(q.queue, id);	// went through the old config: measure again
				}
				else if (ms >= 0)
					st.latency[id] = { ms, at: time() };
				else if (code == 7)
					q.refused = true;	// the test port refused: xray, not the server
				else
					q.failed[id] = time();
				next();
			});
		}
		if (!running && !length(q.queue))
			finish();
	}

	test_resume = next;
	// nothing is known about xray: choose_best() puts its decision off (see check()),
	// a refused test port is checked there
	test_abort = () => {
		if (q.refused)
			st.xray_choose_code = 7;
		done(XRAY_UNKNOWN);
	};
	next();
}

function set_passthrough(on) {
	if (st.passthrough == on)
		return;
	st.passthrough = on;
	log(on ? 'no live servers and kill switch is off: clients go direct'
		: 'server is alive again: clients go through VPN');
	if (!spawn('/usr/bin/ucode', on ? [ CLI, 'fw-apply', 'passthrough' ] : [ CLI, 'fw-apply' ]))
		st.passthrough = !on;	// the next check tries again
}

// Syncs the daemon with the config xray runs now.
function adopt_index() {
	let pending = st.choose_pending;
	st.choose_pending = null;
	if (!length(index.servers)) {
		set_state('no_servers', 'no servers in subscriptions');
		return;
	}
	if (index.active != st.active) {
		// active server disappeared from the list
		st.active = index.active;
		choose_best('server list changed');
		return;
	}
	if (pending)
		choose_best(pending);
	else
		check();
}

// xray restarts with the new config: give it a moment before measuring again.
function settle() {
	settling = true;
	timers.settle = uloop.timer(3000, () => {
		settling = false;
		st.reloading = false;
		alive();
		if (st.reload_pending) {
			st.reload_pending = false;
			reload_service();
			return;
		}
		let paused = st.testing;	// a test started by adopt_index() runs by itself
		adopt_index();
		if (paused)
			test_resume();
	});
}

function after_reload() {
	st.reload_error = null;
	load_index();
	st.passthrough = false;
	settle();
}

// The reload hung or failed: what xray runs is likely the old config (generate writes the
// new one at the end), so the checks, failover and passthrough go on. The status shows
// error until a reload goes through: another try every RELOAD_RETRY, select and updates
// try at once, a reload past the daemon (reindex) counts too.
function reload_failed(why) {
	log(`${why}, next try in ${RELOAD_RETRY} s`);
	st.reload_error = why;
	st.reloading = st.reload_pending = false;
	load_index();
	st.gen++;
	if (st.testing)
		test_abort();
	timers.retry?.cancel();
	timers.retry = uloop.timer(RELOAD_RETRY * 1000, () => {
		log('trying the reload again');
		reload_service();
	});
}

// What a working reload changes: its processes and their CPU time, and those of another
// `init.d/xvpn` (rpcd, UCI triggers) that holds procd's service lock meanwhile. One waiting
// for the lock or for a stuck procd changes nothing.
function reload_sig(pid) {
	let ps = procs(), seen = {}, cpu = 0;
	for (let root in [ pid, ...filter(keys(ps), (p) => match(ps[p].cmd, /\/etc\/init\.d\/xvpn/)) ])
		for (let p in tree(root, ps))
			if (!seen[p]) {
				seen[p] = true;
				cpu += ps[p]?.cpu ?? 0;
			}
	return `${join(',', sort(keys(seen)))} ${cpu}`;
}

function watch_reload(r) {
	r.t = uloop.timer(10000, () => {
		if (reload !== r)
			return;
		let sig = reload_sig(r.p.pid()), t = now();
		if (sig != r.sig) {
			r.sig = sig;
			r.last = t;
		}
		if (t - r.last < RELOAD_IDLE && t - r.at < RELOAD_MAX)
			return r.t.set(10000);
		reload = null;
		kill_tree(r.p.pid());
		unlink(r.out);
		reload_failed(t - r.at >= RELOAD_MAX ? `reload did not finish in ${RELOAD_MAX} s and was killed`
			: `reload made no progress for ${RELOAD_IDLE} s and was killed`);
	});
}

reload_service = function() {
	if (st.reloading) {
		st.reload_pending = true;
		return;
	}
	timers.retry?.cancel();
	st.reloading = true;
	st.gen++;	// measurements in flight go through the config being replaced
	let r = reload = { at: now(), out: `${RUN_DIR}/reload-${++probe_seq}` };
	r.last = r.at;
	// uloop.process reports a killed process as exit code 0: sh writes the script's own
	r.p = spawn('/bin/sh', [ '-c', `/etc/init.d/xvpn reload; echo $? > ${shq(r.out)}` ], (code) => {
		if (reload !== r)
			return;	// killed by watch_reload()
		reload = null;
		r.t?.cancel();
		let rc = readfile(r.out);
		unlink(r.out);
		if (code < 0)
			return reload_failed('cannot start /etc/init.d/xvpn reload');
		if (rc == null || int(rc) >= 128)
			return reload_failed('reload was killed (out of memory?)');
		after_reload();
	});
	// a stuck procd must not stop the reloads for good
	if (r.p)
		watch_reload(r);
};

// The service is also reloaded past the daemon (rpcd, UCI triggers on wireless and
// network): service_started() in init.d notifies us after fw-apply (notified),
// and check() polls the index.
reindex = function(notified) {
	let changed = load_index();
	if (notified || changed)
		st.passthrough = false;	// the reload applies the normal rules
	if (st.reloading) {
		// changed again, or polling saw the change before the reload finished:
		// count the pause from the latest config and from fw-apply
		if (settling && (changed || notified))
			timers.settle.set(3000);
		return;	// our own reload: after_reload() takes over
	}
	if (notified && st.reload_error) {
		st.reload_error = null;	// whoever ran it, the config is applied
		timers.retry?.cancel();
	}
	if (!changed)
		return;
	log('server list changed by a reload outside the daemon');
	st.reloading = true;
	settle();
};

function switch_to(id, reason) {
	let e = server(id);
	if (!e)
		return false;
	log(`switching to "${e.name}" (${reason})`);
	st.last_switch = { from: st.active, to: id, reason, at: time() };
	st.active = id;
	st.since = time();
	st.fails = 0;
	st.xray_choose = null;	// a manual choice wins over a decision put off
	delete st.quarantine[id];
	mkdir_p(ETC_DIR);
	write_file(ACTIVE_FILE, id);
	save();
	set_state('connected', null);
	reload_service();
	return true;
}

choose_best = function(reason) {
	st.xray_choose = null;
	test_all((problem, inst) => {
		// the test may end mid-reload with partial data: decide once it settles
		if (st.reloading) {
			st.choose_pending = reason;
			return;
		}
		// xray did not work during the test: decide once it does
		if (problem == XRAY_UNKNOWN) {
			st.xray_choose = reason;
			return;
		}
		if (problem)
			return xray_down(problem, inst, reason);
		xray_up();
		let b = best() ?? best(true);
		if (!b) {
			set_state('no_servers', 'no live servers');
			if (!cfg.access.killswitch)
				set_passthrough(true);
			return;
		}
		set_passthrough(false);
		if (b.id == st.active && trim(readfile(ACTIVE_FILE) ?? '') == b.id) {
			st.fails = 0;
			set_state('connected', null);
			return;
		}
		switch_to(b.id, reason);
	});
};

function failover(reason) {
	if (st.active)
		st.quarantine[st.active] = time() + H.quarantine;
	set_state('failover', reason);
	choose_best(reason);
}

check = function() {
	reindex(false);
	if (st.testing || st.reloading)
		return;
	alive();
	if (!length(index.servers)) {
		set_state('no_servers', 'no servers in subscriptions');
		return;
	}

	let e = server(st.active);
	if (!e)
		return failover('no active server');

	let gen = st.gen;
	if (st.xray_choose) {
		// a decision put off while xray did not work
		let code = st.xray_choose_code;
		st.xray_choose_code = null;
		xray_check(code, (problem, inst) => {
			if (!valid(gen) || !st.xray_choose || problem == XRAY_UNKNOWN)
				return;
			if (problem)
				return xray_down(problem, inst);
			xray_up();
			let reason = st.xray_choose;
			st.xray_choose = null;
			choose_best(reason);
		});
		return;
	}
	probe(e.test_port, (ms, code) => {
		if (!valid(gen) || st.active != e.id || code < 0)
			return;
		if (ms >= 0) {
			st.latency[e.id] = { ms, at: time() };
			xray_up();
			st.fails = 0;
			set_passthrough(false);
			set_state('connected', null);
			return;
		}
		xray_check(code, (problem, inst) => {
			if (!valid(gen) || st.active != e.id || problem == XRAY_UNKNOWN)
				return;
			if (problem)
				return xray_down(problem, inst);
			xray_up();
			st.latency[e.id] = { ms, at: time() };
			st.fails++;
			if (st.fails < H.fail_threshold) {
				set_state('degraded', `${st.fails} failed checks`);
				return;
			}
			probe(null, (dms, dcode) => {
				if (!valid(gen) || st.active != e.id || dcode < 0)
					return;
				if (dms < 0)
					set_state('wan_down', 'no direct internet access');
				else
					failover(`"${e.name}" is down`);
			});
		});
	});
};

function rank() {
	if (st.testing || st.reloading || st.reload_error || st.state != 'connected')
		return;
	test_all((problem) => {
		if (problem || !H.auto_best || st.reloading)
			return;
		let b = best(), cur = st.latency[st.active];
		if (b && b.id != st.active && cur && cur.ms >= 0 && st.latency[b.id].ms + H.hysteresis < cur.ms)
			switch_to(b.id, `faster server: ${st.latency[b.id].ms} ms vs ${cur.ms} ms`);
	});
}

// Updates due (or all when force) subscriptions in one `cli.uc update` run, the only
// path to update them while the daemon runs (rpcd calls ubus xvpn update).
// Returns an error message or null.
function update_subs(force, only) {
	if (st.updating || update_running())
		return 'busy';
	// a subscription may have been added or enabled a moment ago
	let due = filter(load_config().subscriptions, (s) => s.enabled && s.url
		&& (only ? s.id == only : (force || due_in(s) <= 0)));
	if (!length(due))
		return 'no subscriptions to update';

	st.updating = true;
	spawn('/usr/bin/ucode', [ CLI, 'update', ...map(due, (s) => s.id) ], (code) => {
		st.updating = false;
		if (code == 0)	// server list changed
			reload_service();
	});
	return null;
}

function status() {
	reindex(false);
	let servers = map(index.servers, (e) => ({
		id: e.id, name: e.name, proto: e.proto, address: e.address, port: e.port,
		sub: e.sub, sub_name: e.sub_name,
		latency: st.latency[e.id]?.ms, tested: st.latency[e.id]?.at,
		quarantined: quarantined(e.id),
	}));
	// cli.uc could not apply the rules and blocked the clients (fail closed)
	// and a reload that failed: what xray runs may be not what the daemon wants
	let fw_error = readfile(FW_ERROR_FILE), error = fw_error ?? st.reload_error;
	return {
		state: error ? 'error' : st.state, active: st.active, since: st.since, fails: st.fails,
		testing: st.testing, updating: st.updating || !!update_running(), passthrough: st.passthrough,
		last_error: error ?? st.last_error, last_switch: st.last_switch, last_test: st.last_test,
		xray_restarts: st.xray.restarts ?? 0, servers,
	};
}

// Last resort for a flag left set by a path nobody thought of: no check got past
// testing/reloading for STALL seconds. A hung reload is watch_reload()'s job.
function watchdog() {
	let idle = now() - st.alive;
	if (idle < STALL)
		return;
	log(`health checks stalled for ${idle} s (testing: ${st.testing}, reloading: ${st.reloading}), recovering`);
	let again = st.reload_pending || reload != null;
	if (reload) {
		reload.t?.cancel();
		if (reload.p)
			kill_tree(reload.p.pid());
		reload = null;
	}
	timers.settle?.cancel();
	settling = false;
	st.reloading = st.reload_pending = false;
	st.gen++;
	alive();
	if (st.testing)
		test_abort();
	if (again)
		reload_service();
	else
		check();
}

function every(name, sec, fn) {
	let t;
	t = uloop.timer(sec * 1000, () => {
		t.set(sec * 1000);
		fn();
	});
	timers[name] = t;
}

uloop.init();	// log() needs it

mkdir_p(RUN_DIR);
load_index();
st.active = index.active;
alive();

conn = ubus.connect(null, 2);	// a stuck procd must not hold the loop for long
if (!conn)
	die('cannot connect to ubus');

conn.publish('xvpn', {
	status: {
		call: () => status(),
	},
	test: {
		call: () => {
			// after a failed reload the test ports may not match what xray runs
			if (st.reload_error)
				return { ok: false, error: 'busy' };
			test_all(null);
			return { ok: true };
		},
	},
	check: {
		call: () => {
			check();
			return { ok: true };
		},
	},
	select: {
		args: { id: '' },
		call: (req) => {
			if (st.reloading)
				return { ok: false, error: 'busy' };
			return { ok: switch_to(req.args.id, 'manual selection') };
		},
	},
	update: {
		args: { sid: '' },
		call: (req) => {
			let err = update_subs(true, req.args.sid || null);
			return err ? { ok: false, error: err } : { ok: true };
		},
	},
	reindex: {
		call: () => {
			reindex(true);
			return { ok: true };
		},
	},
});

every('check', H.interval, check);
every('rank', H.rank_interval, rank);
every('subs', SUB_CHECK, () => update_subs(false));
every('watchdog', 30, watchdog);
if (!length(index.servers))
	update_subs(true);
else if (!readfile(ACTIVE_FILE))
	// first start: pick the fastest server
	timers.once = uloop.timer(3000, () => choose_best('startup'));
else {
	timers.check.set(3000);
	timers.subs.set(15000);
}

uloop.run();

// SIGTERM (stop, restart): what is still queued goes out now
for (let m in logq)
	system([ '/usr/bin/logger', '-t', 'xvpn', m ]);
