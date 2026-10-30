// SPDX-License-Identifier: MIT
// Split tunneling tab (#67): networks that go around the tunnel before xray (nftables),
// the Russian network list, domains that xray sends out directly.
'use strict';
'require view';
'require form';
'require rpc';
'require uci';
'require ui';
'require poll';

const callSplit = rpc.declare({ object: 'luci.xvpn', method: 'split' });
const callSplitUpdate = rpc.declare({ object: 'luci.xvpn', method: 'split_update' });

// the same checks as split.uc cidr() and domain_rule(): what the backend would skip
const IPV4 = /^(25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)(\.(25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)){3}$/;
const LABEL = '[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?';
const DOMAIN = new RegExp(`^(${LABEL})(\\.${LABEL})*$`);

function ipv6(a) {
	if (!/^[0-9a-f:.]+$/i.test(a) || (a.match(/::/g) ?? []).length > 1)
		return false;
	let parts = a.split(':'), groups = 0;
	if (IPV4.test(parts[parts.length - 1])) {
		parts.pop();
		groups += 2;
	}
	for (let p of parts)
		if (p !== '') {
			if (!/^[0-9a-f]{1,4}$/i.test(p))
				return false;
			groups++;
		}
	return a.includes('::') ? groups < 8 : groups == 8;
}

function cidr(v) {
	const m = /^([^/]+)(\/(\d{1,3}))?$/.exec(v.trim());
	if (!m)
		return false;
	const v4 = IPV4.test(m[1]);
	if (!v4 && !ipv6(m[1]))
		return false;
	const n = (m[3] != null) ? +m[3] : 1;
	return n >= 1 && n <= (v4 ? 32 : 128);
}

function domain(v) {
	let d = v.trim().toLowerCase().replace(/^(full|domain):/, '').replace(/^\*?\./, '');
	return d.length <= 253 && DOMAIN.test(d);
}

function ago(now, t) {
	const s = Math.max(0, now - t);
	if (s < 3600)
		return _('%d min ago').format(Math.floor(s / 60));
	if (s < 86400)
		return _('%d h ago').format(Math.floor(s / 3600));
	return _('%d days ago').format(Math.floor(s / 86400));
}

return view.extend({
	load() {
		return Promise.all([
			L.resolveDefault(callSplit(), {}),
			uci.load('xvpn'),
		]);
	},

	// text nodes only: the error comes from curl and the server
	listStatus(st) {
		const r = [];
		if (!st.ru)
			return E('em', {}, _('The list is off.'));
		if (st.cached)
			r.push(E('div', {}, _('In the rules: %d IPv4 and %d IPv6 networks.').format(st.cached.v4, st.cached.v6)));
		else
			r.push(E('div', {}, _('Not downloaded yet: until it is, this traffic goes through the tunnel.')));
		if (st.last_ok)
			r.push(E('div', {}, _('Checked %s (%s).').format(ago(st.time, st.last_ok),
				st.via == 'tunnel' ? _('through the tunnel') : _('directly'))));
		if (st.error)
			r.push(E('div', { 'class': 'alert-message warning' }, _('Last download failed: %s').format(st.error)));
		if (st.updating)
			r.push(E('div', {}, E('em', {}, _('Downloading…'))));
		return E('div', {}, r);
	},

	render([ st ]) {
		if (!uci.get('xvpn', 'split'))
			uci.add('xvpn', 'split', 'split');

		const m = new form.Map('xvpn', _('XVPN: split tunneling'),
			_('By default all traffic of the VPN access points goes through the tunnel. Traffic to the addresses and domains below goes out directly through the provider. Traffic to the addresses does not reach xray at all: the router forwards it as without VPN (with flow offloading, in hardware), which takes load off the router.'));

		const s = m.section(form.NamedSection, 'split', 'split', _('Direct by address'),
			_('Connections to these addresses are not intercepted: no tunnel, and the kill switch lets them through. When the service is stopped or the rules fail, they are blocked like everything else.'));
		s.addremove = false;

		let o = s.option(form.DynamicList, 'ip', _('Addresses and networks'),
			_('IPv4 or IPv6 addresses and networks, for example 203.0.113.0/24 or 2001:db8::/32.'));
		o.datatype = 'string';
		o.validate = (sid, v) => !v || cidr(v) || _('Enter an IPv4 or IPv6 address or network');
		o.write = (sid, v) => uci.set('xvpn', sid, 'ip', v.map((e) => e.trim()));

		o = s.option(form.Flag, 'ru', _('Russian networks directly'),
			_('Networks of Russia from an aggregated country list (ipdeny.com, about 10 000 networks, a few MB in the kernel and about 200 KB on the flash). The router downloads it through the tunnel (directly if that fails) and keeps it up to date. A site is matched by the address its DNS answer gives: DNS of the clients goes through the tunnel, so a site on a CDN may get a foreign address and go through the tunnel.'));
		o.default = '0';
		o.rmempty = false;

		o = s.option(form.Value, 'ru_interval', _('Update the list every, h'));
		o.placeholder = '168';
		o.depends('ru', '1');
		o.retain = true;
		o.validate = (sid, v) => !v || (/^\d+$/.test(v.trim()) && +v >= 1 && +v <= 8760) || _('Enter a whole number from %d to %d').format(1, 8760);

		const d = m.section(form.NamedSection, 'split', 'split', _('Direct by domain'),
			_('xray finds the domain of a connection by sniffing (Settings tab, on by default) and sends these domains out directly. Such traffic still passes xray, but without encryption. Keep the list short: tens or hundreds of domains. The router resolves them with its own DNS (the provider\'s), the clients\' DNS still goes through the tunnel.'));
		d.addremove = false;

		o = d.option(form.DynamicList, 'domain', _('Domains'),
			_('"example.ru" — the domain and its subdomains, "ru" — the whole zone, "full:www.example.ru" — only this name. International domains in punycode (xn--p1ai for .рф).'));
		o.datatype = 'string';
		o.validate = (sid, v) => !v || domain(v) || _('Enter a domain, for example example.ru or full:www.example.ru');
		o.write = (sid, v) => uci.set('xvpn', sid, 'domain', v.map((e) => e.trim().toLowerCase()));

		poll.add(() => L.resolveDefault(callSplit(), null).then((r) => {
			const box = document.getElementById('xvpn-split-status');
			if (r && box)
				box.replaceChildren(this.listStatus(r));
		}), 5);

		// the state of the downloaded list, beside the form: polled, the form is not redrawn
		return m.render().then((node) => {
			const btn = E('button', {
				'class': 'cbi-button cbi-button-action',
				'click': ui.createHandlerFn(this, () => callSplitUpdate().then((r) => {
					if (!r?.ok)
						ui.addNotification(null, E('p', {}, _('Could not start the download: %s').format(r?.error ?? '?')), 'warning');
				})),
			}, _('Update the Russian list now'));
			node.appendChild(E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('Russian network list')),
				E('div', { 'id': 'xvpn-split-status' }, this.listStatus(st)),
				E('p', {}, btn),
				E('div', { 'class': 'cbi-section-descr' }, _('Turning the list on or off takes effect after "Save & Apply".')),
			]));
			return node;
		});
	},
});
