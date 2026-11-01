// Tab «Подписки»: the subscriptions of the xvpn config with their update state, traffic
// and expiry (subscription-userinfo, from luci.xvpn subscriptions), update one or all,
// add / edit / delete, and the manual share links checked by luci.xvpn parse_links. A
// share link or a subscription URL in the clipboard is imported with one button. As the
// LuCI view subscriptions.js; saving goes through apply with rollback (src/forms/form.ts).

import { UciSection } from '../api/uci';
import { ParsedLink, Subscription, SubscriptionsReply } from '../api/xvpn';
import { Edit, loadConfig } from '../core/apply';
import { AppContext } from '../core/connection';
import { optionValue, uciBool } from '../forms/diff';
import { SaveOutcome, UciForm, saveBar } from '../forms/form';
import { DEFAULTS, SHARE_LINK, integer, lines, regex, required, subscriptionUrl } from '../forms/validate';
import { t as tf } from '../i18n/forms';
import { t } from '../i18n/subscriptions';
import { Child, clear, h } from '../ui/dom';
import { errorText } from '../ui/errors';
import { ago, bytes, date, dur } from '../ui/format';
import { readClipboard } from '../ui/native';
import { registerView } from './registry';

const POLL_MS = 5000;
const CHECK_DELAY_MS = 400;
/** luci.xvpn parse_links takes up to 200 links a call */
const PARSE_MAX = 200;

/** sections made by the app get a fixed name, like in LuCI: the cache of the router is kept under it */
export function newSubscriptionName(): string {
  const rnd = new Uint8Array(4);
  crypto.getRandomValues(rnd);
  return `sub_${Array.from(rnd, (b) => b.toString(16).padStart(2, '0')).join('')}`;
}

/** the name of a new subscription from its URL: the host only, user info before @ may be its token */
export function nameFromUrl(url: string): string {
  try {
    return new URL(url.trim()).hostname;
  }
  catch {
    return '';
  }
}

function manualText(s: UciSection | undefined): string {
  const v = optionValue(s, 'link');
  return (v == null ? [] : Array.isArray(v) ? v : [v]).join('\n');
}

function updateError(err: string | undefined): string {
  switch (err) {
  case 'busy': return t('err_busy');
  case 'not running': return t('err_not_running');
  case 'timeout': return t('err_timeout');
  case 'no subscriptions to update': return t('err_nothing');
  default: return err ?? '?';
  }
}

function statusLines(s: Subscription | undefined, now: number, updating: boolean): Child[] {
  if (!s)
    return [h('em', { class: 'muted' }, t('not_applied'))];
  const out: Child[] = [];
  out.push(h('div', {}, t('servers', { n: s.count }), s.skipped ? ` ${t('skipped', { n: s.skipped })}` : '', s.format ? `, ${s.format}` : ''));
  if (s.error)
    out.push(h('div', { class: 'error-text' }, t('error', { error: s.error }), s.last_attempt ? ` (${ago(now, s.last_attempt)})` : ''));
  out.push(h('div', {}, t('updated', { ago: ago(now, s.last_ok) }),
    s.last_ok && s.via ? ` (${s.via === 'tunnel' ? t('via_tunnel') : t('via_direct')})` : '',
    s.updated && s.last_ok && s.updated !== s.last_ok ? `, ${t('changed', { ago: ago(now, s.updated) })}` : ''));
  if (updating)
    out.push(h('div', {}, h('em', {}, t('updating'))));
  else if (s.enabled && s.due_in != null)
    out.push(h('div', { class: 'muted' }, t('next', { when: s.due_in <= 0 ? t('due') : t('in', { d: dur(s.due_in) }) })));
  return out;
}

function trafficLines(s: Subscription | undefined, now: number): Child[] {
  const u = s?.userinfo;
  if (!u)
    return [h('span', { class: 'muted' }, '—')];
  const used = (u.upload ?? 0) + (u.download ?? 0);
  const out: Child[] = [];
  if (u.total && u.total > 0) {
    const pct = Math.min(100, Math.round(used / u.total * 100));
    out.push(h('div', {}, h('progress', { max: 100, value: pct }), ` ${bytes(used)} / ${bytes(u.total)} (${pct}%)`));
  }
  else
    out.push(h('div', {}, `${bytes(used)} / ∞`));
  if (u.expire && u.expire > 0) {
    const left = u.expire - now, days = Math.floor(left / 86400);
    const text = `${t('until', { date: date(u.expire) })} (${days ? t('days_left', { n: days }) : t('less_day')})`;
    out.push(left <= 0 ? h('div', { class: 'error-text' }, t('expired', { date: date(u.expire) }))
      : h('div', { class: left < 3 * 86400 ? 'warn-text' : 'muted' }, text));
  }
  else
    out.push(h('div', { class: 'muted' }, t('no_expiry')));
  return out;
}

/** the manual links: each line checked by the parser of the router while typing */
class LinksCheck {
  private parsed = new Map<string, ParsedLink>();
  private failed: string | null = null;
  private timer: ReturnType<typeof setTimeout> | null = null;
  private value = '';

  constructor(private readonly ctx: AppContext, private readonly results: HTMLElement, private readonly onDone: () => void) {}

  set(value: string): void {
    this.value = value;
    if (this.timer)
      clearTimeout(this.timer);
    this.timer = setTimeout(() => void this.run(), CHECK_DELAY_MS);
    this.show();
  }

  stop(): void {
    if (this.timer)
      clearTimeout(this.timer);
  }

  private async run(): Promise<void> {
    const todo = [...new Set(lines(this.value).filter((l) => SHARE_LINK.test(l) && !this.parsed.has(l)))].slice(0, PARSE_MAX);
    if (todo.length) {
      try {
        const r = await this.ctx.xvpn.parseLinks(todo);
        if (!r.links || r.links.length !== todo.length)
          this.failed = r.error ?? t('unexpected');
        else {
          this.failed = null;
          r.links.forEach((p, i) => this.parsed.set(todo[i], p));
        }
      }
      catch (e) {
        this.failed = errorText(e);
      }
      // more than PARSE_MAX new lines: the next call takes the rest
      if (!this.failed && lines(this.value).some((l) => SHARE_LINK.test(l) && !this.parsed.has(l)))
        this.timer = setTimeout(() => void this.run(), 0);
    }
    this.show();
    this.onDone();
  }

  /** null when every line is a link the router can use */
  problem(): string | null {
    const all = this.value.split('\n');
    let unchecked = false;
    for (let i = 0; i < all.length; i++) {
      const l = all[i].trim();
      if (!l)
        continue;
      if (!SHARE_LINK.test(l))
        return t('line', { n: i + 1, message: t('not_link') });
      const p = this.parsed.get(l);
      if (p && 'error' in p)
        return t('line', { n: i + 1, message: p.error });
      if (!p)
        unchecked = true;
    }
    if (unchecked)
      return this.failed ? t('check_failed', { error: this.failed }) : t('checking');
    return null;
  }

  private show(): void {
    const seen = new Map<string, number>();
    const rows: Child[] = [];
    this.value.split('\n').forEach((raw, i) => {
      const l = raw.trim();
      if (!l)
        return;
      const p = SHARE_LINK.test(l) ? this.parsed.get(l) : { error: t('not_link') };
      let check: Child;
      if (!p)
        check = this.failed ? h('span', { class: 'error-text' }, t('not_checked', { error: this.failed })) : h('em', {}, t('checking_one'));
      else if ('error' in p)
        check = h('span', { class: 'error-text' }, p.error);
      else if (seen.has(p.id))
        check = h('span', { class: 'warn-text' }, t('duplicate', { n: seen.get(p.id)! }));
      else {
        seen.set(p.id, i + 1);
        check = h('span', { class: 'ok-text' }, 'OK');
      }
      const ok = p && !('error' in p) ? p : null;
      rows.push(h('tr', {}, h('td', {}, String(i + 1)), h('td', {}, ok?.proto ?? ''), h('td', {}, ok?.name ?? ''),
        h('td', {}, ok ? `${ok.address}:${ok.port}` : ''), h('td', {}, check)));
    });
    clear(this.results, rows.length ? h('table', { class: 'grid' },
      h('tr', {}, ['#', t('proto'), t('name'), t('address'), t('check')].map((x) => h('th', {}, x))), rows) : null);
  }
}

registerView({
  id: 'subscriptions',
  order: 30,
  title: () => t('title'),
  mount(el, ctx) {
    let gen = 0;
    let timer: ReturnType<typeof setTimeout> | null = null;
    let sections: Record<string, UciSection> = {};
    let status: SubscriptionsReply | null = null;
    /** sid → the parts filled again by the poll */
    let cells = new Map<string, { status: HTMLElement; traffic: HTMLElement; update: HTMLButtonElement }>();
    let editor: { form: UciForm; sid: string } | null = null;
    let linksForm: UciForm | null = null;
    let links: LinksCheck | null = null;
    /** the manual links as drawn from the router */
    let manualShown: string | null = null;
    const busy = new Set<string>();

    const notice = h('p', { class: 'save-msg' });
    const say = (text: string, cls = 'muted') => {
      notice.textContent = text;
      notice.className = `save-msg ${cls}`;
    };
    const list = h('div', {}, h('p', { class: 'muted' }, t('loading')));
    const editBox = h('div');
    const manualBox = h('div');
    const reload = () => void load();
    // toggles and deletes: only the message
    const actions = saveBar(ctx, { form: () => null, reload, buttons: false });
    // the editor closes after saving: its outcome goes to the message above the list
    const closed = (r: SaveOutcome) => {
      if (r === 'applied' || r === 'nothing')
        say(tf(r === 'applied' ? 'applied' : 'nothing'), 'ok-text');
      else if (r === 'rolled_back' || r === 'changed')
        say(tf(r), r === 'changed' ? 'warn-text' : 'error-text');
    };
    const editBar = saveBar(ctx, {
      form: () => editor?.form ?? null,
      reload: () => {
        editor = null;
        clear(editBox);
        reload();
      },
      onDone: closed,
    });
    const linksBar = saveBar(ctx, { form: () => linksForm, reload, ready: () => links?.problem() ?? null });

    const updateAll = h('button', { onclick: () => void update() }, t('update_all'));
    el.replaceChildren(h('section', { class: 'subscriptions' },
      h('h2', {}, t('title')),
      h('p', { class: 'muted' }, t('intro')),
      h('div', { class: 'row' },
        updateAll,
        h('button', { onclick: () => edit(null) }, t('add')),
        h('button', { onclick: () => void importClipboard() }, t('import'))),
      notice, actions.el, editBox, list, manualBox));

    const isUpdating = () => !!status?.updating || (ctx.poller.status?.running === true && ctx.poller.status.updating);

    const fillButtons = () => {
      updateAll.disabled = busy.has('') || isUpdating();
      for (const [sid, c] of cells)
        c.update.disabled = busy.has(sid) || isUpdating() || !status?.subscriptions.some((s) => s.id === sid);
    };

    const fill = () => {
      const now = status?.time ?? Math.floor(Date.now() / 1000);
      for (const [sid, c] of cells) {
        const s = status?.subscriptions.find((x) => x.id === sid);
        clear(c.status, statusLines(s, now, isUpdating()));
        clear(c.traffic, trafficLines(s, now));
      }
      fillButtons();
    };

    const poll = async () => {
      if (timer)
        clearTimeout(timer);
      timer = null;
      const my = gen;
      try {
        const r = await ctx.xvpn.subscriptions();
        if (my !== gen)
          return;
        status = r;
        fill();
      }
      catch {
        // the poller reports a router that does not answer
      }
      if (my === gen)
        timer = setTimeout(() => void poll(), POLL_MS);
    };

    const update = async (sid?: string) => {
      busy.add(sid ?? '');
      fillButtons();
      try {
        const r = await ctx.xvpn.update(sid);
        say(r.ok ? t('updating_now') : t('update_failed', { error: updateError(r.error) }), r.ok ? 'muted' : 'error-text');
      }
      catch (e) {
        say(errorText(e), 'error-text');
      }
      finally {
        busy.delete(sid ?? '');
        await poll();
      }
    };

    const remove = (sid: string, btn: HTMLButtonElement) => {
      if (btn.dataset.armed !== '1') {
        btn.dataset.armed = '1';
        btn.textContent = t('delete_sure');
        setTimeout(() => {
          btn.dataset.armed = '';
          btn.textContent = t('delete');
        }, 4000);
        return;
      }
      void actions.save([{ section: sid, type: 'subscription', remove: true }]).then(redrawUnlessDone);
    };

    // another save of the session was running (busy) or this one failed: the cards show
    // the router again (a toggled checkbox goes back)
    const redrawUnlessDone = (r: SaveOutcome) => {
      if (r === 'busy' || r === 'error')
        reload();
    };

    const toggle = (sid: string, on: boolean) => {
      const e: Edit = { section: sid, type: 'subscription', set: { enabled: on ? '1' : '0' } };
      void actions.save([e]).then(redrawUnlessDone);
    };

    const card = (s: UciSection) => {
      const sid = s['.name'];
      const st = h('div', { class: 'sub-status' }), tr = h('div', { class: 'sub-traffic' });
      const upd = h('button', { onclick: () => void update(sid) }, t('update'));
      const del = h('button', { class: 'danger' }, t('delete'));
      del.onclick = () => remove(sid, del);
      cells.set(sid, { status: st, traffic: tr, update: upd });
      const title = status?.subscriptions.find((x) => x.id === sid)?.title;
      const name = String(s.name || sid);
      const url = String(s.url ?? '');
      return h('div', { class: 'card sub' },
        h('div', { class: 'sub-head' },
          h('label', { class: 'check' },
            h('input', { type: 'checkbox', checked: uciBool(optionValue(s, 'enabled'), '1'), title: t('enabled'), onchange: (e: Event) => toggle(sid, (e.target as HTMLInputElement).checked) }),
            h('strong', {}, name)),
          title && title !== name ? h('span', { class: 'muted' }, title) : null,
          h('span', { class: 'spacer' }),
          upd,
          h('button', { onclick: () => edit(sid) }, t('edit')),
          del),
        h('div', { class: 'sub-url muted', title: url }, url),
        h('div', { class: 'sub-body' }, st, tr));
    };

    const edit = (sid: string | null, url?: string) => {
      const name = sid ?? newSubscriptionName();
      const f = new UciForm(sid ? { [sid]: sections[sid] } : {}, { [name]: 'subscription' });
      editor = { form: f, sid: name };
      const urlRow = f.text(name, 'url', { label: t('url'), check: subscriptionUrl, placeholder: 'https://' });
      const nameRow = f.text(name, 'name', { label: t('name'), check: required });
      if (url) {
        urlRow.querySelector('input')!.value = url;
        nameRow.querySelector('input')!.value = nameFromUrl(url);
      }
      clear(editBox, h('div', { class: 'card editor' },
        h('h3', {}, sid ? t('edit_title', { name: String(sections[sid]?.name ?? sid) }) : t('add_title')),
        nameRow, urlRow,
        f.flag(name, 'enabled', { label: t('enabled'), def: '1' }),
        f.text(name, 'update_interval', {
          label: t('interval'), help: t('interval_help'), placeholder: t('auto'), check: (v) => integer(v, 0, 8760),
        }),
        f.text(name, 'user_agent', {
          label: 'User-Agent', help: t('ua_help'), placeholder: DEFAULTS.user_agent, suggest: ['v2rayN/7.0', 'v2rayNG/1.9.0'],
        }),
        f.text(name, 'include', { label: t('include'), help: t('include_help'), check: regex }),
        f.text(name, 'exclude', { label: t('exclude'), help: t('exclude_help'), check: regex }),
        f.flag(name, 'via_tunnel', { label: t('via_tunnel_opt'), help: t('via_tunnel_help'), def: '1' }),
        editBar.el,
        h('button', { onclick: () => { editor = null; clear(editBox); } }, t('cancel'))));
      f.validateAll();
      editBox.scrollIntoView?.({ block: 'nearest' });
    };

    const drawManual = () => {
      manualShown = manualText(sections.manual);
      links?.stop();
      linksForm = new UciForm(sections.manual ? { manual: sections.manual } : {}, { manual: 'manual' });
      const results = h('div', { class: 'link-check' });
      links = new LinksCheck(ctx, results, () => linksForm?.validateAll());
      const row = linksForm.lines('manual', 'link', {
        label: t('links'), rows: 8, placeholder: 'vless://uuid@host:443?type=tcp&security=reality&…#Name',
        check: () => links?.problem() ?? null,
      });
      const area = row.querySelector('textarea')!;
      area.classList.add('mono');
      area.wrap = 'off';
      area.addEventListener('input', () => links?.set(area.value));
      links.set(area.value);
      clear(manualBox, h('div', { class: 'card' },
        h('h3', {}, t('manual')),
        h('p', { class: 'muted' }, t('manual_help')),
        row, results, linksBar.el));
    };

    const importClipboard = async () => {
      let text: string;
      try {
        text = await readClipboard();
      }
      catch (e) {
        say(t('clipboard_failed', { error: errorText(e) }), 'error-text');
        return;
      }
      const ls = lines(text);
      if (ls.length && ls.every((l) => SHARE_LINK.test(l))) {
        const area = manualBox.querySelector('textarea');
        if (!area)
          return;
        const have = new Set(lines(area.value));
        const add = ls.filter((l) => !have.has(l));
        area.value = [...lines(area.value), ...add].join('\n');
        area.dispatchEvent(new Event('input'));
        say(add.length ? t('imported_links', { n: add.length }) : t('imported_none'));
        area.scrollIntoView?.({ block: 'nearest' });
        return;
      }
      if (ls.length === 1 && !subscriptionUrl(ls[0])) {
        edit(null, ls[0]);
        say(t('imported_url'));
        return;
      }
      say(t('clipboard_nothing'), 'warn-text');
    };

    const load = async () => {
      const my = ++gen;
      if (timer)
        clearTimeout(timer);
      timer = null;
      try {
        const [all, st] = await Promise.all([loadConfig(ctx.uci), ctx.xvpn.subscriptions()]);
        if (my !== gen)
          return;
        sections = all;
        status = st;
        cells = new Map();
        const subs = Object.values(all).filter((s) => s['.type'] === 'subscription')
          .sort((a, b) => (a['.index'] ?? 0) - (b['.index'] ?? 0));
        clear(list, subs.length ? subs.map(card) : h('p', { class: 'muted' }, t('none')));
        if (editor && !editor.form.sections[editor.sid] && sections[editor.sid])
          editor = null;
        // the manual links being edited stay, unless the router has just the same now
        const area = manualBox.querySelector('textarea');
        const typed = area ? lines(area.value).join('\n') : null;
        if (typed == null || typed === manualShown || typed === manualText(all.manual))
          drawManual();
        fill();
      }
      catch (e) {
        if (my === gen)
          clear(list, h('p', { class: 'error' }, errorText(e)));
      }
      if (my === gen)
        timer = setTimeout(() => void poll(), POLL_MS);
    };

    const offStatus = ctx.bus.on('status', () => fill());
    void load();
    return () => {
      gen++;
      offStatus();
      links?.stop();
      if (timer)
        clearTimeout(timer);
    };
  },
});
