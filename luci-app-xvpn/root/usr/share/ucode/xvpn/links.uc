// SPDX-License-Identifier: MIT
// Share links (vless/vmess/trojan/ss) and subscription bodies -> xray outbounds.

'use strict';

import { fnv1a } from 'xvpn.util';

const SS_METHODS = [
	'aes-128-gcm', 'aes-256-gcm', 'chacha20-poly1305', 'chacha20-ietf-poly1305',
	'xchacha20-poly1305', 'xchacha20-ietf-poly1305', 'none', 'plain',
	'2022-blake3-aes-128-gcm', '2022-blake3-aes-256-gcm', '2022-blake3-chacha20-poly1305',
];

const NETWORKS = {
	tcp: 'tcp', raw: 'tcp', ws: 'ws', websocket: 'ws', grpc: 'grpc', gun: 'grpc',
	xhttp: 'xhttp', splithttp: 'xhttp', httpupgrade: 'httpupgrade', kcp: 'kcp', mkcp: 'kcp',
};

export function b64(s) {
	if (s == null)
		return null;
	s = replace(s, /\s+/g, '');
	s = replace(replace(s, /-/g, '+'), /_/g, '/');
	while (length(s) % 4)
		s += '=';
	return b64dec(s);
};

export function urldecode(s) {
	if (s == null)
		return null;
	return replace(s, /%([0-9A-Fa-f]{2})/g, (m, h) => chr(hex(h)));
};

// Drops null / empty-string / empty-array members (shallow).
function clean(o) {
	let r = {};
	for (let k, v in o)
		if (v != null && v !== '' && !(type(v) == 'array' && !length(v)))
			r[k] = v;
	return r;
}

function split_list(s) {
	return s ? filter(map(split(s, ','), (e) => trim(e)), (e) => e != '') : [];
}

function truthy(v) {
	return v in [ '1', 'true', 'True', 'yes' ];
}

// host:port, [v6]:port -> [ host, port ]
function parse_hostport(s) {
	let m = match(s, /^\[([0-9A-Fa-f:.]+)\]:([0-9]+)$/) ?? match(s, /^([^:\/]+):([0-9]+)$/);
	if (!m)
		return null;
	let port = int(m[2]);
	if (port < 1 || port > 65535)
		return null;
	return [ m[1], port ];
}

// scheme://userinfo@host:port/path?query#fragment
function parse_url(s) {
	let m = match(s, /^([a-zA-Z0-9+.-]+):\/\/([^#]*)(#(.*))?$/);
	if (!m)
		return null;

	let rest = m[2], query = {}, qpos = index(rest, '?');
	if (qpos >= 0) {
		for (let kv in split(substr(rest, qpos + 1), '&')) {
			if (kv == '')
				continue;
			let eq = index(kv, '=');
			if (eq < 0)
				query[urldecode(kv)] = '';
			else
				query[urldecode(substr(kv, 0, eq))] = urldecode(substr(kv, eq + 1));
		}
		rest = substr(rest, 0, qpos);
	}

	let spos = index(rest, '/');
	if (spos >= 0)
		rest = substr(rest, 0, spos);

	let at = rindex(rest, '@');
	return {
		scheme: lc(m[1]),
		user: (at >= 0) ? substr(rest, 0, at) : null,
		hostport: (at >= 0) ? substr(rest, at + 1) : rest,
		query,
		name: m[4] ? trim(urldecode(m[4])) : null,
	};
}

// Builds xray streamSettings from v2rayN-style parameters:
// type, security, sni, fp, alpn, pbk, sid, spx, host, path, serviceName,
// mode, authority, headerType, seed, extra, allowInsecure, pcs, vcn.
export function stream_settings(p, address) {
	let type = lc(p.type || 'tcp');
	let network = NETWORKS[type];
	if (!network)
		return { error: `unsupported transport "${type}"` };

	let security = lc(p.security || 'none');
	if (security == 'xtls')
		security = 'tls';
	if (!(security in [ 'none', 'tls', 'reality' ]))
		return { error: `unsupported security "${security}"` };

	let ss = { network, security };
	let sni = p.sni || p.peer || p.host || ((security == 'tls' && !match(address, /^[0-9.]+$|:/)) ? address : null);

	if (security == 'tls') {
		ss.tlsSettings = clean({
			serverName: sni,
			fingerprint: p.fp,
			alpn: split_list(p.alpn),
			// xray 26 removed allowInsecure and rejects the server that sets it (#14); pcs and
			// vcn replace it there, 25.1.30 does not know them and ignores them
			allowInsecure: (truthy(p.allowInsecure) || truthy(p.insecure)) ? true : null,
			pinnedPeerCertSha256: p.pcs,
			verifyPeerCertByName: p.vcn,
		});
	}
	else if (security == 'reality') {
		if (!p.pbk)
			return { error: 'reality without public key (pbk)' };
		ss.realitySettings = clean({
			serverName: p.sni || p.peer,
			fingerprint: p.fp || 'chrome',
			publicKey: p.pbk,
			shortId: p.sid,
			spiderX: p.spx,
		});
	}

	let path = p.path, host = p.host;
	if (network == 'ws')
		ss.wsSettings = clean({ path: path || '/', host });
	else if (network == 'httpupgrade')
		ss.httpupgradeSettings = clean({ path: path || '/', host });
	else if (network == 'grpc')
		ss.grpcSettings = clean({
			serviceName: p.serviceName || path,
			authority: p.authority,
			multiMode: (p.mode == 'multi') ? true : null,
		});
	else if (network == 'xhttp') {
		let extra = null;
		if (p.extra) {
			try { extra = json(p.extra); } catch (e) { return { error: 'invalid xhttp extra JSON' }; }
		}
		ss.xhttpSettings = clean({ path: path || '/', host, mode: p.mode || 'auto', extra });
	}
	else if (network == 'kcp')
		ss.kcpSettings = clean({ header: { type: p.headerType || 'none' }, seed: p.seed });
	else if (network == 'tcp' && p.headerType == 'http')
		ss.tcpSettings = {
			header: {
				type: 'http',
				request: clean({ path: split_list(path || '/'), headers: host ? { Host: split_list(host) } : null }),
			},
		};

	return { stream: ss };
};

function server(proto, name, address, port, outbound, key) {
	return {
		// the connection itself: dedupes servers listed twice; the stable id comes from
		// subscription.uc assign_ids()
		hash: fnv1a(join('|', [ proto, address, port, key, sprintf('%J', outbound.streamSettings ?? {}) ])),
		name: name || `${address}:${port}`,
		proto, address, port, outbound,
	};
}

function parse_vless(u) {
	let hp = parse_hostport(u.hostport);
	if (!hp || !u.user)
		return { error: 'malformed vless link' };
	let q = u.query;
	let enc = q.encryption || 'none';
	if (enc != 'none')
		return { error: `unsupported vless encryption "${enc}"` };

	let st = stream_settings(q, hp[0]);
	if (st.error)
		return st;

	let ob = {
		protocol: 'vless',
		settings: {
			vnext: [ { address: hp[0], port: hp[1], users: [ clean({ id: urldecode(u.user), encryption: 'none', flow: q.flow }) ] } ],
		},
		streamSettings: st.stream,
	};
	return server('vless', u.name, hp[0], hp[1], ob, u.user);
}

function parse_trojan(u) {
	let hp = parse_hostport(u.hostport);
	if (!hp || !u.user)
		return { error: 'malformed trojan link' };
	let q = { ...u.query };
	q.security ??= 'tls';

	let st = stream_settings(q, hp[0]);
	if (st.error)
		return st;

	let ob = {
		protocol: 'trojan',
		settings: { servers: [ clean({ address: hp[0], port: hp[1], password: urldecode(u.user), flow: q.flow }) ] },
		streamSettings: st.stream,
	};
	return server('trojan', u.name, hp[0], hp[1], ob, u.user);
}

function parse_vmess(link) {
	let raw = b64(substr(link, 8));
	let v;
	try { v = json(raw); } catch (e) { return { error: 'malformed vmess link' }; }
	if (type(v) != 'object' || !v.add || !v.id)
		return { error: 'malformed vmess link' };

	let port = int(v.port);
	let net = v.net || 'tcp';
	let tls = lc(v.tls ?? '');
	let p = {
		type: net,
		security: (tls in [ 'tls', 'reality' ]) ? tls : 'none',
		sni: v.sni, fp: v.fp, alpn: v.alpn, host: v.host, path: v.path, pbk: v.pbk, sid: v.sid,
		headerType: (net in [ 'tcp', 'kcp' ]) ? v.type : null,
		mode: (net == 'grpc' && v.type == 'multi') ? 'multi' : ((net == 'xhttp') ? v.type : null),
		allowInsecure: v.allowInsecure ? '1' : null,
	};
	if (net == 'grpc')
		p.serviceName = v.path;

	let st = stream_settings(p, v.add);
	if (st.error)
		return st;

	let ob = {
		protocol: 'vmess',
		settings: { vnext: [ { address: v.add, port, users: [ { id: v.id, security: v.scy || 'auto' } ] } ] },
		streamSettings: st.stream,
	};
	return server('vmess', v.ps ? trim(v.ps) : null, v.add, port, ob, v.id);
}

function parse_ss(link) {
	let body = substr(link, 5), name = null;
	let hash = index(body, '#');
	if (hash >= 0) {
		name = trim(urldecode(substr(body, hash + 1)));
		body = substr(body, 0, hash);
	}

	// Legacy: ss://base64(method:password@host:port)
	if (index(body, '@') < 0) {
		let dec = b64(replace(body, /[\/?].*$/, ''));
		if (!dec || index(dec, '@') < 0)
			return { error: 'malformed ss link' };
		body = dec;
	}

	let u = parse_url('ss://' + body);
	if (!u || !u.user)
		return { error: 'malformed ss link' };
	if (u.query.plugin)
		return { error: 'ss plugins are not supported' };

	let hp = parse_hostport(u.hostport);
	if (!hp)
		return { error: 'malformed ss link' };

	let cred = urldecode(u.user);
	if (index(cred, ':') < 0)
		cred = b64(u.user);
	let colon = cred ? index(cred, ':') : -1;
	if (colon < 0)
		return { error: 'malformed ss credentials' };

	let method = lc(substr(cred, 0, colon)), password = substr(cred, colon + 1);
	if (!(method in SS_METHODS))
		return { error: `unsupported ss method "${method}"` };
	if (substr(method, 0, 5) == '2022-') {
		// base64 PSK of the cipher key size; "iPSK:uPSK" for multi-user servers
		let size = (index(method, 'aes-128') >= 0) ? 16 : 32;
		for (let k in split(password, ':'))
			if (length(b64(k) ?? '') != size)
				return { error: 'invalid ss 2022 key' };
	}

	let ob = {
		protocol: 'shadowsocks',
		settings: { servers: [ { address: hp[0], port: hp[1], method, password } ] },
		streamSettings: { network: 'tcp' },
	};
	return server('shadowsocks', name, hp[0], hp[1], ob, cred);
}

// Parses one share link. Returns a server object or { error }.
export function parse_link(link) {
	link = trim(link);
	let scheme = lc(match(link, /^([a-zA-Z0-9]+):\/\//)?.[1] ?? '');
	switch (scheme) {
	case 'vless':
	case 'trojan':
		let u = parse_url(link);
		if (!u)
			return { error: `malformed ${scheme} link` };
		return (scheme == 'vless') ? parse_vless(u) : parse_trojan(u);
	case 'vmess':
		return parse_vmess(link);
	case 'ss':
		return parse_ss(link);
	case '':
		return { error: 'not a link' };
	default:
		return { error: `unsupported protocol "${scheme}"` };
	}
};

const JSON_PROTOCOLS = [ 'vless', 'vmess', 'trojan', 'shadowsocks' ];

function outbound_address(ob) {
	let s = ob.settings ?? {};
	let t = s.vnext?.[0] ?? s.servers?.[0];
	return t ? [ t.address, int(t.port) ] : null;
}

// One full xray config (e.g. Remnawave/3x-ui "xray json" subscription item).
function from_xray_config(c) {
	for (let ob in (c?.outbounds ?? [])) {
		if (!(ob?.protocol in JSON_PROTOCOLS))
			continue;
		let hp = outbound_address(ob);
		if (!hp)
			continue;
		let out = { protocol: ob.protocol, settings: ob.settings };
		if (ob.streamSettings) {
			out.streamSettings = { ...ob.streamSettings };
			// chained proxies are not supported here
			delete out.streamSettings.sockopt;
		}
		if (ob.mux)
			out.mux = ob.mux;
		return server(ob.protocol, c.remarks, hp[0], hp[1], out, sprintf('%J', ob.settings));
	}
	return { error: 'no supported outbound in xray config' };
}

// Decodes a subscription body. Returns { format, servers, skipped, errors }.
export function parse_subscription(body) {
	let res = { format: null, servers: [], skipped: 0, errors: [] };
	body = trim(body ?? '');
	if (body == '') {
		push(res.errors, 'empty subscription');
		return res;
	}

	let items = null;
	if (substr(body, 0, 1) in [ '[', '{' ]) {
		let j = null;
		try { j = json(body); } catch (e) { }
		if (j != null) {
			res.format = 'xray-json';
			for (let c in ((type(j) == 'array') ? j : [ j ])) {
				let s = from_xray_config(c);
				if (s.error) {
					res.skipped++;
					push(res.errors, s.error);
				}
				else
					push(res.servers, s);
			}
			return res;
		}
	}

	if (match(body, /(^|\n)[a-zA-Z0-9]+:\/\//)) {
		res.format = 'plain';
		items = split(body, /\r?\n/);
	}
	else {
		let dec = b64(body);
		if (dec && match(dec, /(^|\n)[a-zA-Z0-9]+:\/\//)) {
			res.format = 'base64';
			items = split(dec, /\r?\n/);
		}
	}

	if (items == null) {
		if (match(body, /(^|\n)(proxies|proxy-groups|mixed-port|port):/))
			push(res.errors, 'Clash YAML is not supported; change the User-Agent so that the provider returns links');
		else if (match(body, /^\s*</))
			push(res.errors, 'provider returned HTML instead of a subscription');
		else
			push(res.errors, 'unknown subscription format');
		return res;
	}

	for (let line in items) {
		line = trim(line);
		if (line == '' || substr(line, 0, 1) == '#')
			continue;
		let s = parse_link(line);
		if (s.error) {
			res.skipped++;
			push(res.errors, s.error);
		}
		else
			push(res.servers, s);
	}
	return res;
};
