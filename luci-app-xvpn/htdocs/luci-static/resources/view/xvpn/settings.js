// SPDX-License-Identifier: MIT
// Settings tab: health checks and server choice, xray, ports, marks and the routing table.
// The service options used by the tests (health.reload_idle, reload_retry, generate_budget) are not shown.
'use strict';
'require view';
'require form';
'require rpc';
'require uci';
'require ui';

const callServers = rpc.declare({ object: 'luci.xvpn', method: 'servers' });
const callXray = rpc.declare({ object: 'luci.xvpn', method: 'xray' });
const callXrayLatest = rpc.declare({ object: 'luci.xvpn', method: 'xray_latest' });
const callXrayInstall = rpc.declare({ object: 'luci.xvpn', method: 'xray_install', params: [ 'tag' ] });
const callXrayRollback = rpc.declare({ object: 'luci.xvpn', method: 'xray_rollback' });

// the defaults of util.uc load_config(); an empty field means the default
const DEFAULTS = {
	xray_bin: '/usr/bin/xray', loglevel: 'warning',
	tproxy_port: 12345, dns_port: 10853, api_port: 10085, control_port: 10086, test_port_base: 20000,
	client_mark: '0x01000000', tproxy_mark: '0x02000000', route_table: 100,
	url: 'https://www.gstatic.com/generate_204', url2: 'https://cp.cloudflare.com/generate_204',
	dl_url: 'https://speed.cloudflare.com/__down?bytes=65536', interval: 30, timeout: 5, fail_threshold: 3,
	rank_interval: 600, hysteresis: 150, quarantine: 300, concurrency: 4,
	auto_mode: 'ping', speed_hysteresis: 20, speedtest_url: 'https://proof.ovh.net/files/10Mb.dat', speedtest_interval: 21600,
};

const PORTS = [ 'tproxy_port', 'dns_port', 'api_port', 'control_port' ];
const MARKS = [ 'client_mark', 'tproxy_mark' ];

// load_config() reads numbers with hex() after 0x, else with int(), which also takes "12abc":
// the UI takes the same decimal and hex numbers, but only whole ones
function number(v) {
	v = String(v ?? '').trim();
	return /^0x[0-9a-f]+$/i.test(v) ? parseInt(v, 16) : /^\d+$/.test(v) ? parseInt(v, 10) : NaN;
}

function integer(min, max) {
	return (sid, v) => {
		if (v == null || v === '')
			return true;
		const n = number(v);
		if (isNaN(n) || n < min || n > max)
			return _('Enter a whole number from %d to %d').format(min, max);
		return true;
	};
}

// 26.10.31 or v26.10.31 against 25.1.30: < 0 older, 0 the same, > 0 newer (xraycore.uc compare())
function compareXray(a, b) {
	const pa = String(a ?? '').replace(/^v/, '').replace(/-.*/, '').split('.');
	const pb = String(b ?? '').replace(/^v/, '').replace(/-.*/, '').split('.');
	for (let i = 0; i < 3; i++) {
		const d = (parseInt(pa[i], 10) || 0) - (parseInt(pb[i], 10) || 0);
		if (d)
			return d;
	}
	return 0;
}

// #31: xray-core of a GitHub release beside the one of the package. The router downloads it
// and restarts the service (luci.xvpn xray_install), the job is polled until it is over
function xrayCore() {
	const box = E('div', {});
	let latest = null, checking = false, timer = null;
	const steps = {
		start: _('starting'), download: _('downloading'), check: _('checking the digest'),
		unpack: _('unpacking'), test: _('testing the binary'), restart: _('restarting the service'),
	};

	const running = (x) => x?.job?.state == 'running';
	const version = (x) => (x.source == 'github') ? x.github?.version : (x.source == 'feed') ? x.feed?.version : null;

	const install = (x, tag) => ui.showModal(_('Install xray %s').format(tag), [
		E('p', {}, _('The router downloads xray %s for %s from github.com/XTLS/Xray-core, checks its SHA-256 and restarts the VPN with it: the clients lose their connections for a moment. Servers that this xray rejects are dropped (the reason is in the log); if xray does not start at all, the previous one comes back.').format(tag, x.arch)),
		E('div', { 'class': 'right' }, [
			E('button', { 'class': 'cbi-button', 'click': ui.hideModal }, _('Cancel')), ' ',
			E('button', { 'class': 'cbi-button cbi-button-positive', 'click': () => {
				ui.hideModal();
				callXrayInstall(tag).then((r) => r?.ok ? refresh() : ui.addNotification(null, E('p', {}, _('Install failed: %s').format(r?.error ?? '?')), 'error'));
			} }, _('Install')),
		]),
	]);

	const rollback = () => callXrayRollback().then((r) => {
		if (!r?.ok)
			ui.addNotification(null, E('p', {}, _('Failed: %s').format(r?.error ?? '?')), 'error');
		refresh();
	});

	const check = (x) => {
		checking = true;
		draw(x);
		callXrayLatest().then((r) => { latest = r; }, (e) => { latest = { error: e.message }; })
			.finally(() => { checking = false; refresh(); });
	};

	const draw = (x) => {
		if (!x) {
			box.replaceChildren(E('em', {}, _('No answer from the router (the package may be older than this page).')));
			return;
		}
		const rows = [];
		const v = version(x);
		if (x.source == 'github')
			rows.push(E('p', {}, _('In use: xray %s from GitHub, installed %s.').format(x.github?.version ?? '?', x.github?.installed ? new Date(x.github.installed * 1000).toLocaleString() : '?')));
		else if (x.source == 'feed')
			rows.push(E('p', {}, _('In use: xray %s of the package xray-core.').format(x.feed?.version ?? '?')));
		else
			rows.push(E('p', {}, _('In use: %s (set by hand).').format(x.bin)));

		const j = x.job;
		if (running(x))
			rows.push(E('p', {}, [ E('span', { 'class': 'spinning' }, _('Installing xray %s: %s…').format(j.tag, steps[j.step] ?? j.step ?? '')) ]));
		else if (j?.state == 'failed')
			rows.push(E('p', { 'style': 'color:var(--error-color-medium, #c00)' }, _('Install of xray %s failed: %s').format(j.tag, j.error)));
		else if (j?.state == 'lost')
			rows.push(E('p', { 'style': 'color:var(--error-color-medium, #c00)' }, _('Install of xray %s stopped halfway.').format(j.tag)));
		else if (j?.state == 'done' && j.servers && j.servers.after < j.servers.before)
			rows.push(E('p', {}, _('xray %s rejects %d of %d servers, see the log.').format(j.tag, j.servers.before - j.servers.after, j.servers.before)));

		if (!x.asset)
			rows.push(E('p', {}, E('em', {}, _('XTLS publishes no xray for this router (%s).').format(x.arch ?? '?'))));
		else if (latest?.error)
			rows.push(E('p', { 'style': 'color:var(--error-color-medium, #c00)' }, _('Cannot check GitHub: %s').format(latest.error)));
		else if (latest?.tag) {
			const cmp = compareXray(latest.tag, v);
			rows.push(E('p', {}, (cmp > 0) ? _('Latest release: %s, newer.').format(latest.tag)
				: (cmp == 0) ? _('Latest release: %s, the one in use.').format(latest.tag) : _('Latest release: %s, older than the one in use.').format(latest.tag)));
		}

		const busy = running(x) || checking;
		const buttons = [];
		if (x.asset)
			buttons.push(E('button', { 'class': 'cbi-button', 'disabled': busy ? '' : null, 'click': () => check(x) },
				checking ? _('Checking…') : _('Check for updates')));
		if (x.asset && latest?.tag && !(x.source == 'github' && compareXray(latest.tag, v) == 0))
			buttons.push(' ', E('button', { 'class': 'cbi-button cbi-button-positive', 'disabled': busy ? '' : null, 'click': () => install(x, latest.tag) },
				_('Install %s').format(latest.tag)));
		if (x.source == 'github' && x.feed)
			buttons.push(' ', E('button', { 'class': 'cbi-button cbi-button-negative', 'disabled': busy ? '' : null, 'click': rollback },
				_('Back to xray %s of the package').format(x.feed.version ?? '')));
		rows.push(E('div', {}, buttons));
		box.replaceChildren(...rows);

		clearTimeout(timer);
		if (running(x))
			timer = setTimeout(refresh, 2000);
	};

	const refresh = () => L.resolveDefault(callXray(), null).then(draw);
	refresh();
	return box;
}

return view.extend({
	load() {
		return Promise.all([
			L.resolveDefault(callServers(), {}),
			uci.load('xvpn'),
		]);
	},

	// the value of an option as the backend will see it: the field, else the default
	value(section, sid, name) {
		const v = section.formvalue(sid, name);
		return (v == null || v === '') ? DEFAULTS[name] : v;
	},

	render([ servers ]) {
		// every server takes a port from test_port_base up
		const count = Math.max(1, servers?.servers?.length ?? 0);

		for (let [ name, type ] of [ [ 'main', 'general' ], [ 'health', 'health' ] ])
			if (!uci.get('xvpn', name))
				uci.add('xvpn', type, name);

		const m = new form.Map('xvpn', _('XVPN: settings'),
			_('Empty fields use the defaults. Changes take effect after "Save & Apply": the service is reloaded, and if the config of xray changed, xray restarts and the VPN clients lose their connections for a moment.'));

		const h = m.section(form.NamedSection, 'health', 'health', _('Health checks'),
			_('The active server is checked by an HTTP request through it. After several failures in a row the best working server is chosen.'));
		h.addremove = false;
		let s = h;

		let o = s.option(form.Value, 'url', _('Check URL'),
			_('Any fast URL that answers with HTTP 2xx or 3xx. The time to the first byte is the ping of the server.'));
		o.placeholder = DEFAULTS.url;
		o.value('https://www.gstatic.com/generate_204');
		o.value('https://cp.cloudflare.com/generate_204');
		o.value('http://www.msftconnecttest.com/connecttest.txt');
		o.validate = (sid, v) => !v || /^https?:\/\/[^\s/?#]+\S*$/i.test(v.trim()) || _('Enter an http:// or https:// URL');
		o.write = (sid, v) => uci.set('xvpn', sid, 'url', v.trim());

		// #61: servers that let through only the sites on their whitelist answer the first URL
		o = s.option(form.Value, 'url2', _('Second check URL'),
			_('Opened through every server that answers the check URL when all servers are tested and a server is chosen. A server that fails it is marked limited and is not chosen automatically while there are others; you can still choose it by hand. Use a URL by domain on another CDN than the check URL. "off" turns this check off.'));
		o.placeholder = DEFAULTS.url2;
		o.value('https://cp.cloudflare.com/generate_204');
		o.value('off', _('off'));
		// the same URL as the first one would turn the check off without a word
		o.validate = (sid, v) => {
			v = (v ?? '').trim();
			if (v && v != 'off' && !/^https?:\/\/[^\s/?#]+\S*$/i.test(v))
				return _('Enter an http:// or https:// URL or "off"');
			if ((v || DEFAULTS.url2) == String(this.value(h, sid, 'url')).trim())
				return _('Use another URL than the check URL, preferably on another CDN');
			return true;
		};
		o.write = (sid, v) => uci.set('xvpn', sid, 'url2', v.trim());

		// #11: DPI may let the handshake through and freeze the stream after the first KB
		o = s.option(form.Value, 'dl_url', _('Download check URL'),
			_('Downloaded through the active server every 5 minutes: a download that stalls or does not finish in 15 s counts as a failed check, like a server that does not answer. Use a file of 64–128 KB. "off" turns this check off.'));
		o.placeholder = DEFAULTS.dl_url;
		o.value('off', _('off'));
		o.validate = (sid, v) => {
			v = (v ?? '').trim();
			return !v || v == 'off' || /^https?:\/\/[^\s/?#]+\S*$/i.test(v) || _('Enter an http:// or https:// URL or "off"');
		};
		o.write = (sid, v) => uci.set('xvpn', sid, 'dl_url', v.trim());

		o = s.option(form.Value, 'interval', _('Check interval, s'),
			_('How often the active server is checked.'));
		o.placeholder = DEFAULTS.interval;
		const shorter = (sid) => (number(this.value(h, sid, 'timeout')) < number(this.value(h, sid, 'interval')))
			|| _('The timeout must be shorter than the check interval');
		o.validate = (sid, v) => {
			const r = integer(5, 3600)(sid, v);
			return (r !== true) ? r : shorter(sid);
		};

		o = s.option(form.Value, 'timeout', _('Timeout, s'),
			_('Time limit of one check.'));
		o.placeholder = DEFAULTS.timeout;
		o.validate = (sid, v) => {
			const r = integer(1, 60)(sid, v);
			return (r !== true) ? r : shorter(sid);
		};

		o = s.option(form.Value, 'fail_threshold', _('Failures before switching'),
			_('Failed checks in a row after which the server is switched.'));
		o.placeholder = DEFAULTS.fail_threshold;
		o.validate = integer(1, 100);

		o = s.option(form.Value, 'rank_interval', _('Test all servers every, s'),
			_('Background test of all servers: their pings in the status tab and the choice of the next server.'));
		o.placeholder = DEFAULTS.rank_interval;
		o.validate = integer(60, 86400);

		o = s.option(form.Value, 'quarantine', _('Quarantine, s'),
			_('A server that failed is not chosen again for this time.'));
		o.placeholder = DEFAULTS.quarantine;
		o.validate = integer(0, 86400);

		o = s.option(form.Value, 'concurrency', _('Parallel tests'),
			_('How many servers are tested at the same time.'));
		o.placeholder = DEFAULTS.concurrency;
		o.validate = integer(1, 8);

		// #95: the server with the best ping may be the slowest one for video and downloads
		o = s.option(form.ListValue, 'auto_mode', _('Server choice'),
			_('What the server is chosen by at start, on failover and when switching to a faster one. Download speed is measured through every live server (about 10 MB each) every few hours; until then the ping decides.'));
		o.value('ping', _('By ping'));
		o.value('speed', _('By download speed'));
		o.value('balanced', _('By ping and speed'));
		o.default = DEFAULTS.auto_mode;

		o = s.option(form.Value, 'speedtest_url', _('Speed test URL'),
			_('A large file (10 MB or more) downloaded through each server for its speed, at most 10 s a server. "off" turns the speed test off.'));
		o.placeholder = DEFAULTS.speedtest_url;
		o.value('https://proof.ovh.net/files/10Mb.dat');
		o.value('off', _('off'));
		o.validate = (sid, v) => {
			v = (v ?? '').trim();
			return !v || v == 'off' || /^https?:\/\/[^\s/?#]+\S*$/i.test(v) || _('Enter an http:// or https:// URL or "off"');
		};
		o.write = (sid, v) => uci.set('xvpn', sid, 'speedtest_url', v.trim());

		o = s.option(form.Value, 'speedtest_interval', _('Speed test every, s'),
			_('With ten servers one run downloads about 100 MB: mind the traffic limit of the subscription.'));
		o.placeholder = DEFAULTS.speedtest_interval;
		o.validate = integer(1800, 604800);
		o.depends('auto_mode', 'speed');
		o.depends('auto_mode', 'balanced');
		o.retain = true;

		o = s.option(form.Flag, 'auto_best', _('Switch to a faster server'),
			_('Off: the server is switched only when it fails. On: also when the background test finds a server that is faster by the hysteresis below.'));
		o.default = '0';
		o.rmempty = false;

		o = s.option(form.Value, 'hysteresis', _('Hysteresis, ms'),
			_('How much faster another server must be to switch to it.'));
		o.placeholder = DEFAULTS.hysteresis;
		o.validate = integer(0, 10000);
		o.depends('auto_best', '1');
		// the value stays in the config while the option is hidden
		o.retain = true;

		o = s.option(form.Value, 'speed_hysteresis', _('Speed hysteresis, %'),
			_('By download speed or by ping and speed: how much better another server must be to switch to it.'));
		o.placeholder = DEFAULTS.speed_hysteresis;
		o.validate = integer(0, 1000);
		o.depends({ auto_best: '1', auto_mode: 'speed' });
		o.depends({ auto_best: '1', auto_mode: 'balanced' });
		o.retain = true;

		s = m.section(form.NamedSection, 'main', 'general', _('xray'));
		s.addremove = false;

		o = s.option(form.DummyValue, '_xray_core', _('xray-core'),
			_('A newer xray from the GitHub releases of XTLS, beside the one of the package, which stays for the way back. It takes about 35 MB of flash.'));
		o.renderWidget = () => xrayCore();

		o = s.option(form.Value, 'xray_bin', _('Path to xray'),
			_('The xray-core binary: the one of the package is /usr/bin/xray, a GitHub release (above) goes to /usr/lib/xvpn/xray.'));
		o.placeholder = DEFAULTS.xray_bin;
		// the same as valid_bin() in util.uc: the service runs it as root
		o.validate = (sid, v) => !v || /^(\/[A-Za-z0-9_][A-Za-z0-9._-]*)*\/xray[A-Za-z0-9._-]*$/.test(v.trim())
			|| _('Enter an absolute path to a binary whose name starts with xray');
		o.write = (sid, v) => uci.set('xvpn', sid, 'xray_bin', v.trim());

		o = s.option(form.ListValue, 'loglevel', _('Log level of xray'),
			_('Messages of xray go to the system log (the Log tab).'));
		o.value('debug', _('Debug'));
		o.value('info', _('Info'));
		o.value('warning', _('Warning'));
		o.value('error', _('Error'));
		o.value('none', _('None'));
		o.default = DEFAULTS.loglevel;

		o = s.option(form.Flag, 'sniffing', _('Sniffing'),
			_('xray takes the domain from HTTP, TLS and QUIC and sends it to the server instead of the IP: many servers do not let clients connect to bare IP addresses.'));
		o.default = '1';
		o.rmempty = false;

		o = s.option(form.Flag, 'block_bittorrent', _('Block BitTorrent'),
			_('BitTorrent connections of the clients are dropped: a torrent client opens thousands of sessions, which may run the router out of memory.'));
		o.default = '0';

		const adv = s = m.section(form.NamedSection, 'main', 'general', _('Advanced'),
			_('Change only on a conflict with other services of the router.'));
		s.addremove = false;

		const portNames = {
			tproxy_port: _('TPROXY port'), dns_port: _('DNS port'), api_port: _('API port'), control_port: _('Control port'),
		};
		const port = (name) => (sid, v) => {
			// below 1024 the rules would drop the port for everyone but the VPN clients (util.uc port())
			const r = integer(1024, 65535)(sid, v);
			if (r !== true)
				return r;
			const p = number(this.value(adv, sid, name)), base = number(this.value(adv, sid, 'test_port_base'));
			for (let other of PORTS)
				if (other != name && number(this.value(adv, sid, other)) == p)
					return _('The same port as "%s"').format(portNames[other]);
			if (p >= base && p < base + count)
				return _('The port is in the range of the test ports %d–%d').format(base, base + count - 1);
			return true;
		};

		for (let name of PORTS) {
			o = s.option(form.Value, name, portNames[name], {
				tproxy_port: _('xray takes the traffic of the VPN clients on this port.'),
				dns_port: _('xray takes the intercepted DNS queries on this port.'),
				api_port: _('xray traffic statistics (metrics over HTTP), on 127.0.0.1.'),
				control_port: _('On 127.0.0.1: the xray API over TCP, to switch servers without a restart, and the UDP check over UDP.'),
			}[name]);
			o.placeholder = DEFAULTS[name];
			o.validate = port(name);
		}

		o = s.option(form.Value, 'test_port_base', _('First test port'),
			_('Every server gets a local SOCKS port on 127.0.0.1 for its health checks: this port and the following ones, %d now.').format(count));
		o.placeholder = DEFAULTS.test_port_base;
		o.validate = (sid, v) => {
			const r = integer(1024, 65535)(sid, v);
			if (r !== true)
				return r;
			const base = number(this.value(adv, sid, 'test_port_base'));
			if (base + count - 1 > 65535)
				return _('%d servers need ports up to %d').format(count, base + count - 1);
			return true;
		};

		const markNames = { client_mark: _('Client mark'), tproxy_mark: _('TPROXY mark') };
		for (let name of MARKS) {
			o = s.option(form.Value, name, markNames[name], {
				client_mark: _('Firewall mark (hex) of the traffic of the VPN clients. It must not share bits with the marks of mwan3 (0x3f00) and pbr (0x00ff0000).'),
				tproxy_mark: _('Firewall mark (hex) of the traffic going to xray; an ip rule sends it to the routing table below.'),
			}[name]);
			o.placeholder = DEFAULTS[name];
			o.validate = (sid, v) => {
				if (!v)
					return true;
				const n = number(v);
				if (isNaN(n) || n < 1 || n > 0xffffffff)
					return _('Enter a number from 0x1 to 0xffffffff (hex) or from 1 to 4294967295');
				const other = MARKS.find((n) => n != name);
				if (number(this.value(adv, sid, name)) & number(this.value(adv, sid, other)))
					return _('Shares bits with "%s"').format(markNames[other]);
				return true;
			};
		}

		o = s.option(form.Value, 'route_table', _('Routing table'),
			_('Number of the routing table for the TPROXY mark: it must not be used by anything else.'));
		o.placeholder = DEFAULTS.route_table;
		o.validate = (sid, v) => {
			const r = integer(1, 2147483647)(sid, v);
			if (r !== true)
				return r;
			if (number(v) >= 253 && number(v) <= 255)
				return _('Tables 253–255 are default, main and local');
			return true;
		};

		return m.render();
	},
});
