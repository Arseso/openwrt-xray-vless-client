// SPDX-License-Identifier: MIT
// Settings tab: health checks and server choice, xray, ports, marks and the routing table.
// The service options used by the tests (health.reload_idle, reload_retry, generate_budget) are not shown.
'use strict';
'require view';
'require form';
'require rpc';
'require uci';

const callServers = rpc.declare({ object: 'luci.xvpn', method: 'servers' });

// the defaults of util.uc load_config(); an empty field means the default
const DEFAULTS = {
	xray_bin: '/usr/bin/xray', loglevel: 'warning',
	tproxy_port: 12345, dns_port: 10853, api_port: 10085, test_port_base: 20000,
	client_mark: '0x01000000', tproxy_mark: '0x02000000', route_table: 100,
	url: 'https://www.gstatic.com/generate_204', url2: 'https://cp.cloudflare.com/generate_204', interval: 30, timeout: 5, fail_threshold: 3,
	rank_interval: 600, hysteresis: 150, quarantine: 300, concurrency: 4,
};

const PORTS = [ 'tproxy_port', 'dns_port', 'api_port' ];
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

		s = m.section(form.NamedSection, 'main', 'general', _('xray'));
		s.addremove = false;

		o = s.option(form.Value, 'xray_bin', _('Path to xray'),
			_('The xray-core binary (25.x).'));
		o.placeholder = DEFAULTS.xray_bin;
		o.validate = (sid, v) => !v || /^\/\S+$/.test(v.trim()) || _('Enter an absolute path');
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
			tproxy_port: _('TPROXY port'), dns_port: _('DNS port'), api_port: _('API port'),
		};
		const port = (name) => (sid, v) => {
			const r = integer(1, 65535)(sid, v);
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
