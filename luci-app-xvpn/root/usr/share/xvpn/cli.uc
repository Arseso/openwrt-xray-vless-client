#!/usr/bin/ucode
// SPDX-License-Identifier: MIT
// xvpn command line: generate | fw-apply [passthrough] | fw-guard | fw-refresh | fw-remove | update [sid|all]

'use strict';

import { readfile, unlink, access, open } from 'fs';
import * as ubus from 'ubus';
import {
	load_config, read_json, write_json, write_file, mkdir_p, log, run, shq,
	ACTIVE_FILE, CONFIG_FILE, INDEX_FILE, VAR_DIR, RUN_DIR,
	FW_WANT_FILE, FW_MODE_FILE, FW_ERROR_FILE, FW_LOCK_FILE
} from 'xvpn.util';
import { all_servers, update } from 'xvpn.subscription';
import { build_index, generate } from 'xvpn.xrayconf';
import { resolve, apply, remove } from 'xvpn.firewall';

const cfg = load_config();

function xray_ok(path) {
	return run(`${shq(cfg.main.xray_bin)} run -test -c ${shq(path)} >/dev/null 2>&1`).code == 0;
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
function fw(want) {
	let lock = fw_lock();
	want ??= readfile(FW_WANT_FILE);
	if (!MODES[want])
		return true;

	mkdir_p(RUN_DIR);
	write_file(FW_WANT_FILE, want);
	let res = resolve(cfg, ubus.connect());
	let err = apply(cfg, res, MODES[want]);
	if (err == null) {
		write_file(FW_MODE_FILE, want);
		unlink(FW_ERROR_FILE);
		return true;
	}

	for (let m in [ 'block', 'minimal' ]) {
		if (m == want)
			continue;
		if (apply(cfg, res, MODES[m]) == null) {
			write_file(FW_MODE_FILE, m);
			log(`VPN clients are blocked (${m}) until the firewall rules are fixed`);
			break;
		}
	}
	write_file(FW_ERROR_FILE, `firewall rules failed: ${err}`);
	return false;
}

function active_port() {
	let idx = read_json(INDEX_FILE);
	return filter(idx?.servers ?? [], (e) => e.id == idx.active)[0]?.test_port;
}

switch (ARGV[0]) {
case 'generate': {
	let servers = all_servers(cfg);
	let active = trim(readfile(ACTIVE_FILE) ?? '');
	let idx = build_index(cfg, servers, active);
	mkdir_p(VAR_DIR);
	write_json(CONFIG_FILE, generate(cfg, servers, idx));

	// one malformed server must not take the whole VPN down: drop the ones xray rejects
	if (length(servers) && access(cfg.main.xray_bin, 'x') && !xray_ok(CONFIG_FILE)) {
		let good = [], bad = [], tmp = `${VAR_DIR}/check.json`;
		for (let s in servers) {
			write_json(tmp, generate(cfg, [ s ], build_index(cfg, [ s ], s.id)));
			if (xray_ok(tmp))
				push(good, s);
			else
				push(bad, s.name);
		}
		unlink(tmp);
		log(`xray rejected ${length(bad)} server(s): ${join(', ', bad)}`);
		servers = good;
		idx = build_index(cfg, servers, active);
		write_json(CONFIG_FILE, generate(cfg, servers, idx));
		if (length(servers) && !xray_ok(CONFIG_FILE)) {
			log(`xray rejects the generated config, check: ${cfg.main.xray_bin} run -test -c ${CONFIG_FILE}`);
			exit(4);
		}
	}

	write_json(INDEX_FILE, idx);
	print(`${length(servers)} servers, active ${idx.active ?? 'none'}\n`);
	exit(length(servers) ? 0 : 3);
}

case 'fw-apply':
	exit(fw(ARGV[1] == 'passthrough' ? 'passthrough' : 'full') ? 0 : 1);

// xray is not running (boot, stop with the service enabled): clients do not go around the VPN
case 'fw-guard':
	exit(fw(cfg.access.killswitch ? 'block' : 'passthrough') ? 0 : 1);

// devices changed (a wifi came up) or fw4 flushed the tables: the wanted mode again
case 'fw-refresh':
	exit(fw(null) ? 0 : 1);

case 'fw-remove': {
	let lock = fw_lock();
	remove(cfg);
	unlink(FW_WANT_FILE);
	unlink(FW_MODE_FILE);
	unlink(FW_ERROR_FILE);
	exit(0);
}

case 'update': {
	let sid = ARGV[1] ?? 'all', port = active_port(), out = {}, changed = false;
	for (let sub in cfg.subscriptions) {
		if (!sub.enabled || (sid != 'all' && sid != sub.id))
			continue;
		let r = update(sub, port);
		out[sub.id] = r;
		changed ||= r.changed;
		log(r.error ? `subscription "${sub.name}": ${r.error}`
			: `subscription "${sub.name}": ${r.count} servers${r.skipped ? `, ${r.skipped} skipped` : ''}${r.changed ? ' (changed)' : ''}`);
	}
	printf('%J\n', out);
	exit(changed ? 0 : 2);
}

default:
	warn('usage: cli.uc generate | fw-apply [passthrough] | fw-guard | fw-refresh | fw-remove | update [sid|all]\n');
	exit(1);
}
