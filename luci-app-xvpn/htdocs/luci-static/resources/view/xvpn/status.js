// SPDX-License-Identifier: MIT
// Status tab: daemon state, active server, subscriptions, servers and service actions.
'use strict';
'require view';
'require rpc';
'require poll';
'require ui';
'require dom';

// luci.xvpn stats reads xray's metrics over loopback HTTP (no xray process); a hung xray
// holds rpcd for the 1 s timeout until the daemon sees xray_down: once in this many seconds
const STATS_EVERY = 10;

const callStatus = rpc.declare({ object: 'luci.xvpn', method: 'status' });
const callTest = rpc.declare({ object: 'luci.xvpn', method: 'test' });
const callSelect = rpc.declare({ object: 'luci.xvpn', method: 'select', params: [ 'id' ] });
const callSetAuto = rpc.declare({ object: 'luci.xvpn', method: 'set_auto', params: [ 'id', 'auto' ] });
const callServers = rpc.declare({ object: 'luci.xvpn', method: 'servers' });
const callSubscriptions = rpc.declare({ object: 'luci.xvpn', method: 'subscriptions', params: [ 'updating' ] });
const callStats = rpc.declare({ object: 'luci.xvpn', method: 'stats' });
const callFirewall = rpc.declare({ object: 'luci.xvpn', method: 'firewall' });
const callUpdate = rpc.declare({ object: 'luci.xvpn', method: 'update' });
const callService = rpc.declare({ object: 'luci.xvpn', method: 'service', params: [ 'action' ] });

// what a firewall error means for the clients depends on the mode that got applied
function fwErrorText(mode) {
	return {
		block: _('Firewall error: VPN clients are blocked'),
		minimal: _('Firewall error: VPN clients are blocked'),
		passthrough: _('Firewall error: VPN clients go to the internet directly'),
	}[mode] ?? _('Firewall error');
}

// [ label class, text ]; a state missing here is shown as is
function stateInfo(state, fwMode) {
	return {
		starting: [ 'notice', _('Starting') ],
		waiting_time: [ 'notice', _('Waiting for NTP time sync') ],
		connected: [ 'success', _('Connected') ],
		degraded: [ 'warning', _('Unstable: health checks fail') ],
		failover: [ 'warning', _('Switching to another server') ],
		wan_down: [ 'warning', _('No internet on WAN') ],
		no_servers: [ 'error', _('No live servers') ],
		testing: [ 'notice', _('Testing servers') ],
		error: [ 'error', fwErrorText(fwMode) ],
		xray_down: [ 'error', _('xray is not running') ],
	}[state] ?? [ 'notice', state ];
}

function fwModeText(mode) {
	return {
		full: _('Full: VPN clients go through the tunnel'),
		passthrough: _('Passthrough: VPN clients go directly'),
		block: _('Block: VPN clients have no internet'),
		minimal: _('Minimal block: bridge rules were not applied'),
	}[mode] ?? mode;
}

function errorText(err) {
	return {
		'busy': _('Busy, try again later'),
		'not running': _('The daemon is not running'),
		'timeout': _('The daemon did not answer in time, the request may still be carried out'),
		'unknown server': _('The server is no longer in the list, reload the page'),
		'xvpn has uncommitted changes': _('/etc/config/xvpn has uncommitted changes (uci set without uci commit)'),
	}[err] ?? err ?? _('unknown error');
}

// server names, subscription titles and errors come from outside: text nodes only
function txt(s) {
	return document.createTextNode(s ?? '');
}

// fw_error and fw_warn may hold several lines
function lines(s, style) {
	return E('span', { 'style': 'white-space:pre-line' + (style ? ';' + style : '') }, [ txt(s) ]);
}

// themes have no red label (.important is the primary color in bootstrap): 'error' is inline
function label(cls, text) {
	if (cls == 'error')
		return E('span', { 'class': 'label', 'style': 'background-color:var(--error-color-high, #c00);color:#fff' }, [ txt(text) ]);
	return E('span', { 'class': 'label ' + cls }, [ txt(text) ]);
}

// a server that fails health.url2 (#61)
function limited(url2) {
	const l = label('warning', _('limited'));
	l.title = _('%s does not open through this server: it may let through only some sites. It is not chosen automatically while there are other servers.').format(url2 ?? _('The second check URL'));
	return l;
}

// two largest units: '%t' prints "0h 0m 6s"
function dur(sec) {
	sec = Math.max(0, Math.floor(sec));
	const d = Math.floor(sec / 86400), h = Math.floor(sec / 3600) % 24, m = Math.floor(sec / 60) % 60, s = sec % 60;
	if (d)
		return _('%dd %dh').format(d, h);
	if (h)
		return _('%dh %dm').format(h, m);
	if (m)
		return _('%dm %ds').format(m, s);
	return _('%ds').format(s);
}

function bytes(n) {
	return '%1024.2mB'.format(n ?? 0);
}

function ago(now, at) {
	return at ? _('%s ago').format(dur(now - at)) : _('never');
}

function notify(msg, type) {
	if (ui.addTimeLimitedNotification)
		ui.addTimeLimitedNotification(null, E('p', {}, [ txt(msg) ]), 5000, type);
	else
		ui.addNotification(null, E('p', {}, [ txt(msg) ]), type);
}

function table(titles, rows, empty) {
	return E('table', { 'class': 'table' }, [
		E('tr', { 'class': 'tr table-titles' }, titles.map((t) => E('th', { 'class': 'th' }, t))),
		...(rows.length ? rows : [
			E('tr', { 'class': 'tr placeholder' }, E('td', { 'class': 'td' }, E('em', {}, empty)))
		])
	]);
}

function row(titles, cells, cls) {
	return E('tr', { 'class': 'tr' + (cls ? ' ' + cls : '') },
		cells.map((c, i) => E('td', { 'class': 'td', 'data-title': titles[i] }, Array.isArray(c) ? c : [ c ])));
}

// gRPC carries every connection of the tunnel in one HTTP/2 connection, so one CPU
// core does all of it: about 130 Mbit/s on a dual-core Cortex-A53 router (issue #68)
function protoCell(s) {
	const cell = [ txt(s.proto) ];
	if (s.transport)
		cell.push(E('br'), E('small', s.transport.startsWith('grpc') ? {
			'title': _('gRPC sends all connections through one connection that one CPU core handles: on a weak router it is slower than TCP (e.g. tcp+reality+vision)')
		} : {}, [ txt(s.transport) ]));
	return cell;
}

function info(rows) {
	return E('table', { 'class': 'table' }, rows.filter((r) => r).map((r) => E('tr', { 'class': 'tr' }, [
		E('td', { 'class': 'td left', 'width': '33%' }, r[0]),
		E('td', { 'class': 'td left' }, Array.isArray(r[1]) ? r[1] : [ r[1] ]),
	])));
}

return view.extend({
	handleSaveApply: null,
	handleSave: null,
	handleReset: null,

	load() {
		// running: false when the daemon is not on ubus; enabled and the router time come with it
		return L.resolveDefault(callStatus(), {}).then((status) => {
			const up = (status.running === true);
			// with xray down the query would wait for its timeout and hold rpcd
			const due = up && status.enabled && status.state != 'xray_down' && !(status.time - this.statsAt < STATS_EVERY);
			if (due)
				this.statsAt = status.time;
			return Promise.all([
				status,
				// the daemon has the list already
				up ? {} : L.resolveDefault(callServers(), {}),
				// updating comes from status
				L.resolveDefault(callSubscriptions(false), {}),
				due ? L.resolveDefault(callStats(), null) : null,
				L.resolveDefault(callFirewall(), {}),
			]);
		});
	},

	// an action and the poll may load at once: only the latest result is drawn
	refresh() {
		const seq = ++this.seq;
		return this.load().then((data) => (seq == this.seq) ? this.update(data) : null);
	},

	confirm(key, action) {
		const [ title, text, ok ] = action.confirm;
		ui.showModal(title, [
			E('p', {}, text),
			E('div', { 'class': 'right' }, [
				E('button', { 'class': 'cbi-button', 'click': ui.hideModal }, _('Cancel')),
				' ',
				E('button', {
					'class': 'cbi-button cbi-button-negative',
					'click': () => { ui.hideModal(); this.run(key, action); },
				}, ok),
			]),
		]);
	},

	// runs the action of a button, keeps it spinning until the call returns
	run(key, action) {
		const btn = this.buttons[key], { fn, done } = action;
		this.busy[key] = true;
		btn.classList.add('spinning');
		btn.disabled = true;
		return this.call(key, fn, done);
	},

	// the call of a button or a checkbox: its errors are shown, the page is redrawn after it
	call(key, fn, done) {
		return Promise.resolve().then(fn).then((res) => {
			if (typeof(res) == 'number' && res != 0)
				notify(_('Request failed: %s').format(rpc.getStatusText(res)), 'error');
			else if (res?.ok === false)
				notify(_('Request failed: %s').format(errorText(res.error)), 'error');
			else if (done)
				notify(done, 'info');
		}).catch((e) => notify(e.message, 'error')).finally(() => {
			delete this.busy[key];
			return this.refresh();
		});
	},

	// kept across redraws like the buttons; while its call runs it shows what was clicked
	checkbox(key, checked, disabled, title, fn) {
		const busy = !!this.busy[key];
		this.used[key] = true;
		const box = this.buttons[key] ??= E('input', { 'type': 'checkbox', 'change': () => {
			this.busy[key] = true;
			box.disabled = true;
			return this.call(key, () => box.xvpnAction(box.checked));
		} });
		if (!busy)
			box.checked = !!checked;
		box.disabled = !!(disabled || busy);
		box.title = title;
		box.xvpnAction = fn;
		return box;
	},

	// the page is redrawn on every poll: buttons are kept, so a click in progress is not lost
	// confirm: [ title, text, button ] of a dialog before the action
	button(key, cls, text, disabled, fn, done, confirm) {
		const busy = !!this.busy[key];
		this.used[key] = true;
		const btn = this.buttons[key] ??= E('button', { 'click': () => {
			const action = btn.xvpnAction;
			return action.confirm ? this.confirm(key, action) : this.run(key, action);
		} });
		btn.className = 'cbi-button ' + cls + (busy ? ' spinning' : '');
		btn.disabled = !!(disabled || busy);
		btn.textContent = text;
		btn.xvpnAction = { fn, done, confirm };
		return btn;
	},

	// sums the traffic of a stats sample, the speed is the average since the previous one
	takeStats(sample) {
		let down = 0, up = 0;
		for (let id in sample.traffic ?? {}) {
			down += sample.traffic[id].down ?? 0;
			up += sample.traffic[id].up ?? 0;
		}
		const prev = this.stats;
		// counters restart with xray: no speed until the next sample
		const speed = (prev && sample.time > prev.time && down >= prev.down && up >= prev.up)
			? [ (down - prev.down) / (sample.time - prev.time), (up - prev.up) / (sample.time - prev.time) ] : null;
		this.stats = { time: sample.time, traffic: sample.traffic ?? {}, down, up, speed };
	},

	update([ status, servers, subs, sample, fw ]) {
		const up = (status.running === true);
		// the daemon is on ubus but did not answer in 2 s
		const hung = !up && (status.timeout === true);
		const enabled = (status.enabled === true);
		const now = status.time ?? Math.floor(Date.now() / 1000);
		const list = (up ? status.servers : servers.servers) ?? [];
		const activeId = up ? status.active : servers.active;
		const byId = {};
		const fwError = (fw.error ?? '').trim();
		const fwWant = (fw.want ?? '').trim(), fwMode = (fw.mode ?? '').trim(), fwWarn = (fw.warning ?? '').trim();
		const updating = up && !!status.updating;

		if (!up || !enabled)
			this.stats = this.statsAt = null;
		else if (sample?.time)
			this.takeStats(sample);
		const stats = this.stats, traffic = stats?.traffic ?? {};

		// redrawing would drop a text selection: wait for the next poll
		const sel = window.getSelection();
		if (sel && !sel.isCollapsed && this.root.contains(sel.anchorNode))
			return;

		this.used = {};
		for (let s of list)
			byId[s.id] = s;
		const active = byId[activeId];
		const name = (id) => byId[id]?.name ?? id ?? '?';

		const alerts = [];
		if (!enabled)
			alerts.push(E('div', { 'class': 'alert-message notice' },
				_('The service is disabled: VPN clients are not routed through xray.')));
		else if (hung)
			alerts.push(E('div', { 'class': 'alert-message warning' },
				_('The xvpnd daemon does not answer: it is busy or hung. If this message stays, restart the service.')));
		else if (!up)
			alerts.push(E('div', { 'class': 'alert-message warning' },
				_('The xvpnd daemon is not running. It is restarted by procd within seconds; if this message stays, check the log.')));
		if (fwError)
			alerts.push(E('div', { 'class': 'alert-message error' }, [
				E('strong', {}, {
					block: _('Firewall rules are not applied, VPN clients are blocked:'),
					minimal: _('Firewall rules are not applied, VPN clients are blocked:'),
					passthrough: _('Firewall rules are not applied, VPN clients go to the internet directly:'),
				}[fwMode] ?? _('Firewall rules are not applied:')), ' ', lines(fwError),
			]));
		if (fwWarn)
			alerts.push(E('div', { 'class': 'alert-message warning' }, [ lines(fwWarn) ]));
		if (up && status.passthrough)
			alerts.push(E('div', { 'class': 'alert-message warning' },
				_('Kill switch is off and there are no live servers: VPN clients go to the internet directly.')));

		const actions = E('div', { 'class': 'cbi-section-actions', 'style': 'margin-bottom:1em' }, [
			this.button('test', 'cbi-button-action', _('Test all'), !up || status.testing,
				() => callTest(), _('Testing all servers…')),
			' ',
			this.button('update', 'cbi-button-action', _('Update subscriptions'), updating,
				() => callUpdate(), _('Updating subscriptions…')),
			' ',
			enabled ? this.button('restart', 'cbi-button-reload', _('Restart'), false,
				() => callService('restart'), _('Restarting the service…'), [
					_('Restart XVPN'),
					_('xray and the daemon restart: VPN clients lose their connections for a few seconds.'),
					_('Restart'),
				]) : '',
			enabled ? ' ' : '',
			enabled
				? this.button('service', 'cbi-button-negative', _('Disable'), false,
					() => callService('stop'), _('Stopping the service…'), [
						_('Disable XVPN'),
						_('The tunnel is stopped and its rules are removed: VPN clients go to the internet directly until the service is enabled again.'),
						_('Disable'),
					])
				: this.button('service', 'cbi-button-positive', _('Enable'), false,
					() => callService('start'), _('Starting the service…')),
		]);

		let state;
		if (up) {
			const [ cls, text ] = stateInfo(status.state, fwMode);
			state = [ label(cls, text) ];
			if (status.testing && status.state != 'testing')
				state.push(' ', label('notice', _('testing servers')));
			if (updating)
				state.push(' ', label('notice', _('updating subscriptions')));
		}

		const sw = up ? status.last_switch : null;
		const lat = active?.latency;
		const sinceTitle = (up && status.state == 'connected') ? _('Connected for') : _('Active for');
		const fwText = fwMode
			? fwModeText(fwMode) + ((fwWant && fwWant != fwMode) ? ' ' + _('(requested: %s)').format(fwWant) : '')
			: _('not applied');

		const statusSection = E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, _('Status')),
			actions,
			info([
				[ _('Service'), enabled ? (up ? _('Enabled, running') : hung ? _('Enabled, daemon not answering')
					: _('Enabled, daemon not running')) : _('Disabled') ],
				up ? [ _('State'), state ] : null,
				[ _('Active server'), active
					? [ E('strong', {}, [ txt(active.name) ]), txt(' (' + [ active.proto, active.transport, active.sub_name ].filter((x) => x).join(', ') + ')') ]
					: (activeId ? txt(activeId) : E('em', {}, _('none'))) ],
				(up && active) ? [ _('Latency'), (lat == null) ? '—' : (lat < 0)
					? [ label('error', _('failed')), ' ', txt(ago(now, active.tested)) ]
					: [ txt(_('%d ms').format(lat) + ', ' + ago(now, active.tested)), ...((active.limited && lat >= 0) ? [ ' ', limited(status.url2) ] : []) ] ] : null,
				// #10: names resolve over DoH, but QUIC, calls and games of the clients need UDP
				(up && active && status.udp === false) ? [ _('UDP'), [ label('warning', _('does not pass')), ' ',
					txt(_('UDP does not pass through this server: QUIC, voice calls and games of the clients may not work.')) ] ] : null,
				(up && active && status.since) ? [ sinceTitle, txt(dur(now - status.since)) ] : null,
				(up && status.fails > 0) ? [ _('Failed checks in a row'), txt(String(status.fails)) ] : null,
				sw ? [ _('Last switch'), txt(
					((sw.from && sw.from != sw.to) ? name(sw.from) + ' → ' : '') + name(sw.to) + ': ' + (sw.reason ?? '') + ', ' + ago(now, sw.at)) ] : null,
				(up && status.last_test) ? [ _('Last test of all servers'), txt(ago(now, status.last_test)) ] : null,
				// no live servers: the daemon tests all of them again after a pause, longer each time
				(up && status.retry) ? [ _('Next test of all servers'), txt(((status.retry.at <= now) ? _('due')
					: _('in %s').format(dur(status.retry.at - now))) + ' ' + _('(pause %s)').format(dur(status.retry.delay))) ] : null,
				(up && status.last_error && status.last_error.trim() != fwError)
					? [ _('Last error'), lines(status.last_error, 'color:var(--error-color-high, #c00)') ] : null,
				[ _('Firewall rules'), txt(fwText) ],
				stats ? [ _('Traffic through xray'), txt('↓ ' + bytes(stats.down) + '  ↑ ' + bytes(stats.up) +
					(stats.speed ? '  (↓ ' + bytes(stats.speed[0]) + '/s  ↑ ' + bytes(stats.speed[1]) + '/s)' : '')) ] : null,
			]),
		]);

		const subTitles = [ _('Name'), _('Servers'), _('Traffic'), _('Expires'), _('Updated'), _('Next update'), _('Status') ];
		const subRows = (subs.subscriptions ?? []).map((s) => {
			const ui_ = s.userinfo ?? {};
			let trafficCell = '—';
			if (s.userinfo) {
				const used = (ui_.upload ?? 0) + (ui_.download ?? 0);
				if (ui_.total > 0) {
					const pct = Math.min(100, Math.round(used / ui_.total * 100));
					trafficCell = E('div', {
						'class': 'cbi-progressbar',
						'title': '%s / %s (%d%%)'.format(bytes(used), bytes(ui_.total), pct),
					}, E('div', { 'style': 'width:%d%%'.format(pct) }));
				}
				else
					trafficCell = txt(bytes(used) + ' / ∞');
			}

			let expires = '—';
			if (ui_.expire > 0) {
				const left = ui_.expire - now;
				const date = new Date(ui_.expire * 1000).toLocaleDateString();
				const days = Math.floor(left / 86400);
				const text = '%s (%s)'.format(date, days
					? N_(days, '%d day left', '%d days left').format(days) : _('less than a day left'));
				expires = (left <= 0) ? label('error', _('expired %s').format(date))
					: (left < 3 * 86400) ? label('warning', text) : txt(text);
			}
			else if (s.userinfo)
				expires = txt(_('never'));

			const names = [ E('strong', {}, [ txt(s.name ?? s.id) ]) ];
			if (s.title && s.title != s.name)
				names.push(E('br'), E('small', {}, [ txt(s.title) ]));

			return row(subTitles, [
				names,
				txt(String(s.count ?? 0) + (s.skipped ? ' ' + _('(%d skipped)').format(s.skipped) : '')),
				trafficCell,
				expires,
				txt(ago(now, s.last_ok)),
				!s.enabled ? E('em', {}, _('disabled'))
					: (s.due_in == null) ? '—'
					: txt((s.due_in <= 0) ? _('due') : _('in %s').format(dur(s.due_in))),
				s.error ? E('span', { 'style': 'color:var(--error-color-high, #c00)' }, [ txt(s.error) ])
					: s.last_ok ? label('success', _('OK')) : '—',
			], s.enabled ? null : 'disabled');
		});

		const subsSection = E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, _('Subscriptions')),
			table(subTitles, subRows, _('No subscriptions. Add one on the "Subscriptions" tab.')),
		]);

		const srvTitles = [ _('Name'), _('Protocol'), _('Address'), _('Subscription'), _('Latency'), _('Traffic'), _('Auto'), '' ];
		const srvRows = list.map((s) => {
			const isActive = (s.id == activeId);
			const t = traffic[s.id];
			let ping = '—';
			if (s.latency != null)
				ping = (s.latency < 0) ? label('error', _('failed'))
					: E('span', { 'title': ago(now, s.tested) }, [ txt(_('%d ms').format(s.latency)) ]);
			// #61: answers the check URL, not the second one
			if (s.limited && s.latency >= 0)	// one that does not answer at all is just failed
				ping = [ ping, ' ', limited(status.url2) ];

			const nameCell = [ isActive ? E('strong', {}, [ txt(s.name) ]) : txt(s.name) ];
			if (isActive)
				nameCell.push(' ', label('success', _('active')));
			if (s.quarantined)
				nameCell.push(' ', label('warning', _('quarantine')));

			return row(srvTitles, [
				nameCell,
				protoCell(s),
				txt((s.address ?? '') + (s.port ? ':' + s.port : '')),
				s.sub_name ? txt(s.sub_name) : E('em', {}, _('manual')),
				ping,
				t ? txt('↓ ' + bytes(t.down) + ' ↑ ' + bytes(t.up)) : '—',
				// health.no_auto: the daemon does not choose it by itself, "Use" still does
				this.checkbox('auto:' + s.id, s.auto !== false, !up,
					_('Takes part in auto selection: at start, on failover and when switching to a faster server'),
					(on) => callSetAuto(s.id, on)),
				isActive ? '' : this.button('select:' + s.id, 'cbi-button-apply', _('Use'), !up,
					() => callSelect(s.id), _('Switching to %s…').format(s.name)),
			]);
		});

		const srvSection = E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, _('Servers')),
			table(srvTitles, srvRows, _('No servers yet. Add a subscription or a link on the "Subscriptions" tab.')),
		]);

		// buttons of servers that left the list are dropped, a running one is kept until it is done
		for (let key in this.buttons)
			if (!this.used[key] && !this.busy[key])
				delete this.buttons[key];

		// buttons are kept across redraws: give the focus back to the one that had it
		const focused = document.activeElement;
		dom.content(this.root, [ ...alerts, statusSection, subsSection, srvSection ]);
		if (focused && focused !== document.activeElement && this.root.contains(focused))
			focused.focus({ preventScroll: true });
	},

	render(data) {
		this.seq = 0;
		this.busy = {};
		this.buttons = {};
		this.root = E('div');
		this.update(data);
		poll.add(() => this.refresh(), 5);

		return E('div', { 'class': 'cbi-map' }, [
			E('h2', {}, _('XVPN')),
			E('div', { 'class': 'cbi-map-descr' },
				_('VPN client on xray-core with subscriptions and automatic failover between servers.')),
			this.root,
		]);
	},
});
