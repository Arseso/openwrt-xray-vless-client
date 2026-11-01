// Tab «Серверы» (#78): the servers of the daemon with ping, quarantine, restricted access
// and auto selection (#60); Use (select), Auto (set_auto), Test all (test). The list
// comes with the shared poll, no call of its own.

import { DaemonServer, Status } from '../api/xvpn';
import { t } from '../i18n/servers';
import { clear, h } from '../ui/dom';
import { errorText } from '../ui/errors';
import { ping } from '../ui/format';
import { registerView } from './registry';

export function matches(s: DaemonServer, q: string): boolean {
  if (!q)
    return true;
  const hay = `${s.name} ${s.address}:${s.port} ${s.proto} ${s.sub_name ?? ''}`.toLowerCase();
  return q.toLowerCase().split(/\s+/).every((w) => hay.includes(w));
}

registerView({
  id: 'servers',
  order: 20,
  title: () => t('title'),
  mount(el, ctx) {
    let query = '';
    let busy = false;
    // test(): done once status.tests reaches this run
    let waitRun: number | null = null;
    let testsAt = 0;
    let error: string | null = null;

    const testBtn = h('button', { class: 'primary' }, t('test_all'));
    const filter = h('input', { type: 'search', placeholder: t('filter'), oninput: () => { query = filter.value.trim(); render(ctx.poller.status); } });
    const note = h('div');
    const table = h('div', { class: 'servers' });
    el.replaceChildren(h('section', {},
      h('div', { class: 'toolbar' }, h('h2', {}, t('title')), h('span', { class: 'spacer' }), testBtn),
      filter, note, table));

    const act = async (fn: () => Promise<{ ok: boolean; error?: string }>) => {
      busy = true;
      error = null;
      render(ctx.poller.status);
      try {
        const r = await fn();
        if (!r.ok)
          error = r.error ?? 'failed';
      }
      catch (e) {
        error = errorText(e);
      }
      busy = false;
      await ctx.poller.refresh();
    };

    testBtn.onclick = () => void act(async () => {
      const r = await ctx.xvpn.test();
      if (r.ok && r.run != null)
        waitRun = r.run;
      return r;
    });

    const row = (s: DaemonServer, active: boolean, online: boolean) => {
      const flags = [
        active && h('span', { class: 'badge ok' }, t('active')),
        s.quarantined && h('span', { class: 'badge warn', title: t('quarantined_hint') }, t('quarantined')),
        s.limited && h('span', { class: 'badge warn', title: t('limited_hint') }, t('limited')),
        !s.auto && h('span', { class: 'badge', title: t('auto_hint') }, t('excluded')),
      ];
      const auto = h('input', {
        type: 'checkbox', checked: s.auto, disabled: !online || busy, title: t('auto_hint'),
        onchange: () => void act(() => ctx.xvpn.setAuto(s.id, auto.checked)),
      });
      return h('tr', { class: active ? 'active' : '', 'data-id': s.id },
        h('td', {}, h('div', {}, s.name), h('small', { class: 'muted' }, s.sub_name ?? t('manual'))),
        h('td', {}, s.proto),
        h('td', { class: 'mono' }, `${s.address}:${s.port}`),
        h('td', { class: 'num' }, ping(s.latency)),
        h('td', {}, flags),
        h('td', {}, auto),
        h('td', {}, h('button', {
          disabled: active || !online || busy,
          onclick: () => void act(() => ctx.xvpn.select(s.id)),
        }, t('use'))));
    };

    const render = (st: Status | null) => {
      const up = st?.running ? st : null;
      // done; or the daemon restarted (its counter starts over) or went away
      if (waitRun != null && (!up || up.tests >= waitRun || up.tests < testsAt))
        waitRun = null;
      if (up)
        testsAt = up.tests;
      const testing = !!up && (up.testing || waitRun != null);
      testBtn.disabled = !up || busy || testing;
      testBtn.textContent = testing ? t('testing') : t('test_all');
      clear(note,
        error ? h('p', { class: 'error' }, error) : null,
        st && !up ? h('p', { class: 'warn' }, t('stopped')) : null);
      const all = up?.servers ?? [];
      const list = all.filter((s) => matches(s, query));
      clear(table,
        !all.length ? h('p', { class: 'muted' }, up ? t('empty') : '') : !list.length ? h('p', { class: 'muted' }, t('none_match')) : h('table', {},
          h('thead', {}, h('tr', {},
            h('th', {}, t('name')), h('th', {}, t('proto')), h('th', {}, t('address')), h('th', { class: 'num' }, t('ping')),
            h('th', {}), h('th', { title: t('auto_hint') }, t('auto')), h('th', {}))),
          h('tbody', {}, list.map((s) => row(s, s.id === up!.active, !!up)))),
        all.length ? h('p', { class: 'muted' }, t('count', { n: all.length })) : null);
    };

    render(ctx.poller.status);
    return ctx.bus.on('status', ({ status }) => render(status));
  },
});
