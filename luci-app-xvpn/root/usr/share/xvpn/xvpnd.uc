#!/usr/bin/ucode
// SPDX-License-Identifier: MIT
// xvpnd: health checks, failover to the fastest server by HTTP ping,
// subscription auto-update. Publishes the ubus object "xvpn".

'use strict';

import * as uloop from 'uloop';
import * as ubus from 'ubus';
import { readfile, unlink } from 'fs';
import {
	load_config, read_json, write_json, write_file, mkdir_p, log, shq, update_running,
	ETC_DIR, RUN_DIR, INDEX_FILE, ACTIVE_FILE, STATE_FILE, FW_ERROR_FILE
} from 'xvpn.util';
import { due_in } from 'xvpn.subscription';

const CLI = '/usr/share/xvpn/cli.uc';
const SUB_CHECK = 300;

const cfg = load_config();
const H = cfg.health;

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
	choose_pending: null,	// choose_best() decision put off until the reload settles
	passthrough: false,
	last_error: null,
	last_switch: prev.last_switch,
	last_test: prev.last_test,
	latency: prev.latency ?? {},
	quarantine: prev.quarantine ?? {},
};
let test_waiters = [], testq = null, test_resume = null;
let timers = {}, settling = false;
let probe_seq = 0;
// ucode does not hoist functions: these call each other in a cycle, defined below
let reload_service, reindex, choose_best, check;

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

function spawn(cmd, args, cb) {
	uloop.process(cmd, args, { PATH: '/usr/sbin:/usr/bin:/sbin:/bin' }, cb ?? (() => null));
}

// HTTP ping through a SOCKS test port (or direct when port is null).
// Calls cb(ms), ms < 0 on failure.
function probe(port, cb) {
	let out = `${RUN_DIR}/probe-${++probe_seq}`;
	let cmd = sprintf("/usr/bin/curl -s -o /dev/null --connect-timeout %d --max-time %d -w '%%{http_code} %%{time_starttransfer}' %s %s > %s 2>/dev/null",
		H.timeout, H.timeout, port ? `-x socks5h://127.0.0.1:${port}` : '', shq(H.url), shq(out));

	spawn('/bin/sh', [ '-c', cmd ], (code) => {
		let r = split(trim(readfile(out) ?? ''), ' ');
		unlink(out);
		let http = int(r[0]);
		let ok = (code == 0 && (http == 204 || http == 200));
		cb(ok ? int(+r[1] * 1000) : -1);
	});
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
	testq = { queue: [], seen: {} };
	for (let e in index.servers) {
		testq.seen[e.id] = true;
		push(testq.queue, e.id);
	}
	let running = 0;

	function finish() {
		st.testing = false;
		testq = test_resume = null;
		st.last_test = time();
		save();
		let w = test_waiters;
		test_waiters = [];
		for (let f in w)
			f();
	}

	// the port is looked up by id at start: the queue survives index changes
	function next() {
		// nothing is measured while xray restarts: settle() resumes the test
		while (!st.reloading && running < H.concurrency && length(testq.queue)) {
			let id = shift(testq.queue), e = server(id), gen = st.gen;
			if (!e)
				continue;	// gone from the list meanwhile
			running++;
			probe(e.test_port, (ms) => {
				running--;
				if (valid(gen))
					st.latency[id] = { ms, at: time() };
				else if (server(id))
					push(testq.queue, id);	// went through the old config: measure again
				next();
			});
		}
		if (!running && !length(testq.queue))
			finish();
	}

	test_resume = next;
	next();
}

function set_passthrough(on) {
	if (st.passthrough == on)
		return;
	st.passthrough = on;
	log(on ? 'no live servers and kill switch is off: clients go direct'
		: 'server is alive again: clients go through VPN');
	spawn('/usr/bin/ucode', on ? [ CLI, 'fw-apply', 'passthrough' ] : [ CLI, 'fw-apply' ]);
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
	load_index();
	st.passthrough = false;
	settle();
}

reload_service = function() {
	if (st.reloading) {
		st.reload_pending = true;
		return;
	}
	st.reloading = true;
	st.gen++;	// measurements in flight go through the config being replaced
	spawn('/etc/init.d/xvpn', [ 'reload' ], () => after_reload());
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
	delete st.quarantine[id];
	mkdir_p(ETC_DIR);
	write_file(ACTIVE_FILE, id);
	save();
	set_state('connected', null);
	reload_service();
	return true;
}

choose_best = function(reason) {
	test_all(() => {
		// the test may end mid-reload with partial data: decide once it settles
		if (st.reloading) {
			st.choose_pending = reason;
			return;
		}
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
	if (!length(index.servers)) {
		set_state('no_servers', 'no servers in subscriptions');
		return;
	}

	let e = server(st.active);
	if (!e)
		return failover('no active server');

	let gen = st.gen;
	probe(e.test_port, (ms) => {
		if (!valid(gen) || st.active != e.id)
			return;
		st.latency[e.id] = { ms, at: time() };
		if (ms >= 0) {
			st.fails = 0;
			set_passthrough(false);
			set_state('connected', null);
			return;
		}
		st.fails++;
		if (st.fails < H.fail_threshold) {
			set_state('degraded', `${st.fails} failed checks`);
			return;
		}
		probe(null, (dms) => {
			if (!valid(gen) || st.active != e.id)
				return;
			if (dms < 0)
				set_state('wan_down', 'no direct internet access');
			else
				failover(`"${e.name}" is down`);
		});
	});
};

function rank() {
	if (st.testing || st.reloading || st.state != 'connected')
		return;
	test_all(() => {
		if (!H.auto_best || st.reloading)
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
	let fw_error = readfile(FW_ERROR_FILE);
	return {
		state: fw_error ? 'error' : st.state, active: st.active, since: st.since, fails: st.fails,
		testing: st.testing, updating: st.updating || !!update_running(), passthrough: st.passthrough,
		last_error: fw_error ?? st.last_error, last_switch: st.last_switch, last_test: st.last_test,
		servers,
	};
}

function every(name, sec, fn) {
	let t;
	t = uloop.timer(sec * 1000, () => {
		t.set(sec * 1000);
		fn();
	});
	timers[name] = t;
}

mkdir_p(RUN_DIR);
load_index();
st.active = index.active;

uloop.init();

let conn = ubus.connect();
if (!conn)
	die('cannot connect to ubus');

conn.publish('xvpn', {
	status: {
		call: () => status(),
	},
	test: {
		call: () => {
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
