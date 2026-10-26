#!/usr/bin/ucode
// SPDX-License-Identifier: MIT
// xvpn command line: generate | fw-apply [passthrough] | fw-guard | fw-refresh | fw-remove | update [sid|all]

'use strict';

import { readfile, unlink, access } from 'fs';
import * as ubus from 'ubus';
import {
	load_config, read_json, write_json, write_file, mkdir_p, log, run, shq,
	ACTIVE_FILE, CONFIG_FILE, INDEX_FILE, VAR_DIR, RUN_DIR, FW_MODE_FILE, FW_ERROR_FILE
} from 'xvpn.util';
import { all_servers, update } from 'xvpn.subscription';
import { build_index, generate } from 'xvpn.xrayconf';
import { resolve, apply, remove } from 'xvpn.firewall';

const cfg = load_config();

function xray_ok(path) {
	return run(`${shq(cfg.main.xray_bin)} run -test -c ${shq(path)} >/dev/null 2>&1`).code == 0;
}

// Applies the rules in mode full | passthrough | block. When nft rejects them, falls back
// to block (fail closed) and leaves the error in FW_ERROR_FILE for the status.
function fw(mode) {
	let res = resolve(cfg, ubus.connect());
	let err = apply(cfg, res, { passthrough: mode == 'passthrough', block: mode == 'block' });
	mkdir_p(RUN_DIR);
	if (err == null) {
		write_file(FW_MODE_FILE, mode);
		unlink(FW_ERROR_FILE);
		return true;
	}
	if (mode != 'block' && apply(cfg, res, { block: true }) == null) {
		write_file(FW_MODE_FILE, 'block');
		log('VPN clients are blocked until the firewall rules are fixed');
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

// access point devices changed (a wifi came up): same mode, devices resolved again
case 'fw-refresh': {
	let mode = readfile(FW_MODE_FILE);
	exit((mode == null || fw(mode)) ? 0 : 1);
}

case 'fw-remove':
	remove(cfg);
	unlink(FW_MODE_FILE);
	unlink(FW_ERROR_FILE);
	exit(0);

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
