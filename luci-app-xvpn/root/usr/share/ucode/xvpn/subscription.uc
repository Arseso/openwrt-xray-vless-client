// SPDX-License-Identifier: MIT
// Subscription download, cache and server list assembly.

'use strict';

import { readfile, unlink } from 'fs';
import { SUBS_DIR, RUN_DIR, read_json, write_json, mkdir_p, shq, run } from 'xvpn.util';
import { b64, parse_link, parse_subscription } from 'xvpn.links';

// Failed downloads are retried after this many seconds.
const RETRY_AFTER = 1800;

export function cache_path(sid) {
	return `${SUBS_DIR}/${sid}.json`;
};

// Volatile per-subscription status (tmpfs): last attempt, error, traffic info.
export function status_path(sid) {
	return `${RUN_DIR}/sub-${sid}.json`;
};

export function load_cache(sid) {
	return read_json(cache_path(sid));
};

export function load_status(sid) {
	return read_json(status_path(sid)) ?? {};
};

function parse_headers(text) {
	let h = {};
	// with -L curl dumps headers of every hop; the last block wins
	for (let line in split(text ?? '', /\r?\n/)) {
		let m = match(line, /^([A-Za-z0-9-]+):[ \t]*(.*)$/);
		if (m)
			h[lc(m[1])] = trim(m[2]);
	}
	return h;
}

export function parse_userinfo(v) {
	if (!v)
		return null;
	let r = {};
	for (let kv in split(v, ';')) {
		let m = match(trim(kv), /^(upload|download|total|expire)=([0-9]+)/);
		if (m)
			r[m[1]] = int(m[2]);
	}
	return length(r) ? r : null;
};

function parse_title(v) {
	if (!v)
		return null;
	if (substr(v, 0, 7) == 'base64:')
		return b64(substr(v, 7));
	return v;
}

function download(sub, proxy_port) {
	mkdir_p(RUN_DIR);
	let hdr = `${RUN_DIR}/sub-${sub.id}.hdr`, body = `${RUN_DIR}/sub-${sub.id}.body`;
	let cmd = sprintf("curl -sS -L --connect-timeout 10 --max-time 40 -A %s -D %s -o %s -w '%%{http_code}' %s %s 2>&1",
		shq(sub.user_agent), shq(hdr), shq(body),
		proxy_port ? `-x socks5h://127.0.0.1:${proxy_port}` : '',
		shq(sub.url));

	let r = run(cmd);
	let code = int(substr(trim(r.out), -3));
	let res = { headers: parse_headers(readfile(hdr)), body: readfile(body), http: code };
	unlink(hdr);
	unlink(body);

	if (r.code != 0)
		res.error = trim(r.out) || `curl exit code ${r.code}`;
	else if (code < 200 || code >= 300)
		res.error = `HTTP ${code}`;
	return res;
}

// Updates one subscription. proxy_port: SOCKS port of the active server, or null.
// Returns { changed, count, skipped, error }.
export function update(sub, proxy_port) {
	if (!sub.url)
		return { changed: false, error: 'no URL' };

	let dl = null, via = null;
	if (sub.via_tunnel && proxy_port) {
		dl = download(sub, proxy_port);
		via = 'tunnel';
	}
	if (!dl || dl.error) {
		dl = download(sub, null);
		via = 'direct';
	}

	let st = load_status(sub.id);
	st.last_attempt = time();
	st.via = via;

	let parsed = dl.error ? null : parse_subscription(dl.body);
	if (dl.error || !length(parsed.servers)) {
		st.error = dl.error ?? parsed.errors[0] ?? 'no servers';
		mkdir_p(RUN_DIR);
		write_json(status_path(sub.id), st);
		return { changed: false, error: st.error };
	}

	let cache = {
		format: parsed.format,
		title: parse_title(dl.headers['profile-title']),
		interval: int(dl.headers['profile-update-interval'] ?? 0) || null,
		skipped: parsed.skipped,
		servers: parsed.servers,
	};
	let old = load_cache(sub.id);
	// timestamp only changes with content, so unchanged subscriptions never hit the flash
	cache.updated = (old && sprintf('%J', { ...old, updated: null }) == sprintf('%J', { ...cache, updated: null })) ? old.updated : time();

	mkdir_p(SUBS_DIR);
	let changed = write_json(cache_path(sub.id), cache);

	st.error = null;
	st.last_ok = time();
	st.userinfo = parse_userinfo(dl.headers['subscription-userinfo']);
	mkdir_p(RUN_DIR);
	write_json(status_path(sub.id), st);

	return { changed, count: length(parsed.servers), skipped: parsed.skipped, error: null };
};

// Seconds until the subscription is due for an update (<= 0 means now).
export function due_in(sub) {
	let cache = load_cache(sub.id), st = load_status(sub.id);
	let hours = sub.update_interval || cache?.interval || 12;
	let last = st.last_ok ?? 0;
	if (st.error && st.last_attempt > last)
		return st.last_attempt + RETRY_AFTER - time();
	return last + hours * 3600 - time();
};

function compile(re) {
	if (!re)
		return null;
	try {
		return regexp(re, 'i');
	}
	catch (e) {
		return null;
	}
}

// All usable servers: enabled subscriptions (filtered) + manual links, deduplicated.
export function all_servers(cfg) {
	let out = [], seen = {};
	let add = (s, sid, sname) => {
		if (seen[s.id])
			return;
		seen[s.id] = true;
		push(out, { ...s, sub: sid, sub_name: sname });
	};

	for (let sub in cfg.subscriptions) {
		if (!sub.enabled)
			continue;
		let inc = compile(sub.include), exc = compile(sub.exclude);
		for (let s in (load_cache(sub.id)?.servers ?? [])) {
			if (inc && !match(s.name, inc))
				continue;
			if (exc && match(s.name, exc))
				continue;
			add(s, sub.id, sub.name);
		}
	}

	for (let link in cfg.manual) {
		let s = parse_link(link);
		if (!s.error)
			add(s, 'manual', 'manual');
	}
	return out;
};
