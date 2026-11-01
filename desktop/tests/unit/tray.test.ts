import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { Profile } from '../../src/api/profiles';
import { Status, StatusUp } from '../../src/api/xvpn';
import { Connection, ConnectionState } from '../../src/core/connection';
import { setLang } from '../../src/core/i18n';
import { TrayAction, TrayBackend, startTray } from '../../src/tray';
import { INFO_LINES, MAX_SERVERS, TrayInput, TrayModel, trayIcon, trayModel } from '../../src/tray/model';
import { FakeRouter, STATUS_UP } from './fake';

const profile: Profile = { id: 'p', name: 'Home', url: 'https://192.168.1.1', username: 'root' };
const online: ConnectionState = { phase: 'online', profile, pkg: { version: '0.1.0-r1', api: 1 }, error: null };
const up = (patch: Partial<StatusUp> = {}) => ({ ...STATUS_UP, manual: false, ...patch }) as StatusUp;
const down = { enabled: true, time: 1, running: false, timeout: false } as const;
const model = (status: Status | null, more: Partial<TrayInput> = {}) => trayModel({ conn: online, status, ...more });

describe('tray icon', () => {
  it.each<[string, ConnectionState, Status | null, string]>([
    ['connected', online, up(), 'connected'],
    ['failover', online, up({ state: 'failover' }), 'failover'],
    ['degraded', online, up({ state: 'degraded' }), 'failover'],
    ['wan_down', online, up({ state: 'wan_down' }), 'wan_down'],
    ['xray_down', online, up({ state: 'xray_down' }), 'xray_down'],
    ['no servers', online, up({ state: 'no_servers' }), 'xray_down'],
    ['passthrough', online, up({ passthrough: true }), 'xray_down'],
    ['service stopped', online, { ...down, enabled: false }, 'stopped'],
    ['daemon down while enabled', online, down, 'xray_down'],
    ['daemon busy', online, { ...down, timeout: true }, 'failover'],
    ['router not answering', { ...online, phase: 'offline' }, up(), 'offline'],
    ['not connected', { ...online, phase: 'disconnected', profile: null }, null, 'offline'],
  ])('%s', (_, conn, st, icon) => expect(trayIcon(conn, st)).toBe(icon));

  it('an old status is not shown as current', () => {
    expect(trayIcon(online, up(), 'access denied')).toBe('offline');
  });
});

describe('tray menu texts', () => {
  beforeEach(() => setLang('ru'));
  afterEach(() => setLang('en'));

  it('the lines of the issue: state, server (auto), ping, speed', () => {
    const m = model(up({ speed: { down: 1_540_000, up: 137_500 } }));
    expect(m.info).toEqual(['● Подключено · xray работает', 'Сервер: A (авто)', 'Пинг: 40 мс', 'Скорость: ↓ 12,3 Мбит/с  ↑ 1,1 Мбит/с']);
    expect(m.tooltip).toBe('xvpn · Подключено · xray работает\nA · 40 мс\n↓ 12,3 Мбит/с  ↑ 1,1 Мбит/с');
    expect(m.servers).toEqual([{ id: 'a', label: 'A · 40 мс', active: true }]);
    expect(m.auto).toBe(true);
    expect(m.online).toBe(true);
    expect(m.profileId).toBe('p');
    expect(m.labels.auto).toBe('Автовыбор');
  });

  it('always the same number of info lines: an open menu is not rebuilt', () => {
    for (const m of [model(up({ speed: null })), model(up()), model({ ...down, enabled: false }),
      trayModel({ conn: { ...online, phase: 'offline' }, status: up() }), model(up(), { error: 'busy' }), model(null)])
      expect(m.info).toHaveLength(INFO_LINES);
    expect(model(up({ speed: null })).info[3]).toBe('Скорость: —');
  });

  it('auto selection is the mode of the daemon (status.manual), not set_auto of the server', () => {
    const m = model(up({ manual: true }));
    expect(m.info[1]).toBe('Сервер: A (вручную)');
    expect(m.auto).toBe(false);
    // a reason with "by hand" or a server named "manual" does not matter
    const n = model(up({ manual: false, last_switch: { to: 'a', reason: 'test by hand', at: 1 } }));
    expect(n.info[1]).toBe('Сервер: A (авто)');
    // a package before #78: unknown, the item disabled
    const old = model({ ...STATUS_UP } as StatusUp);
    expect(old.info[1]).toBe('Сервер: A');
    expect(old.auto).toBeNull();
  });

  it('quarantine and a failed test in the server list', () => {
    const m = model(up({
      servers: [
        { ...STATUS_UP.servers[0] },
        { id: 'b', name: 'B', proto: 'trojan', address: 'b', port: 1, latency: null, quarantined: true, auto: false, limited: false },
        { id: 'c', name: 'C', proto: 'ss', address: 'c', port: 1, latency: -1, quarantined: false, auto: true, limited: false },
      ],
    }));
    expect(m.servers[1]).toEqual({ id: 'b', label: 'B · — · карантин', active: false });
    expect(m.servers[2]).toEqual({ id: 'c', label: 'C · нет ответа', active: false });
  });

  it('xray down and a stopped service', () => {
    expect(model(up({ state: 'xray_down' })).info[0]).toBe('● xray не запущен · xray не запущен');
    const m = model({ ...down, enabled: false });
    expect(m.info[0]).toBe('● Служба остановлена');
    expect(m.servers).toEqual([]);
    expect(m.auto).toBeNull();
  });

  it('router not answering, or polls failing for long: actions off', () => {
    const m = trayModel({ conn: { ...online, phase: 'offline' }, status: up() });
    expect(m.info[0]).toBe('● Роутер не отвечает');
    expect(m.online).toBe(false);
    const s = model(up(), { stale: 'нет доступа' });
    expect(s.info[0]).toBe('● Роутер не отвечает · нет доступа');
    expect(s.online).toBe(false);
    expect(s.icon).toBe('offline');
  });

  it('a long list is cut, the active server stays', () => {
    const servers = Array.from({ length: 60 }, (_, i) => ({ ...STATUS_UP.servers[0], id: `s${i}`, name: `S${i}` }));
    const m = model(up({ servers, active: 's55' }));
    expect(m.servers).toHaveLength(MAX_SERVERS + 2);
    expect(m.servers.at(-2)).toMatchObject({ id: 's55', active: true });
    expect(m.servers.at(-1)).toMatchObject({ id: '', label: '… и ещё 20 в окне' });
  });

  it('Stop asks unless the kill switch is off', () => {
    expect(model(up(), { killswitch: true }).confirmStop).toMatch(/kill switch/);
    expect(model(up(), { killswitch: null }).confirmStop).toMatch(/kill switch/);
    expect(model(up(), { killswitch: false }).confirmStop).toBeNull();
  });
});

describe('startTray', () => {
  beforeEach(() => vi.useFakeTimers());
  afterEach(() => vi.useRealTimers());

  function setup() {
    let status: StatusUp = up({ servers: [...STATUS_UP.servers, { ...STATUS_UP.servers[0], id: 'b', name: 'B' }] });
    const router = new FakeRouter()
      .on('luci.xvpn.version', () => ({ version: '0.1.0-r1', api: 1 }))
      .on('luci.xvpn.status', () => status)
      .on('uci.get', () => ({ value: '1' }))
      .on('luci.xvpn.select', ({ id }) => {
        status = { ...status, active: id as string, manual: true };
        return { ok: true };
      })
      .on('luci.xvpn.auto', () => {
        status = { ...status, manual: false };
        return { ok: true };
      })
      .on('luci.xvpn.service', () => ({ ok: false, error: 'busy' }));
    const other = new FakeRouter()
      .on('luci.xvpn.version', () => ({ version: '0.1.0-r1', api: 1 }))
      .on('luci.xvpn.status', () => up({ active: 'z', servers: [{ ...STATUS_UP.servers[0], id: 'z', name: 'Z' }] }));
    const conn = new Connection({ transport: (p) => (p.id === 'other' ? other : router), intervalMs: 1000 });
    const models: TrayModel[] = [];
    const errors: string[] = [];
    let fire!: (a: TrayAction) => void;
    const backend: TrayBackend = {
      update: async (m) => void models.push(m),
      onAction: (fn) => { fire = fn; return () => {}; },
    };
    const stop = startTray(conn, backend, { onError: (e) => errors.push(e) });
    return {
      router, conn, models, errors, stop,
      fire: (a: TrayAction) => fire(a),
      setStatus: (s: StatusUp) => { status = s; },
      calls: (m: string) => router.calls.filter((c) => c.method === m),
    };
  }

  it('updates on each change, not on equal polls', async () => {
    const { conn, models, stop } = setup();
    expect(models.at(-1)?.icon).toBe('offline');
    await conn.connect(profile);
    await vi.advanceTimersByTimeAsync(0);
    expect(models.at(-1)?.icon).toBe('connected');
    const n = models.length;
    await vi.advanceTimersByTimeAsync(3000);
    expect(models.length).toBe(n);
    stop();
    conn.disconnect();
  });

  it('a failover reaches the tray at the next poll', async () => {
    const { conn, models, setStatus, stop } = setup();
    await conn.connect(profile);
    await vi.advanceTimersByTimeAsync(0);
    setStatus(up({ state: 'failover' }));
    await vi.advanceTimersByTimeAsync(1000);
    expect(models.at(-1)?.icon).toBe('failover');
    stop();
    conn.disconnect();
  });

  it('select from the menu is applied and polled at once', async () => {
    const { conn, models, fire, calls, stop } = setup();
    await conn.connect(profile);
    await vi.advanceTimersByTimeAsync(0);
    fire({ action: 'select', id: 'b' });
    await vi.advanceTimersByTimeAsync(0);
    expect(calls('select')[0]?.args).toEqual({ id: 'b' });
    expect(models.at(-1)?.servers.find((s) => s.active)?.id).toBe('b');
    expect(models.at(-1)?.auto).toBe(false);
    stop();
    conn.disconnect();
  });

  it('Auto selection: on calls auto, off keeps the active server by hand', async () => {
    const { conn, models, fire, calls, stop } = setup();
    await conn.connect(profile);
    await vi.advanceTimersByTimeAsync(0);
    fire({ action: 'auto', value: false });
    await vi.advanceTimersByTimeAsync(0);
    expect(calls('select')[0]?.args).toEqual({ id: 'a' });
    expect(models.at(-1)?.auto).toBe(false);
    fire({ action: 'auto', value: true });
    await vi.advanceTimersByTimeAsync(0);
    expect(calls('auto')).toHaveLength(1);
    expect(models.at(-1)?.auto).toBe(true);
    expect(calls('set_auto')).toEqual([]);
    stop();
    conn.disconnect();
  });

  it('one action at a time: busy in the model, a second click is dropped', async () => {
    const { conn, models, fire, calls, router, stop } = setup();
    await conn.connect(profile);
    await vi.advanceTimersByTimeAsync(0);
    let release!: () => void;
    router.on('luci.xvpn.test', () => ({ ok: true, run: 2 }));
    const req = router.request.bind(router);
    router.request = async (b) => {
      if ((b.params as string[])[2] === 'test')
        await new Promise<void>((r) => { release = r; });
      return req(b);
    };
    fire({ action: 'test' });
    await vi.advanceTimersByTimeAsync(0);
    expect(models.at(-1)?.busy).toBe(true);
    fire({ action: 'test' });
    release();
    await vi.advanceTimersByTimeAsync(0);
    expect(calls('test')).toHaveLength(1);
    expect(models.at(-1)?.busy).toBe(false);
    stop();
    conn.disconnect();
  });

  it('a refused action is reported to the window and shown in the state line', async () => {
    const { conn, models, errors, fire, stop } = setup();
    await conn.connect(profile);
    await vi.advanceTimersByTimeAsync(0);
    fire({ action: 'service', value: 'restart' });
    await vi.advanceTimersByTimeAsync(0);
    expect(errors).toEqual(['busy']);
    expect(models.at(-1)?.info[0]).toMatch(/⚠ busy$/);
    stop();
    conn.disconnect();
  });

  it('auto off without an active server says so', async () => {
    const { conn, errors, fire, setStatus, stop } = setup();
    setStatus(up({ active: null }));
    await conn.connect(profile);
    await vi.advanceTimersByTimeAsync(0);
    fire({ action: 'auto', value: false });
    await vi.advanceTimersByTimeAsync(0);
    expect(errors).toHaveLength(1);
    stop();
    conn.disconnect();
  });

  it('an action finishing after a profile change does not poll the old router into the new one', async () => {
    const { conn, models, router, fire, stop } = setup();
    await conn.connect(profile);
    await vi.advanceTimersByTimeAsync(0);
    let release!: () => void;
    const req = router.request.bind(router);
    router.request = async (b) => {
      if ((b.params as string[])[2] === 'select')
        await new Promise<void>((r) => { release = r; });
      return req(b);
    };
    fire({ action: 'select', id: 'b' });
    await vi.advanceTimersByTimeAsync(0);
    await conn.connect({ ...profile, id: 'other' });
    await vi.advanceTimersByTimeAsync(0);
    const statusCalls = router.calls.filter((c) => c.method === 'status').length;
    release();
    await vi.advanceTimersByTimeAsync(0);
    expect(router.calls.filter((c) => c.method === 'status').length).toBe(statusCalls);
    expect(models.at(-1)?.servers.map((s) => s.id)).toEqual(['z']);
    stop();
    conn.disconnect();
  });

  it('polls failing for three intervals: the tray stops showing the old status as current', async () => {
    const { conn, models, router, stop } = setup();
    await conn.connect(profile);
    await vi.advanceTimersByTimeAsync(0);
    // ubus timeouts: not an error that stops the connection, the poller keeps going
    router.request = async () => ({ jsonrpc: '2.0', id: 1, result: [7] });
    await vi.advanceTimersByTimeAsync(1000);
    expect(models.at(-1)?.icon).toBe('connected');
    await vi.advanceTimersByTimeAsync(4000);
    expect(models.at(-1)?.icon).toBe('offline');
    expect(models.at(-1)?.online).toBe(false);
    stop();
    conn.disconnect();
  });
});
