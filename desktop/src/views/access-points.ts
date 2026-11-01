// Tab «Точки доступа»: which networks, LAN ports and SSIDs go through the VPN (access
// section, the choices from luci.xvpn access_points) and split tunneling (split section,
// the state of the Russian list from luci.xvpn split, split_update). As the LuCI views
// access.js and split.js; saving goes through apply with rollback (src/forms/form.ts).

import { AccessPointsReply, SplitReply } from '../api/xvpn';
import { loadConfig } from '../core/apply';
import { UciForm, saveBar } from '../forms/form';
import { DEFAULTS, cidr, domain, eachLine, integer } from '../forms/validate';
import { t } from '../i18n/access-points';
import { Child, clear, h } from '../ui/dom';
import { errorText } from '../ui/errors';
import { ago } from '../ui/format';
import { registerView } from './registry';

const TYPES = { access: 'access', split: 'split' };
const SPLIT_POLL_MS = 5000;

const BANDS: Record<string, string> = { '2g': '2.4 GHz', '5g': '5 GHz', '6g': '6 GHz', '60g': '60 GHz' };

function choice(name: string, details: (string | undefined | null)[], warn?: string | null): Child {
  const d = details.filter((x): x is string => !!x);
  return h('span', {}, h('strong', {}, name), d.length ? ` (${d.join(', ')})` : '', warn ? h('span', { class: 'warn-text' }, ` ${warn}`) : null);
}

function splitStatus(st: SplitReply): Child[] {
  if (!st.ru)
    return [h('em', { class: 'muted' }, t('ru_off'))];
  const out: Child[] = [];
  out.push(h('div', {}, st.cached ? t('ru_cached', { v4: st.cached.v4, v6: st.cached.v6 }) : t('ru_not_yet')));
  if (st.last_ok)
    out.push(h('div', {}, t('ru_checked', { ago: ago(st.time, st.last_ok), via: st.via === 'tunnel' ? t('via_tunnel') : t('via_direct') })));
  if (st.error)
    out.push(h('div', { class: 'warn' }, t('ru_error', { error: st.error })));
  if (st.updating)
    out.push(h('div', {}, h('em', {}, t('ru_updating'))));
  return out;
}

registerView({
  id: 'access-points',
  order: 40,
  title: () => t('title'),
  mount(el, ctx) {
    let form: UciForm | null = null;
    let gen = 0;
    let timer: ReturnType<typeof setTimeout> | null = null;
    const body = h('div', {}, h('p', { class: 'muted' }, t('loading')));
    const listBox = h('div');
    const listMsg = h('span', { class: 'save-msg' });
    const bar = saveBar(ctx, { form: () => form, reload: () => void load() });
    const updateBtn = h('button', {
      onclick: async () => {
        updateBtn.disabled = true;
        listMsg.textContent = '';
        try {
          const r = await ctx.xvpn.splitUpdate();
          if (!r.ok)
            listMsg.textContent = t('update_failed', { error: r.error ?? '?' });
          await pollSplit();
        }
        catch (e) {
          listMsg.textContent = errorText(e);
        }
        finally {
          updateBtn.disabled = false;
        }
      },
    }, t('update_ru'));

    el.replaceChildren(h('section', { class: 'access-points' },
      h('h2', {}, t('title')),
      h('p', { class: 'muted' }, t('intro')),
      body, bar.el,
      h('div', { class: 'card' },
        h('h3', {}, t('ru_list')),
        listBox,
        h('div', { class: 'row' }, updateBtn, listMsg),
        h('small', { class: 'muted' }, t('ru_apply')))));

    const pollSplit = async () => {
      if (timer)
        clearTimeout(timer);
      timer = null;
      const my = gen;
      try {
        const st = await ctx.xvpn.split();
        if (my === gen)
          clear(listBox, splitStatus(st));
      }
      catch (e) {
        if (my === gen)
          listBox.replaceChildren(h('p', { class: 'error' }, errorText(e)));
      }
      if (my === gen)
        timer = setTimeout(() => void pollSplit(), SPLIT_POLL_MS);
    };

    const draw = (f: UciForm, ap: AccessPointsReply) => {
      const warn = ap.flow_offloading || ap.flow_offloading_hw
        ? h('p', { class: 'warn' }, ap.flow_offloading_hw ? t('offload_hw') : t('offload_sw'), ' ', t('offload_text'))
        : null;
      // a port may be listed by several bridge sections
      const ports = [...new Map(ap.ports.map((p) => [p.name, p])).values()];
      const points = h('div', { class: 'card' },
        h('h3', {}, t('points')),
        h('p', { class: 'muted' }, t('points_help')),
        f.checks('access', 'network', {
          label: t('networks'), help: t('networks_help'),
          choices: ap.networks.map((n) => ({ value: n.name, label: choice(n.name, [n.proto, n.device]) })),
        }),
        f.checks('access', 'port', {
          label: t('ports'), help: t('ports_help'),
          choices: ports.map((p) => ({ value: p.name, label: choice(p.name, [p.bridge]) })),
        }),
        f.checks('access', 'wifi', {
          label: t('wifi'), help: t('wifi_help'),
          choices: ap.wifi.map((w) => {
            const net = Array.isArray(w.network) ? w.network.join(' ') : w.network;
            return {
              value: w.section,
              label: choice(w.ssid || w.section, [w.band ? BANDS[w.band] ?? w.band : null, w.radio, net ? t('network', { name: net }) : null, w.ifname],
                w.disabled ? t('disabled') : null),
            };
          }),
        }));

      const split = h('div', { class: 'card' },
        h('h3', {}, t('split')),
        h('p', { class: 'muted' }, t('split_help')),
        f.lines('split', 'ip', {
          label: t('ip'), help: t('ip_help'), placeholder: '203.0.113.0/24', check: (v) => eachLine(v, cidr),
        }),
        f.flag('split', 'ru', { label: t('ru'), help: t('ru_help'), def: '0' }),
        f.text('split', 'ru_interval', {
          label: t('ru_interval'), placeholder: DEFAULTS.ru_interval, check: (v) => integer(v, 1, 8760),
          visible: () => f.value('split', 'ru') === '1',
        }),
        f.lines('split', 'domain', {
          label: t('domains'), help: t('domains_help'), placeholder: 'example.ru', lower: true, check: (v) => eachLine(v, domain),
        }));
      clear(body, warn, points, split);
      f.validateAll();
    };

    const load = async () => {
      const my = ++gen;
      try {
        const [sections, ap] = await Promise.all([loadConfig(ctx.uci), ctx.xvpn.accessPoints()]);
        if (my !== gen)
          return;
        form = new UciForm(sections, TYPES);
        draw(form, ap);
      }
      catch (e) {
        if (my === gen)
          body.replaceChildren(h('p', { class: 'error' }, errorText(e)));
      }
      if (my === gen)
        void pollSplit();
    };
    void load();
    return () => {
      gen++;
      if (timer)
        clearTimeout(timer);
    };
  },
});
