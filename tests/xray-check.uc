// SPDX-License-Identifier: MIT
// Checks a generated config with `xray run -test` (scripts/test.sh):
//   ucode tests/xray-check.uc <xray> <config> [lenient]
// Strict: xray must accept the whole config. Lenient (a newer xray than the feed's, #14):
// a server rejected for something its link sets that the newer xray forbids is dropped,
// as cli.uc generate drops it, and the rest must be accepted; any other error fails.

'use strict';

import { readfile, writefile, unlink } from 'fs';

const XRAY = ARGV[0], CONF = ARGV[1], LENIENT = ARGV[2] == 'lenient';

// what newer xray versions forbid in a server that the subscription set
const FORBIDDEN = [
	/without TLS( or other encryption)? is prohibited unless the server address is a private/,	// 26.x: plain vless and trojan
	/"allowInsecure" has been removed/,	// 26.x
];

let conf = json(readfile(CONF)), tmp = `${CONF}.check.json`, log = `${CONF}.check.log`;
for (let n = 0; ; n++) {
	writefile(tmp, sprintf('%J', conf));
	let rc = system(`${XRAY} run -test -c ${tmp} >${log} 2>&1`);
	let out = readfile(log) ?? '';
	if (rc == 0) {
		print(`${CONF}: ok${n ? `, ${n} server(s) dropped` : ''}\n`);
		break;
	}
	let err = match(out, /Failed to start: [^\n]*/)?.[0] ?? out;
	let tag = match(err, /outbound config with tag (srv-[0-9]+)/)?.[1];
	if (!LENIENT || !tag || !length(filter(FORBIDDEN, (re) => match(err, re)))) {
		warn(`${CONF}: xray rejects the config: ${err}\n`);
		exit(1);
	}
	print(`${CONF}: dropped ${tag}: ${err}\n`);
	let i = substr(tag, 4);
	conf.outbounds = filter(conf.outbounds, (o) => o.tag != tag);
	conf.inbounds = filter(conf.inbounds, (o) => o.tag != `test-${i}`);
	conf.routing.rules = filter(conf.routing.rules, (r) => r.outboundTag != tag && !(`test-${i}` in (r.inboundTag ?? [])));
}
unlink(tmp);
unlink(log);
