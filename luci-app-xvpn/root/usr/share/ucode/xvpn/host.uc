// SPDX-License-Identifier: MIT
// What the router offers before generate: IPv6 and the ports other programs hold.
// proc: the /proc to read (tests pass a fake one).

'use strict';

import { readfile, lsdir, readlink } from 'fs';
import { CONFIG_FILE } from 'xvpn.util';

// IPv6 is off: disabled for all, or no address at all (lo has ::1 while it is on; no file:
// a kernel without IPv6 or booted with ipv6.disable=1, where a bind on :: fails).
export function ipv6_up(proc) {
	proc ??= '/proc';
	return !!trim(readfile(`${proc}/net/if_inet6`) ?? '')
		&& trim(readfile(`${proc}/sys/net/ipv6/conf/all/disable_ipv6`) ?? '0') != '1';
};

// Socket inodes of the xray that runs our config (procd's `xray run -c CONFIG_FILE`, whatever
// the binary): the ports it holds are ours, the new config takes them over.
function own_sockets(proc) {
	let own = {};
	for (let pid in lsdir(proc) ?? []) {
		if (!match(pid, /^[0-9]+$/))
			continue;
		let argv = split(readfile(`${proc}/${pid}/cmdline`) ?? '', '\0');
		if (!('run' in argv) || !(CONFIG_FILE in argv))
			continue;
		for (let fd in lsdir(`${proc}/${pid}/fd`) ?? []) {
			let m = match(readlink(`${proc}/${pid}/fd/${fd}`) ?? '', /^socket:\[([0-9]+)\]$/);
			if (m)
				own[m[1]] = true;
		}
	}
	return own;
}

// Ports held by other programs: { tcp: { port: true }, udp: { port: true } }. TCP counts
// listening sockets only: a connection from a port does not stop a bind (xray binds with
// SO_REUSEADDR).
export function busy_ports(proc) {
	proc ??= '/proc';
	let own = own_sockets(proc), busy = { tcp: {}, udp: {} };
	for (let f in [ 'tcp', 'tcp6', 'udp', 'udp6' ]) {
		let proto = substr(f, 0, 3), lines = split(readfile(`${proc}/net/${f}`) ?? '', '\n');
		// sl local_address rem_address st tx:rx tr:when retrnsmt uid timeout inode
		for (let i = 1; i < length(lines); i++) {
			let c = filter(split(lines[i], /[ \t]+/), (w) => w != '');
			if (length(c) < 10 || (proto == 'tcp' && c[3] != '0A') || own[c[9]])
				continue;
			let port = hex(split(c[1], ':')[1]);
			if (port > 0)
				busy[proto][port] = true;
		}
	}
	return busy;
};

// What build_index() needs to know about the router.
export function host_env(proc) {
	return { ipv6: ipv6_up(proc), busy: busy_ports(proc) };
};
