// SPDX-License-Identifier: MIT
// Subscriptions tab: subscriptions with their update status and manual share links.
'use strict';
'require view';
'require form';
'require rpc';
'require poll';
'require uci';
'require ui';
'require dom';

const callSubscriptions = rpc.declare({ object: 'luci.xvpn', method: 'subscriptions' });
const callUpdate = rpc.declare({ object: 'luci.xvpn', method: 'update', params: [ 'sid' ] });
const callParseLinks = rpc.declare({ object: 'luci.xvpn', method: 'parse_links', params: [ 'links' ] });

const SCHEMES = /^(vless|vmess|trojan|ss):\/\/\S+$/i;

function errorText(err) {
	return {
		'busy': _('An update is already running'),
		'not running': _('The daemon is not running'),
		'timeout': _('The daemon did not answer in time, the request may still be carried out'),
		'no subscriptions to update': _('Nothing to update: the subscription is disabled, has no URL or is not applied yet'),
	}[err] ?? err ?? _('unknown error');
}

// subscription titles, server names and errors come from outside: text nodes only
function txt(s) {
	return document.createTextNode(s ?? '');
}

// themes have no red label (.important is the primary color in bootstrap): 'error' is inline
function label(cls, text) {
	if (cls == 'error')
		return E('span', { 'class': 'label', 'style': 'background-color:var(--error-color-high, #c00);color:#fff' }, [ txt(text) ]);
	return E('span', { 'class': 'label ' + cls }, [ txt(text) ]);
}

function red(text) {
	return E('span', { 'style': 'color:var(--error-color-high, #c00)' }, [ txt(text) ]);
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

// sections made in the UI get a fixed name: an anonymous one is renamed by uci whenever its
// options change, and the downloaded servers and the status are kept under that name
function newName() {
	const rnd = new Uint8Array(4);
	crypto.getRandomValues(rnd);
	return 'sub_' + Array.from(rnd, (b) => b.toString(16).padStart(2, '0')).join('');
}

const SubSection = form.GridSection.extend({
	handleAdd(ev, name) {
		return this.super('handleAdd', [ ev, name ?? newName() ]);
	},

	// "Update all" next to "Add subscription"
	renderSectionAdd(extra_class) {
		const el = this.super('renderSectionAdd', [ extra_class ]);
		el.append(' ', this.view.updateButton(null));
		return el;
	},

	// "Update" in front of Edit / Delete
	renderRowActions(section_id) {
		const td = this.super('renderRowActions', [ section_id ]);
		td.lastElementChild?.prepend(this.view.updateButton(section_id), ' ');
		return td;
	},
});

// manual links: one per line in a textarea, a list in UCI; each line is checked by the
// parser of the backend while typing
const LinksValue = form.TextValue.extend({
	cfgvalue(section_id) {
		return L.toArray(uci.get('xvpn', section_id, 'link')).join('\n');
	},

	formvalue(section_id) {
		return this.super('formvalue', [ section_id ]) ?? '';
	},

	write(section_id, value) {
		const links = value.split('\n').map((l) => l.trim()).filter((l) => l);
		if (links.length)
			uci.set('xvpn', section_id, 'link', links);
		else
			uci.unset('xvpn', section_id, 'link');
	},

	remove(section_id) {
		uci.unset('xvpn', section_id, 'link');
	},

	validate(section_id, value) {
		this.schedule(section_id, value);
		const lines = (value ?? '').split('\n');
		for (let i = 0; i < lines.length; i++) {
			const l = lines[i].trim();
			if (!l)
				continue;
			if (!SCHEMES.test(l))
				return _('Line %d: not a vless://, vmess://, trojan:// or ss:// link').format(i + 1);
			if (this.parsed?.[l]?.error)
				return _('Line %d: %s').format(i + 1, this.parsed[l].error);
		}
		return true;
	},

	// asks the backend about the lines it has not seen yet, then validates again
	schedule(section_id, value) {
		this.value_ = value;
		window.clearTimeout(this.timer);
		this.timer = window.setTimeout(() => {
			const todo = [ ...new Set(this.lines(this.value_).filter((l) => SCHEMES.test(l) && !this.parsed[l])) ];
			if (!todo.length)
				return this.showResults();
			callParseLinks(todo).then((res) => {
				(res?.links ?? []).forEach((r, i) => this.parsed[todo[i]] = r);
				this.triggerValidation(section_id);
				this.showResults();
			}).catch((e) => notify(_('Could not check the links: %s').format(e.message), 'error'));
		}, 400);
	},

	lines(value) {
		return (value ?? '').split('\n').map((l) => l.trim()).filter((l) => l);
	},

	// what the backend makes of every line: the servers, errors and duplicates
	showResults() {
		if (!this.results)
			return;
		const titles = [ '#', _('Protocol'), _('Name'), _('Address'), _('Check') ];
		const seen = {};
		const rows = [];
		(this.value_ ?? '').split('\n').forEach((raw, i) => {
			const l = raw.trim();
			if (!l)
				return;
			const r = SCHEMES.test(l) ? this.parsed[l] : { error: _('not a vless://, vmess://, trojan:// or ss:// link') };
			let check;
			if (!r)
				check = E('em', {}, _('checking…'));
			else if (r.error)
				check = red(r.error);
			else if (seen[r.id])
				check = label('warning', _('duplicate of line %d, skipped').format(seen[r.id]));
			else {
				seen[r.id] = i + 1;
				check = label('success', _('OK'));
			}
			rows.push(E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td', 'data-title': titles[0] }, [ txt(String(i + 1)) ]),
				E('td', { 'class': 'td', 'data-title': titles[1] }, [ txt(r?.proto ?? '') ]),
				E('td', { 'class': 'td', 'data-title': titles[2] }, [ txt(r?.name ?? '') ]),
				E('td', { 'class': 'td', 'data-title': titles[3] }, [ txt(r?.address ? r.address + ':' + r.port : '') ]),
				E('td', { 'class': 'td', 'data-title': titles[4] }, [ check ]),
			]));
		});
		dom.content(this.results, rows.length ? E('table', { 'class': 'table' }, [
			E('tr', { 'class': 'tr table-titles' }, titles.map((t) => E('th', { 'class': 'th' }, [ txt(t) ]))),
			...rows,
		]) : []);
	},

	renderWidget(section_id, option_index, cfgvalue) {
		this.parsed ??= {};
		this.results = E('div', { 'style': 'margin-top:.5em' });
		this.value_ = cfgvalue ?? '';
		this.schedule(section_id, this.value_);
		return E('div', {}, [ this.super('renderWidget', [ section_id, option_index, cfgvalue ]), this.results ]);
	},
});

return view.extend({
	load() {
		return Promise.all([
			L.resolveDefault(callSubscriptions(), {}),
			uci.load('xvpn'),
		]);
	},

	// the status of a subscription cell by cell; the poll fills them again in place
	takeStatus(res) {
		this.subs = {};
		for (let s of res?.subscriptions ?? [])
			this.subs[s.id] = s;
		this.updating = !!res?.updating;
		this.now = res?.time ?? Math.floor(Date.now() / 1000);
	},

	statusCell(sid) {
		const node = this.cells[sid + '/status'] = E('div', { 'style': 'min-width:14em' });
		this.fillStatus(sid);
		return node;
	},

	trafficCell(sid) {
		const node = this.cells[sid + '/traffic'] = E('div', { 'style': 'min-width:12em' });
		this.fillTraffic(sid);
		return node;
	},

	fillStatus(sid) {
		const node = this.cells[sid + '/status'], s = this.subs[sid], now = this.now;
		if (!node)
			return;
		if (!s) {
			dom.content(node, E('em', {}, _('not applied yet')));
			return;
		}

		const out = [];
		if (s.title && s.title != s.name)
			out.push(E('strong', {}, [ txt(s.title) ]), E('br'));
		out.push(txt(N_(s.count ?? 0, '%d server', '%d servers').format(s.count ?? 0)));
		if (s.skipped)
			out.push(txt(' ' + _('(%d skipped)').format(s.skipped)));
		if (s.format)
			out.push(txt(', ' + s.format));
		out.push(E('br'));

		if (s.error)
			out.push(red(_('Error: %s').format(s.error)),
				txt(s.last_attempt ? ' (' + ago(now, s.last_attempt) + ')' : ''), E('br'));
		out.push(txt(_('Updated: %s').format(ago(now, s.last_ok)) +
			((s.last_ok && s.via) ? ' ' + ((s.via == 'tunnel') ? _('(through the tunnel)') : _('(directly)')) : '')));
		if (s.updated && s.last_ok && s.updated != s.last_ok)
			out.push(txt(', ' + _('list changed %s').format(ago(now, s.updated))));
		out.push(E('br'));

		if (this.updating)
			out.push(label('notice', _('updating…')));
		else if (s.enabled && s.due_in != null)
			out.push(txt(_('Next update: %s').format((s.due_in <= 0) ? _('due') : _('in %s').format(dur(s.due_in)))));
		dom.content(node, out);
	},

	fillTraffic(sid) {
		const node = this.cells[sid + '/traffic'], s = this.subs[sid], now = this.now;
		if (!node)
			return;
		const u = s?.userinfo;
		if (!u) {
			dom.content(node, txt('—'));
			return;
		}

		const out = [];
		const used = (u.upload ?? 0) + (u.download ?? 0);
		if (u.total > 0) {
			const pct = Math.min(100, Math.round(used / u.total * 100));
			out.push(E('div', {
				'class': 'cbi-progressbar',
				'title': '%s / %s (%d%%)'.format(bytes(used), bytes(u.total), pct),
			}, E('div', { 'style': 'width:%d%%'.format(pct) })));
		}
		else
			out.push(txt(bytes(used) + ' / ∞'), E('br'));

		if (u.expire > 0) {
			const left = u.expire - now;
			const date = new Date(u.expire * 1000).toLocaleDateString();
			const days = Math.floor(left / 86400);
			const text = _('until %s').format(date) + ' (' + (days
				? N_(days, '%d day left', '%d days left').format(days) : _('less than a day left')) + ')';
			out.push((left <= 0) ? label('error', _('expired %s').format(date))
				: (left < 3 * 86400) ? label('warning', text) : E('small', {}, [ txt(text) ]));
		}
		else
			out.push(E('small', {}, [ txt(_('no expiry date')) ]));
		dom.content(node, out);
	},

	// one button per subscription and one for all; kept across form redraws by key
	updateButton(sid) {
		const btn = this.buttons[sid ?? ''] = E('button', {
			'class': 'cbi-button cbi-button-action',
			'title': sid ? _('Download this subscription now') : _('Download all enabled subscriptions now'),
			'click': ui.createHandlerFn(this, 'handleUpdate', sid),
		}, sid ? _('Update') : _('Update all'));
		this.fillButton(sid ?? '');
		return btn;
	},

	fillButton(key) {
		const btn = this.buttons[key];
		if (!btn)
			return;
		const busy = !!this.busy[key];
		btn.classList.toggle('spinning', busy);
		// a subscription not applied yet is unknown to the backend
		btn.disabled = busy || this.updating || (key != '' && !this.subs[key]);
	},

	handleUpdate(sid) {
		const key = sid ?? '';
		this.busy[key] = true;
		this.fillButton(key);
		return callUpdate(sid ?? null).then((res) => {
			if (typeof(res) == 'number' && res != 0)
				notify(_('Request failed: %s').format(rpc.getStatusText(res)), 'error');
			else if (res?.ok === false)
				notify(_('Request failed: %s').format(errorText(res.error)), 'error');
			else
				notify(_('Updating subscriptions…'), 'info');
		}).catch((e) => notify(e.message, 'error')).finally(() => {
			delete this.busy[key];
			return this.refresh();
		});
	},

	refresh() {
		const seq = ++this.seq;
		return L.resolveDefault(callSubscriptions(), null).then((res) => {
			if (seq != this.seq || !res)
				return;
			this.takeStatus(res);
			for (let key in this.cells) {
				const [ sid, what ] = key.split('/');
				if (!this.cells[key].isConnected)
					delete this.cells[key];
				else if (what == 'status')
					this.fillStatus(sid);
				else
					this.fillTraffic(sid);
			}
			for (let key in this.buttons) {
				if (!this.buttons[key].isConnected)
					delete this.buttons[key];
				else
					this.fillButton(key);
			}
		});
	},

	render([ subs ]) {
		this.seq = 0;
		this.cells = {};
		this.buttons = {};
		this.busy = {};
		this.takeStatus(subs);

		// the package ships it; brought back if it was deleted by hand
		if (!uci.get('xvpn', 'manual'))
			uci.add('xvpn', 'manual', 'manual');

		const m = new form.Map('xvpn', _('XVPN: subscriptions'),
			_('Servers come from subscriptions and manual links. Changes take effect after "Save & Apply"; a new subscription is downloaded within 5 minutes after that, or press "Update".'));

		let s = m.section(SubSection, 'subscription', _('Subscriptions'),
			_('A subscription is a URL with a base64 or plain list of links, or with xray JSON. Traffic and the expiry date come from the subscription-userinfo header of the provider.'));
		s.view = this;
		s.anonymous = true;
		s.addremove = true;
		s.sortable = true;
		s.nodescriptions = true;
		s.addbtntitle = _('Add subscription');
		s.modaltitle = _('Subscription');
		s.sectiontitle = null;

		let o = s.option(form.Flag, 'enabled', _('Enabled'));
		o.default = '1';
		o.rmempty = false;
		o.editable = true;

		o = s.option(form.Value, 'name', _('Name'));
		o.rmempty = false;
		o.validate = (sid, v) => (v.trim() != '') || _('Enter a name');

		o = s.option(form.Value, 'url', _('URL'));
		o.rmempty = false;
		o.validate = (sid, v) => /^https?:\/\/[^\s/?#]+\S*$/i.test(v.trim()) || _('Enter an http:// or https:// URL');
		o.textvalue = (sid) => {
			const url = uci.get('xvpn', sid, 'url') ?? '';
			return E('span', {
				'title': url,
				'style': 'display:inline-block;max-width:16em;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;vertical-align:bottom',
			}, [ txt(url) ]);
		};

		o = s.option(form.Value, 'update_interval', _('Interval, h'),
			_('0 or empty: the interval from the profile-update-interval header of the provider, otherwise 12 hours.'));
		o.datatype = 'uinteger';
		o.placeholder = _('auto');
		o.textvalue = (sid) => {
			const v = +(uci.get('xvpn', sid, 'update_interval') ?? 0);
			return v ? _('%d h').format(v) : _('auto');
		};

		o = s.option(form.DummyValue, '_status', _('Status'));
		o.modalonly = false;
		o.textvalue = (sid) => this.statusCell(sid);

		o = s.option(form.DummyValue, '_traffic', _('Traffic and expiry'));
		o.modalonly = false;
		o.textvalue = (sid) => this.trafficCell(sid);

		o = s.option(form.Value, 'user_agent', _('User-Agent'),
			_('Providers (Marzban, Remnawave, 3x-ui) choose the format by the User-Agent. Clash and sing-box formats are not supported.'));
		o.modalonly = true;
		o.placeholder = 'v2rayN/7.0';
		o.value('v2rayN/7.0');
		o.value('v2rayNG/1.9.0');

		const regex = (sid, v) => {
			if (!v)
				return true;
			try {
				new RegExp(v, 'i');
				return true;
			}
			catch (e) {
				return _('Invalid regular expression: %s').format(e.message);
			}
		};

		o = s.option(form.Value, 'include', _('Include'),
			_('Regular expression: only servers with a matching name are used. Case-insensitive.'));
		o.modalonly = true;
		o.validate = regex;

		o = s.option(form.Value, 'exclude', _('Exclude'),
			_('Regular expression: servers with a matching name are skipped. Case-insensitive.'));
		o.modalonly = true;
		o.validate = regex;

		o = s.option(form.Flag, 'via_tunnel', _('Through the tunnel'),
			_('Download through the active server; if that fails, directly.'));
		o.modalonly = true;
		o.default = '1';
		o.rmempty = false;

		s = m.section(form.NamedSection, 'manual', 'manual', _('Manual links'),
			_('One vless://, vmess://, trojan:// or ss:// link per line. Each line is checked by the parser of the router; links it cannot use block saving. A server that is also in a subscription is used once.'));
		s.addremove = false;

		o = s.option(LinksValue, 'link', _('Links'));
		o.rows = 8;
		// lines of the check below are numbered: one link, one line
		o.wrap = false;
		o.monospace = true;
		o.rmempty = true;
		o.placeholder = 'vless://uuid@host:443?type=tcp&security=reality&…#Name';

		poll.add(() => this.refresh(), 5);

		return m.render();
	},
});
