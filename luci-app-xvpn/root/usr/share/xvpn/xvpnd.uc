#!/usr/bin/ucode
// SPDX-License-Identifier: MIT
// xvpnd: health checks, failover to the best server by HTTP ping and download speed,
// subscription auto-update. Publishes the ubus object "xvpn".

'use strict';

import * as uloop from 'uloop';
import * as ubus from 'ubus';
import { cursor } from 'uci';
import { readfile, unlink, access, stat } from 'fs';
import {
	load_config, read_json, write_json, write_file, mkdir_p, shq, update_running, procs, tree, kill_tree,
	no_auto_ids, set_no_auto, retry_delay, auto_pick, better, MANUAL_FILE, ETC_DIR, RUN_DIR, CONFIG_FILE, INDEX_FILE, ACTIVE_FILE, STATE_FILE, FW_ERROR_FILE, GENERATE_ERROR_FILE, STALE_FILE
} from 'xvpn.util';
import { due_in } from 'xvpn.subscription';
import { dns_via_module, set_active } from 'xvpn.xrayconf';
import { lists_due_in } from 'xvpn.split';
import { counters, counter_step } from 'xvpn.firewall';

const CLI = '/usr/share/xvpn/cli.uc';
const SUB_CHECK = 300;
const XRAY_GRACE = 10;		// s xray may be down before it counts: start, procd respawn
const XRAY_RETRY = 15;		// s between our restarts of xray
const XRAY_RESTARTS = 3;
const XRAY_BACKOFF = 600;	// s between tries once the restarts did not help
const XRAY_UNKNOWN = 'unknown';	// procd does not answer: neither xray nor the server is blamed
const cfg = load_config();
const H = cfg.health;
const RELOAD_IDLE = H.reload_idle;	// s a reload may make no progress before it is killed, see watch_reload()
const RELOAD_MAX = H.generate_budget + 120;	// s at most for a reload from taking procd's lock; generate gives up after its budget
const RELOAD_RETRY = H.reload_retry;	// s between a failed reload and the next try
const RELOAD_TICK = min(10, max(1, int(RELOAD_IDLE / 4))) * 1000;
const STALL = 3 * H.interval + RELOAD_MAX + 30;	// s without health checks: see watchdog()
const TIME_FLAG = `${RUN_DIR}/time_synced`;	// hotplug.d/ntp/50-xvpn: sysntpd has set the clock
const TIME_UNTIL = `${RUN_DIR}/time_wait`;	// end of the wait (monotonic): restarts do not wait again
const URL2 = (H.url2 && H.url2 != H.url) ? H.url2 : null;	// see limited_check()
const URL2_CDN = H.url2_cdn;	// live servers in a row that fail url2 before any passes it: ask it directly
// DNS of the clients (#10): https:// is asked with a DoH request through the test port, an IP
// over UDP (udpcheck.uc); tcp:// is not checked. The UDP check also runs in DoH mode: UDP of
// the clients (QUIC, calls, games) through the server, a warning only (status udp)
const DNS = cfg.access.dns_server;
const DOH = H.dns_check && dns_via_module(cfg) && match(DNS, /^https:/) ? DNS : null;
const UDP_DNS = H.dns_check && !dns_via_module(cfg);
// RFC 8484 GET: A of www.gstatic.com, ID 0
const SPEED = cfg.main.speed_interval;	// s between reads of the tunnel counters, see speed()
const COUNTERS_FILE = `${RUN_DIR}/counters.json`;
const DOH_QUERY = replace(replace(replace(b64enc('\x00\x00\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00\x03www\x07gstatic\x03com\x00\x00\x01\x00\x01'), '+', '-'), '/', '_'), '=', '');

let index = { servers: [] }, index_raw = null;
let prev = read_json(STATE_FILE) ?? {};

let st = {
	state: 'starting',
	active: null,
	since: time(),
	fails: 0,
	gen: 0,			// index generation, see load_index()
	testing: false,
	tests: 0,		// test runs finished, see the ubus method test
	updating: false,
	reloading: false,	// a reload is running or xray is settling after one
	reload_pending: false,
	reload_error: null,	// the last reload hung or failed: status shows error until one goes through
	choose_pending: null,	// choose_best() decision put off until the reload settles
	switches: 0,		// switch_to() calls: a choose_best() older than the last switch is dropped
	failing_over: false,	// failover() began: its switch_to() marks last_switch.failover (desktop notifications)
	passthrough: false,
	last_error: null,
	last_switch: prev.last_switch,
	last_test: prev.last_test,
	latency: prev.latency ?? {},
	speeds: prev.speeds ?? {},	// { id: { mbps, at } } (#95), mbps -1: the download failed, see speed_run()
	speed_last: prev.speed_last,	// the last run of the speed test ended (router clock)
	speed_runs: 0,	// runs finished, see the ubus method speedtest
	quarantine: prev.quarantine ?? {},
	limited: (URL2 && prev.limited_url == URL2) ? (prev.limited ?? {}) : {},	// { id: since }, see limited_check()
	url2_down: false,	// the last test found the CDN of url2 down, see limited_check()
	xray: {},	// see xray_down()
	xray_choose: null,	// choose_best() decision put off while xray does not work
	xray_choose_code: null,	// 7: the test aborted with xray_choose saw a refused test port
	time_wait: null,	// waiting for NTP until then (monotonic), see time_ok()
	time_choose: null,	// choose_best() decision put off until the clock is set
	dead: null,	// no live servers: { delay, next } (monotonic) of the next test of all, see check()
	subs_force: false,	// the first update at start, see auto_update()
	lists_updating: false,	// `cli.uc lists` runs (split tunneling, #67)
	udp: null,	// UDP passes through the active server (#10); null: not checked yet
	dl_at: null,	// the last download (#11) through the active server that went through (monotonic)
	dl_failing: false,	// the last one stalled: tried again at every check
	streak: 0,	// failed checks in a row: counts up when one passes, see failed()
};
let test_waiters = [], testq = null, test_resume = null, test_abort = null;
let timers = {}, settling = false, reload = null;
let probe_seq = 0;
let deep = null;	// deep_check() running: { at } (monotonic)
let bo = null;	// `xray api bo` running: { again }, see apply_active()
let no_auto_sig = null, no_auto_set = {};
let conn;
// speed meter (#83): the last sample, bytes through the tunnel since xvpnd started, B/s
let tun = { last: null, reading: false, traffic: { up: 0, down: 0 }, speed: null };
// ucode does not hoist functions: these call each other in a cycle, defined below
let reload_service, reindex, choose_best, check, reload_failed;

// The daemon must not wait for logd (logger and logread do): messages go to one logger
// at a time in the background, at most LOG_QUEUE wait meanwhile. A logger stuck with logd
// is not killed: that would lose its messages, they arrive once logd is back.
const LOG_QUEUE = 100;
let logq = [], logging = false, log_dropped = 0;

// ucode-mod-uloop (2025.07.18) clears a process after its callback and writes into the handle
// after dropping its own reference to it: a handle nobody else holds is freed by then (use
// after free; musl may unmap it, xvpnd died in uloop.so). Every handle is held here until
// a later run_process(): by then uloop has cleared it. Not in the callback's closure: without
// periodic GC that cycle would never be freed.
let procs_held = {}, procs_done = [], procs_seq = 0;

function run_process(cmd, args, cb) {
	for (let k in procs_done)
		delete procs_held[k];
	procs_done = [];
	let key = `${++procs_seq}`;
	let p = uloop.process(cmd, args, { PATH: '/usr/sbin:/usr/bin:/sbin:/bin' }, (code) => {
		cb(code);
		push(procs_done, key);	// after cb: a run_process() in it must not drop this one yet
	});
	if (p)
		procs_held[key] = p;
	return p;
}

function flush_log() {
	let batch = logq, p;
	logq = [];
	if (log_dropped)
		push(batch, `${log_dropped} log messages dropped, logd is stuck`);
	log_dropped = 0;
	logging = true;
	p = run_process('/bin/sh', [ '-c', 'printf "%s\\n" "$@" | /usr/bin/logger -t xvpn', 'sh', ...batch ], () => {
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

// write_file() dies when a write fails: a full overlay would stop the daemon and procd
// would restart it in a loop (#18). Here the daemon goes on without the file: logged once,
// status shows error until a write to it goes through. fn: write_file or write_json.
let write_errors = {};
function put(fn, path, data) {
	try {
		fn(path, data);
	}
	catch (e) {
		if (!write_errors[path])
			log(`cannot write ${path} (no space left?), going on without it`);
		write_errors[path] = true;
		return false;
	}
	if (write_errors[path]) {
		delete write_errors[path];
		log(`${path} is written again`);
	}
	return true;
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
	st.dead = null;	// other servers: test them at once

	let ids = {};
	for (let e in index.servers)
		ids[e.id] = true;
	for (let id in keys(st.latency))
		if (!ids[id])
			delete st.latency[id];
	for (let id in keys(st.speeds))
		if (!ids[id])
			delete st.speeds[id];
	for (let id in keys(st.quarantine))
		if (!ids[id])
			delete st.quarantine[id];
	for (let id in keys(st.limited))
		if (!ids[id])
			delete st.limited[id];
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
	put(write_json, STATE_FILE, {
		last_switch: st.last_switch, last_test: st.last_test,
		latency: st.latency, quarantine: st.quarantine,
		limited: st.limited, limited_url: URL2,
		speeds: st.speeds, speed_last: st.speed_last,
	});
}

function set_state(s, err) {
	if (st.state != s)
		log(`state: ${st.state} -> ${s}${err ? ` (${err})` : ''}`);
	st.state = s;
	st.last_error = err;
	// the failed server works again: the failover is over without a switch
	if (s == 'connected')
		st.failing_over = false;
	// a live server or WAN back: no pause before the next test of all (see check())
	if (s == 'connected' || s == 'wan_down')
		st.dead = null;
}

// When the process cannot be started (out of memory), cb gets -1 a second later.
function spawn(cmd, args, cb) {
	let p = run_process(cmd, args, cb ?? (() => null));
	if (!p) {
		log(`cannot start ${cmd}`);
		if (cb)
			uloop.timer(1000, () => cb(-1));
	}
	return p;
}


// HTTP ping of url (health.url by default) through a SOCKS test port (or direct when port is null).
// Calls cb(ms, code), ms < 0 on failure, code is the curl exit code (-1: curl did not start).
function probe(port, cb, url) {
	let out = `${RUN_DIR}/probe-${++probe_seq}`;
	let cmd = sprintf("/usr/bin/curl -s --proto =http,https -o /dev/null --connect-timeout %d --max-time %d -w '%%{http_code} %%{time_starttransfer}' %s %s > %s 2>/dev/null",
		H.timeout, H.timeout, port ? `-x socks5h://127.0.0.1:${port}` : '', shq(url ?? H.url), shq(out));

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

// curl with -w fmt through a SOCKS test port (directly when port is null): cb(code, fields),
// code is the curl exit code (-1: curl did not start), fields what -w wrote.
function curl_w(port, url, max_time, fmt, extra, cb) {
	let out = `${RUN_DIR}/probe-${++probe_seq}`;
	let cmd = sprintf("/usr/bin/curl -s --proto =http,https -o /dev/null --connect-timeout %d --max-time %d -w %s %s %s %s > %s 2>/dev/null",
		H.timeout, max_time, shq(fmt), extra, port ? `-x socks5h://127.0.0.1:${port}` : '', shq(url), shq(out));
	spawn('/bin/sh', [ '-c', cmd ], (code) => {
		let r = (code < 0) ? [] : split(trim(readfile(out) ?? ''), ' ');
		unlink(out);
		cb(code, r);
	});
}

// The DoH server of the clients answers through port (directly when null): cb(ok, code, http).
function doh_probe(port, cb) {
	let url = `${DOH}${match(DOH, /\?/) ? '&' : '?'}dns=${DOH_QUERY}`;
	curl_w(port, url, H.timeout, '%{http_code}', "-H 'accept: application/dns-message'", (code, r) =>
		cb(code == 0 && int(r[0]) == 200, code, int(r[0] ?? 0)));
}

// A DNS query over UDP to host:port answers in time: cb(ok), null when the check did not start.
function udp_probe(host, port, cb) {
	spawn('/usr/bin/ucode', [ '/usr/share/xvpn/udpcheck.uc', host, `${port}`, `${min(H.timeout, 3)}` ],
		(code) => cb(code < 0 ? null : code == 0));
}

// health.dl_url downloads in full within dl_timeout (#11): DPI that lets the handshake
// through and freezes the stream after the first KB, or slows it down to a crawl.
// cb(ok, why), ok null when curl did not start.
function dl_probe(port, cb) {
	curl_w(port, H.dl_url, H.dl_timeout, '%{http_code} %{size_download}', '', (code, r) => {
		if (code < 0)
			return cb(null);
		let http = int(r[0]), kb = int(+(r[1] ?? 0) / 1024);
		if (code == 0 && http == 200)
			return cb(true);
		cb(false, code == 28 ? `stalls after ${kb} KB (${H.dl_timeout} s)` : (code ? `fails (curl ${code}, ${kb} KB)` : `fails (HTTP ${http})`));
	});
}

// Direct internet (#11): up when one of health.wan_url answers, so a blocked or broken
// one is no wan_down. cb(up), up null when no curl started.
function wan_probe(cb) {
	let left = length(H.wan_url), up = false, ran = false;
	for (let url in H.wan_url)
		probe(null, (ms, code) => {
			if (code >= 0)
				ran = true;
			if (ms >= 0 && !up) {
				up = true;
				cb(true);
			}
			if (--left == 0 && !up)
				cb(ran ? false : null);
		}, url);
}

// Monotonic: grace and retries must not jump with the clock set by NTP at boot.
function now() {
	return clock(true)[0];
}

// One nft (no process stays) reads the counters of the table: cheap enough for every few
// seconds, unlike `luci.xvpn stats` (xray's own counters). No table (block, stopped
// firewall) is zero speed; a new table starts its counters over, see counter_step(). A nft
// that fails otherwise keeps the base; one that hangs is killed after 3 intervals and the
// speed is unknown (null) meanwhile.
function speed() {
	if (tun.reading)
		return;
	tun.reading = true;
	let t = null, killed = false, p;
	p = run_process('/bin/sh', [ '-c', `exec /usr/sbin/nft -j list counters table inet xvpn > ${COUNTERS_FILE} 2>&1` ], (code) => {
		t?.cancel();
		tun.reading = false;
		if (killed)
			return;	// uloop reports a signal as 0, what it wrote is no answer
		let out = readfile(COUNTERS_FILE), c = clock(true);
		// nft says "No such file or directory" for a table that is not there
		let cur = (code == 0) ? counters(out) : match(out ?? '', /No such file or directory/) ? false : null;
		let s = counter_step(tun.last, cur, c[0] + c[1] / 1e9);
		tun.last = s.last;
		if (s.add) {
			tun.traffic.up += s.add.up;
			tun.traffic.down += s.add.down;
		}
		if (s.speed)
			tun.speed = s.speed;
	});
	if (!p) {
		tun.reading = false;	// out of memory: the next tick tries again
		return;
	}
	t = uloop.timer(3 * SPEED * 1000, () => {
		tun.speed = null;
		killed = true;
		system([ '/bin/kill', '-9', `${p.pid()}` ]);
	});
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
	// with xray's GC settings (init.d gives them to the daemon too): a bad one fails it alike
	let env = join('', map(filter([ 'GOMEMLIMIT', 'GOGC' ], (k) => getenv(k)), (k) => `${k}=${shq(getenv(k))} `));
	p = spawn('/bin/sh', [ '-c', `${env}exec ${shq(cfg.main.xray_bin)} run -test -c ${shq(CONFIG_FILE)} > ${shq(out)} 2>&1` ], () => {
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
	spawn('/usr/bin/curl', [ '-s', '-o', '/dev/null', '--max-time', '3', `http://127.0.0.1:${index.ports?.api ?? cfg.main.api_port}/` ], (c) => {
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

// sysntpd runs: on with servers configured or taken from DHCP
function ntp_on() {
	let c = cursor(), n, off = (v) => v in [ '0', 'false', 'no', 'off', 'disabled' ];
	c.load('system');
	n = c.get_all('system', 'ntp');
	return n?.['.type'] == 'timeserver' && !off(n.enabled) && (length(n.server ?? []) || !off(n.use_dhcp))
		&& system([ '/etc/init.d/sysntpd', 'enabled' ]) == 0;
}

// No RTC: until NTP sets the clock VMess, Shadowsocks 2022, REALITY and TLS fail on
// every server, so none is blamed. Waits at most time_wait s from the first start after boot.
function time_ok() {
	if (st.time_wait == null)
		return true;
	let synced = access(TIME_FLAG);
	if (!synced && now() < st.time_wait)
		return false;
	log(synced ? 'the clock is set by NTP' : `no NTP sync in ${H.time_wait} s, going on with the clock as it is`);
	st.time_wait = null;
	timers.time?.cancel();
	timers.subs?.set(1000);	// the updates put off meanwhile
	return true;
}

function quarantined(id) {
	return (st.quarantine[id] ?? 0) > time();
}

// health.no_auto as { id: true }: read again whenever /etc/config/xvpn changes
// (set_auto, prune in generate, uci by hand); the daemon is not restarted for it (init.d)
function no_auto() {
	let s = stat('/etc/config/xvpn'), sig = s ? `${s.inode}:${s.mtime}:${s.size}` : '';
	if (sig != no_auto_sig) {
		let was = no_auto_set;
		no_auto_sig = sig;
		no_auto_set = {};
		for (let id in no_auto_ids())
			no_auto_set[id] = true;
		// back in auto selection (uci by hand, not set_auto): it may be alive, no pause
		if (length(filter(keys(was), (id) => !no_auto_set[id])))
			st.dead = null;
	}
	return no_auto_set;
}

// The server the daemon or the user chose last (switch_to); generate falls back to the first
// one in the list when there is none or it is gone
function chosen() {
	return trim(readfile(ACTIVE_FILE) ?? '');
}

// The user chose it (select): it stays while it answers, also left out of auto selection.
// One the daemon chose is left as soon as it is left out (set_auto, check()).
function manual_id() {
	return trim(readfile(MANUAL_FILE) ?? '');
}

function by_hand(id) {
	return chosen() == id && manual_id() == id;
}

// Only the servers in auto selection: the fastest out of quarantine and not limited, else
// see auto_pick(). { server, limited } or null.
function pick() {
	let q = {};
	for (let e in index.servers)
		if (quarantined(e.id))
			q[e.id] = true;
	return auto_pick(index.servers, st.latency, no_auto(), q, st.limited, st.speeds, H.auto_mode);
}

// The best server with nothing against it, for a switch to a faster one; null when none.
function best() {
	let p = pick();
	return (p && !p.limited && !quarantined(p.server.id)) ? p.server : null;
}

// Why the daemon stays on a limited server or chose one (see auto_pick())
function only_limited() {
	return `only limited servers answer: ${URL2} fails through every one`;
}

// Why best() found nothing, for last_error.
function no_candidates() {
	let off = no_auto(), n = length(filter(index.servers, (e) => off[e.id]));
	if (n == length(index.servers))
		return 'all servers are excluded from auto selection';
	return n ? `no live servers in auto selection (${n} excluded)` : 'no live servers';
}

// A server that answers health.url may let through only the sites on its whitelist (#61):
// tests also open health.url2 through it, by domain on another CDN. A failure is tried once
// more (not a timeout: a CDN that drops would cost 2 x timeout per server); the verdicts
// of the run go to q.limited, set_limited() takes them once xray is known to work.
// The first URL2_CDN live servers in a row that fail it: a group of whitelists or the CDN
// is down. url2 is asked directly then, past xray: it fails too, the CDN is down, no
// verdicts in this run and no more url2 requests (st.url2_down). No quarantine either way,
// the checks of the active server go on with health.url alone.
function limited_check(q, e, gen, cb, again) {
	if (q.url2_off)
		return cb();
	probe(e.test_port, (ms, code) => {
		// the test went on without us or the server went away: no verdict; 7 is xray's
		if (testq !== q || q.url2_off || code < 0 || code == 7 || !valid(gen) || !server(e.id))
			return cb();
		if (ms < 0 && !again && code != 28)
			return limited_check(q, e, gen, cb, true);
		if (ms >= 0)
			q.url2_ok = true;
		q.limited[e.id] = (ms < 0) ? `curl ${code}` : null;
		if (ms >= 0 || q.url2_ok || ++q.url2_fails != URL2_CDN)
			return cb();
		probe(null, (dms, dcode) => {
			if (testq !== q)
				return cb();
			if (dms < 0 && dcode >= 0) {
				q.url2_off = true;
				q.limited = {};
				log(`${URL2} fails through ${URL2_CDN} servers in a row and directly: its CDN is down, the limited marks stay as they are`);
			}
			else
				q.url2_ok = true;	// it answers past xray: those are whitelists, go on
			cb();
		}, URL2);
	}, URL2);
}

// The url2 verdicts of a test run (null: passes it).
function set_limited(q) {
	st.url2_down = !!q.url2_off;	// leave_limited() does not act on old marks meanwhile
	for (let id, why in q.limited) {
		let e = server(id);
		if (!e || !why == !st.limited[id])
			continue;
		if (why)
			st.limited[id] = time();
		else
			delete st.limited[id];
		log(why ? `"${e.name}" is limited: ${URL2} fails through it (${why})` : `"${e.name}" is no longer limited`);
	}
}

function test_all(cb) {
	if (cb)
		push(test_waiters, cb);
	if (st.testing)
		return;

	reindex(false);
	st.testing = true;
	// testq is this run's until done(): callbacks of an aborted run see another one or null
	let q = testq = { queue: [], seen: {}, failed: {}, refused: false, limited: {}, url2_fails: 0 };
	for (let e in index.servers) {
		q.seen[e.id] = true;
		push(q.queue, e.id);
	}
	let running = 0;

	function done(problem, inst, refused) {
		st.testing = false;
		st.tests++;
		testq = test_resume = test_abort = null;
		st.last_test = time();
		save();
		let w = test_waiters;
		test_waiters = [];
		for (let f in w)
			f(problem, inst, refused);
	}

	// failures count only when xray works: with xray down every server would look dead;
	// so do url2 failures (a hung xray times out)
	function finish() {
		if (!length(q.failed) && !q.refused && !length(filter(values(q.limited), (why) => why))) {
			set_limited(q);
			return done(null);
		}
		q.finishing = true;
		let gen = st.gen;
		xray_check(q.refused ? 7 : null, (problem, inst) => {
			if (testq !== q)
				return;
			if (!valid(gen)) {
				// a reload during the check: the failures went through the old config
				q.finishing = false;
				// and so did the url2 verdicts: those servers are measured again too
				for (let id in uniq([ ...keys(q.failed), ...keys(q.limited) ]))
					if (server(id))
						push(q.queue, id);
				q.failed = {};
				q.limited = {};
				q.refused = false;
				return next();
			}
			if (!problem) {
				for (let id, at in q.failed)
					if (server(id))
						st.latency[id] = { ms: -1, at };
				set_limited(q);
			}
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
				if (testq !== q)
					return;
				alive();
				if (code < 0)
					;	// curl did not start: no verdict on the server
				else if (!valid(gen)) {
					if (server(id))
						push(q.queue, id);	// went through the old config: measure again
				}
				else if (ms >= 0) {
					st.latency[id] = { ms, at: time() };
					// the slot stays taken: one curl per slot, as without url2
					if (URL2)
						return limited_check(q, e, gen, () => {
							running--;
							next();
						});
				}
				else if (code == 7)
					q.refused = true;	// the test port refused: xray, not the server
				else
					q.failed[id] = time();
				running--;
				next();
			});
		}
		if (!running && !length(q.queue))
			finish();
	}

	test_resume = next;
	// nothing is known about xray: choose_best() puts its decision off (see check()),
	// a refused test port is checked there
	test_abort = () => done(XRAY_UNKNOWN, null, q.refused);
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

// Meanwhile the active server is probed: connected while it answers; without the kill
// switch the clients go direct while it does not (or there is none). Nothing goes to
// quarantine, xray is not checked.
function wait_time(e) {
	let gen = st.gen;
	function dead() {
		set_state('waiting_time', 'waiting for NTP to set the clock');
		if (!cfg.access.killswitch)
			set_passthrough(true);
	}
	if (!e)
		return dead();
	probe(e.test_port, (ms, code) => {
		if (!valid(gen) || st.active != e.id || code < 0 || st.time_wait == null)
			return;
		if (ms < 0)
			return dead();
		st.latency[e.id] = { ms, at: time() };
		set_passthrough(false);
		set_state('connected', null);
	});
}

// Syncs the daemon with the config xray runs now.
function adopt_index() {
	let pending = st.choose_pending;
	st.choose_pending = null;
	if (!length(index.servers)) {
		set_state('no_servers', 'no servers in subscriptions');
		return;
	}
	// generate found the chosen server under a new id by its hash (build_index): the same server
	if (index.moved_from && index.moved_from == st.active)
		st.active = index.active;
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
	let err = readfile(GENERATE_ERROR_FILE);
	if (err)
		return reload_failed(trim(err));
	st.reload_error = null;
	load_index();
	st.passthrough = false;
	settle();
}

// The reload hung or failed: what xray runs is likely the old config (generate writes the
// new one at the end), so the checks, failover and passthrough go on. The status shows
// error until a reload goes through: another try every RELOAD_RETRY, select and updates
// try at once, a reload past the daemon (reindex) counts too.
reload_failed = function(why) {
	log(`${why}, next try in ${RELOAD_RETRY} s`);
	st.reload_error = why;
	st.reloading = st.reload_pending = false;
	let pending = st.choose_pending;	// put off until the reload settles: it will not
	st.choose_pending = null;
	load_index();
	st.gen++;
	// clients go through the server of the config xray runs: a switch (select, failover)
	// is done once a reload applies it, ACTIVE_FILE keeps it for the next try
	if (index.active && server(index.active) && index.active != st.active) {
		log(`"${server(index.active).name}" stays active until a reload goes through`);
		st.active = index.active;
	}
	if (st.testing)
		test_abort();
	timers.retry?.cancel();
	timers.retry = uloop.timer(RELOAD_RETRY * 1000, () => {
		log('trying the reload again');
		reload_service();
	});
	// e.g. failover at stale addresses (choose_best): choose with the config xray runs
	if (pending)
		choose_best(pending);
};

// What a working reload changes: its processes and their CPU time, and those of another
// `init.d/xvpn` (rpcd, UCI triggers) that holds procd's service lock meanwhile. One waiting
// for the lock or for a stuck procd changes nothing.
// locked: start_service runs (it calls cli.uc), so the reload has procd's lock.
function reload_sig(pid) {
	let ps = procs(), seen = {}, cpu = 0;
	let locked = length(filter(tree(pid, ps), (p) => match(ps[p]?.cmd ?? '', /\/usr\/share\/xvpn\/cli\.uc/))) > 0;
	for (let root in [ pid, ...filter(keys(ps), (p) => match(ps[p].cmd, /\/etc\/init\.d\/xvpn/)) ])
		for (let p in tree(root, ps))
			if (!seen[p]) {
				seen[p] = true;
				cpu += ps[p]?.cpu ?? 0;
			}
	return { sig: `${join(',', sort(keys(seen)))} ${cpu}`, locked };
}

function watch_reload(r) {
	r.t = uloop.timer(RELOAD_TICK, () => {
		if (reload !== r)
			return;
		let s = reload_sig(r.p.pid()), t = now();
		if (s.sig != r.sig) {
			r.sig = s.sig;
			r.last = t;
		}
		// waiting for the lock behind a legit reload does not count, RELOAD_IDLE covers it
		if (s.locked)
			r.locked ??= t;
		let long = r.locked != null && t - r.locked >= RELOAD_MAX;
		if (t - r.last < RELOAD_IDLE && !long)
			return r.t.set(RELOAD_TICK);
		reload = null;
		kill_tree(r.p.pid());
		unlink(r.out);
		reload_failed(long ? `reload did not finish in ${RELOAD_MAX} s and was killed`
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
	let r = reload = { last: now(), out: `${RUN_DIR}/reload-${++probe_seq}` };
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
	let gen_error = notified ? readfile(GENERATE_ERROR_FILE) : null;
	// a reload past the daemon (UCI triggers, rpcd) failed to generate (a port taken):
	// tried again every RELOAD_RETRY like ours
	if (gen_error && !st.reload_error)
		return reload_failed(trim(gen_error));
	if (gen_error)
		st.reload_error = trim(gen_error);	// the latest reason, the retry is on already
	if (notified && st.reload_error && !gen_error) {
		st.reload_error = null;	// whoever ran it, the config is applied
		timers.retry?.cancel();
	}
	if (!changed)
		return;
	log('server list changed by a reload outside the daemon');
	st.reloading = true;
	settle();
};

// The config and the index of the running xray point at the server it switched to: for the
// next start of xray (respawn, a restart of its key) and of the daemon. Not when a reload or
// update wrote another index meanwhile: generate took the choice from ACTIVE_FILE.
function save_active(e) {
	if (readfile(INDEX_FILE) !== index_raw)
		return;
	let conf = read_json(CONFIG_FILE);
	if (!conf)
		return;
	set_active(conf, e.tag);
	// the index must not point at another server than the config
	if (!put(write_json, CONFIG_FILE, conf))
		return;
	index.active = e.id;
	index.moved_from = null;
	put(write_json, INDEX_FILE, index);
	index_raw = readfile(INDEX_FILE);
}

// The clients go to the active server (#13): `xray api bo` points the balancer of the running
// xray at it, no restart, the connections open now go on through the old one. When xray does
// not run the config of the index (a reload going on or failed, an update not applied, an
// index from before #13 without the control port) or the call fails: a reload as before.
// One call at a time: a switch meanwhile is applied once it ends.
function apply_active() {
	if (bo) {
		bo.again = true;
		return;
	}
	let e = server(st.active), port = index.ports?.control, inst = xray_instance();
	if (!e || !port || !inst?.running || st.reloading || st.reload_pending || st.reload_error
			|| access(STALE_FILE) || readfile(INDEX_FILE) !== index_raw)
		return reload_service();
	let me = bo = { again: false, killed: false }, t;
	let p = spawn('/bin/sh', [ '-c', `exec ${shq(cfg.main.xray_bin)} api bo -s 127.0.0.1:${port} -t 3 -b active ${shq(e.tag)} >/dev/null 2>&1` ], (code) => {
		t?.cancel();
		bo = null;
		// uloop.process reports a killed process as exit code 0
		if (code != 0 || me.killed) {
			log(`cannot switch xray to "${e.name}" without a restart (xray api bo: ${me.killed ? 'hung' : (code < 0 ? 'cannot start' : `exit ${code}`)}), reloading`);
			return reload_service();
		}
		save_active(e);
		if (me.again || st.active != e.id)
			apply_active();
	});
	if (p)
		t = uloop.timer(6000, () => {
			me.killed = true;
			system([ '/bin/kill', '-9', `${p.pid()}` ]);
		});
}

function switch_to(id, reason, manual) {
	let e = server(id);
	if (!e)
		return false;
	log(`switching to "${e.name}" (${reason})`);
	// failover: away from a server that failed, not by hand, a faster one, the list or the start
	st.last_switch = { from: st.active, to: id, reason, at: time(), failover: !manual && st.failing_over };
	st.failing_over = false;
	st.active = id;
	st.since = time();
	st.fails = 0;
	st.switches++;
	st.udp = st.dl_at = null;	// the new one is checked at once
	st.dl_failing = false;
	deep = null;	// those of the old one do not hold up its checks
	// a newer choice wins over decisions put off (#70): the choice by hand, or one of two
	// choose_best() waiting for the same test of all, whose sibling switched first
	st.xray_choose = st.choose_pending = null;
	delete st.quarantine[id];
	mkdir_p(ETC_DIR);
	put(write_file, ACTIVE_FILE, id);
	if (manual)
		put(write_file, MANUAL_FILE, id);
	// the choice by hand gives way to the daemon's, unless it is gone from the list for now:
	// once it is back, check() returns to it
	else if (server(manual_id()))
		unlink(MANUAL_FILE);
	save();
	set_state('connected', null);
	set_passthrough(false);
	apply_active();
	return true;
}

choose_best = function(reason) {
	st.xray_choose = null;
	if (!time_ok()) {
		st.time_choose = reason;	// check() takes it once the clock is set
		return set_state('waiting_time', 'waiting for NTP to set the clock');
	}
	st.time_choose = null;
	// an update moved servers xray does not use now (cli.uc update): measure them at their
	// new addresses. A reload drops the connections, but the choice may switch anyway
	if (access(STALE_FILE) && !st.reloading && !st.reload_error) {
		log(`applying the updated server list before choosing (${reason})`);
		st.choose_pending = reason;
		reload_service();
		return;
	}
	let seq = st.switches;
	test_all((problem, inst, refused) => {
		// a switch since this decision began (by hand, or another choose_best() for the same
		// test) is newer: it stands (#70)
		if (st.switches != seq)
			return;
		// the test may end mid-reload with partial data: decide once it settles
		if (st.reloading) {
			st.choose_pending = reason;
			return;
		}
		// xray did not work during the test: decide once it does
		if (problem == XRAY_UNKNOWN) {
			st.xray_choose = reason;
			st.xray_choose_code = refused ? 7 : null;
			return;
		}
		if (problem)
			return xray_down(problem, inst, reason);
		xray_up();
		let p = pick(), b = p?.server;
		if (!b) {
			// a server left out of auto selection that the user chose stays while it answers
			let e = server(st.active);
			if (e && no_auto()[e.id] && by_hand(e.id) && !quarantined(e.id) && (st.latency[e.id]?.ms ?? -1) >= 0) {
				st.fails = 0;
				set_passthrough(false);
				set_state('connected', `${no_candidates()}, staying on "${e.name}"`);
				return;
			}
			// the next test of all servers after a pause, longer each time (see check()); once
			// a run: two choose_best() waiting for the same one (set_auto during a test)
			if (st.dead?.run != st.tests) {
				let delay = retry_delay(st.dead?.delay, H.interval, H.retry_max);
				st.dead = { delay, next: now() + delay, run: st.tests };
			}
			set_state('no_servers', no_candidates());
			if (!cfg.access.killswitch)
				set_passthrough(true);
			return;
		}
		set_passthrough(false);
		if (b.id == st.active && chosen() == b.id) {
			st.fails = 0;
			set_state('connected', null);
			return;
		}
		switch_to(b.id, p.limited ? `${reason}; ${only_limited()}` : reason);
	});
};

// A test found the server the daemon chose limited: another one, as when it is left out
// of auto selection (check()). One chosen by hand stays. The switch drops the connections
// of the clients: url2 is tried once more through it LEAVE_RECHECK s later, a short CDN
// failure passes meanwhile. True when it may switch: the rank leaves auto_best alone.
const LEAVE_RECHECK = 3;
let leave_limited_pending = false;
function leave_limited() {
	let e = server(st.active);
	let busy = () => st.reloading || st.reload_pending || st.reload_error || st.testing;
	if (!e || !st.limited[e.id] || by_hand(e.id) || !best() || busy() || leave_limited_pending || st.url2_down)
		return false;
	let gen = st.gen;
	leave_limited_pending = true;
	uloop.timer(LEAVE_RECHECK * 1000, () => probe(e.test_port, (ms, code) => {
		leave_limited_pending = false;
		let b = best();
		if (!valid(gen) || st.active != e.id || !st.limited[e.id] || by_hand(e.id) || !b || busy() || code < 0 || code == 7)
			return;
		if (ms >= 0) {
			delete st.limited[e.id];
			save();
			log(`"${e.name}" is no longer limited: ${URL2} opens through it again`);
			return;
		}
		let why = `"${e.name}" is limited: ${URL2} fails through it`;
		// measured at an old address (cli.uc update): choose again at the new ones
		if (access(STALE_FILE))
			choose_best(why);
		else
			switch_to(b.id, why);
	}, URL2));
	return true;
}

function failover(reason) {
	if (st.active)
		st.quarantine[st.active] = time() + H.quarantine;
	st.failing_over = true;
	set_state('failover', reason);
	choose_best(reason);
}

// After health.url answers through the active server: the DNS of the clients through it (#10),
// its UDP (status udp, a warning unless the DNS of the clients is an IP: then it is their DNS)
// and every dl_interval a download (#11; at every check while it fails). cb(kind, why): kind
// null when they pass, 'dns' or 'dl'.
function deep_check(e, cb) {
	let me = deep = { at: now() };
	function end(kind, why) {
		if (deep === me)
			deep = null;
		cb(kind, why);
	}
	function dl() {
		if (!H.dl_url || (!st.dl_failing && st.dl_at != null && now() - st.dl_at < H.dl_interval))
			return end(null);
		dl_probe(e.test_port, (ok, why) => {
			if (ok == null || st.active != e.id)
				return end(null);
			st.dl_failing = !ok;
			if (!ok)
				return end('dl', `${H.dl_url} ${why} through it`);
			st.dl_at = now();
			end(null);
		});
	}
	function udp(next) {
		let port = index.ports?.control;
		if (!H.dns_check || !port)
			return next(null);
		udp_probe('127.0.0.1', port, (ok) => {
			if (ok != null && st.active == e.id) {
				if (ok != st.udp && (ok || st.udp != null))
					log(ok ? `UDP passes through "${e.name}" again` : `UDP does not pass through "${e.name}": QUIC, calls and games of the clients fail`);
				st.udp = ok;
			}
			next(ok);
		});
	}
	if (DOH)
		return doh_probe(e.test_port, (ok, code, http) => {
			if (code >= 0 && !ok)
				return end('dns', `DNS ${DOH} fails through it (${code ? `curl ${code}` : `HTTP ${http}`})`);
			udp(() => dl());
		});
	udp((ok) => (UDP_DNS && ok === false) ? end('dns', `DNS ${DNS} over UDP fails through it`) : dl());
}

// The fastest live server but e by ping, for elsewhere_ok(); null when there is none.
function other(e) {
	let q = { [e.id]: true };
	for (let s in index.servers)
		if (quarantined(s.id))
			q[s.id] = true;
	let p = auto_pick(index.servers, st.latency, no_auto(), q, st.limited);
	return (p && p.server.id != e.id && (st.latency[p.server.id]?.ms ?? -1) >= 0) ? p.server : null;
}

// What failed through the active server (deep_check()) passes elsewhere: through the fastest
// other server, else directly (a DoH server may be blocked directly but not through the
// tunnel, so the other server comes first; UDP has no test port of its own: directly only).
// cb(ok), null when no check started.
function elsewhere_ok(kind, e, cb) {
	let o = (kind == 'dl' || DOH) ? other(e) : null;
	let check = (port, f) => (kind == 'dl')
		? dl_probe(port, (ok) => f(ok))
		: doh_probe(port, (ok, code) => f(code < 0 ? null : ok));
	if (kind == 'dns' && !DOH)
		return udp_probe(DNS, 53, cb);
	if (!o)
		return check(null, cb);
	check(o.test_port, (ok) => ok ? cb(true) : check(null, (dok) => cb(dok ?? ok)));
}

// The active server answers.
function up(e, ms) {
	st.latency[e.id] = { ms, at: time() };
	xray_up();
	st.fails = 0;
	st.streak++;
	set_passthrough(false);
	set_state('connected', null);
}

// A failed check of the active server: kind null (health.url does not answer), 'dns' or 'dl'
// (see deep_check()). fail_threshold in a row: failover, unless the internet is down (none of
// health.wan_url answers directly, #11) or what failed fails elsewhere too: a DNS server or a
// CDN down, not the server's fault, another one would fail the same.
function failed(e, gen, kind, why) {
	st.fails++;
	// no live servers: the pause was the wait, straight to failover
	if (st.fails < H.fail_threshold && st.state != 'no_servers')
		return set_state('degraded', `${st.fails} failed checks${why ? `: ${why}` : ''}`);
	// a check passed meanwhile, even if the next one failed again: this verdict is old
	let streak = st.streak, stale = () => !valid(gen) || st.active != e.id || st.streak != streak;
	wan_probe((wan) => {
		if (stale() || wan == null)
			return;
		if (!wan)
			return set_state('wan_down', 'no direct internet access');
		if (!kind)
			return failover(`"${e.name}" is down`);
		elsewhere_ok(kind, e, (ok) => {
			if (stale() || ok == null)
				return;
			if (ok)
				return failover(`"${e.name}": ${why}`);
			// not the server: the download waits dl_interval again, not every check
			if (kind == 'dl') {
				st.dl_failing = false;
				st.dl_at = now();
			}
			set_state('degraded', `${why}, and through another server and directly too: not the server's fault`);
		});
	});
}

check = function() {
	reindex(false);
	if (st.testing || st.reloading)
		return;
	alive();
	let timed = time_ok();	// also without servers: it runs the updates put off
	if (!length(index.servers)) {
		set_state('no_servers', 'no servers in subscriptions');
		return;
	}

	let e = server(st.active);
	if (!timed)
		return wait_time(e);
	if (st.time_choose) {
		let reason = st.time_choose;
		st.time_choose = null;
		return choose_best(reason);
	}
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
	// the server chosen by hand is back in the list (an update dropped it for a while, the
	// daemon chose another meanwhile): back to it. Not after a failed reload (see below)
	let m = manual_id();
	if (m && m != e.id && server(m) && !st.reload_error && !st.reload_pending)
		return switch_to(m, 'chosen by hand, back in the list', true);
	let off = no_auto()[e.id] && !by_hand(e.id);
	// nothing to choose from (#12): the next test of all servers once the pause is over
	// (retry_delay(), reset by set_state(), load_index() and the user); meanwhile only the
	// active one is probed, one curl a check: back as soon as it answers. A refused test
	// port is xray's problem (see xray_check()): xray_down() as on the usual path, without a
	// decision put off (the next check of it would pass on the api port and test all again)
	if (st.state == 'no_servers' && st.dead && now() < st.dead.next) {
		if (!off)
			probe(e.test_port, (ms, code) => {
				if (!valid(gen) || st.active != e.id || st.state != 'no_servers')
					return;
				if (ms >= 0)
					return up(e, ms);
				if (code == 7)
					xray_check(code, (problem, inst) => {
						if (valid(gen) && st.active == e.id && st.state == 'no_servers'
								&& problem && problem != XRAY_UNKNOWN)
							xray_down(problem, inst);
					});
			});
		return;
	}
	// left out of auto selection and not chosen by hand (the daemon chose it before, or
	// generate's fallback: nothing chosen yet, the chosen one gone): choose again. Not after
	// a failed reload: the active one is then what xray runs, not what was chosen (reload_failed())
	if (off && !st.reload_error && !st.reload_pending)
		return choose_best(`"${e.name}" is excluded from auto selection`);
	// the DNS, UDP and download checks of the last one still run: it counts, not this one
	if (deep && now() - deep.at < 60)
		return;
	probe(e.test_port, (ms, code) => {
		if (!valid(gen) || st.active != e.id || code < 0)
			return;
		if (ms >= 0 && deep)
			return;	// a probe of the last check started them meanwhile
		if (ms >= 0)
			return deep_check(e, (kind, why) => {
				if (!valid(gen) || st.active != e.id)
					return;
				if (!kind)
					return up(e, ms);
				st.latency[e.id] = { ms, at: time() };
				xray_up();	// health.url went through it
				failed(e, gen, kind, why);
			});
		xray_check(code, (problem, inst) => {
			if (!valid(gen) || st.active != e.id || problem == XRAY_UNKNOWN)
				return;
			if (problem)
				return xray_down(problem, inst);
			xray_up();
			st.latency[e.id] = { ms, at: time() };
			failed(e, gen, null, null);
		});
	});
};

// auto_best: to the best server by auto_mode once it beats the active one by the hysteresis
// (better()), after a test of all and after a speed test.
function to_better() {
	// a server out of auto selection the user chose is not left for a faster one
	if (no_auto()[st.active] && by_hand(st.active))
		return;
	let b = best(), cur = server(st.active);
	let why = (b && cur) ? better(H.auto_mode, index.servers, cur, b, st.latency, st.speeds, H) : null;
	if (!why)
		return;
	// measured at an old address (cli.uc update): choose again at the new ones
	if (access(STALE_FILE))
		return choose_best(`${why} at old addresses`);
	switch_to(b.id, why);
}

function rank() {
	if (st.testing || st.reloading || st.reload_error || st.state != 'connected' || st.time_wait != null)
		return;
	test_all((problem) => {
		if (problem || st.reloading || leave_limited() || !H.auto_best)
			return;
		to_better();
	});
}

// Download speed of the servers (#95): speedtest_url through the test port of each live
// server in auto selection (and of the active one) in turn. One curl at a time, at most
// speedtest_time s each, and not during a test of all or a reload: a download takes the CPU
// of the router and the line, and it would slow the pings down. The speed counts from the
// first byte: the ping is the other half of balanced. Clients that download more than
// speedtest_busy Mbit/s put it off, at most for one more speedtest_interval.
// cb(mbps, why): mbps -1 when it fails, null when curl did not start.
const SPEED_MIN = 262144;	// bytes: less is no measurement
let sq = null;	// the run going on: { queue, since (monotonic), done, ok, run, t }

function speed_probe(port, cb) {
	curl_w(port, H.speedtest_url, H.speedtest_time, '%{http_code} %{size_download} %{time_total} %{time_starttransfer}', '', (code, r) => {
		if (code < 0)
			return cb(null);
		let http = int(r[0] ?? 0), size = +(r[1] ?? 0), t = +(r[2] ?? 0) - +(r[3] ?? 0);
		// 28: speedtest_time is over, what came by then counts
		if ((code == 0 || code == 28) && (http == 200 || http == 206) && size >= SPEED_MIN && t > 0)
			return cb(int(size * 8 / t / 100000) / 10.0);
		cb(-1, (http == 200 || http == 206) ? `${int(size / 1024)} KB in ${H.speedtest_time} s` : code ? `curl ${code}` : `HTTP ${http}`);
	});
}

function speed_done(q) {
	sq = null;
	st.speed_runs++;
	st.speed_last = time();
	save();
	log(`speed test: ${q.ok} of ${q.done} servers downloaded ${H.speedtest_url}`);
	if (H.auto_best && H.auto_mode != 'ping' && st.state == 'connected' && !st.testing && !st.reloading && !st.reload_error)
		to_better();
}

function speed_next(q) {
	if (sq !== q)
		return;
	// the pings of a test of all and the config of a reload first
	if (st.testing || st.reloading || st.time_wait != null) {
		q.t = uloop.timer(5000, () => speed_next(q));
		return;
	}
	let mbit = (tun.speed?.down ?? 0) * 8 / 1e6;
	if (H.speedtest_busy > 0 && mbit >= H.speedtest_busy && now() - q.since < H.speedtest_interval) {
		if (!q.waited)
			log(`speed test put off: the clients download ${int(mbit)} Mbit/s`);
		q.waited = true;
		q.t = uloop.timer(60000, () => speed_next(q));
		return;
	}
	let e = null;
	while (!e && length(q.queue)) {
		e = server(shift(q.queue));
		// dead or failed since the run began: no download through it
		if (e && ((st.latency[e.id]?.ms ?? -1) < 0 || quarantined(e.id)))
			e = null;
	}
	if (!e)
		return speed_done(q);
	let gen = st.gen;
	speed_probe(e.test_port, (mbps, why) => {
		if (sq !== q)
			return;
		// through the config being replaced: the next run measures it
		if (mbps != null && valid(gen) && server(e.id)) {
			st.speeds[e.id] = { mbps, at: time() };
			q.done++;
			if (mbps >= 0)
				q.ok++;
			else
				log(`speed test of "${e.name}" failed: ${why}`);
		}
		speed_next(q);
	});
}

// Starts a run unless one goes on: false when there is nothing to measure.
function speed_run(why) {
	if (sq)
		return true;
	if (!H.speedtest_url)
		return false;
	let off = no_auto();
	let queue = map(filter(index.servers, (e) => (!off[e.id] || e.id == st.active)
		&& (st.latency[e.id]?.ms ?? -1) >= 0 && !quarantined(e.id)), (e) => e.id);
	if (!length(queue))
		return false;
	log(`speed test of ${length(queue)} servers (${why})`);
	sq = { queue, since: now(), done: 0, ok: 0, run: st.speed_runs + 1 };
	speed_next(sq);
	return true;
}

// Every speedtest_interval in the modes speed and balanced; without live servers (start,
// no_servers) again in 5 minutes.
function speed_schedule(sec) {
	timers.speedtest?.cancel();
	timers.speedtest = uloop.timer(sec * 1000, () => {
		let ran = (st.state == 'connected' || st.state == 'degraded') && speed_run('scheduled');
		speed_schedule(ran ? H.speedtest_interval : 300);
	});
}

// The best server by balanced (#95), whatever the mode and the choice by hand: the badge
// "optimal" of the UIs. null until a server has a speed: by the ping alone it says nothing new.
function optimal() {
	if (!length(filter(values(st.speeds), (v) => v.mbps >= 0)))
		return null;
	let q = {};
	for (let e in index.servers)
		if (quarantined(e.id))
			q[e.id] = true;
	return auto_pick(index.servers, st.latency, no_auto(), q, st.limited, st.speeds, 'balanced')?.server.id;
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

// Downloads the Russian list of split tunneling when due (or now when force) in a
// `cli.uc lists` run: it applies a changed list to the rules itself, xray is not restarted.
// Returns an error message or null.
function update_lists(force) {
	if (st.lists_updating)
		return 'busy';
	let c = load_config(), due = lists_due_in(c);
	if (due == null)
		return 'the Russian list is off';
	if (!force && due > 0)
		return null;
	st.lists_updating = true;
	spawn('/usr/bin/ucode', [ CLI, 'lists' ], () => {
		st.lists_updating = false;
	});
	return null;
}

function status() {
	reindex(false);
	let off = no_auto();
	let servers = map(index.servers, (e) => ({
		id: e.id, name: e.name, proto: e.proto, transport: e.transport, address: e.address, port: e.port,
		sub: e.sub, sub_name: e.sub_name,
		latency: st.latency[e.id]?.ms, tested: st.latency[e.id]?.at,
		// Mbit/s of speedtest_url (#95): -1 the last download failed, null not measured
		speed: st.speeds[e.id]?.mbps, speed_tested: st.speeds[e.id]?.at,
		quarantined: quarantined(e.id), auto: !off[e.id], limited: !!st.limited[e.id],
	}));
	// cli.uc could not apply the rules and blocked the clients (fail closed)
	// and a reload that failed: what xray runs may be not what the daemon wants
	// generate failed past the daemon (start, rpcd: a port taken) and a config error in
	// the index (ipv6 = tunnel without IPv6 on the router)
	let fw_error = readfile(FW_ERROR_FILE), gen_error = readfile(GENERATE_ERROR_FILE);
	let write_error = length(write_errors) ? `cannot write ${join(', ', keys(write_errors))}: no space left on the router?` : null;
	let error = fw_error ?? st.reload_error ?? (gen_error ? trim(gen_error) : null) ?? index.config_error ?? write_error;
	// the active server is limited and there is nothing better: not kept in last_error, a check would clear it
	let limited_error = (st.state == 'connected' && st.limited[st.active] && !best()) ? only_limited() : null;
	return {
		state: error ? 'error' : st.state, active: st.active, since: st.since, fails: st.fails,
		testing: st.testing, tests: st.tests, updating: st.updating || !!update_running(), passthrough: st.passthrough,
		lists_updating: st.lists_updating,
		last_error: error ?? st.last_error ?? limited_error, last_switch: st.last_switch, last_test: st.last_test,
		// the active server was chosen by hand (select): failover does not leave it while it
		// answers, until the method auto
		manual: by_hand(st.active),
		xray_restarts: st.xray.restarts ?? 0, url2: URL2, servers,
		// UDP through the active server (#10); null: not checked
		udp: (st.state == 'connected' || st.state == 'degraded') ? st.udp : null,
		// no live servers: the next test of all (router clock) and the pause before it
		retry: (st.state == 'no_servers' && st.dead)
			? { at: time() + max(0, st.dead.next - now()), delay: st.dead.delay } : null,
		// the tunnel (#83): { up, down } B/s over the last main.speed_interval (null: not
		// measured yet or off) and bytes since xvpnd started; IP packets, headers included
		speed: tun.speed, traffic: SPEED > 0 ? tun.traffic : null,
		// #95: what the daemon chooses by, the best server by ping and speed, the speed test
		// (null: speedtest_url off; runs counts finished runs like tests)
		auto_mode: H.auto_mode, optimal: optimal(),
		speedtest: H.speedtest_url ? { running: !!sq, runs: st.speed_runs, last: st.speed_last, url: H.speedtest_url } : null,
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
			// after a failed reload the test ports may not match what xray runs;
			// before NTP sets the clock every server may look dead
			if (st.reload_error || st.time_wait != null)
				return { ok: false, error: 'busy' };
			// starts a run or joins the running one: either way that run is over
			// once status shows tests >= run (with no servers it is over at once)
			let run = st.tests + 1;
			// no live servers: choose from this run, the pause starts over (see check())
			if (st.state == 'no_servers' && st.dead && !st.testing && !st.reloading) {
				st.dead = null;
				choose_best('test by hand');
			}
			else
				test_all((problem) => {
					if (!problem && !st.reloading)
						leave_limited();
				});
			return { ok: true, run };
		},
	},
	// the speed test of all live servers now (#95): over once status shows speedtest.runs >= run
	speedtest: {
		call: () => {
			if (!H.speedtest_url)
				return { ok: false, error: 'speed test is off' };
			if (st.reload_error || st.time_wait != null)
				return { ok: false, error: 'busy' };
			let run = sq ? sq.run : st.speed_runs + 1;
			if (!speed_run('by hand'))
				return { ok: false, error: 'no live servers' };
			return { ok: true, run };
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
			return { ok: switch_to(req.args.id, 'manual selection', true) };
		},
	},
	// back to auto selection after select: the choice by hand is dropped and the daemon
	// chooses again (a test of all, as at start)
	auto: {
		call: () => {
			if (st.reloading)
				return { ok: false, error: 'busy' };
			if (!manual_id())
				return { ok: true };
			unlink(MANUAL_FILE);
			log('back to auto selection');
			choose_best('back to auto selection');
			return { ok: true };
		},
	},
	// the server takes part in auto selection or not (health.no_auto): UCI only, xray and
	// the daemon go on as they are (see no_auto())
	set_auto: {
		args: { id: '', auto: true },
		call: (req) => {
			let id = req.args.id, auto = req.args.auto, e = server(id);
			if (type(auto) != 'bool')
				return { ok: false, error: 'invalid arguments' };
			if (!e)
				return { ok: false, error: 'unknown server' };
			let off = no_auto();
			if (!off[id] == auto)
				return { ok: true };
			let ids = filter(keys(off), (x) => x != id);
			if (!auto)
				push(ids, id);
			let err = set_no_auto(cursor(), sort(ids));
			if (err)
				return { ok: false, error: err };
			log(`"${e.name}" ${auto ? 'takes part in' : 'is excluded from'} auto selection`);
			// nothing to choose from until now: this one may be
			if (auto && st.state == 'no_servers' && !st.testing && !st.reloading) {
				st.dead = null;
				choose_best(`"${e.name}" is back in auto selection`);
			}
			// the daemon chose it: another one now, one chosen by hand stays (see check())
			if (!auto && id == st.active && !by_hand(id) && !st.reload_error)
				choose_best(`"${e.name}" is excluded from auto selection`);
			return { ok: true };
		},
	},
	update: {
		args: { sid: '' },
		call: (req) => {
			let err = update_subs(true, req.args.sid || null);
			return err ? { ok: false, error: err } : { ok: true };
		},
	},
	lists: {
		call: () => {
			let err = update_lists(true);
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

// automatic updates wait for the clock too (TLS fails with it behind), time_ok() runs them
function auto_update() {
	if (st.time_wait != null)
		return;
	let force = st.subs_force;
	st.subs_force = false;
	update_subs(force);
	update_lists(false);
}

every('check', H.interval, check);
every('rank', H.rank_interval, rank);
every('subs', SUB_CHECK, auto_update);
every('watchdog', 30, watchdog);
if (SPEED > 0) {
	every('speed', SPEED, speed);
	speed();
}
// the first run a while after the start (the servers are tested first), unless the last one
// is recent: a restart of the daemon (a change of the config) does not download all again
if (H.speedtest_url && H.auto_mode != 'ping') {
	let age = st.speed_last ? time() - st.speed_last : null;
	speed_schedule((age != null && age >= 0 && age < H.speedtest_interval) ? max(120, H.speedtest_interval - age) : 120);
}
// generate failed at start (a port taken): tried again every RELOAD_RETRY
if (readfile(GENERATE_ERROR_FILE))
	reload_failed(trim(readfile(GENERATE_ERROR_FILE)));
if (H.time_wait > 0 && !access(TIME_FLAG) && ntp_on()) {
	let until = int(readfile(TIME_UNTIL) ?? 0);
	if (!until) {
		until = now() + H.time_wait;
		put(write_file, TIME_UNTIL, `${until}`);
	}
	if (now() < until) {
		st.time_wait = until;
		timers.time = uloop.timer((until - now()) * 1000, check);
		set_state('waiting_time', 'waiting for NTP to set the clock');
	}
}
if (!length(index.servers)) {
	st.subs_force = true;
	auto_update();
}
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
