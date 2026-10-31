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
  /** the PC clock: noon */
  const clock = { t: new Date(2026, 9, 31, 12, 0).getTime() };
  const now = opts.now ?? (() => clock.t);
  const notifier = new Notifier((title, body) => {
    shown.push({ title, body });
  }, { settings: () => s, now, store: opts.store ?? null });
  /** the notices shown */
  const sent: Notice[] = [];
  const spy = {
    send: (n: Notice) => {
      const v = notifier.send(n);
      if (v === 'sent')
        sent.push(n);
      return v;
    },
  };
  return { shown, sent, notifier, watcher: new Watcher(spy, () => s, now), s, clock };
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

  it('a notice in quiet hours or of a type off is not marked sent: a condition is told later', async () => {
    let now = new Date(2026, 9, 31, 2, 0).getTime();
    const { shown, notifier, s } = setup({ s: settings({ quiet: { enabled: true, from: '23:00', to: '08:00' } }), now: () => now });
    const n: Notice = { type: 'subscription', key: 'k', title: 'x', body: '', persist: true };
    expect(notifier.send(n)).toBe('quiet');
    now = new Date(2026, 9, 31, 9, 0).getTime();
    s.types.subscription = false;
    expect(notifier.send(n)).toBe('off');
    s.types.subscription = true;
    expect(notifier.send(n)).toBe('sent');
    expect(notifier.send(n)).toBe('duplicate');
    await Promise.resolve();
    expect(shown).toHaveLength(1);
  });

  it('VPN down in quiet hours: no "back" without a "down" (#12)', () => {
    const quiet = settings({ quiet: { enabled: true, from: '11:00', to: '13:00' } });
    const { watcher, sent, clock } = setup({ s: quiet });
    watcher.onStatus('p', UP);
    watcher.onStatus('p', st({ state: 'no_servers', since: 1000 }));
    clock.t += 2 * 3600_000;
    watcher.onStatus('p', st({ state: 'connected', since: 1100 }));
    expect(sent).toEqual([]);
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

  it('failover of an older daemon (no last_switch.failover): the state failover before the switch', () => {
    const { watcher, sent } = setup();
    watcher.onStatus('p', st({ last_switch: { from: null, to: 'a', reason: 'start', at: 900 } }));
    watcher.onStatus('p', st({ state: 'failover', since: 950 }));
    const after = st({ active: 'b', since: 960, last_switch: { from: 'a', to: 'b', reason: 'health check failed', at: 960 } });
    watcher.onStatus('p', after);
    watcher.onStatus('p', after);
    // without the state failover seen: a test by hand, the list changed... (#4)
    watcher.onStatus('p', st({ active: 'a', last_switch: { from: 'b', to: 'a', reason: 'test by hand', at: 980 } }));
    expect(sent.map((n) => [n.type, n.body])).toEqual([['failover', 'A → B: health check failed']]);
  });

  it('last_switch.failover decides: one notice from → to, not a down/up pair (#4)', () => {
    const { watcher, sent } = setup();
    const sw = (at: number, from: string, to: string, reason: string, failover: boolean) =>
      st({ active: to, last_switch: { from, to, reason, at, failover } });
    watcher.onStatus('p', sw(900, 'b', 'a', 'startup', false));
    // missed the state failover between two polls: the flag tells
    watcher.onStatus('p', sw(960, 'a', 'b', '"A" is down', true));
    watcher.onStatus('p', sw(960, 'a', 'b', '"A" is down', true));
    for (const [at, reason] of [[970, 'test by hand'], [980, '"B" is excluded from auto selection'], [990, 'server list changed'], [995, 'startup']] as const)
      watcher.onStatus('p', sw(at, 'b', 'a', reason, false));
    expect(sent.map((n) => [n.type, n.body])).toEqual([['failover', 'A → B: "A" is down']]);
  });

  it('a switch seen before a reconnect or older than 2 min is not news (#5)', () => {
    const { watcher, sent } = setup();
    const sw = (at: number, time = 1000) => st({ time, active: 'b', last_switch: { from: 'a', to: 'b', reason: 'x', at, failover: true } });
    watcher.onStatus('p', sw(500));
    watcher.onConnected('p');
    watcher.onStatus('p', sw(500));
    // one from while the app was away
    watcher.onStatus('p', sw(700, 1000));
    watcher.onConnected('p');
    watcher.onStatus('p', sw(700, 1000));
    expect(sent).toEqual([]);
    watcher.onStatus('p', sw(990, 1000));
    expect(sent.map((n) => n.type)).toEqual(['failover']);
  });

  it('the service not running: a restart is not an outage, a long stop is (#3)', () => {
    const { watcher, sent, clock } = setup();
    const stopped: Status = { enabled: true, time: 1, running: false, timeout: false };
    watcher.onStatus('p', UP);
    watcher.onStatus('p', stopped);
    clock.t += 10_000;
    watcher.onStatus('p', stopped);
    watcher.onStatus('p', st({ state: 'starting' }));
    watcher.onStatus('p', UP);
    expect(sent).toEqual([]);
    watcher.onStatus('p', stopped);
    clock.t += 50_000;
    watcher.onStatus('p', stopped);
    watcher.onStatus('p', UP);
    expect(types(sent)).toEqual(['vpn:VPN is down', 'vpn:VPN is back']);
  });

  it('stopped from the app, or a reboot just over: no "VPN down" (#3)', () => {
    const { watcher, sent, clock } = setup();
    const stopped: Status = { enabled: true, time: 1, running: false, timeout: false };
    watcher.onStatus('p', UP);
    watcher.onService('p', 'stop');
    watcher.onStatus('p', stopped);
    clock.t += 600_000;
    watcher.onStatus('p', stopped);
    watcher.onService('p', 'start');
    watcher.onStatus('p', st({ state: 'no_servers' }));
    watcher.onStatus('p', UP);
    expect(sent).toEqual([]);
    // the router rebooted: the service and WAN come up within ROUTER_GRACE_MS
    watcher.onRouterDown('p', 'Home', clock.t);
    clock.t += 60_000;
    watcher.onRouterUp('p', 'Home');
    watcher.onStatus('p', st({ state: 'wan_down' }));
    clock.t += 30_000;
    watcher.onStatus('p', UP);
    expect(sent.map((n) => n.type)).toEqual(['router', 'router']);
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
    a.watcher.onStatus('p', st({ state: 'no_servers' }));
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
    // each failed attempt of the same failure is one notice (#8); after an update went
    // through, the next failure is news
    watcher.onSubscriptions('p', reply({ error: 'HTTP 500', last_attempt: 5, last_ok: 1 }));
    watcher.onSubscriptions('p', reply({ error: 'HTTP 500', last_attempt: 6, last_ok: 1 }));
    watcher.onSubscriptions('p', reply({ error: 'HTTP 500', last_attempt: 9, last_ok: 8 }));
    expect(sent.map((n) => `${n.type}:${n.body}`)).toEqual([
      'subscription:Sub: 2 d left.',
      'subscription:Sub: 96% used (96 of 100 GB).',
      'sub_error:Sub: HTTP 500',
      'sub_error:Sub: HTTP 500',
    ]);
  });

  it('expiring soon, then expired: two notices (#2)', () => {
    const { watcher, sent } = setup();
    const reply = (time: number): SubscriptionsReply => ({
      time, subscriptions: [{ id: 's1', name: 'Sub', enabled: true, count: 1, userinfo: { expire: 1_000_000 } }],
    });
    watcher.onSubscriptions('p', reply(1_000_000 - 86400));
    watcher.onSubscriptions('p', reply(1_000_000 - 3600));
    watcher.onSubscriptions('p', reply(1_000_001));
    watcher.onSubscriptions('p', reply(1_100_000));
    expect(sent.map((n) => n.title)).toEqual(['Subscription expires soon', 'Subscription has expired']);
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

    status = st({ active: 'b', since: 960, last_switch: { from: 'a', to: 'b', reason: 'health check failed', at: 960, failover: true } });
    await vi.advanceTimersByTimeAsync(5000);

    // the poll interval of the settings (3 s): about 18 s away
    for (let i = 0; i < 6; i++)
      r.failures.push(new XvpnError('unreachable'));
    await vi.advanceTimersByTimeAsync(30_000);
    expect(shown).toEqual(['Server switched', 'Router is unreachable', 'Router is reachable again']);
    stop();
    conn.disconnect();
  });

  it('the router away from the start: "unreachable", then "reachable again" once connected (#6)', async () => {
    const r = new FakeRouter()
      .on('luci.xvpn.version', () => ({ version: '0.2.0-r1', api: 1 }))
      .on('luci.xvpn.status', () => UP)
      .on('luci.xvpn.subscriptions', () => ({ time: 1, subscriptions: [] }));
    for (let i = 0; i < 4; i++)
      r.failures.push(new XvpnError('timeout'));
    const conn = new Connection({ transport: () => r, intervalMs: 1000, retryMs: 1000 });
    const shown: string[] = [];
    const stop = startNotifications(conn, { notifier: new Notifier((title) => {
      shown.push(title);
    }, { settings: () => settings(), store: null }) });
    const done = conn.connect(profile);
    await vi.advanceTimersByTimeAsync(10_000);
    expect((await done).phase).toBe('online');
    expect(shown).toEqual(['Router is unreachable', 'Router is reachable again']);
    stop();
    conn.disconnect();
  });

  it('a stop from the app (luci.xvpn service) is no outage (#3)', async () => {
    let status: Status = UP;
    const r = new FakeRouter()
      .on('luci.xvpn.version', () => ({ version: '0.2.0-r1', api: 1 }))
      .on('luci.xvpn.status', () => status)
      .on('luci.xvpn.service', () => {
        status = { enabled: true, time: 1, running: false, timeout: false };
        return { ok: true };
      })
      .on('luci.xvpn.subscriptions', () => ({ time: 1, subscriptions: [] }));
    const conn = new Connection({ transport: () => r });
    const shown: string[] = [];
    const stop = startNotifications(conn, { notifier: new Notifier((title) => {
      shown.push(title);
    }, { settings: () => settings(), store: null }) });
    await conn.connect(profile);
    await vi.advanceTimersByTimeAsync(5000);
    await conn.context!.xvpn.service('stop');
    await vi.advanceTimersByTimeAsync(300_000);
    expect(shown).toEqual([]);
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
