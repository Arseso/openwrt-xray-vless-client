#!/usr/bin/ucode
// SPDX-License-Identifier: MIT
// xvpn command line: generate | fw-apply [passthrough] | fw-remove | update [sid...|all]

'use strict';

import { readfile, unlink, access, symlink, readlink } from 'fs';
import * as ubus from 'ubus';
import {
	load_config, read_json, write_json, mkdir_p, log, run, shq, is_updater,
	ACTIVE_FILE, CONFIG_FILE, INDEX_FILE, VAR_DIR, RUN_DIR, UPDATE_LOCK
} from 'xvpn.util';
import { all_servers, update } from 'xvpn.subscription';
import { build_index, generate } from 'xvpn.xrayconf';
import { resolve, apply, remove } from 'xvpn.firewall';

const cfg = load_config();

function xray_ok(path) {
	return run(`${shq(cfg.main.xray_bin)} run -test -c ${shq(path)} >/dev/null 2>&1`).code == 0;
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
	// the service is reloaded not only by the daemon (rpcd, UCI triggers): let it re-read the index
	ubus.connect()?.call('xvpn', 'reindex', {});
	print(`${length(servers)} servers, active ${idx.active ?? 'none'}\n`);
	exit(length(servers) ? 0 : 3);
}

case 'fw-apply': {
	let res = resolve(cfg, ubus.connect());
	exit(apply(cfg, res, { passthrough: ARGV[1] == 'passthrough' }) ? 0 : 1);
}

case 'fw-remove':
	remove(cfg);
	exit(0);

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
	warn('usage: cli.uc generate | fw-apply [passthrough] | fw-remove | update [sid...|all]\n');
	exit(1);
}
