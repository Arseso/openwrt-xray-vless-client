// SPDX-License-Identifier: MIT
// Subscription download, cache and server list assembly.

'use strict';

import { readfile, unlink, lsdir } from 'fs';
import { SUBS_DIR, RUN_DIR, read_json, write_json, mkdir_p, shq, run, fnv1a } from 'xvpn.util';
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
	// the URL comes from UCI as is: no file://, scp:// and the like, also not through a redirect
	let cmd = sprintf("curl -sS -L --proto =http,https --proto-redir =http,https --connect-timeout 10 --max-time 40 -A %s -D %s -o %s -w '%%{http_code}' %s %s 2>&1",
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

// Removes the cache and the status of subscriptions that are no longer in UCI.
export function prune(cfg) {
	let known = {};
	for (let sub in cfg.subscriptions)
		known[sub.id] = true;
	for (let f in (lsdir(SUBS_DIR) ?? [])) {
		let m = match(f, /^(.+)\.json$/);
		if (m && !known[m[1]])
			unlink(`${SUBS_DIR}/${f}`);
	}
	for (let f in (lsdir(RUN_DIR) ?? [])) {
		let m = match(f, /^sub-(.+)\.(json|hdr|body)$/);
		if (m && !known[m[1]])
			unlink(`${RUN_DIR}/${f}`);
	}
};

// Seconds until the subscription is due for an update (<= 0 means now).
// cache and st: already loaded by the caller (rpcd lists every subscription)
export function due_in(sub, cache, st) {
	cache ??= load_cache(sub.id);
	st ??= load_status(sub.id);
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

// What identifies a server's account: the user id or the password, not the address.
function credentials(s) {
	let st = s.outbound?.settings ?? {};
	let t = st.vnext?.[0] ?? st.servers?.[0] ?? {};
	return t.users?.[0]?.id ?? t.password ?? '';
}

// Server ids that survive a change of address or port: some subscriptions hand out
// another host of the same server on every download (#49). The id comes from the
// source (subscription id or "manual"), protocol, name and credentials; servers that
// share all of them in one source are told apart by their order. hash: the connection
// itself (links.uc), the server id before #49; caches written then hold it as id.
export function assign_ids(servers, source) {
	let seen = {};
	return map(servers, (s) => {
		let key = join('|', [ source, s.proto, s.name, credentials(s) ]);
		let n = seen[key] = (seen[key] ?? 0) + 1;
		return { ...s, hash: s.hash ?? s.id, id: fnv1a((n > 1) ? `${key}|${n}` : key) };
	});
};

// What an update of the server list needs (cli.uc update): 'reload' when servers came
// or went or one of active_ids changed, 'stale' when only the others changed (xray goes
// on with their old addresses until the next reload), null when nothing changed.
export function list_change(before, after, active_ids) {
	let a = {}, b = {};
	for (let s in before)
		a[s.id] = sprintf('%J', s);
	for (let s in after)
		b[s.id] = sprintf('%J', s);
	if (join('|', sort(keys(a))) != join('|', sort(keys(b))))
		return 'reload';
	for (let id in active_ids)
		if (id && a[id] != b[id])
			return 'reload';
	return (sprintf('%J', before) != sprintf('%J', after)) ? 'stale' : null;
};

// All usable servers: enabled subscriptions (filtered) + manual links, deduplicated.
export function all_servers(cfg) {
	let out = [], seen = {};
	let add = (s, sid, sname) => {
		if (seen[s.hash] || seen[s.id])
			return;
		seen[s.hash] = seen[s.id] = true;
		push(out, { ...s, sub: sid, sub_name: sname });
	};

	for (let sub in cfg.subscriptions) {
		if (!sub.enabled)
			continue;
		let inc = compile(sub.include), exc = compile(sub.exclude);
		// ids before the filters: changing them does not renumber the servers
		for (let s in assign_ids(load_cache(sub.id)?.servers ?? [], sub.id)) {
			if (inc && !match(s.name, inc))
				continue;
			if (exc && match(s.name, exc))
				continue;
			add(s, sub.id, sub.name);
		}
	}

	let manual = filter(map(cfg.manual ?? [], (l) => parse_link(l)), (s) => !s.error);
	for (let s in assign_ids(manual, 'manual'))
		add(s, 'manual', 'manual');
	return out;
};
