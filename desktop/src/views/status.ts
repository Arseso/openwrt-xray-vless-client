// Tab «Статус» (#78): state, kill switch, the active server with ping, speed and traffic,
// the service, "am I behind the VPN", autostart. Everything but traffic of the server
// comes with the shared poll; stats (it starts the xray api on the router) at most once
// in 30 s, like LuCI.

import { invokeRust } from '../api/transport';
import { StatsReply, Status, StatusUp } from '../api/xvpn';
import { AppContext } from '../core/connection';
import { FamilyCheck, SERVICES, checkVpn } from '../core/vpncheck';
import { t } from '../i18n/status';
import { byHand } from '../tray/model';
import { clear, h } from '../ui/dom';
import { errorText } from '../ui/errors';
import { bytes, dur, ping, speed } from '../ui/format';
import { registerView } from './registry';

export const STATS_EVERY_MS = 30_000;

// across mounts: switching tabs does not call stats again; the time of the attempt, so a
// failing stats is not retried on every mount either, and one call shared by all callers
let statsCache: { profile: string; at: number; data: StatsReply | null } | null = null;
let statsCall: { profile: string; p: Promise<StatsReply | null> } | null = null;

function stateText(s: Status): string {
  if (!s.running)
    return s.timeout ? t('not_answering') : t('stopped');
  return t(`state.${s.state}`);
}

function stats(ctx: AppContext): Promise<StatsReply | null> {
  const id = ctx.profile.id;
  if (statsCache && statsCache.profile === id && Date.now() - statsCache.at < STATS_EVERY_MS)
    return Promise.resolve(statsCache.data);
  if (statsCall?.profile === id)
    return statsCall.p;
  const p = ctx.xvpn.stats().then((data) => data, () => null).then((data) => {
    statsCache = { profile: id, at: Date.now(), data: data ?? (statsCache?.profile === id ? statsCache.data : null) };
    statsCall = null;
    return statsCache.data;
  });
  statsCall = { profile: id, p };
  return p;
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
    const vpnOther = h('button', { class: 'link', onclick: () => void runVpnCheck(true) }, t('vpn_other', { services: SERVICES.other }));
    const autostart = h('input', { type: 'checkbox', onchange: () => void setAutostart() });
    el.replaceChildren(h('section', { class: 'status' },
      h('h2', {}, t('title')),
      stateBox, serverBox, serviceBox,
      h('div', { class: 'card' },
        h('h3', {}, t('vpn_title')),
        h('p', { class: 'muted' }, t('vpn_hint', { services: SERVICES.main })),
        h('div', { class: 'row' }, vpnBtn, vpnOther), vpnResult),
      h('div', { class: 'card' },
        h('label', { class: 'check' }, autostart, ' ', t('autostart')),
        h('dl', { class: 'props' },
          h('dt', {}, t('router')), h('dd', {}, `${ctx.profile.name} (${ctx.profile.url})`),
          h('dt', {}, t('package')), h('dd', { id: 'pkg-version' }, ctx.pkg.version)))));

    const act = (fn: () => Promise<{ ok: boolean; error?: string }>) => async () => {
      actionError = null;
      try {
        const r = await fn();
        if (!r.ok)
          actionError = r.error ?? 'failed';
      }
      catch (e) {
        actionError = errorText(e);
      }
      await ctx.poller.refresh();
    };
    const service = (action: 'start' | 'stop' | 'restart') => async () => {
      if (action === 'stop' && killswitch !== false && !confirm(t('confirm_stop')))
        return;
      await act(() => ctx.xvpn.service(action))();
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
          up ? h('span', { class: 'muted' }, ` · ${t('since', { d: dur(s.time - up.since) })}`) : null),
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
              h('strong', {}, active.name), h('span', { class: 'muted' }, ` · ${active.proto} ${active.address}:${active.port}`),
              byHand(up!) == null ? null : h('span', { class: 'muted' }, ` · ${byHand(up!) ? t('by_hand') : t('by_auto')}`),
              byHand(up!) ? [' ', h('button', { onclick: act(() => ctx.xvpn.auto()) }, t('back_auto'))] : null),
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

    const runVpnCheck = async (other = false) => {
      const s = ctx.poller.status;
      vpnBtn.disabled = vpnOther.disabled = true;
      clear(vpnResult, h('p', { class: 'muted' }, t('vpn_checking')));
      try {
        const r = s?.running ? await checkVpn(s, undefined, other) : null;
        if (!r) {
          clear(vpnResult, h('p', { class: 'muted' }, t('vpn_none')));
        }
        else {
          const ips = r.serverIps.join(', ') || '?';
          const line = (f: FamilyCheck) => {
            const family = f.family === 'v4' ? 'IPv4' : 'IPv6';
            if (!f.ip)
              return h('li', { class: 'muted' }, t('vpn_family_none', { family, error: f.error ?? '' }));
            const text = t(f.verdict === 'vpn' ? 'vpn_family_yes' : 'vpn_family_no', { family, ip: f.ip, server: `${r.server} (${ips})` });
            return h('li', { class: f.verdict === 'vpn' ? 'ok' : f.verdict === 'direct' ? 'warn-text' : '' }, text);
          };
          const any = [r.v4, r.v6].filter((f) => f.verdict);
          const all = any.length > 0 && any.every((f) => f.verdict === 'vpn');
          clear(vpnResult,
            r.resolveError ? h('p', { class: 'error' }, t('vpn_resolve_failed', { server: r.server, error: r.resolveError })) : null,
            any.length ? h('p', { class: all ? 'ok' : 'warn' },
              all ? t('vpn_yes', { server: r.server })
                : t('vpn_no', { ip: any.find((f) => f.verdict === 'direct')!.ip!, server: r.server, ips })) : null,
            h('ul', { class: 'plain' }, line(r.v4), line(r.v6)));
        }
      }
      catch (e) {
        clear(vpnResult, h('p', { class: 'error' }, errorText(e)));
      }
      vpnBtn.disabled = vpnOther.disabled = false;
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
