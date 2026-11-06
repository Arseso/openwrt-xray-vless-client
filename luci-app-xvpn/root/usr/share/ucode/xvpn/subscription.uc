// SPDX-License-Identifier: MIT
// Subscription download, cache and server list assembly.

'use strict';

import { readfile, unlink, lsdir } from 'fs';
import { cursor } from 'uci';
import { SUBS_DIR, RUN_DIR, ETC_DIR, read_json, write_json, mkdir_p, shq, run, fnv1a, log, no_auto_ids, set_no_auto } from 'xvpn.util';
import { b64, parse_link, parse_subscription } from 'xvpn.links';

// Failed downloads are retried after this many seconds.
const RETRY_AFTER = 1800;
// The body goes to tmpfs (RAM): a wrong or hostile URL must not fill it (#17). Hundreds of
// servers as links are well below; curl stops a larger one also without Content-Length.
export const MAX_SIZE = 2 * 1024 * 1024;

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
	let cmd = sprintf("curl -sS -L --proto =http,https --proto-redir =http,https --connect-timeout 10 --max-time 40 --max-filesize %d -A %s -D %s -o %s -w '%%{http_code}' %s %s 2>&1",
		MAX_SIZE, shq(sub.user_agent), shq(hdr), shq(body),
		proxy_port ? `-x socks5h://127.0.0.1:${proxy_port}` : '',
		shq(sub.url));

	let r = run(cmd);
	let code = int(substr(trim(r.out), -3));
	let res = { headers: parse_headers(readfile(hdr)), body: readfile(body), http: code };
	unlink(hdr);
	unlink(body);

	// 63: --max-filesize
	if (r.code == 63)
		res.error = `the answer is larger than ${MAX_SIZE / 1048576} MB`;
	else if (r.code != 0)
		res.error = trim(r.out) || `curl exit code ${r.code}`;
	else if (code < 200 || code >= 300)
		res.error = `HTTP ${code}`;
	return res;
}

// A host no client can reach a server at: 0.0.0.0, ::, empty.
function unspecified(a) {
	return a == null || a == '' || a == '0.0.0.0' || match(a, /^\[?::\]?$/) != null;
}

// Loopback and private addresses: on the router or in its LAN, not a VPN server out there.
function local_addr(a) {
	a = lc(replace(a ?? '', /^\[|\]$/g, ''));
	return a == 'localhost' || match(a, /^(127\.|10\.|192\.168\.|169\.254\.|172\.(1[6-9]|2[0-9]|3[01])\.)/) != null
		|| a == '::1' || match(a, /^f[cd][0-9a-f]{2}:|^fe[89ab][0-9a-f]:/) != null;
}

// A panel (Marzban, Remnawave, 3x-ui) answers an expired or blocked subscription with one or
// two placeholder "servers" named like "Subscription expired" at 0.0.0.0 or 127.0.0.1 (#17).
// Servers at unspecified addresses are dropped; a list left empty, or left with only local
// addresses while the cache had a server out there, is no update: the cache stays and the
// error says why. old: the servers of the cache. { servers, dropped } or { error }.
export function check_stub(servers, old, userinfo) {
	let kept = filter(servers, (s) => !unspecified(s.address));
	let public_ = (l) => length(filter(l ?? [], (s) => !unspecified(s.address) && !local_addr(s.address)));
	if (!length(kept) || (!public_(kept) && public_(old))) {
		let names = join(', ', map(slice(servers, 0, 2), (s) => `"${s.name}" (${s.address})`));
		let exp = userinfo?.expire, d = exp ? gmtime(exp) : null;
		let why = (exp && exp <= time()) ? sprintf(', the subscription expired on %04d-%02d-%02d', d.year, d.mon, d.mday) : '';
		return { error: `only placeholder servers: ${names}${why}; the servers from the last update are kept` };
	}
	return { servers: kept, dropped: length(servers) - length(kept) };
};

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

	let old = load_cache(sub.id);
	let userinfo = parse_userinfo(dl.headers['subscription-userinfo']);
	let stub = check_stub(parsed.servers, old?.servers, userinfo);
	if (stub.error) {
		st.error = stub.error;
		st.userinfo = userinfo ?? st.userinfo;	// the expiry date shows up in the UI
		mkdir_p(RUN_DIR);
		write_json(status_path(sub.id), st);
		return { changed: false, error: st.error };
	}
	let cache = {
		format: parsed.format,
		title: parse_title(dl.headers['profile-title']),
		interval: int(dl.headers['profile-update-interval'] ?? 0) || null,
		skipped: (parsed.skipped ?? 0) + stub.dropped,
		servers: stub.servers,
	};
	// timestamp only changes with content, so unchanged subscriptions never hit the flash
	cache.updated = (old && sprintf('%J', { ...old, updated: null }) == sprintf('%J', { ...cache, updated: null })) ? old.updated : time();

	mkdir_p(SUBS_DIR);
	let changed = write_json(cache_path(sub.id), cache);

	st.error = null;
	st.last_ok = time();
	st.userinfo = userinfo;
	mkdir_p(RUN_DIR);
	write_json(status_path(sub.id), st);

	return { changed, count: length(stub.servers), skipped: cache.skipped, error: null };
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
		// a link without a name is named address:port (links.uc): no name for the id
		let name = (s.name == `${s.address}:${s.port}`) ? '' : s.name;
		let key = join('|', [ source, s.proto, name, credentials(s) ]);
		let n = seen[key] = (seen[key] ?? 0) + 1;
		// fixed key order: a cache from before #49 compares equal to a new one (list_change)
		return {
			id: fnv1a((n > 1) ? `${key}|${n}` : key), hash: s.hash ?? s.id,
			name: s.name, proto: s.proto, address: s.address, port: s.port, outbound: s.outbound,
		};
	});
};

// What an update of the server list needs (cli.uc update): 'reload' when servers came
// or went or an active one changed, 'stale' when only the others changed (xray goes on
// with their old addresses until the next reload), null when nothing changed.
// active_ids: ids or hashes (the id before #49) of the servers in use.
export function list_change(before, after, active_ids) {
	let a = {}, b = {};
	active_ids = filter(active_ids, (x) => x);
	for (let s in before)
		a[s.id] = sprintf('%J', s);
	for (let s in after)
		b[s.id] = sprintf('%J', s);
	if (join('|', sort(keys(a))) != join('|', sort(keys(b))))
		return 'reload';
	for (let s in before)
		if (((s.id in active_ids) || (s.hash in active_ids)) && a[s.id] != b[s.id])
			return 'reload';
	return (sprintf('%J', before) != sprintf('%J', after)) ? 'stale' : null;
};

// Leaves whose value is no secret: the log shows what they changed from and to. Everything
// else (ids, passwords, keys, short ids) is named by its path only.
const PLAIN_LEAVES = [ 'name', 'address', 'port', 'serverName', 'sni', 'host', 'path', 'serviceName',
	'flow', 'fingerprint', 'network', 'security', 'alpn' ];

// Paths of the leaves that differ between two values, e.g. outbound.settings.vnext[0].address.
function diff_paths(a, b, path, out) {
	if (type(a) == 'object' && type(b) == 'object') {
		let ks = {};
		for (let k in a)
			ks[k] = true;
		for (let k in b)
			ks[k] = true;
		for (let k in sort(keys(ks)))
			diff_paths(a[k], b[k], path ? `${path}.${k}` : k, out);
	}
	else if (type(a) == 'array' && type(b) == 'array' && length(a) == length(b)) {
		for (let i = 0; i < length(a); i++)
			diff_paths(a[i], b[i], `${path}[${i}]`, out);
	}
	else if (sprintf('%J', a) != sprintf('%J', b)) {
		let parts = split(path, '.'), leaf = replace(parts[length(parts) - 1], /\[[0-9]+\]$/, '');
		push(out, (leaf in PLAIN_LEAVES) ? `${path} ${sprintf('%J', a)} -> ${sprintf('%J', b)}` : path);
	}
}

// Why an update of the server list asks for a reload, or only marks the list stale: one line
// per server that came, went or changed (the same comparison as list_change()), no secrets.
// An update that restarts xray every hour drops the clients' connections: this is what to
// look at to see what the subscription changes.
export function list_diff(before, after, active_ids) {
	let a = {}, b = {}, out = [];
	active_ids = filter(active_ids, (x) => x);
	for (let s in before)
		a[s.id] = s;
	for (let s in after)
		b[s.id] = s;
	let what = (s) => `"${s.name}" ${s.address}:${s.port}`;
	for (let id in sort(keys(a)))
		if (!b[id])
			push(out, `gone: ${what(a[id])}`);
	for (let id in sort(keys(b)))
		if (!a[id])
			push(out, `new: ${what(b[id])}`);
	for (let id in sort(keys(a))) {
		if (!b[id] || sprintf('%J', a[id]) == sprintf('%J', b[id]))
			continue;
		let paths = [];
		diff_paths(a[id], b[id], '', paths);
		let used = (id in active_ids) || (a[id].hash in active_ids);
		push(out, `${used ? 'ACTIVE ' : ''}changed: ${what(b[id])}: ${join(', ', paths)}`);
	}
	return out;
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

// Ids of every server the subscriptions (enabled or not, before the filters) and the
// manual links still have: a flag of health.no_auto outlives a filter or a disabled one.
export function known_ids(cfg) {
	let ids = {};
	for (let sub in cfg.subscriptions)
		for (let s in assign_ids(load_cache(sub.id)?.servers ?? [], sub.id))
			ids[s.id] = true;
	let manual = filter(map(cfg.manual ?? [], (l) => parse_link(l)), (s) => !s.error);
	for (let s in assign_ids(manual, 'manual'))
		ids[s.id] = true;
	return ids;
};

// A server gone from the subscriptions keeps its health.no_auto flag this long: a provider
// may hand out a stub list for a while, the server would come back into auto selection
export const NO_AUTO_GRACE = 7 * 86400;
const NO_AUTO_GONE = `${ETC_DIR}/no_auto_gone.json`;

// Drops the health.no_auto ids of servers gone for NO_AUTO_GRACE (#60), commits only then.
// gone: a JSON file { id: since } of the ones missing now. c: a uci cursor; returns the ids dropped.
export function prune_no_auto(c, known, gone, at) {
	gone ??= NO_AUTO_GONE;
	at ??= time();
	let ids = no_auto_ids(c), seen = read_json(gone) ?? {}, still = {}, drop = [];
	for (let id in ids) {
		if (known[id])
			continue;
		let since = seen[id];
		// a clock set back (NTP after boot) does not make it older
		if (type(since) != 'int' || since > at) {
			since = at;
			log(`server ${id} is gone from the subscriptions and links, its health.no_auto flag goes in ${NO_AUTO_GRACE / 86400} days`);
		}
		if (at - since >= NO_AUTO_GRACE)
			push(drop, id);
		else
			still[id] = since;
	}
	if (length(drop)) {
		let err = set_no_auto(c, filter(ids, (id) => !(id in drop)));
		if (err) {
			log(`${err}: ids of servers that are gone stay in health.no_auto`);
			for (let id in drop)
				still[id] = seen[id];
			drop = [];
		}
		for (let id in drop)
			log(`server ${id} is gone for ${NO_AUTO_GRACE / 86400} days, removed from health.no_auto`);
	}
	if (length(still))
		write_json(gone, still);
	else
		unlink(gone);
	return drop;
};

// Removes the cache and the status of subscriptions that are no longer in UCI
// and the ids of servers that are gone from health.no_auto.
export function prune(cfg) {
	mkdir_p(ETC_DIR);
	prune_no_auto(cursor(), known_ids(cfg));
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
