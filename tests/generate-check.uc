// SPDX-License-Identifier: MIT
// After cli.uc generate in scripts/test.sh: ucode tests/generate-check.uc <number of servers>
// The servers named in XRAY_REJECT (space-separated) and only they were rejected, each
// with xray's reason kept in tested.json.

'use strict';

import { readfile } from 'fs';

let total = int(ARGV[0]), want = filter(split(getenv('XRAY_REJECT') ?? '', ' '), (n) => n != '');
let idx = json(readfile('/var/etc/xvpn/index.json')), t = json(readfile('/var/etc/xvpn/tested.json'));
let names = map(idx.servers, (e) => e.name), why = values(t.why ?? {});
for (let r in why)
	print(`generate: rejected: ${r}\n`);
if (length(filter(want, (n) => n in names)) || length(names) + length(want) != total || length(why) != length(want)) {
	warn(sprintf('generate: want rejected %J, kept %J, reasons %J\n', want, names, why));
	exit(1);
}
print(sprintf('generate: %d servers kept, rejected %J\n', length(names), want));
