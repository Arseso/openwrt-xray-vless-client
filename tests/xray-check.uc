// SPDX-License-Identifier: MIT
// xray checks of scripts/test.sh (#14):
//   ucode tests/xray-check.uc config <xray> <config> [lenient]
//     Strict: xray must accept the whole config. Lenient (a newer xray than the feed's):
//     a server rejected for something its link sets that the newer xray forbids is
//     dropped, as cli.uc generate drops it, and the rest must be accepted; any other
//     error fails.
//   ucode tests/xray-check.uc generate <number of servers>
//     After cli.uc generate: the servers named in XRAY_REJECT (space-separated) and only
//     they were rejected, each with a reason in tested.json that FORBIDDEN knows.
//   ucode tests/xray-check.uc again <xray runs before> <log>
//     After a second generate with the same servers: xray did not run again, the log has
//     "rejected … earlier" with every rejected server and its reason.

'use strict';

import { readfile, writefile, unlink } from 'fs';

// what newer xray versions forbid in a server that the subscription set
const FORBIDDEN = [
	/without TLS( or other encryption)? is prohibited unless the server address is a private/,	// 26.x: plain vless and trojan
	/"allowInsecure" has been removed/,	// 26.x
];
const forbidden = (text) => length(filter(FORBIDDEN, (re) => match(text, re))) > 0;
const WANT = filter(split(getenv('XRAY_REJECT') ?? '', ' '), (n) => n != '');

function fail(msg) {
	warn(`${msg}\n`);
	exit(1);
}

function check_config(xray, path, lenient) {
	let conf = json(readfile(path)), tmp = `${path}.check.json`, log = `${path}.check.log`;
	for (let n = 0; ; n++) {
		writefile(tmp, sprintf('%J', conf));
		let rc = system(`${xray} run -test -c ${tmp} >${log} 2>&1`);
		let out = readfile(log) ?? '';
		if (rc == 0) {
			print(`${path}: ok${n ? `, ${n} server(s) dropped` : ''}\n`);
			break;
		}
		let err = match(out, /Failed to start: [^\n]*/)?.[0] ?? out;
		let tag = match(err, /outbound config with tag (srv-[0-9]+)/)?.[1];
		if (!lenient || !tag || !forbidden(err))
			fail(`${path}: xray rejects the config: ${err}`);
		print(`${path}: dropped ${tag}: ${err}\n`);
		let i = substr(tag, 4);
		conf.outbounds = filter(conf.outbounds, (o) => o.tag != tag);
		conf.inbounds = filter(conf.inbounds, (o) => o.tag != `test-${i}`);
		conf.routing.rules = filter(conf.routing.rules, (r) => r.outboundTag != tag && !(`test-${i}` in (r.inboundTag ?? [])));
	}
	unlink(tmp);
	unlink(log);
}

function check_generate(total) {
	let idx = json(readfile('/var/etc/xvpn/index.json')), t = json(readfile('/var/etc/xvpn/tested.json'));
	let names = map(idx.servers, (e) => e.name), why = values(t.why ?? {});
	for (let r in why) {
		print(`generate: rejected: ${r}\n`);
		if (!forbidden(r))
			fail(`generate: not a known reason: ${r}`);
	}
	if (length(filter(WANT, (n) => n in names)) || length(names) + length(WANT) != total || length(why) != length(WANT))
		fail(sprintf('generate: want rejected %J, kept %J, reasons %J', WANT, names, why));
	print(sprintf('generate: %d servers kept, rejected %J\n', length(names), WANT));
}

function check_again(runs, log) {
	let now = length(filter(split(readfile('/tmp/xray-runs') ?? '', '\n'), (l) => l != ''));
	if (now != runs)
		fail(`generate again: xray ran ${now - runs} more time(s)`);
	let line = filter(split(readfile(log) ?? '', '\n'), (l) => index(l, 'earlier: ') >= 0)[-1];
	if (!length(WANT)) {
		if (line)
			fail(`generate again: ${line}`);
		print('generate again: no xray run, nothing rejected\n');
		return;
	}
	if (!line || index(line, `rejected ${length(WANT)} server(s) earlier: `) < 0)
		fail(`generate again: no "rejected ${length(WANT)} server(s) earlier" in the log: ${readfile(log)}`);
	for (let n in WANT)
		if (!match(line, regexp(`(^|: |, )${replace(n, /[^A-Za-z0-9 ]/g, '.')} \\([^)]+\\)`)))
			fail(`generate again: no "${n} (<reason>)" in: ${line}`);
	print(`generate again: no xray run; ${line}\n`);
}

switch (ARGV[0]) {
case 'config':
	check_config(ARGV[1], ARGV[2], ARGV[3] == 'lenient');
	break;
case 'generate':
	check_generate(int(ARGV[1]));
	break;
case 'again':
	check_again(int(ARGV[1]), ARGV[2]);
	break;
default:
	fail('usage: xray-check.uc config <xray> <config> [lenient] | generate <servers> | again <runs> <log>');
}
