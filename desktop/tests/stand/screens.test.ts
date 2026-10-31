// The tabs of #79 against the stand of scripts/luci.sh: saving from the app is seen by
// LuCI and the other way round, apply without confirm is rolled back by rpcd, and the
// screens work for the rpcd user of the app without root (rpcd-user.sh). "LuCI" here is
// a root session doing what LuCI does: uci set, apply with rollback, confirm.
//   XVPN_URL, XVPN_PASS as in client.test.ts; XVPN_CONTAINER: the stand container, needed
//   to create the rpcd user (else the app side logs in as root as well).
// Run by scripts/desktop-itest.sh.

import { execFileSync } from 'node:child_process';
import { randomBytes } from 'node:crypto';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { UbusClient } from '../../src/api/ubus';
import { UciApi } from '../../src/api/uci';
import { XvpnApi } from '../../src/api/xvpn';
import { Bus } from '../../src/core/bus';
import { AppContext } from '../../src/core/connection';
import { applyStaged, loadConfig, save } from '../../src/core/apply';
import { collectDiagnostics } from '../../src/core/diagnostics';
import { PollerEvents, StatusPoller } from '../../src/core/poller';
import { NodeTransport } from './node-transport';

const URL = process.env.XVPN_URL ?? 'http://127.0.0.1:8019';
const PASS = process.env.XVPN_PASS ?? 'xvpn-luci-test';
const CONTAINER = process.env.XVPN_CONTAINER;
const DOCKER = (process.env.DOCKER ?? 'docker --context default').split(' ');
const APP_USER = 'xvpnitest';

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

function inStand(cmd: string, input?: string): string {
  return execFileSync(DOCKER[0], [...DOCKER.slice(1), 'exec', '-i', CONTAINER!, 'sh', '-c', cmd], { input, encoding: 'utf8' });
}

function client(user: string, password: string) {
  const ubus = new UbusClient(new NodeTransport(URL, user, password), { timeoutMs: 15_000 });
  return { ubus, xvpn: new XvpnApi(ubus), uci: new UciApi(ubus) };
}

// a test password of the stand only, made for this run
const appPass = randomBytes(12).toString('hex');
let app = client('root', PASS);
const luci = client('root', PASS);
const fast = { timeout: 20, holdoffMs: 500, intervalMs: 500 };

/** what LuCI does on "Save & Apply" */
async function luciSave(section: string, values: Record<string, string>): Promise<void> {
  await luci.uci.set('xvpn', section, values);
  await luci.uci.apply({ rollback: true, timeout: 30 });
  await luci.uci.confirm();
}

describe(`tabs of #79 against ${URL}`, () => {
  let health: Record<string, unknown>;
  let access: Record<string, unknown>;

  beforeAll(async () => {
    if (CONTAINER) {
      inStand(`sh /usr/share/xvpn/rpcd-user.sh add ${APP_USER} -`, `${appPass}\n`);
      app = client(APP_USER, appPass);
    }
    health = (await luci.uci.getSection('xvpn', 'health'))!;
    access = (await luci.uci.getSection('xvpn', 'access'))!;
  });

  afterAll(async () => {
    // the stand as it was
    await luciSave('health', { interval: String(health.interval ?? '30'), quarantine: String(health.quarantine ?? '300') });
    await luciSave('access', { dns_server: String(access.dns_server ?? 'https://cloudflare-dns.com/dns-query') });
    if (CONTAINER)
      inStand(`sh /usr/share/xvpn/rpcd-user.sh del ${APP_USER}`);
  });

  it.skipIf(!CONTAINER)('the app logs in as the rpcd user without root', async () => {
    await app.xvpn.status();
    expect(app.ubus.session).toBeTruthy();
    // no rights beyond luci-app-xvpn: another config is refused
    await expect(app.uci.get('network', 'lan', 'proto')).rejects.toMatchObject({ code: 'acl' });
  });

  it('a change saved in the app is seen by LuCI', async () => {
    const v = String(Number(health.interval ?? 30) === 45 ? 50 : 45);
    expect(await save(app.uci, app.xvpn, [{ section: 'health', type: 'health', set: { interval: v } }], fast)).toBe('applied');
    expect(await luci.uci.get('xvpn', 'health', 'interval')).toBe(v);
    // and by the backend, which LuCI reads too
    expect(app.ubus.hasStaged).toBe(false);
  });

  it('a change saved in LuCI is seen by the app', async () => {
    await luciSave('access', { dns_server: '9.9.9.9' });
    expect((await app.uci.getAll('xvpn')).access.dns_server).toBe('9.9.9.9');
  });

  it('apply without confirm is rolled back by the router', async () => {
    const before = await luci.uci.get('xvpn', 'health', 'quarantine');
    await app.uci.set('xvpn', 'health', { quarantine: '123' });
    await app.uci.apply({ rollback: true, timeout: 5 });
    // applied at once: LuCI sees it while the router waits for the confirm
    expect(await luci.uci.get('xvpn', 'health', 'quarantine')).toBe('123');
    await sleep(9000);
    expect(await luci.uci.get('xvpn', 'health', 'quarantine')).toBe(before);
    // the late confirm: rpcd no longer waits for it (ubus status 5)
    await expect(app.uci.confirm()).rejects.toMatchObject({ code: 'ubus', detail: { ubusStatus: 5 } });
    // rpcd put the reverted change back into the session of the apply as staged: the
    // forms load through loadConfig, which drops it
    expect(await app.uci.changes('xvpn')).toContainEqual(['set', 'health', 'quarantine', '123']);
    expect((await loadConfig(app.uci)).health.quarantine).toBe(before);
    expect(await app.uci.changes('xvpn')).toEqual([]);
  }, 30_000);

  it('applyStaged reports the late confirm as rolled back', async () => {
    await app.uci.set('xvpn', 'health', { quarantine: '124' });
    // the router "cannot be reached" for longer than the timer: no confirm in time
    let calls = 0;
    const slow = new Proxy(app.xvpn, {
      get: (o, k) => (k === 'version' ? async () => {
        calls++;
        await sleep(7000);
        return o.version();
      } : Reflect.get(o, k)),
    });
    expect(await applyStaged(app.uci, slow, { timeout: 5, holdoffMs: 0 })).toBe('rolled_back');
    expect(calls).toBe(1);
    expect(await luci.uci.get('xvpn', 'health', 'quarantine')).not.toBe('124');
    // nothing of it left in the session of the app
    expect(await app.uci.changes('xvpn')).toEqual([]);
  }, 30_000);

  it('the read and action methods of the tabs work for the app user', async () => {
    const subs = await app.xvpn.subscriptions();
    expect(subs.subscriptions[0]?.name).toBe('Test subscription');
    const ap = await app.xvpn.accessPoints();
    expect(ap.networks.map((n) => n.name)).toContain('lan');
    expect(await app.xvpn.split()).toHaveProperty('ru');
    expect(await app.xvpn.firewall()).toBeTypeOf('object');
    expect((await app.xvpn.log()).log ?? '').toBeTypeOf('string');
    expect((await app.xvpn.parseLinks(['vless://11111111-2222-3333-4444-555555555555@10.0.0.1:443?type=tcp#x'])).links?.[0])
      .toMatchObject({ proto: 'vless' });
    expect(await app.xvpn.update(subs.subscriptions[0].id)).toHaveProperty('ok');
  });

  it('the diagnostics have every part and no subscription URL or link credentials', async () => {
    const bus = new Bus<PollerEvents>();
    const ctx = {
      profile: { id: 'stand', name: 'stand', url: URL, username: CONTAINER ? APP_USER : 'root' },
      pkg: { version: 'stand', api: 1 },
      ubus: app.ubus, xvpn: app.xvpn, uci: app.uci, poller: new StatusPoller(app.xvpn, bus), bus,
    } as unknown as AppContext;
    const text = await collectDiagnostics(ctx, { app: 'itest' });
    for (const part of ['status', 'firewall', 'subscriptions', 'config xvpn', 'log'])
      expect(text).toMatch(new RegExp(`===== ${part} =====\\n(?!error: )`));
    expect(text).not.toContain('cgi-bin/xvpn-sub');
    expect(text).not.toContain('11111111-2222-3333-4444-555555555555');
    expect(text).toContain('vless://***@127.0.0.1:18443');
  });
});
