#!/usr/bin/ucode
// SPDX-License-Identifier: MIT
// xvpn command line: generate | ifnames | ifnames-wait | fw-apply [passthrough] | fw-guard | fw-refresh | fw-remove | update [sid...|all]

'use strict';

import { readfile, unlink, access, open, symlink, readlink } from 'fs';
import * as ubus from 'ubus';
import {
	load_config, read_json, write_json, write_file, mkdir_p, log, run, shq, is_updater,
	ACTIVE_FILE, CONFIG_FILE, INDEX_FILE, VAR_DIR, RUN_DIR, UPDATE_LOCK,
	FW_WANT_FILE, FW_MODE_FILE, FW_ERROR_FILE, FW_WARN_FILE, FW_LOCK_FILE
} from 'xvpn.util';
import { all_servers, update } from 'xvpn.subscription';
import { build_index, generate } from 'xvpn.xrayconf';
import { resolve, apply, remove, fix_ifnames, ifnames_applied } from 'xvpn.firewall';

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
	let servers = all_servers(cfg);
	let active = trim(readfile(ACTIVE_FILE) ?? '');
	let idx = build_index(cfg, servers, active);
	mkdir_p(VAR_DIR);
	write_json(CONFIG_FILE, generate(cfg, servers, idx));

	// one malformed server must not take the whole VPN down: drop the ones xray rejects
	if (length(servers) && access(cfg.main.xray_bin, 'x') && !xray_ok(CONFIG_FILE)) {
		let good = [], bad = [], tmp = `${VAR_DIR}/check.json`;
		// xray that rejects a config without servers is broken itself: keep the servers,
		// the daemon reports xray_down rather than "no servers"
		write_json(tmp, generate(cfg, [], build_index(cfg, [], null)));
		if (!xray_ok(tmp)) {
			unlink(tmp);
			write_json(INDEX_FILE, idx);
			log(`xray does not work, check: ${cfg.main.xray_bin} run -test -c ${CONFIG_FILE}`);
			exit(4);
		}
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
		system('/usr/bin/ucode /usr/share/xvpn/cli.uc ifnames-wait >/dev/null 2>&1 </dev/null &');
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
