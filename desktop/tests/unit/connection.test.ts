import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { XvpnError } from '../../src/api/errors';
import { Profile } from '../../src/api/profiles';
import { Connection } from '../../src/core/connection';
import { FakeRouter, STATUS_UP } from './fake';

const profile: Profile = { id: 'p', name: 'Home', url: 'http://192.168.1.1', username: 'root' };

function router() {
  return new FakeRouter()
    .on('luci.xvpn.version', () => ({ version: '0.2.0-r1', api: 1 }))
    .on('luci.xvpn.status', () => STATUS_UP);
}

describe('Connection', () => {
  beforeEach(() => vi.useFakeTimers());
  afterEach(() => vi.useRealTimers());

  it('goes online with the package version and starts polling', async () => {
    const r = router();
    const conn = new Connection({ transport: () => r, intervalMs: 1000 });
    const phases: string[] = [];
    conn.bus.on('connection', (s) => phases.push(s.phase));
    const st = await conn.connect(profile);
    expect(st.phase).toBe('online');
    expect(st.pkg).toEqual({ version: '0.2.0-r1', api: 1 });
    expect(conn.context?.pkg.version).toBe('0.2.0-r1');
    await vi.advanceTimersByTimeAsync(0);
    expect(conn.context?.poller.status).toEqual(STATUS_UP);
    expect(phases).toEqual(['connecting', 'online']);
    conn.disconnect();
  });

  it('fails without retries on a wrong password', async () => {
    const r = router();
    r.given = 'bad';
    const conn = new Connection({ transport: () => r });
    const st = await conn.connect(profile);
    expect(st.phase).toBe('failed');
    expect(st.error?.code).toBe('wrong_password');
    await vi.advanceTimersByTimeAsync(60_000);
    expect(r.logins).toBe(1);
  });

  it('keeps retrying while the router does not answer at startup', async () => {
    const r = router();
    r.failures.push(new XvpnError('unreachable'), new XvpnError('timeout'));
    const conn = new Connection({ transport: () => r, retryMs: 1000 });
    const p = conn.connect(profile);
    await vi.advanceTimersByTimeAsync(0);
    expect(conn.state.get().phase).toBe('offline');
    await vi.advanceTimersByTimeAsync(2000);
    expect((await p).phase).toBe('online');
    conn.disconnect();
  });

  it('survives a router reboot: offline, then online with a new session', async () => {
    const r = router();
    const conn = new Connection({ transport: () => r, intervalMs: 1000 });
    await conn.connect(profile);
    await vi.advanceTimersByTimeAsync(0);
    // reboot: no answers for a while, then rpcd without the old session
    r.failures.push(...Array.from({ length: 3 }, () => new XvpnError('unreachable')));
    await vi.advanceTimersByTimeAsync(2000);
    expect(conn.state.get().phase).toBe('offline');
    r.expireSessions();
    await vi.advanceTimersByTimeAsync(2000);
    expect(conn.state.get().phase).toBe('online');
    expect(r.logins).toBe(2);
    conn.disconnect();
  });

  it('an old package fails with a clear code', async () => {
    const r = new FakeRouter().on('luci.xvpn.status', () => STATUS_UP);
    r.denied.add('luci.xvpn.version');
    const conn = new Connection({ transport: () => r });
    expect((await conn.connect(profile)).error?.code).toBe('old_package');
  });
});
