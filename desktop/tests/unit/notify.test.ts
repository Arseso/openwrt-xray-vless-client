import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { XvpnError } from '../../src/api/errors';
import { Profile } from '../../src/api/profiles';
import { Status, SubscriptionsReply } from '../../src/api/xvpn';
import { Connection } from '../../src/core/connection';
import {
  DEFAULT_SETTINGS, KeyValue, Notice, Notifier, NotifySettings, Watcher, health, inQuietHours, normalize,
  startNotifications,
} from '../../src/core/notify';
import { FakeRouter, STATUS_UP } from './fake';

const SERVERS = [
  { ...STATUS_UP.servers[0] },
  { id: 'b', name: 'B', proto: 'vless', address: '2.2.2.2', port: 443, latency: 60, quarantined: false, auto: true, limited: false },
];
const UP = { ...STATUS_UP, servers: SERVERS } as Status;

function st(patch: Record<string, unknown>): Status {
  return { ...UP, ...patch } as Status;
}

class MemStore implements KeyValue {
  data = new Map<string, string>();
  getItem(k: string) {
    return this.data.get(k) ?? null;
  }
  setItem(k: string, v: string) {
    this.data.set(k, v);
  }
}

function settings(patch: Partial<NotifySettings> = {}): NotifySettings {
  return { ...structuredClone(DEFAULT_SETTINGS), ...patch };
}

/** a notifier that records what it shows */
function setup(opts: { s?: NotifySettings; now?: () => number; store?: KeyValue } = {}) {
  const shown: { title: string; body: string }[] = [];
  const s = opts.s ?? settings();
  const notifier = new Notifier((title, body) => {
    shown.push({ title, body });
  }, { settings: () => s, now: opts.now ?? (() => new Date(2026, 9, 31, 12, 0).getTime()), store: opts.store ?? null });
  const sent: Notice[] = [];
  const spy = {
    send: (n: Notice) => {
      const v = notifier.send(n);
      if (v !== 'duplicate')
        sent.push(n);
      return v;
    },
  };
  return { shown, sent, notifier, watcher: new Watcher(spy, () => s), s };
}

const types = (sent: Notice[]) => sent.map((n) => `${n.type}:${n.title}`);

describe('quiet hours', () => {
  const at = (h: number, m = 0) => new Date(2026, 9, 31, h, m);

  it('spans midnight when from > to', () => {
    const q = { enabled: true, from: '23:00', to: '08:00' };
    expect(inQuietHours(at(23), q)).toBe(true);
    expect(inQuietHours(at(3), q)).toBe(true);
    expect(inQuietHours(at(7, 59), q)).toBe(true);
    expect(inQuietHours(at(8), q)).toBe(false);
    expect(inQuietHours(at(12), q)).toBe(false);
    expect(inQuietHours(at(22, 59), q)).toBe(false);
  });

  it('within a day, off, and from == to', () => {
    expect(inQuietHours(at(13), { enabled: true, from: '12:30', to: '14:00' })).toBe(true);
    expect(inQuietHours(at(14), { enabled: true, from: '12:30', to: '14:00' })).toBe(false);
    expect(inQuietHours(at(3), { enabled: false, from: '23:00', to: '08:00' })).toBe(false);
    expect(inQuietHours(at(3), { enabled: true, from: '08:00', to: '08:00' })).toBe(false);
  });

  it('drops notices in quiet hours and does not tell them later', async () => {
    let now = new Date(2026, 9, 31, 2, 0).getTime();
    const { shown, notifier } = setup({ s: settings({ quiet: { enabled: true, from: '23:00', to: '08:00' } }), now: () => now });
    const n: Notice = { type: 'router', key: 'k', title: 'x', body: '' };
    expect(notifier.send(n)).toBe('quiet');
    now = new Date(2026, 9, 31, 9, 0).getTime();
    expect(notifier.send(n)).toBe('duplicate');
    expect(notifier.send({ ...n, key: 'k2' })).toBe('sent');
    await Promise.resolve();
    expect(shown).toHaveLength(1);
  });
});

describe('Notifier', () => {
  it('sends each key once and honours the types', async () => {
    const { shown, notifier, s } = setup();
    const n: Notice = { type: 'vpn', key: 'a', title: 't', body: 'b' };
    expect(notifier.send(n)).toBe('sent');
    expect(notifier.send(n)).toBe('duplicate');
    s.types.failover = false;
    expect(notifier.send({ type: 'failover', key: 'f', title: 't', body: '' })).toBe('off');
    await Promise.resolve();
    expect(shown).toEqual([{ title: 't', body: 'b' }]);
  });

  it('keeps the persistent keys across restarts', () => {
    const store = new MemStore();
    const n: Notice = { type: 'subscription', key: 'sub', title: 't', body: '', persist: true };
    expect(setup({ store }).notifier.send(n)).toBe('sent');
    expect(setup({ store }).notifier.send(n)).toBe('duplicate');
    // a key that is not persistent is told again after a restart
    const m: Notice = { type: 'vpn', key: 'vpn', title: 't', body: '' };
    expect(setup({ store }).notifier.send(m)).toBe('sent');
    expect(setup({ store }).notifier.send(m)).toBe('sent');
  });

  it('normalizes broken settings', () => {
    const s = normalize({ intervalMs: 5, quiet: { enabled: true, from: '25:00' }, types: { vpn: false, router: 'no' }, trafficPct: NaN });
    expect(s.intervalMs).toBe(1000);
    expect(s.quiet).toEqual({ enabled: true, from: '23:00', to: '08:00' });
    expect(s.types.vpn).toBe(false);
    expect(s.types.router).toBe(true);
    expect(s.trafficPct).toBe(90);
  });
});

describe('Watcher: transitions to notices', () => {
  it('classifies the daemon states', () => {
    expect(health(st({ state: 'connected' }))).toBe('up');
    expect(health(st({ state: 'failover' }))).toBeNull();
    expect(health(st({ state: 'no_servers' }))).toBe('down');
    expect(health(st({ passthrough: true }))).toBe('down');
    expect(health({ enabled: true, time: 1, running: false, timeout: false })).toBe('down');
    expect(health({ enabled: true, time: 1, running: false, timeout: true })).toBeNull();
    expect(health({ enabled: false, time: 1, running: false, timeout: false })).toBe('off');
  });

  it('VPN down once and back once, whatever the polls in between', () => {
    const { watcher, sent } = setup();
    watcher.onStatus('p', UP);
    watcher.onStatus('p', UP);
    for (let i = 0; i < 3; i++)
      watcher.onStatus('p', st({ state: 'no_servers', since: 1000, time: 1000 + i }));
    watcher.onStatus('p', st({ state: 'failover', since: 1010 }));
    watcher.onStatus('p', st({ state: 'connected', since: 1020 }));
    watcher.onStatus('p', st({ state: 'connected', since: 1020 }));
    expect(types(sent)).toEqual(['vpn:VPN is down', 'vpn:VPN is back']);
  });

  it('failover: one notice from → to, and not a down/up pair', () => {
    const { watcher, sent } = setup();
    watcher.onStatus('p', st({ last_switch: { from: null, to: 'a', reason: 'start', at: 900 } }));
    watcher.onStatus('p', st({ state: 'failover', since: 950 }));
    const after = st({ active: 'b', since: 960, last_switch: { from: 'a', to: 'b', reason: 'health check failed', at: 960 } });
    watcher.onStatus('p', after);
    watcher.onStatus('p', after);
    expect(sent.map((n) => [n.type, n.body])).toEqual([['failover', 'A → B: health check failed']]);
  });

  it('a switch by hand or to a faster server is no failover; a switch before the start is not told', () => {
    const { watcher, sent } = setup();
    watcher.onStatus('p', st({ last_switch: { from: 'b', to: 'a', reason: 'health check failed', at: 800 } }));
    watcher.onStatus('p', st({ active: 'b', last_switch: { from: 'a', to: 'b', reason: 'manual selection', at: 900 } }));
    watcher.onStatus('p', st({ active: 'a', last_switch: { from: 'b', to: 'a', reason: 'faster server: 40 ms vs 60 ms', at: 1000 } }));
    expect(sent).toEqual([]);
  });

  it('router down once and up once, the up only after a down', () => {
    const { watcher, sent } = setup();
    watcher.onRouterUp('p', 'Home');
    watcher.onRouterDown('p', 'Home', 1);
    watcher.onRouterDown('p', 'Home', 2);
    watcher.onRouterUp('p', 'Home');
    watcher.onRouterUp('p', 'Home');
    expect(sent.map((n) => n.title)).toEqual(['Router is unreachable', 'Router is reachable again']);
  });

  it('VPN down at the first status is told, up and off are not', () => {
    const a = setup();
    a.watcher.onStatus('p', { enabled: true, time: 1, running: false, timeout: false });
    expect(types(a.sent)).toEqual(['vpn:VPN is down']);
    const b = setup();
    b.watcher.onStatus('p', UP);
    b.watcher.onStatus('p', { enabled: false, time: 1, running: false, timeout: false });
    b.watcher.onStatus('p', UP);
    expect(b.sent).toEqual([]);
  });

  it('subscriptions: expiring, traffic and an update error, once each', () => {
    const { watcher, sent } = setup();
    const reply = (patch: Record<string, unknown> = {}): SubscriptionsReply => ({
      time: 1_000_000,
      subscriptions: [
        { id: 's1', name: 'Sub', enabled: true, count: 3, userinfo: { upload: 1e9, download: 9.5e10, total: 1e11, expire: 1_000_000 + 2 * 86400 }, ...patch },
        { id: 's2', name: 'Fine', enabled: true, count: 3, userinfo: { upload: 0, download: 1e9, total: 1e11, expire: 1_000_000 + 30 * 86400 } },
        { id: 's3', name: 'Off', enabled: false, count: 0, error: 'HTTP 404' },
      ],
    });
    watcher.onSubscriptions('p', reply());
    watcher.onSubscriptions('p', reply());
    watcher.onSubscriptions('p', reply({ error: 'HTTP 500', last_attempt: 5 }));
    watcher.onSubscriptions('p', reply({ error: 'HTTP 500', last_attempt: 5 }));
    watcher.onSubscriptions('p', reply({ error: 'HTTP 500', last_attempt: 6 }));
    expect(sent.map((n) => `${n.type}:${n.body}`)).toEqual([
      'subscription:Sub: 2 d left.',
      'subscription:Sub: 96% used (96 of 100 GB).',
      'sub_error:Sub: HTTP 500',
      'sub_error:Sub: HTTP 500',
    ]);
  });
});

describe('startNotifications on the connection bus', () => {
  const profile: Profile = { id: 'p', name: 'Home', url: 'http://192.168.1.1', username: 'root' };
  beforeEach(() => vi.useFakeTimers());
  afterEach(() => vi.useRealTimers());

  it('router off and back: one "unreachable" and one "reachable again"; failover once', async () => {
    let status: Status = st({ last_switch: { from: null, to: 'a', reason: 'start', at: 900 } });
    const r = new FakeRouter()
      .on('luci.xvpn.version', () => ({ version: '0.2.0-r1', api: 1 }))
      .on('luci.xvpn.status', () => status)
      .on('luci.xvpn.subscriptions', () => ({ time: 1, subscriptions: [] }));
    const conn = new Connection({ transport: () => r, intervalMs: 1000 });
    const shown: string[] = [];
    const notifier = new Notifier((title) => {
      shown.push(title);
    }, { settings: () => settings({ intervalMs: 1000 }), store: null });
    const stop = startNotifications(conn, { notifier });
    await conn.connect(profile);
    await vi.advanceTimersByTimeAsync(2500);

    status = st({ active: 'b', since: 960, last_switch: { from: 'a', to: 'b', reason: 'health check failed', at: 960 } });
    await vi.advanceTimersByTimeAsync(5000);

    // the poll interval of the settings (3 s): about 18 s away
    for (let i = 0; i < 6; i++)
      r.failures.push(new XvpnError('unreachable'));
    await vi.advanceTimersByTimeAsync(30_000);
    expect(shown).toEqual(['Server switched', 'Router is unreachable', 'Router is reachable again']);
    stop();
    conn.disconnect();
  });

  it('asks the subscriptions apart from the poller and applies the interval', async () => {
    const r = new FakeRouter()
      .on('luci.xvpn.version', () => ({ version: '0.2.0-r1', api: 1 }))
      .on('luci.xvpn.status', () => UP)
      .on('luci.xvpn.subscriptions', () => ({ time: 1, subscriptions: [] }));
    const conn = new Connection({ transport: () => r, intervalMs: 1000 });
    const stop = startNotifications(conn, { notifier: new Notifier(() => {}, { store: null }), subsFirstMs: 100, subsEveryMs: 60_000 });
    await conn.connect(profile);
    expect(conn.context?.poller.interval).toBe(DEFAULT_SETTINGS.intervalMs);
    await vi.advanceTimersByTimeAsync(130_000);
    expect(r.calls.filter((c) => c.method === 'subscriptions')).toHaveLength(3);
    stop();
    conn.disconnect();
  });
});
