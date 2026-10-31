// Notifications tab: the poll interval, quiet hours and the kinds of notifications
// (src/core/notify.ts). Saved at once on each change, on this PC.

import {
  INTERVAL_MAX_MS, INTERVAL_MIN_MS, NOTIFY_TYPES, NotifySettings, inQuietHours, loadSettings, saveSettings,
  showSystem,
} from '../core/notify';
import { t } from '../i18n/notifications';
import { h } from '../ui/dom';
import { errorText } from '../ui/errors';
import { registerView } from './registry';

registerView({
  id: 'notifications',
  order: 80,
  title: () => t('title'),
  mount(el) {
    const note = h('p', { class: 'muted' });
    const update = (patch: (s: NotifySettings) => void) => {
      const s = structuredClone(loadSettings());
      patch(s);
      render(saveSettings(s));
    };
    const num = (v: string) => Number(v.trim() === '' ? NaN : v);

    const render = (s: NotifySettings) => {
      note.textContent = inQuietHours(new Date(), s.quiet) ? t('quiet_now') : '';
      el.replaceChildren(h('section', { class: 'notify-settings' },
        h('h2', {}, t('title')),
        h('p', { class: 'muted' }, t('stored_here')),

        h('div', { class: 'card' },
          h('h3', {}, t('poll')),
          h('label', {}, t('interval'), ' ',
            h('input', {
              type: 'number', min: INTERVAL_MIN_MS / 1000, max: INTERVAL_MAX_MS / 1000, step: 1, class: 'short',
              value: String(s.intervalMs / 1000),
              onchange: (e: Event) => update((x) => {
                x.intervalMs = num((e.target as HTMLInputElement).value) * 1000;
              }),
            })),
          h('p', { class: 'muted' }, t('interval_hint'))),

        h('div', { class: 'card' },
          h('h3', {}, t('quiet')),
          h('label', { class: 'check' },
            h('input', {
              type: 'checkbox', checked: s.quiet.enabled,
              onchange: (e: Event) => update((x) => {
                x.quiet.enabled = (e.target as HTMLInputElement).checked;
              }),
            }),
            t('quiet_on'), ' ',
            h('input', {
              type: 'time', class: 'short', value: s.quiet.from,
              onchange: (e: Event) => update((x) => {
                x.quiet.from = (e.target as HTMLInputElement).value;
              }),
            }),
            ' ', t('quiet_to'), ' ',
            h('input', {
              type: 'time', class: 'short', value: s.quiet.to,
              onchange: (e: Event) => update((x) => {
                x.quiet.to = (e.target as HTMLInputElement).value;
              }),
            })),
          note),

        h('div', { class: 'card' },
          h('h3', {}, t('kinds')),
          NOTIFY_TYPES.map((k) => h('label', { class: 'check' },
            h('input', {
              type: 'checkbox', checked: s.types[k],
              onchange: (e: Event) => update((x) => {
                x.types[k] = (e.target as HTMLInputElement).checked;
              }),
            }),
            t(`type.${k}`))),
          h('label', {}, t('expire_days'), ' ',
            h('input', {
              type: 'number', min: 1, max: 60, step: 1, class: 'short', value: String(s.expireDays),
              onchange: (e: Event) => update((x) => {
                x.expireDays = num((e.target as HTMLInputElement).value);
              }),
            })),
          h('label', {}, t('traffic_pct'), ' ',
            h('input', {
              type: 'number', min: 50, max: 100, step: 1, class: 'short', value: String(s.trafficPct),
              onchange: (e: Event) => update((x) => {
                x.trafficPct = num((e.target as HTMLInputElement).value);
              }),
            }))),

        h('div', { class: 'row' }, test)));
    };

    const result = h('span', { class: 'muted' });
    const test = h('span', {},
      h('button', {
        onclick: () => {
          result.textContent = '';
          // Ok means handed over: the system may still not show it (no notification daemon)
          Promise.resolve(showSystem(t('test_title'), t('test_body')))
            .then(() => {
              result.textContent = t('test_sent');
            }, (e: unknown) => {
              result.textContent = t('test_failed', { error: errorText(e) });
            });
        },
      }, t('test')), ' ', result);

    render(loadSettings());
    // the quiet note follows the clock
    const tick = setInterval(() => {
      note.textContent = inQuietHours(new Date(), loadSettings().quiet) ? t('quiet_now') : '';
    }, 60_000);
    return () => clearInterval(tick);
  },
});
