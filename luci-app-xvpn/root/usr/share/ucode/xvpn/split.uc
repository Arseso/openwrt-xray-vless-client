// SPDX-License-Identifier: MIT
// Split tunneling (#67): addresses that go around the tunnel before TPROXY (nft sets in
// inet xvpn, firewall.uc) and the small list of domains xray sends out directly (freedom).

'use strict';

import { readfile, unlink, stat } from 'fs';
import { ETC_DIR, RUN_DIR, mkdir_p, write_file, write_json, read_json, run, shq, log } from 'xvpn.util';

export const LISTS_DIR = `${ETC_DIR}/lists`;
// the downloaded Russian list, normalized: one network per line, IPv4 first. On the flash
// like the subscriptions: the bypass works after a boot without the source. Written only
// when it changed
export const RU_FILE = `${LISTS_DIR}/ru.txt`;
// last attempt, error, counts (tmpfs)
export const LISTS_STATUS = `${RUN_DIR}/lists.json`;
// aggregated country lists, plain text, one network per line; split.ru_url replaces them
export const RU_URLS = [
	'https://www.ipdeny.com/ipblocks/data/aggregated/ru-aggregated.zone',
	'https://www.ipdeny.com/ipv6/ipaddresses/aggregated/ru-aggregated.zone',
];
// the kernel set takes them in a few MB; a file far over that is not a country list
const MAX_NETS = 50000, MAX_DOMAINS = 1000, MAX_BYTES = 4194304;
// failed downloads are tried again after this many seconds
const RETRY_AFTER = 1800;

// An IPv4/IPv6 address or network, normalized (host bits cleared, /32 and /128 dropped):
// { v6, net } or null. /0 is no list entry: everything direct is the service turned off.
export function cidr(s) {
	let m = match(trim(`${s ?? ''}`), /^([0-9A-Fa-f:.]+)(\/([0-9]{1,3}))?$/);
	let a = m ? iptoarr(m[1]) : null;
	if (!a)
		return null;
	let bits = length(a) * 8, n = (m[3] != null) ? int(m[3]) : bits;
	if (n < 1 || n > bits)
		return null;
	for (let i = 0; i < length(a); i++) {
		let keep = min(8, max(0, n - i * 8));
		a[i] = a[i] & ((0xff << (8 - keep)) & 0xff);
	}
	return { v6: length(a) == 16, net: (n == bits) ? arrtoip(a) : `${arrtoip(a)}/${n}` };
};

// Networks of a list: whitespace separated, # and ; start a comment.
// { v4: [], v6: [], bad: <entries that are not networks> }
export function parse_nets(text) {
	let r = { v4: [], v6: [], bad: 0 };
	for (let l in split(text ?? '', '\n')) {
		l = replace(l, /[#;].*$/, '');
		for (let w in split(l, /[ \t\r,]+/)) {
			if (w == '')
				continue;
			let c = cidr(w);
			if (c)
				push(c.v6 ? r.v6 : r.v4, c.net);
			else
				r.bad++;
		}
	}
	return r;
};

// A domain of split.domain as an xray routing entry: "example.ru" (with subdomains) and
// "ru" (the whole zone) give domain:, "full:www.example.ru" only that name. IDN in
// punycode (xn--p1ai). null for anything else: xray would reject the whole config.
export function domain_rule(s) {
	let d = lc(trim(`${s ?? ''}`)), kind = 'domain';
	let m = match(d, /^(full|domain):(.*)$/);
	if (m) {
		kind = m[1];
		d = m[2];
	}
	d = replace(d, /^(\*?\.)/, '');
	if (length(d) > 253 || !match(d, /^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)*$/))
		return null;
	return `${kind}:${d}`;
};

// The domains xray sends to the freedom outbound, without duplicates; bad ones go to the log.
export function direct_domains(cfg) {
	let r = [];
	for (let d in cfg.split?.domain ?? []) {
		let e = domain_rule(d);
		if (!e)
			log(`split tunneling: "${d}" is not a domain, skipped`);
		else if (!(e in r))
			push(r, e);
	}
	if (length(r) > MAX_DOMAINS) {
		log(`split tunneling: ${length(r)} domains, only the first ${MAX_DOMAINS} are used`);
		r = slice(r, 0, MAX_DOMAINS);
	}
	return r;
};

// The networks that go around the tunnel: split.ip and, with split.ru, the cached list.
// { v4: [], v6: [] }; bad entries of split.ip go to the log.
export function direct_nets(cfg, ru_file) {
	let r = { v4: [], v6: [] };
	for (let e in cfg.split?.ip ?? []) {
		let c = cidr(e);
		if (c)
			push(c.v6 ? r.v6 : r.v4, c.net);
		else
			log(`split tunneling: "${e}" is not an IP address or network, skipped`);
	}
	if (cfg.split?.ru) {
		let l = parse_nets(readfile(ru_file ?? RU_FILE));
		push(r.v4, ...l.v4);
		push(r.v6, ...l.v6);
	}
	return { v4: uniq(r.v4), v6: uniq(r.v6) };
};

export function lists_status() {
	return read_json(LISTS_STATUS) ?? {};
};

// Seconds until the list is due for a download (<= 0: now); null when it is off.
export function lists_due_in(cfg, st) {
	if (!cfg.split?.ru)
		return null;
	st ??= lists_status();
	let last = st.last_ok ?? 0;
	if (st.error && (st.last_attempt ?? 0) > last)
		return st.last_attempt + RETRY_AFTER - time();
	// a boot clears the status: a cached list is kept until a download goes through
	return last + cfg.split.ru_interval * 3600 - time();
};

function download(url, proxy_port) {
	mkdir_p(RUN_DIR);
	let body = `${RUN_DIR}/lists.body`;
	let r = run(sprintf("curl -sS -L --proto =http,https --proto-redir =http,https --connect-timeout 10 --max-time 60 --max-filesize %d -o %s -w '%%{http_code}' %s %s 2>&1",
		MAX_BYTES, shq(body), proxy_port ? `-x socks5h://127.0.0.1:${proxy_port}` : '', shq(url)));
	let code = int(substr(trim(r.out), -3)), text = readfile(body);
	unlink(body);
	if (r.code != 0)
		return { error: trim(r.out) || `curl exit code ${r.code}` };
	if (code < 200 || code >= 300)
		return { error: `HTTP ${code}` };
	return { text };
}

// Downloads the Russian list (every URL of split.ru_url, all of them or nothing: half a
// list would send the other half through the tunnel without a word) through the active
// server, then directly. Writes RU_FILE when it changed. proxy_port: the test port of the
// active server or null. Returns { changed, v4, v6, error }.
export function update_lists(cfg, proxy_port) {
	if (!cfg.split?.ru)
		return { changed: false, error: 'the Russian list is off' };
	let st = lists_status(), nets = { v4: [], v6: [], bad: 0 }, err = null, via = 'tunnel';
	st.last_attempt = time();
	for (let tunnel in (proxy_port ? [ true, false ] : [ false ])) {
		nets = { v4: [], v6: [], bad: 0 };
		err = null;
		via = tunnel ? 'tunnel' : 'direct';
		for (let url in (length(cfg.split.ru_url) ? cfg.split.ru_url : RU_URLS)) {
			let d = download(url, tunnel ? proxy_port : null);
			if (d.error) {
				err = `${url}: ${d.error}`;
				break;
			}
			let l = parse_nets(d.text);
			push(nets.v4, ...l.v4);
			push(nets.v6, ...l.v6);
			nets.bad += l.bad;
		}
		if (!err)
			break;
	}
	let total = length(nets.v4) + length(nets.v6);
	if (!err && !total)
		err = 'no networks in the list';
	else if (!err && total > MAX_NETS)
		err = `${total} networks, more than ${MAX_NETS}: not a country list`;
	// a page instead of a list (captive portal, an error page with 200)
	else if (!err && nets.bad > total)
		err = `${nets.bad} entries are not networks`;
	st.via = via;
	if (err) {
		st.error = err;
		mkdir_p(RUN_DIR);
		write_json(LISTS_STATUS, st);
		return { changed: false, error: err };
	}
	mkdir_p(LISTS_DIR);
	let changed = write_file(RU_FILE, join('\n', [ ...uniq(nets.v4), ...uniq(nets.v6) ]) + '\n');
	st.error = null;
	st.last_ok = time();
	st.v4 = length(uniq(nets.v4));
	st.v6 = length(uniq(nets.v6));
	st.bad = nets.bad;
	mkdir_p(RUN_DIR);
	write_json(LISTS_STATUS, st);
	return { changed, v4: st.v4, v6: st.v6, error: null };
};

// The list is off: its cache leaves the flash (generate, at every start and reload).
export function prune_lists(cfg) {
	if (cfg.split?.ru)
		return;
	if (stat(RU_FILE))
		unlink(RU_FILE);
	unlink(LISTS_STATUS);
};
