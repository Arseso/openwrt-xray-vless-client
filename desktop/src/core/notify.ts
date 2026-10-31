// Notifications (#80): what happened on the router, told by the system while the
// window is hidden to the tray. The decisions are here, Rust only shows them
// (src-tauri/src/notifications.rs, notify_show).
//
//   Watcher    turns statuses, router down/up and subscription lists into notices,
//              one per event: transitions are remembered per profile, so a reconnect
//              to the same router does not tell again what it already told
//   Notifier   drops the notices of a type turned off, in quiet hours, and those whose
//              key was sent already (subscription keys are kept across restarts)
//   startNotifications(conn)  wires both to connection.bus once at startup, applies
//              the poll interval and asks luci.xvpn subscriptions now and then, apart
//              from the shared poller
//
// The settings are local to the PC (localStorage), not per router.

import { invokeRust } from '../api/transport';
import { Status, SubscriptionsReply } from '../api/xvpn';
import { t } from '../i18n/notifications';
import { AppContext, Connection } from './connection';

export type NotifyType = 'vpn' | 'failover' | 'router' | 'subscription' | 'sub_error';
export const NOTIFY_TYPES: readonly NotifyType[] = ['vpn', 'failover', 'router', 'subscription', 'sub_error'];

export interface QuietHours {
  enabled: boolean;
  /** HH:MM, local time of the PC; from > to spans midnight */
  from: string;
  to: string;
}

export interface NotifySettings {
  /** the shared poller (luci.xvpn status), also while the window is hidden */
  intervalMs: number;
  quiet: QuietHours;
  types: Record<NotifyType, boolean>;
  /** a subscription expiring within this many days */
  expireDays: number;
  /** a subscription with this share of its traffic used, % */
  trafficPct: number;
}

export const DEFAULT_SETTINGS: NotifySettings = {
  intervalMs: 3000,
  quiet: { enabled: false, from: '23:00', to: '08:00' },
  types: { vpn: true, failover: true, router: true, subscription: true, sub_error: true },
  expireDays: 3,
  trafficPct: 90,
};

export const INTERVAL_MIN_MS = 1000;
export const INTERVAL_MAX_MS = 60_000;
/** luci.xvpn subscriptions: rarely, the userinfo changes once per update */
export const SUBS_EVERY_MS = 30 * 60_000;
const SUBS_FIRST_MS = 15_000;
/** sent keys kept across restarts are forgotten after */
const SENT_TTL_MS = 60 * 86400_000;

/** localStorage, or nothing (tests, private mode) */
export interface KeyValue {
  getItem(key: string): string | null;
  setItem(key: string, value: string): void;
}

function storage(): KeyValue | null {
  try {
    return typeof localStorage !== 'undefined' ? localStorage : null;
  }
  catch {
    return null;
  }
}

const SETTINGS_KEY = 'xvpn.notify';
const SENT_KEY = 'xvpn.notify.sent';

function clamp(n: unknown, min: number, max: number, def: number): number {
  return typeof n === 'number' && Number.isFinite(n) ? Math.min(max, Math.max(min, Math.round(n))) : def;
}

function hhmm(s: unknown, def: string): string {
  return typeof s === 'string' && /^([01]\d|2[0-3]):[0-5]\d$/.test(s) ? s : def;
}

/** whatever was stored (an older or broken record) as valid settings */
export function normalize(raw: unknown): NotifySettings {
  const r = (raw && typeof raw === 'object' ? raw : {}) as Partial<Record<keyof NotifySettings, unknown>>;
  const d = DEFAULT_SETTINGS;
  const q = (r.quiet && typeof r.quiet === 'object' ? r.quiet : {}) as Partial<QuietHours>;
  const types = (r.types && typeof r.types === 'object' ? r.types : {}) as Partial<Record<NotifyType, unknown>>;
  return {
    intervalMs: clamp(r.intervalMs, INTERVAL_MIN_MS, INTERVAL_MAX_MS, d.intervalMs),
    quiet: { enabled: q.enabled === true, from: hhmm(q.from, d.quiet.from), to: hhmm(q.to, d.quiet.to) },
    types: Object.fromEntries(NOTIFY_TYPES.map((k) => [k, typeof types[k] === 'boolean' ? types[k] : d.types[k]])) as Record<NotifyType, boolean>,
    expireDays: clamp(r.expireDays, 1, 60, d.expireDays),
    trafficPct: clamp(r.trafficPct, 50, 100, d.trafficPct),
  };
}

const settingsListeners = new Set<(s: NotifySettings) => void>();
let settings: NotifySettings | null = null;

export function loadSettings(): NotifySettings {
  if (!settings) {
    let raw: unknown = null;
    try {
      raw = JSON.parse(storage()?.getItem(SETTINGS_KEY) ?? 'null');
    }
    catch {
      // broken record: defaults
    }
    settings = normalize(raw);
  }
  return settings;
}

export function saveSettings(s: NotifySettings): NotifySettings {
  settings = normalize(s);
  try {
    storage()?.setItem(SETTINGS_KEY, JSON.stringify(settings));
  }
  catch {
    // kept for this run only
  }
  for (const fn of [...settingsListeners])
    fn(settings);
  return settings;
}

export function onSettingsChange(fn: (s: NotifySettings) => void): () => void {
  settingsListeners.add(fn);
  return () => {
    settingsListeners.delete(fn);
  };
}

function minutes(s: string): number {
  const [h, m] = s.split(':').map(Number);
  return h * 60 + m;
}

/** from is in, to is out; from == to is no quiet time at all */
export function inQuietHours(date: Date, q: QuietHours): boolean {
  if (!q.enabled)
    return false;
  const now = date.getHours() * 60 + date.getMinutes();
  const from = minutes(q.from), to = minutes(q.to);
  if (from === to)
    return false;
  return from < to ? now >= from && now < to : now >= from || now < to;
}

export interface Notice {
  type: NotifyType;
  /** the event: a notice with a key sent already is not sent again */
  key: string;
  title: string;
  body: string;
  /** keep the key across restarts (conditions that hold for days: a subscription) */
  persist?: boolean;
}

export type Show = (title: string, body: string) => Promise<void> | void;

export interface NotifierOptions {
  settings?: () => NotifySettings;
  now?: () => number;
  store?: KeyValue | null;
}

export type Verdict = 'sent' | 'duplicate' | 'off' | 'quiet';

export class Notifier {
  private sent = new Map<string, number>();
  private kept: Record<string, number> = {};
  private readonly settings: () => NotifySettings;
  private readonly now: () => number;
  private readonly store: KeyValue | null;

  constructor(private readonly show: Show, opts: NotifierOptions = {}) {
    this.settings = opts.settings ?? loadSettings;
    this.now = opts.now ?? Date.now;
    this.store = opts.store === undefined ? storage() : opts.store;
    try {
      const raw = JSON.parse(this.store?.getItem(SENT_KEY) ?? '{}') as unknown;
      if (raw && typeof raw === 'object') {
        const old = this.now() - SENT_TTL_MS;
        for (const [k, v] of Object.entries(raw as Record<string, unknown>)) {
          if (typeof v === 'number' && v > old)
            this.kept[k] = v;
        }
      }
    }
    catch {
      // nothing kept
    }
  }

  /**
   * A notice dropped (type off, quiet hours) counts as sent: the event is not told an
   * hour later when the quiet time ends, only the next one is.
   */
  send(n: Notice): Verdict {
    if (this.sent.has(n.key) || n.key in this.kept)
      return 'duplicate';
    const at = this.now();
    this.sent.set(n.key, at);
    if (n.persist) {
      this.kept[n.key] = at;
      try {
        this.store?.setItem(SENT_KEY, JSON.stringify(this.kept));
      }
      catch {
        // this run only
      }
    }
    const s = this.settings();
    if (!s.types[n.type])
      return 'off';
    if (inQuietHours(new Date(at), s.quiet))
      return 'quiet';
    void Promise.resolve()
      .then(() => this.show(n.title, n.body))
      .catch((e: unknown) => console.error('notify: show failed', e));
    return 'sent';
  }
}

/** up: tunnel works; down: it does not while it should; off: turned off by the user */
export type Health = 'up' | 'down' | 'off';

/** null: in between (starting, failover, busy daemon), the last verdict holds */
export function health(s: Status): Health | null {
  if (!s.enabled)
    return 'off';
  if (!s.running)
    return s.timeout ? null : 'down';
  if (s.passthrough)
    return 'down';
  switch (s.state) {
  case 'connected':
  case 'degraded':
    return 'up';
  case 'no_servers':
  case 'xray_down':
  case 'wan_down':
  case 'error':
    return 'down';
  default:
    return null;
  }
}

/** switches the user asked for or that only found a faster server are not failovers */
const NOT_FAILOVER = /^(manual selection|chosen by hand|faster server)/;

interface RouterMemory {
  health?: Health;
  /** the down notice of the current outage was sent: its recovery is told too */
  downTold: boolean;
  /** outages told: the key of each down/up pair */
  outages: number;
  /** last_switch.at seen, undefined before the first status */
  switchAt?: number | null;
  routerDownSince: number | null;
}

function serverName(s: Status, id: string | null | undefined): string {
  if (!id)
    return '—';
  return (s.running && s.servers.find((x) => x.id === id)?.name) || id;
}

function gb(bytes: number): string {
  return (bytes / 1e9).toFixed(bytes >= 1e10 ? 0 : 1);
}

export class Watcher {
  private routers = new Map<string, RouterMemory>();

  constructor(private readonly notifier: Pick<Notifier, 'send'>, private readonly settings: () => NotifySettings = loadSettings) {}

  private mem(pid: string): RouterMemory {
    let m = this.routers.get(pid);
    if (!m)
      this.routers.set(pid, m = { downTold: false, outages: 0, routerDownSince: null });
    return m;
  }

  /** every answer of the poller of router pid (profile id) */
  onStatus(pid: string, s: Status): void {
    const m = this.mem(pid);
    this.failover(pid, m, s);
    const h = health(s);
    if (h === null)
      return;
    const prev = m.health;
    m.health = h;
    if (h === prev)
      return;
    if (h === 'down') {
      // also at the first status: the app started while the VPN does not work
      if (prev === 'up' || prev === undefined) {
        const why = s.running ? (s.passthrough ? t('why.passthrough') : (s.last_error || t(`state.${s.state}`))) : t('why.stopped');
        this.notifier.send({ type: 'vpn', key: `vpn-down:${pid}:${++m.outages}`, title: t('vpn_down'), body: why });
        m.downTold = true;
      }
    }
    else {
      if (h === 'up' && m.downTold && s.running)
        this.notifier.send({ type: 'vpn', key: `vpn-up:${pid}:${m.outages}`, title: t('vpn_up'), body: t('vpn_up_body', { server: serverName(s, s.active) }) });
      m.downTold = false;
    }
  }

  private failover(pid: string, m: RouterMemory, s: Status): void {
    if (!s.running)
      return;
    const sw = s.last_switch ?? null;
    const seen = m.switchAt;
    m.switchAt = sw?.at ?? null;
    // the first status: a switch from before the app started
    if (seen === undefined || !sw || sw.at === seen || !sw.from || NOT_FAILOVER.test(sw.reason))
      return;
    this.notifier.send({
      type: 'failover', key: `failover:${pid}:${sw.at}:${sw.to}`,
      title: t('failover'),
      body: t('failover_body', { from: serverName(s, sw.from), to: serverName(s, sw.to), reason: sw.reason }),
    });
  }

  onRouterDown(pid: string, profileName: string, since: number): void {
    const m = this.mem(pid);
    if (m.routerDownSince !== null)
      return;
    m.routerDownSince = since;
    this.notifier.send({ type: 'router', key: `router-down:${pid}:${since}`, title: t('router_down'), body: t('router_down_body', { name: profileName }) });
  }

  onRouterUp(pid: string, profileName: string): void {
    const m = this.mem(pid);
    const since = m.routerDownSince;
    if (since === null)
      return;
    m.routerDownSince = null;
    this.notifier.send({ type: 'router', key: `router-up:${pid}:${since}`, title: t('router_up'), body: t('router_up_body', { name: profileName }) });
  }

  /** luci.xvpn subscriptions: expiry and traffic from subscription-userinfo, update errors */
  onSubscriptions(pid: string, r: SubscriptionsReply): void {
    const set = this.settings();
    for (const sub of r.subscriptions) {
      if (!sub.enabled)
        continue;
      const name = sub.name || sub.title || sub.id;
      const ui = sub.userinfo;
      if (ui?.expire) {
        const left = ui.expire - r.time;
        if (left <= set.expireDays * 86400) {
          const days = Math.max(0, Math.ceil(left / 86400));
          this.notifier.send({
            type: 'subscription', key: `sub-expire:${pid}:${sub.id}:${ui.expire}`, persist: true,
            title: left > 0 ? t('sub_expiring') : t('sub_expired'),
            body: left > 0 ? t('sub_expiring_body', { name, days }) : t('sub_expired_body', { name }),
          });
        }
      }
      if (ui?.total && ui.total > 0) {
        const used = (ui.upload ?? 0) + (ui.download ?? 0);
        const pct = Math.floor(used / ui.total * 100);
        if (pct >= set.trafficPct) {
          this.notifier.send({
            type: 'subscription', key: `sub-traffic:${pid}:${sub.id}:${ui.total}:${ui.expire ?? ''}`, persist: true,
            title: t('sub_traffic'),
            body: t('sub_traffic_body', { name, pct, used: gb(used), total: gb(ui.total) }),
          });
        }
      }
      if (sub.error) {
        this.notifier.send({
          type: 'sub_error', key: `sub-error:${pid}:${sub.id}:${sub.last_attempt ?? sub.error}`, persist: true,
          title: t('sub_error'), body: t('sub_error_body', { name, error: sub.error }),
        });
      }
    }
  }
}

export interface NotificationsOptions {
  show?: Show;
  notifier?: Pick<Notifier, 'send'>;
  subsEveryMs?: number;
  subsFirstMs?: number;
}

export const showSystem: Show = (title, body) => invokeRust('notify_show', { title, body });

/**
 * Subscribes to the bus of the connection for the whole run (call once at startup).
 * Returns the function that stops it (tests).
 */
export function startNotifications(conn: Connection, opts: NotificationsOptions = {}): () => void {
  const notifier = opts.notifier ?? new Notifier(opts.show ?? showSystem);
  const watcher = new Watcher(notifier);
  const every = opts.subsEveryMs ?? SUBS_EVERY_MS;
  let ctx: AppContext | null = null;
  let timer: ReturnType<typeof setTimeout> | null = null;
  let wasUpdating = false;

  const stopSubs = () => {
    if (timer)
      clearTimeout(timer);
    timer = null;
  };
  const pollSubs = (c: AppContext, delay: number) => {
    stopSubs();
    timer = setTimeout(() => {
      timer = null;
      const s = loadSettings();
      const wanted = s.types.subscription || s.types.sub_error;
      (wanted ? c.xvpn.subscriptions({ updating: false }) : Promise.resolve(null)).then((r) => {
        if (r && c === ctx)
          watcher.onSubscriptions(c.profile.id, r);
      }, () => {
        // the router is away or busy: the next round
      }).finally(() => {
        if (c === ctx && !timer)
          pollSubs(c, every);
      });
    }, delay);
  };

  const offs = [
    conn.bus.on('connection', () => {
      const c = conn.context;
      if (c === ctx)
        return;
      ctx = c;
      stopSubs();
      wasUpdating = false;
      if (c) {
        c.poller.setInterval(loadSettings().intervalMs);
        pollSubs(c, opts.subsFirstMs ?? SUBS_FIRST_MS);
        // connected anew while the router was told away (the poller of the outage is gone)
        watcher.onRouterUp(c.profile.id, c.profile.name);
      }
    }),
    conn.bus.on('status', ({ status }) => {
      if (!ctx)
        return;
      watcher.onStatus(ctx.profile.id, status);
      // a subscription update just finished: its result now, not in half an hour
      const updating = status.running && status.updating;
      if (wasUpdating && !updating)
        pollSubs(ctx, 2000);
      wasUpdating = updating;
    }),
    conn.bus.on('router-down', ({ since }) => {
      if (ctx)
        watcher.onRouterDown(ctx.profile.id, ctx.profile.name, since);
    }),
    conn.bus.on('router-up', () => {
      if (ctx)
        watcher.onRouterUp(ctx.profile.id, ctx.profile.name);
    }),
    onSettingsChange((s) => ctx?.poller.setInterval(s.intervalMs)),
  ];
  return () => {
    stopSubs();
    for (const off of offs)
      off();
  };
}
