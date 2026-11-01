// Tab «Журнал»: the last lines of xvpn, its daemon and xray in the system log
// (luci.xvpn log), filtered by text or /regex/, source and errors, refreshed every
// 10 s; the shown lines go to the clipboard. «Diagnostics» saves one text file with the
// versions, status, firewall, config and log without secrets (src/core/diagnostics.ts).

import { collectDiagnostics } from '../core/diagnostics';
import { t } from '../i18n/log';
import { h } from '../ui/dom';
import { errorText } from '../ui/errors';
import { appVersion, saveTextFile, writeClipboard } from '../ui/native';
import { registerView } from './registry';

// rpcd serves nothing else while it reads the log (as in log.js)
const REFRESH_MS = 10_000;

export type Source = '' | 'xvpn' | 'xray';

// logread lines: "Tue Oct 27 10:00:00 2026 user.notice xvpn: …"; the backend sends only
// the lines tagged xvpn, ucode (xvpnd itself) and those of xray
const XVPN = / (xvpn|ucode)(\[\d+\])?: /;
const ERRORS = /\.(err|crit|alert|emerg)\b|\berror\b|\bfailed\b/i;

/** a matcher of the filter: case-insensitive text, a regex when written as /…/; throws on a bad regex */
export function matcher(query: string): (line: string) => boolean {
  const q = query.trim();
  if (!q)
    return () => true;
  const re = /^\/(.+)\/$/.exec(q);
  if (re) {
    const r = new RegExp(re[1], 'i');
    return (l) => r.test(l);
  }
  const s = q.toLowerCase();
  return (l) => l.toLowerCase().includes(s);
}

export function filterLog(lines: string[], o: { query: string; source: Source; errors: boolean }): string[] {
  const match = matcher(o.query);
  return lines.filter((l) => (o.source === '' || (o.source === 'xvpn') === XVPN.test(l))
    && (!o.errors || ERRORS.test(l)) && match(l));
}

function stamp(d: Date): string {
  const p = (n: number) => String(n).padStart(2, '0');
  return `${d.getFullYear()}${p(d.getMonth() + 1)}${p(d.getDate())}-${p(d.getHours())}${p(d.getMinutes())}`;
}

registerView({
  id: 'log',
  order: 60,
  title: () => t('title'),
  mount(el, ctx) {
    let all: string[] = [];
    let shown: string[] = [];
    let gen = 0;
    let timer: ReturnType<typeof setTimeout> | null = null;

    const query = h('input', { type: 'text', class: 'log-query', placeholder: t('filter'), spellcheck: false, oninput: () => show() });
    const source = h('select', { onchange: () => show() },
      h('option', { value: '' }, t('all_sources')), h('option', { value: 'xvpn' }, 'xvpn'), h('option', { value: 'xray' }, 'xray'));
    const errors = h('input', { type: 'checkbox', onchange: () => show() });
    const auto = h('input', { type: 'checkbox', checked: true, onchange: () => schedule() });
    const count = h('span', { class: 'muted' });
    const msg = h('span', { class: 'save-msg' });
    const pre = h('pre', { class: 'log' });
    const say = (text: string, cls = 'muted') => {
      msg.textContent = text;
      msg.className = `save-msg ${cls}`;
    };

    const copy = h('button', {
      onclick: async () => {
        try {
          await writeClipboard(shown.join('\n'));
          say(t('copied', { n: shown.length }), 'ok-text');
        }
        catch (e) {
          say(errorText(e), 'error-text');
        }
      },
    }, t('copy'));
    const diag = h('button', {
      onclick: async () => {
        diag.disabled = true;
        say(t('collecting'));
        try {
          const now = new Date();
          const text = await collectDiagnostics(ctx, { app: await appVersion(), now });
          const saved = await saveTextFile(`xvpn-diagnostics-${stamp(now)}.txt`, text);
          say(saved ? t('saved') : '', 'ok-text');
        }
        catch (e) {
          say(t('save_failed', { error: errorText(e) }), 'error-text');
        }
        finally {
          diag.disabled = false;
        }
      },
    }, t('diagnostics'));

    el.replaceChildren(h('section', { class: 'log-view' },
      h('h2', {}, t('title')),
      h('p', { class: 'muted' }, t('intro')),
      h('div', { class: 'row log-tools' },
        query, source,
        h('label', { class: 'check' }, errors, t('errors_only')),
        h('label', { class: 'check' }, auto, t('auto', { s: REFRESH_MS / 1000 })),
        h('button', { onclick: () => void refresh(true) }, t('refresh')),
        copy, diag),
      h('div', { class: 'row' }, count, msg),
      pre));

    function show(): void {
      // the view stays at the bottom only if it was there: reading older lines goes on
      const bottom = pre.scrollTop + pre.clientHeight >= pre.scrollHeight - 4;
      let bad = false;
      try {
        shown = filterLog(all, { query: query.value, source: source.value as Source, errors: errors.checked });
      }
      catch {
        bad = true;
        shown = filterLog(all, { query: '', source: source.value as Source, errors: errors.checked });
      }
      query.classList.toggle('invalid', bad);
      // lines of the log are text only
      pre.textContent = shown.join('\n');
      count.textContent = all.length ? t('count', { n: shown.length, total: all.length }) : t('empty');
      copy.disabled = !shown.length;
      if (bottom)
        pre.scrollTop = pre.scrollHeight;
    }

    function schedule(): void {
      if (timer)
        clearTimeout(timer);
      timer = auto.checked ? setTimeout(() => void refresh(false), REFRESH_MS) : null;
    }

    async function refresh(force: boolean): Promise<void> {
      const my = gen;
      // a redraw would drop the text selected in the log
      const sel = getSelection();
      if (!force && sel && !sel.isCollapsed && pre.contains(sel.anchorNode))
        return schedule();
      try {
        const r = await ctx.xvpn.log();
        if (my !== gen)
          return;
        all = (r.log ?? '').split('\n').filter((l) => l.trim());
        show();
      }
      catch (e) {
        if (my === gen)
          say(errorText(e), 'error-text');
      }
      if (my === gen)
        schedule();
    }

    void refresh(true).then(() => {
      pre.scrollTop = pre.scrollHeight;
    });
    return () => {
      gen++;
      if (timer)
        clearTimeout(timer);
    };
  },
});
