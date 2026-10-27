// SPDX-License-Identifier: MIT
// Log tab: the last lines of the system log from xvpn and xray, refreshed and filtered.
'use strict';
'require view';
'require rpc';
'require poll';
'require dom';

const callLog = rpc.declare({ object: 'luci.xvpn', method: 'log' });

const REFRESH = 5;

// logread lines: "Tue Oct 27 10:00:00 2026 user.notice xvpn: …"; the backend sends only the lines
// tagged xvpn and those of xray (tagged with the name of its binary)
const XVPN = / xvpn(\[\d+\])?: /;
const SOURCES = {
	'': () => true,
	xvpn: (l) => XVPN.test(l),
	xray: (l) => !XVPN.test(l),
};

function txt(s) {
	return document.createTextNode(s ?? '');
}

return view.extend({
	load() {
		return L.resolveDefault(callLog(), {});
	},

	lines: [],

	take(res) {
		this.lines = (res?.log ?? '').split('\n').filter((l) => l.trim() != '');
	},

	// case-insensitive text; a regular expression when written as /…/
	matcher() {
		const q = this.query.value.trim();
		this.query.setCustomValidity('');
		if (!q)
			return () => true;
		const re = q.match(/^\/(.+)\/$/);
		if (re) {
			try {
				const r = new RegExp(re[1], 'i');
				return (l) => r.test(l);
			}
			catch (e) {
				this.query.setCustomValidity(e.message);
				this.query.reportValidity();
				return () => true;
			}
		}
		const s = q.toLowerCase();
		return (l) => l.toLowerCase().includes(s);
	},

	show() {
		const pre = this.pre;
		// keep the view at the bottom only if it was there: reading older lines is not interrupted
		const bottom = pre.scrollTop + pre.clientHeight >= pre.scrollHeight - 4;
		const src = SOURCES[this.source.value], match = this.matcher();
		const errors = this.errors.checked;
		const shown = this.lines.filter((l) => src(l) && match(l) && (!errors || /\.(err|crit|alert|emerg)\b|\berror\b|\bfailed\b/i.test(l)));
		// lines from the log are text only
		pre.textContent = shown.length ? shown.join('\n') : '';
		dom.content(this.count, txt(this.lines.length
			? _('%d of %d lines').format(shown.length, this.lines.length) : _('The log has no lines of xvpn or xray')));
		if (bottom)
			pre.scrollTop = pre.scrollHeight;
	},

	refresh() {
		// text selected in the log would be lost by the redraw
		const sel = window.getSelection();
		if (sel && !sel.isCollapsed && this.pre.contains(sel.anchorNode))
			return Promise.resolve();
		return L.resolveDefault(callLog(), null).then((res) => {
			if (res) {
				this.take(res);
				this.show();
			}
		});
	},

	toggleAuto(on) {
		if (on && !this.poller) {
			this.poller = () => this.refresh();
			poll.add(this.poller, REFRESH);
		}
		else if (!on && this.poller) {
			poll.remove(this.poller);
			this.poller = null;
		}
	},

	render(res) {
		this.take(res);

		const update = () => this.show();
		this.query = E('input', {
			'type': 'text', 'class': 'cbi-input-text', 'style': 'width:18em',
			'placeholder': _('Filter, or /regex/'), 'input': update,
		});
		this.source = E('select', { 'class': 'cbi-input-select', 'change': update }, [
			E('option', { 'value': '' }, _('xvpn and xray')),
			E('option', { 'value': 'xvpn' }, 'xvpn'),
			E('option', { 'value': 'xray' }, 'xray'),
		]);
		this.errors = E('input', { 'type': 'checkbox', 'id': 'xvpn-log-errors', 'change': update });
		const auto = E('input', {
			'type': 'checkbox', 'id': 'xvpn-log-auto', 'checked': '',
			'change': (ev) => this.toggleAuto(ev.target.checked),
		});
		this.count = E('span', { 'style': 'margin-left:auto' });
		this.pre = E('pre', {
			'style': 'height:60vh;overflow:auto;white-space:pre-wrap;word-break:break-all;font-size:12px;margin:0;padding:.5em;border:1px solid var(--border-color-medium, #ccc)',
		});

		const node = E('div', { 'class': 'cbi-map' }, [
			E('h2', {}, _('XVPN: log')),
			E('div', { 'class': 'cbi-map-descr' },
				_('The last 300 lines of the system log from the xvpn service and xray. The log level of xray is set in the Settings tab.')),
			E('div', { 'class': 'cbi-section' }, [
				E('div', { 'style': 'display:flex;flex-wrap:wrap;gap:.5em 1em;align-items:center;margin-bottom:.5em' }, [
					this.query,
					this.source,
					E('label', { 'for': 'xvpn-log-errors', 'style': 'cursor:pointer' }, [ this.errors, ' ', _('Errors only') ]),
					E('label', { 'for': 'xvpn-log-auto', 'style': 'cursor:pointer' },
						[ auto, ' ', _('Refresh every %d s').format(REFRESH) ]),
					E('button', {
						'class': 'cbi-button cbi-button-action',
						'click': () => this.refresh(),
					}, _('Refresh')),
					this.count,
				]),
				this.pre,
			]),
		]);

		this.show();
		// the newest lines are at the bottom: scrolled there once the page shows the log
		window.setTimeout(() => this.pre.scrollTop = this.pre.scrollHeight, 0);
		this.toggleAuto(true);
		return node;
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null,
});
