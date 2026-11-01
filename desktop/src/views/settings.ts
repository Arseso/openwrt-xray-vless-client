// Tab «Настройки»: the main options of the xvpn config — health checks and server
// choice (health), kill switch, DNS and IPv6 (access), the log level and sniffing of
// xray (main). The ports, marks and routing table stay in LuCI. The checks are those of
// the LuCI views settings.js / access.js and of util.uc load_config(); saving goes
// through apply with rollback (src/forms/form.ts).

import { loadConfig } from '../core/apply';
import { UciForm, saveBar } from '../forms/form';
import { DEFAULTS, dnsServer, httpUrl, integer, secondUrl, timeoutShorter } from '../forms/validate';
import { t } from '../i18n/settings';
import { h } from '../ui/dom';
import { errorText } from '../ui/errors';
import { registerView } from './registry';

const TYPES = { main: 'general', health: 'health', access: 'access' };

registerView({
  id: 'settings',
  order: 50,
  title: () => t('title'),
  mount(el, ctx) {
    let form: UciForm | null = null;
    let gen = 0;
    const body = h('div', {}, h('p', { class: 'muted' }, t('loading')));
    const bar = saveBar(ctx, { form: () => form, reload: () => void load() });
    el.replaceChildren(h('section', { class: 'settings' },
      h('h2', {}, t('title')),
      h('p', { class: 'muted' }, t('intro')),
      body, bar.el));

    const int = (min: number, max: number, also?: (v: string) => string | null) =>
      (v: string) => integer(v, min, max) ?? also?.(v) ?? null;

    const draw = (f: UciForm) => {
      const v = (s: string, o: string) => f.value(s, o);
      const health = h('div', { class: 'card' },
        h('h3', {}, t('health')),
        h('p', { class: 'muted' }, t('health_help')),
        f.text('health', 'url', {
          label: t('url'), help: t('url_help'), placeholder: DEFAULTS.url, check: (x) => httpUrl(x),
          suggest: ['https://www.gstatic.com/generate_204', 'https://cp.cloudflare.com/generate_204', 'http://www.msftconnecttest.com/connecttest.txt'],
        }),
        f.text('health', 'url2', {
          label: t('url2'), help: t('url2_help'), placeholder: DEFAULTS.url2, suggest: ['https://cp.cloudflare.com/generate_204', 'off'],
          check: (x) => secondUrl(x, v('health', 'url')),
        }),
        f.text('health', 'dl_url', {
          label: t('dl_url'), help: t('dl_url_help'), placeholder: DEFAULTS.dl_url, suggest: ['off'], check: (x) => httpUrl(x, true),
        }),
        f.text('health', 'interval', {
          label: t('interval'), help: t('interval_help'), placeholder: DEFAULTS.interval,
          check: int(5, 3600, (x) => timeoutShorter(v('health', 'timeout'), x)),
        }),
        f.text('health', 'timeout', {
          label: t('timeout'), help: t('timeout_help'), placeholder: DEFAULTS.timeout,
          check: int(1, 60, (x) => timeoutShorter(x, v('health', 'interval'))),
        }),
        f.text('health', 'fail_threshold', {
          label: t('fail_threshold'), help: t('fail_threshold_help'), placeholder: DEFAULTS.fail_threshold, check: int(1, 100),
        }),
        f.text('health', 'rank_interval', {
          label: t('rank_interval'), help: t('rank_interval_help'), placeholder: DEFAULTS.rank_interval, check: int(60, 86400),
        }),
        f.text('health', 'quarantine', {
          label: t('quarantine'), help: t('quarantine_help'), placeholder: DEFAULTS.quarantine, check: int(0, 86400),
        }),
        f.text('health', 'concurrency', {
          label: t('concurrency'), help: t('concurrency_help'), placeholder: DEFAULTS.concurrency, check: int(1, 8),
        }),
        // #95: the server with the best ping may be the slowest one for video and downloads
        f.select('health', 'auto_mode', {
          label: t('auto_mode'), help: t('auto_mode_help'), def: DEFAULTS.auto_mode,
          choices: [['ping', t('mode_ping')], ['speed', t('mode_speed')], ['balanced', t('mode_balanced')]],
        }),
        f.text('health', 'speedtest_url', {
          label: t('speedtest_url'), help: t('speedtest_url_help'), placeholder: DEFAULTS.speedtest_url, suggest: [DEFAULTS.speedtest_url, 'off'],
          check: (x) => httpUrl(x, true),
        }),
        f.text('health', 'speedtest_interval', {
          label: t('speedtest_interval'), help: t('speedtest_interval_help'), placeholder: DEFAULTS.speedtest_interval, check: int(1800, 604800),
          visible: () => v('health', 'auto_mode') !== 'ping',
        }),
        f.flag('health', 'auto_best', { label: t('auto_best'), help: t('auto_best_help'), def: '0' }),
        f.text('health', 'hysteresis', {
          label: t('hysteresis'), help: t('hysteresis_help'), placeholder: DEFAULTS.hysteresis, check: int(0, 10000),
          visible: () => v('health', 'auto_best') === '1',
        }),
        f.text('health', 'speed_hysteresis', {
          label: t('speed_hysteresis'), help: t('speed_hysteresis_help'), placeholder: DEFAULTS.speed_hysteresis, check: int(0, 1000),
          visible: () => v('health', 'auto_best') === '1' && v('health', 'auto_mode') !== 'ping',
        }));

      const protection = h('div', { class: 'card' },
        h('h3', {}, t('protection')),
        f.flag('access', 'killswitch', { label: t('killswitch'), help: t('killswitch_help'), def: '1' }),
        f.flag('access', 'dns_hijack', { label: t('dns_hijack'), help: t('dns_hijack_help'), def: '1' }),
        f.text('access', 'dns_server', {
          label: t('dns_server'), help: t('dns_server_help'), placeholder: DEFAULTS.dns_server, check: dnsServer,
          suggest: ['https://cloudflare-dns.com/dns-query', 'https://dns.google/dns-query', 'https://dns.quad9.net/dns-query', '1.1.1.1', '8.8.8.8'],
        }),
        f.select('access', 'ipv6', {
          label: 'IPv6', help: t('ipv6_help'), def: 'block', choices: [['block', t('ipv6_block')], ['tunnel', t('ipv6_tunnel')]],
        }));

      const xray = h('div', { class: 'card' },
        h('h3', {}, 'xray'),
        f.select('main', 'loglevel', {
          label: t('loglevel'), help: t('loglevel_help'), def: DEFAULTS.loglevel,
          choices: [['debug', 'debug'], ['info', 'info'], ['warning', 'warning'], ['error', 'error'], ['none', 'none']],
        }),
        f.flag('main', 'sniffing', { label: t('sniffing'), help: t('sniffing_help'), def: '1' }),
        f.flag('main', 'block_bittorrent', { label: t('block_bittorrent'), help: t('block_bittorrent_help'), def: '0' }));

      body.replaceChildren(health, protection, xray);
      f.validateAll();
    };

    const load = async () => {
      const my = ++gen;
      try {
        const sections = await loadConfig(ctx.uci);
        if (my !== gen)
          return;
        form = new UciForm(sections, TYPES);
        draw(form);
      }
      catch (e) {
        if (my === gen)
          body.replaceChildren(h('p', { class: 'error' }, errorText(e)));
      }
    };
    void load();
    return () => {
      gen++;
    };
  },
});
