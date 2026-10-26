#!/usr/bin/ucode
// SPDX-License-Identifier: MIT
// xvpnd: health checks, failover to the fastest server by HTTP ping,
// subscription auto-update. Publishes the ubus object "xvpn".

'use strict';

import * as uloop from 'uloop';
import * as ubus from 'ubus';
import { readfile, unlink } from 'fs';
import {
	load_config, read_json, write_json, write_file, mkdir_p, log, shq,
	ETC_DIR, RUN_DIR, INDEX_FILE, ACTIVE_FILE, STATE_FILE
} from 'xvpn.util';
import { due_in } from 'xvpn.subscription';

const CLI = '/usr/share/xvpn/cli.uc';
const SUB_CHECK = 300;

const cfg = load_config();
const H = cfg.health;

let index = read_json(INDEX_FILE) ?? { servers: [] };
let prev = read_json(STATE_FILE) ?? {};

let st = {
	state: 'starting',
	active: index.active,
	since: time(),
	fails: 0,
	testing: false,
	updating: false,
	reloading: false,
	passthrough: false,
	last_error: null,
	last_switch: prev.last_switch,
	last_test: prev.last_test,
	latency: prev.latency ?? {},
	quarantine: prev.quarantine ?? {},
};
let test_waiters = [];
let timers = {};

function server(id) {
	return filter(index.servers, (e) => e.id == id)[0];
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
	if (err !== undefined)
		st.last_error = err;
}

function spawn(cmd, args, cb) {
	uloop.process(cmd, args, { PATH: '/usr/sbin:/usr/bin:/sbin:/bin' }, cb ?? (() => null));
}

// HTTP ping through a SOCKS test port (or direct when port is null).
// Calls cb(ms), ms < 0 on failure.
function probe(port, cb) {
	let out = `${RUN_DIR}/probe-${port ?? 'direct'}`;
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

	st.testing = true;
	let queue = [ ...index.servers ], running = 0;

	function finish() {
		st.testing = false;
		st.last_test = time();
		save();
		let w = test_waiters;
		test_waiters = [];
		for (let f in w)
			f();
	}

	function next() {
		while (running < H.concurrency && length(queue)) {
			let e = shift(queue);
			running++;
			probe(e.test_port, (ms) => {
				st.latency[e.id] = { ms, at: time() };
				running--;
				if (!length(queue) && !running)
					finish();
				else
					next();
			});
		}
	}

	if (length(queue))
		next();
	else
		finish();
}

function set_passthrough(on) {
	if (st.passthrough == on)
		return;
	st.passthrough = on;
	log(on ? 'no live servers and kill switch is off: clients go direct'
		: 'server is alive again: clients go through VPN');
	spawn('/usr/bin/ucode', on ? [ CLI, 'fw-apply', 'passthrough' ] : [ CLI, 'fw-apply' ]);
}

function after_reload() {
	index = read_json(INDEX_FILE) ?? { servers: [] };
	st.reloading = false;
	st.passthrough = false;
	if (!length(index.servers)) {
		set_state('no_servers', 'no servers in subscriptions');
		return;
	}
	if (!server(st.active)) {
		// active server disappeared from the subscription
		st.active = index.active;
		timers.once = uloop.timer(3000, () => choose_best('server list changed'));
		return;
	}
	timers.check.set(3000);
}

function reload_service() {
	st.reloading = true;
	spawn('/etc/init.d/xvpn', [ 'reload' ], () => after_reload());
}

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

function choose_best(reason) {
	test_all(() => {
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
}

function failover(reason) {
	if (st.active)
		st.quarantine[st.active] = time() + H.quarantine;
	set_state('failover', reason);
	choose_best(reason);
}

function check() {
	if (st.testing || st.reloading)
		return;
	if (!length(index.servers)) {
		set_state('no_servers', 'no servers in subscriptions');
		return;
	}

	let e = server(st.active);
	if (!e)
		return failover('no active server');

	probe(e.test_port, (ms) => {
		if (st.reloading || st.active != e.id)
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
			if (dms < 0)
				set_state('wan_down', 'no direct internet access');
			else
				failover(`"${e.name}" is down`);
		});
	});
}

function rank() {
	if (st.testing || st.reloading || st.state != 'connected')
		return;
	test_all(() => {
		if (!H.auto_best || st.reloading)
			return;
		let b = best(), cur = st.latency[st.active];
		if (b && b.id != st.active && cur && cur.ms >= 0 && b.ms + H.hysteresis < cur.ms)
			switch_to(b.id, `faster server: ${st.latency[b.id].ms} ms vs ${cur.ms} ms`);
	});
}

// Updates due (or all when force) subscriptions one after another.
function update_subs(force, only) {
	if (st.updating)
		return;
	let due = filter(cfg.subscriptions, (s) => s.enabled && s.url
		&& (only ? s.id == only : (force || due_in(s) <= 0)));
	if (!length(due))
		return;

	st.updating = true;
	let changed = false;
	function next() {
		let s = shift(due);
		if (!s) {
			st.updating = false;
			if (changed)
				reload_service();
			return;
		}
		spawn('/usr/bin/ucode', [ CLI, 'update', s.id ], (code) => {
			changed ||= (code == 0);
			next();
		});
	}
	next();
}

function status() {
	let servers = map(index.servers, (e) => ({
		id: e.id, name: e.name, proto: e.proto, address: e.address, port: e.port,
		sub: e.sub, sub_name: e.sub_name,
		latency: st.latency[e.id]?.ms, tested: st.latency[e.id]?.at,
		quarantined: quarantined(e.id),
	}));
	return {
		state: st.state, active: st.active, since: st.since, fails: st.fails,
		testing: st.testing, updating: st.updating, passthrough: st.passthrough,
		last_error: st.last_error, last_switch: st.last_switch, last_test: st.last_test,
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
			update_subs(true, req.args.sid || null);
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
