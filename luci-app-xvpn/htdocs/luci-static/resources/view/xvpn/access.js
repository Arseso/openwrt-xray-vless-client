// SPDX-License-Identifier: MIT
// Access points tab: which networks, LAN ports and SSIDs go through the VPN; kill switch, DNS, IPv6.
'use strict';
'require view';
'require form';
'require rpc';
'require uci';
'require ui';
'require dom';

const callAccessPoints = rpc.declare({ object: 'luci.xvpn', method: 'access_points' });

const DEFAULT_DNS = 'https://cloudflare-dns.com/dns-query';

// network, port and SSID names come from the configs of the router: text nodes only
function txt(s) {
	return document.createTextNode(s ?? '');
}

function choice(name, details, warn) {
	return E('span', {}, [
		E('strong', {}, [ txt(name) ]),
		txt(details.length ? ' (' + details.join(', ') + ')' : ''),
		warn ? E('span', { 'style': 'color:var(--error-color-high, #c00)' }, [ txt(' ' + warn) ]) : '',
	]);
}

function bandText(band) {
	return { '2g': '2.4 GHz', '5g': '5 GHz', '6g': '6 GHz', '60g': '60 GHz' }[band] ?? band;
}

// what util.uc dns_server() takes as is: an IP (forwarded to <IP>:53 through the tunnel)
// or an https:// / tcp:// URL; anything else would be replaced by the default
function validDns(sid, v) {
	if (!v)
		return true;
	v = v.trim();
	if (/^(https|tcp):\/\/[^\/\s]+\S*$/i.test(v))
		return true;
	if (/^\d{1,3}(\.\d{1,3}){3}$/.test(v) && v.split('.').every((o) => +o <= 255))
		return true;
	if (/^[0-9a-f:.]+$/i.test(v) && v.includes(':')) {
		try {
			new URL('http://[' + v + ']/');
			return true;
		}
		catch (e) { }
	}
	return _('Enter an IP address, an https:// (DoH) or a tcp:// URL');
}

// checkboxes for a list; ui.Select with widget 'checkbox' returns only one value
const UICheckList = ui.AbstractElement.extend({
	__init__(values, choices, options) {
		this.values = values;
		this.choices = choices;
		this.options = options;
	},

	render() {
		const frameEl = E('div', { 'id': this.options.id });
		this.options.sort.forEach((key, i) => {
			const id = '%s.%d'.format(this.options.id, i);
			frameEl.appendChild(E('div', {}, [
				E('span', { 'class': 'cbi-checkbox' }, [
					E('input', {
						'id': id, 'type': 'checkbox', 'class': 'cbi-input-checkbox', 'value': key,
						'checked': this.values.includes(key) ? '' : null,
					}),
					E('label', { 'for': id }),
				]),
				' ',
				E('label', { 'for': id, 'style': 'display:inline;cursor:pointer' }, [ this.choices[key] ]),
			]));
		});
		this.node = frameEl;
		this.setUpdateEvents(frameEl, 'change');
		this.setChangeEvents(frameEl, 'change');
		dom.bindClassInstance(frameEl, this);
		return frameEl;
	},

	getValue() {
		return Array.from(this.node.querySelectorAll('input[type="checkbox"]:checked'), (el) => el.value);
	},

	setValue(values) {
		values = L.toArray(values);
		this.node.querySelectorAll('input[type="checkbox"]').forEach((el) => el.checked = values.includes(el.value));
	},
});

// a list option as checkboxes: one per access point found on the router, labels are nodes
const CheckList = form.MultiValue.extend({
	// value() makes the lists only on its first call: there may be no access points
	__init__(...args) {
		this.super('__init__', args);
		this.keylist = [];
		this.vallist = [];
	},

	renderWidget(section_id, option_index, cfgvalue) {
		const values = L.toArray(cfgvalue ?? this.default);
		// a configured name the router does not have any more stays selectable
		for (let v of values)
			if (!this.keylist.includes(v))
				this.value(v, choice(v, [], _('not found')));
		if (!this.keylist.length)
			return E('em', {}, _('none found'));
		return new UICheckList(values, this.transformChoices(), { id: this.cbid(section_id), sort: this.keylist }).render();
	},

	formvalue(section_id) {
		return this.keylist.length ? L.toArray(this.super('formvalue', [ section_id ])) : this.cfgvalue(section_id);
	},

	write(section_id, value) {
		if (L.toArray(value).length)
			uci.set('xvpn', section_id, this.option, L.toArray(value));
		else
			uci.unset('xvpn', section_id, this.option);
	},
});

return view.extend({
	load() {
		return Promise.all([
			L.resolveDefault(callAccessPoints(), {}),
			uci.load('xvpn'),
		]);
	},

	render([ ap ]) {
		// the package ships it; brought back if it was deleted by hand
		if (!uci.get('xvpn', 'access'))
			uci.add('xvpn', 'access', 'access');

		const m = new form.Map('xvpn', _('XVPN: access points'),
			_('Clients of the selected access points go to the internet only through the VPN (full tunnel). Other clients of the router are not affected. Changes take effect after "Save & Apply".'));

		let s = m.section(form.NamedSection, 'access', 'access', _('Access points'),
			_('Networks, LAN ports and SSIDs can be combined. A port or SSID that is part of a selected network is covered by the network anyway.'));
		s.addremove = false;

		let o = s.option(CheckList, 'network', _('Networks'),
			_('Whole OpenWrt networks (interfaces), with every port and SSID in them. WAN networks are not listed.'));
		for (let n of ap.networks ?? []) {
			const details = [];
			if (n.proto)
				details.push(n.proto);
			if (n.device)
				details.push(n.device);
			o.value(n.name, choice(n.name, details));
		}

		o = s.option(CheckList, 'port', _('LAN ports'),
			_('Single ports of a bridge (DSA), e.g. lan2: devices plugged into them go through the VPN, the rest of the bridge does not.'));
		for (let p of ap.ports ?? [])
			if (!o.keylist.includes(p.name))
				o.value(p.name, choice(p.name, p.bridge ? [ p.bridge ] : []));

		o = s.option(CheckList, 'wifi', _('Wi-Fi (SSID)'),
			_('A selected SSID gets the fixed interface name xvpn-apN in /etc/config/wireless (an ifname set by you is kept), so the rules know it before Wi-Fi is up; the name is removed when the SSID is deselected. Selecting or deselecting an SSID runs "network reload": Wi-Fi clients may reconnect. SSIDs of a Wi-Fi-only network selected above get the name too.'));
		for (let w of ap.wifi ?? []) {
			const details = [];
			if (w.band)
				details.push(bandText(w.band));
			if (w.radio)
				details.push(w.radio);
			const net = L.toArray(w.network).join(' ');
			if (net)
				details.push(_('network %s').format(net));
			if (w.ifname)
				details.push(w.ifname);
			o.value(w.section, choice(w.ssid || w.section, details, w.disabled ? _('disabled') : null));
		}

		s = m.section(form.NamedSection, 'access', 'access', _('Protection'));
		s.addremove = false;

		o = s.option(form.Flag, 'killswitch', _('Kill switch'),
			_('When no server works, the VPN clients have no internet. Off: they go to the internet directly until a server works again. Only TCP and UDP go through the tunnel: ICMP (ping) and other protocols are rejected with the kill switch on and go directly with it off.'));
		o.default = '1';
		o.rmempty = false;

		o = s.option(form.Flag, 'dns_hijack', _('Intercept DNS'),
			_('DNS queries of the VPN clients to any server go to the DNS server below through the tunnel.'));
		o.default = '1';
		o.rmempty = false;

		o = s.option(form.Value, 'dns_server', _('DNS server'),
			_('A URL is DoH (https://) or DNS over TCP (tcp://) through the DNS module of xray: it answers only A and AAAA queries. An IP address: queries are forwarded to it, port 53, through the tunnel. Other schemes (+local) would query around the tunnel and are not accepted.'));
		o.placeholder = DEFAULT_DNS;
		o.value('https://cloudflare-dns.com/dns-query');
		o.value('https://dns.google/dns-query');
		o.value('https://dns.quad9.net/dns-query');
		o.value('1.1.1.1');
		o.value('8.8.8.8');
		o.validate = validDns;
		o.write = (sid, v) => uci.set('xvpn', sid, 'dns_server', v.trim());

		o = s.option(form.ListValue, 'ipv6', _('IPv6'),
			_('Block: IPv6 of the VPN clients is rejected, they fall back to IPv4. Tunnel: IPv6 TCP/UDP goes through the tunnel too; the server must have IPv6.'));
		o.value('block', _('Block'));
		o.value('tunnel', _('Tunnel'));
		o.default = 'block';

		// section descriptions are strings only: the warning goes in front of the first section
		return m.render().then((node) => {
			if (ap.flow_offloading || ap.flow_offloading_hw)
				node.insertBefore(E('div', { 'class': 'alert-message warning' }, [
					txt(ap.flow_offloading_hw
						? _('Hardware flow offloading is enabled in the firewall.')
						: _('Software flow offloading is enabled in the firewall.')),
					txt(' '),
					txt(_('Traffic of the VPN clients is redirected to xray and is not offloaded, but connections opened before the VPN started are offloaded and bypass it until they end. Reconnect the clients or restart the router after enabling the VPN.')),
				]), node.querySelector('.cbi-section'));
			return node;
		});
	},
});
