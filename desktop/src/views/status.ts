// Tab «Статус» (#78): state, kill switch, the active server with ping, speed and traffic,
// the service, "am I behind the VPN", autostart. Everything but traffic of the server
// comes with the shared poll; stats (it starts the xray api on the router) at most once
// in 30 s, like LuCI.

import { invokeRust } from '../api/transport';
import { StatsReply, Status, StatusUp } from '../api/xvpn';
import { AppContext } from '../core/connection';
import { checkVpn } from '../core/vpncheck';
import { t } from '../i18n/status';
import { byHand } from '../tray/model';
import { clear, h } from '../ui/dom';
import { errorText } from '../ui/errors';
import { bytes, duration, ping, speed } from '../ui/format';
import { registerView } from './registry';

export const STATS_EVERY_MS = 30_000;

// across mounts: switching tabs does not call stats again
let statsCache: { profile: string; at: number; data: StatsReply } | null = null;

function stateText(s: Status): string {
  if (!s.running)
    return s.timeout ? t('not_answering') : t('stopped');
  return t(`state.${s.state}`);
}

async function stats(ctx: AppContext, force = false): Promise<StatsReply | null> {
  const fresh = statsCache && statsCache.profile === ctx.profile.id && Date.now() - statsCache.at < STATS_EVERY_MS;
  if (fresh && !force)
    return statsCache!.data;
  const data = await ctx.xvpn.stats();
  statsCache = { profile: ctx.profile.id, at: Date.now(), data };
  return data;
}

registerView({
  id: 'status',
  order: 10,
  title: () => t('title'),
  mount(el, ctx) {
    let killswitch: boolean | null = null;
    let traffic: StatsReply | null = statsCache?.profile === ctx.profile.id ? statsCache.data : null;
    let actionError: string | null = null;

    const stateBox = h('div', { class: 'card state-card' });
    const serverBox = h('div', { class: 'card' });
    const serviceBox = h('div', { class: 'card' });
    const vpnResult = h('div');
    const vpnBtn = h('button', { onclick: () => void runVpnCheck() }, t('vpn_check'));
    const autostart = h('input', { type: 'checkbox', onchange: () => void setAutostart() });
    el.replaceChildren(h('section', { class: 'status' },
      h('h2', {}, t('title')),
      stateBox, serverBox, serviceBox,
      h('div', { class: 'card' },
        h('h3', {}, t('vpn_title')),
        h('p', { class: 'muted' }, t('vpn_hint')),
        vpnBtn, vpnResult),
      h('div', { class: 'card' },
        h('label', { class: 'check' }, autostart, ' ', t('autostart')),
        h('dl', { class: 'props' },
          h('dt', {}, t('router')), h('dd', {}, `${ctx.profile.name} (${ctx.profile.url})`),
          h('dt', {}, t('package')), h('dd', { id: 'pkg-version' }, ctx.pkg.version)))));

    const service = (action: 'start' | 'stop' | 'restart') => async () => {
      if (action === 'stop' && killswitch !== false && !confirm(t('confirm_stop')))
        return;
      actionError = null;
      try {
        const r = await ctx.xvpn.service(action);
        if (!r.ok)
          actionError = r.error ?? 'failed';
      }
      catch (e) {
        actionError = errorText(e);
      }
      await ctx.poller.refresh();
    };

    const render = (s: Status | null) => {
      if (!s) {
        clear(stateBox, h('p', { class: 'muted' }, t('waiting')));
        return;
      }
      const up: StatusUp | null = s.running ? s : null;
      clear(stateBox,
        h('div', { class: 'state-line' },
          h('span', { class: 'state-dot', 'data-state': up ? up.state : 'stopped' }, '●'),
          h('strong', { 'data-state': up ? up.state : 'stopped' }, stateText(s)),
          up ? h('span', { class: 'muted' }, ` · ${t('since', { d: duration(s.time - up.since) })}`) : null),
        h('dl', { class: 'props' },
          h('dt', {}, t('killswitch')), h('dd', {}, killswitch == null ? '—' : killswitch ? t('on') : t('off')),
          up?.last_error ? [h('dt', {}, t('error')), h('dd', { class: 'error-text' }, up.last_error)] : null),
        up?.passthrough ? h('p', { class: 'warn' }, t('passthrough')) : null);

      const active = up?.servers.find((x) => x.id === up.active);
      const own = active && traffic?.traffic[active.id];
      clear(serverBox,
        h('h3', {}, t('active')),
        active
          ? h('dl', { class: 'props' },
            h('dt', {}, t('active')), h('dd', { id: 'active-server' },
              h('strong', {}, active.name), h('span', { class: 'muted' }, ` · ${active.proto} ${active.address}:${active.port} · ${byHand(up!) ? t('by_hand') : t('by_auto')}`)),
            h('dt', {}, t('ping')), h('dd', {}, ping(active.latency)),
            up!.udp != null ? [h('dt', {}, t('udp')), h('dd', {}, up!.udp ? t('udp_ok') : t('udp_bad'))] : null,
            up!.speed !== undefined ? [h('dt', {}, t('speed')), h('dd', { id: 'speed' },
              up!.speed ? `↓ ${speed(up!.speed.down)}  ↑ ${speed(up!.speed.up)}` : t('speed_none'))] : null,
            up!.traffic ? [h('dt', {}, t('tunnel_traffic')), h('dd', {}, `↓ ${bytes(up!.traffic.down)}  ↑ ${bytes(up!.traffic.up)}`)] : null,
            own ? [h('dt', {}, t('server_traffic')), h('dd', { title: t('traffic_hint') }, `↓ ${bytes(own.down)}  ↑ ${bytes(own.up)}`)] : null)
          : h('p', { class: 'muted' }, '—'));

      clear(serviceBox,
        h('h3', {}, t('service')),
        h('div', { class: 'row' },
          h('button', { disabled: up != null && s.enabled, onclick: service('start') }, t('start')),
          h('button', { disabled: !s.enabled, onclick: service('stop') }, t('stop')),
          h('button', { disabled: !s.enabled, onclick: service('restart') }, t('restart'))),
        actionError ? h('p', { class: 'error' }, actionError) : null);
    };

    const runVpnCheck = async () => {
      const s = ctx.poller.status;
      vpnBtn.disabled = true;
      clear(vpnResult, h('p', { class: 'muted' }, t('vpn_checking')));
      try {
        const r = s?.running ? await checkVpn(s) : null;
        if (!r)
          clear(vpnResult, h('p', { class: 'muted' }, t('vpn_none')));
        else
          clear(vpnResult,
            h('p', { class: r.verdict === 'vpn' ? 'ok' : 'warn' },
              r.verdict === 'vpn' ? t('vpn_yes', { server: r.server })
                : t('vpn_no', { ip: r.publicIp, server: r.server, ips: r.serverIps.join(', ') || '?' })),
            h('p', { class: 'muted' }, t('vpn_ip', { ip: r.publicIp, source: r.source.replace(/^https:\/\//, '') })));
      }
      catch (e) {
        clear(vpnResult, h('p', { class: 'error' }, errorText(e)));
      }
      vpnBtn.disabled = false;
    };

    const setAutostart = async () => {
      try {
        await invokeRust('tray_autostart_set', { enabled: autostart.checked });
      }
      catch (e) {
        autostart.checked = !autostart.checked;
        actionError = errorText(e);
        render(ctx.poller.status);
      }
    };

    let alive = true;
    const refreshStats = () => stats(ctx).then((d) => {
      if (alive && d) {
        traffic = d;
        render(ctx.poller.status);
      }
    }, () => {});

    render(ctx.poller.status);
    void ctx.uci.get('xvpn', 'access', 'killswitch').then((v) => {
      // unset: on (util.uc load_config)
      killswitch = v == null ? true : v === '1' || v === 'true' || v === 'yes' || v === 'on';
      render(ctx.poller.status);
    }, () => {});
    void invokeRust<boolean>('tray_autostart_get').then((v) => { autostart.checked = v; }, () => { autostart.disabled = true; });
    void refreshStats();
    const timer = setInterval(refreshStats, STATS_EVERY_MS);
    const off = ctx.bus.on('status', ({ status }) => render(status));
    return () => {
      alive = false;
      clearInterval(timer);
      off();
    };
  },
});
