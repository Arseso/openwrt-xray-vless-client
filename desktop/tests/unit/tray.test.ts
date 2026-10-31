import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { Profile } from '../../src/api/profiles';
import { Status, StatusUp } from '../../src/api/xvpn';
import { Connection, ConnectionState } from '../../src/core/connection';
import { setLang } from '../../src/core/i18n';
import { TrayAction, TrayBackend, startTray } from '../../src/tray';
import { MAX_SERVERS, TrayModel, trayIcon, trayModel } from '../../src/tray/model';
import { FakeRouter, STATUS_UP } from './fake';

const profile: Profile = { id: 'p', name: 'Home', url: 'https://192.168.1.1', username: 'root' };
const online: ConnectionState = { phase: 'online', profile, pkg: { version: '0.1.0-r1', api: 1 }, error: null };
const up = (patch: Partial<StatusUp> = {}) => ({ ...STATUS_UP, ...patch }) as StatusUp;
const down = { enabled: true, time: 1, running: false, timeout: false } as const;

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
});

describe('tray menu texts', () => {
  beforeEach(() => setLang('ru'));
  afterEach(() => setLang('en'));

  it('the lines of the issue: state, server (auto), ping, speed', () => {
    const m = trayModel(online, up({ speed: { down: 1_540_000, up: 137_500 } }));
    expect(m.info).toEqual(['● Подключено · xray работает', 'Сервер: A (авто)', 'Пинг: 40 мс', 'Скорость: ↓ 12,3 Мбит/с  ↑ 1,1 Мбит/с']);
    expect(m.tooltip).toBe('xvpn · Подключено · xray работает\nA · 40 мс\n↓ 12,3 Мбит/с  ↑ 1,1 Мбит/с');
    expect(m.servers).toEqual([{ id: 'a', label: 'A · 40 мс', active: true }]);
    expect(m.auto).toBe(true);
    expect(m.online).toBe(true);
    expect(m.luciUrl).toBe('https://192.168.1.1/cgi-bin/luci/admin/services/xvpn');
    expect(m.labels.auto).toBe('Автовыбор');
  });

  it('no speed line until the second reading (or before #83)', () => {
    expect(trayModel(online, up({ speed: null })).info).toHaveLength(3);
    expect(trayModel(online, up()).info).toHaveLength(3);
  });

  it('a server chosen by hand, quarantine, no ping', () => {
    const st = up({
      last_switch: { to: 'a', reason: 'manual selection', at: 1 },
      servers: [
        { ...STATUS_UP.servers[0] },
        { id: 'b', name: 'B', proto: 'trojan', address: 'b', port: 1, latency: null, quarantined: true, auto: false, limited: false },
      ],
    });
    const m = trayModel(online, st);
    expect(m.info[1]).toBe('Сервер: A (вручную)');
    expect(m.servers[1]).toEqual({ id: 'b', label: 'B · — · карантин', active: false });
  });

  it('xray down and a stopped service', () => {
    expect(trayModel(online, up({ state: 'xray_down' })).info[0]).toBe('● xray не запущен · xray не запущен');
    const m = trayModel(online, { ...down, enabled: false });
    expect(m.info).toEqual(['● Служба остановлена']);
    expect(m.online).toBe(true);
    expect(m.servers).toEqual([]);
    expect(m.auto).toBeNull();
  });

  it('router not answering: one line, actions off', () => {
    const m = trayModel({ ...online, phase: 'offline' }, up());
    expect(m.info).toEqual(['● Роутер не отвечает']);
    expect(m.online).toBe(false);
    expect(m.icon).toBe('offline');
  });

  it('a long list is cut, the active server stays', () => {
    const servers = Array.from({ length: 60 }, (_, i) => ({ ...STATUS_UP.servers[0], id: `s${i}`, name: `S${i}` }));
    const m = trayModel(online, up({ servers, active: 's55' }));
    expect(m.servers).toHaveLength(MAX_SERVERS + 2);
    expect(m.servers.at(-2)).toMatchObject({ id: 's55', active: true });
    expect(m.servers.at(-1)).toMatchObject({ id: '', label: '… и ещё 20 в окне' });
  });

  it('an error of an action is shown as a line', () => {
    expect(trayModel(online, up(), 'busy').info.at(-1)).toBe('⚠ busy');
  });
});

describe('startTray', () => {
  beforeEach(() => vi.useFakeTimers());
  afterEach(() => vi.useRealTimers());

  function setup() {
    const router = new FakeRouter()
      .on('luci.xvpn.version', () => ({ version: '0.1.0-r1', api: 1 }))
      .on('luci.xvpn.status', () => status);
    let status: StatusUp = up({ servers: [...STATUS_UP.servers, { ...STATUS_UP.servers[0], id: 'b', name: 'B' }] });
    router.on('luci.xvpn.select', ({ id }) => {
      status = { ...status, active: id as string, last_switch: { to: id as string, reason: 'manual selection', at: 2 } };
      return { ok: true };
    });
    router.on('luci.xvpn.set_auto', () => ({ ok: false, error: 'unknown server' }));
    const conn = new Connection({ transport: () => router, intervalMs: 1000 });
    const models: TrayModel[] = [];
    let fire!: (a: TrayAction) => void;
    const backend: TrayBackend = {
      update: async (m) => void models.push(m),
      onAction: (fn) => { fire = fn; return () => {}; },
    };
    const stop = startTray(conn, backend);
    return { router, conn, models, fire: (a: TrayAction) => fire(a), stop, setStatus: (s: StatusUp) => { status = s; } };
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

  it('select from the menu calls luci.xvpn select and polls at once', async () => {
    const { conn, models, router, fire, stop } = setup();
    await conn.connect(profile);
    await vi.advanceTimersByTimeAsync(0);
    fire({ action: 'select', id: 'b' });
    await vi.advanceTimersByTimeAsync(0);
    expect(router.calls.find((c) => c.method === 'select')?.args).toEqual({ id: 'b' });
    expect(models.at(-1)?.servers.find((s) => s.active)?.id).toBe('b');
    expect(models.at(-1)?.info[1]).toMatch(/B \((manual|вручную)\)/);
    stop();
    conn.disconnect();
  });

  it('a refused action shows its error in the menu for a while', async () => {
    const { conn, models, fire, stop } = setup();
    await conn.connect(profile);
    await vi.advanceTimersByTimeAsync(0);
    fire({ action: 'auto', value: false });
    await vi.advanceTimersByTimeAsync(0);
    expect(models.at(-1)?.info.at(-1)).toBe('⚠ unknown server');
    await vi.advanceTimersByTimeAsync(21_000);
    expect(models.at(-1)?.info.at(-1)).not.toMatch(/⚠/);
    stop();
    conn.disconnect();
  });
});
