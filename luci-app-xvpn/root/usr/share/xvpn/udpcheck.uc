#!/usr/bin/ucode
// SPDX-License-Identifier: MIT
// udpcheck.uc <host> <port> <timeout s>: a DNS query over UDP (A of www.gstatic.com); exit 0
// when an answer comes in time. The daemon asks the UDP inbound of xray (through the active
// server) and the DNS server of the clients directly (#10).

'use strict';

import * as socket from 'socket';

let host = ARGV[0], port = int(ARGV[1]), wait = int(ARGV[2] ?? 3) * 1000;
let ns = clock(true)[1], id = chr((ns >> 4) & 255, (ns >> 12) & 255);	// no ucode-mod-math
let q = id + '\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00\x03www\x07gstatic\x03com\x00\x00\x01\x00\x01';

let s = socket.connect(host, port, { socktype: socket.SOCK_DGRAM });
if (!s || s.send(q) != length(q))
	exit(1);
let end = clock(true), deadline = end[0] * 1000 + end[1] / 1000000 + wait;
for (;;) {
	let t = clock(true), left = deadline - (t[0] * 1000 + t[1] / 1000000);
	if (left <= 0)
		exit(1);
	let r = socket.poll(int(left), [ s, socket.POLLIN ]);
	// POLLERR: ICMP unreachable, nobody listens
	if (!length(r) || !(r[0][1] & socket.POLLIN))
		exit(1);
	let a = s.recv(512);
	// an answer to this query: the ID and the QR bit
	if (a && length(a) >= 12 && substr(a, 0, 2) == id && (ord(a, 2) & 0x80))
		exit(0);
}
