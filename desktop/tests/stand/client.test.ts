// The TS client against a live router: the stand of scripts/luci.sh by default.
//   XVPN_URL (http://127.0.0.1:8019), XVPN_USER (root), XVPN_PASS (xvpn-luci-test),
//   XVPN_CONTAINER: the stand container; set, the test restarts rpcd in it (all
//   sessions gone, as after a router reboot) and stops uhttpd for a while.
// Run by scripts/desktop-itest.sh.

import { execFileSync } from 'node:child_process';
import { describe, expect, it } from 'vitest';
import { Profile } from '../../src/api/profiles';
import { UbusClient } from '../../src/api/ubus';
import { UciApi } from '../../src/api/uci';
import { checkPackage } from '../../src/api/version';
import { XvpnApi } from '../../src/api/xvpn';
import { Bus } from '../../src/core/bus';
import { Connection } from '../../src/core/connection';
import { PollerEvents, StatusPoller } from '../../src/core/poller';
import { NodeTransport } from './node-transport';

const URL = process.env.XVPN_URL ?? 'http://127.0.0.1:8019';
const USER = process.env.XVPN_USER ?? 'root';
const PASS = process.env.XVPN_PASS ?? 'xvpn-luci-test';
const CONTAINER = process.env.XVPN_CONTAINER;
const DOCKER = (process.env.DOCKER ?? 'docker --context default').split(' ');

function inStand(cmd: string): void {
  execFileSync(DOCKER[0], [...DOCKER.slice(1), 'exec', CONTAINER!, 'sh', '-c', cmd], { stdio: 'inherit' });
}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

async function until<T>(fn: () => T | Promise<T>, ms: number): Promise<NonNullable<T>> {
  const end = Date.now() + ms;
  for (;;) {
    const v = await fn();
    if (v)
      return v as NonNullable<T>;
    if (Date.now() > end)
      throw new Error('timed out');
    await sleep(200);
  }
}

function client(password = PASS) {
  const ubus = new UbusClient(new NodeTransport(URL, USER, password), { timeoutMs: 15_000 });
  return { ubus, xvpn: new XvpnApi(ubus), uci: new UciApi(ubus) };
}

describe(`client against ${URL}`, () => {
  it('reads the package version (or says the package is older than the app)', async () => {
    const { xvpn } = client();
    try {
      const pkg = await checkPackage(xvpn);
      // 'unknown': files copied without opkg (scripts/luci.sh), see pkg_version() of luci.xvpn
      expect(pkg.version).toMatch(/^(\d+\.\d+\.\d+-r\d+|unknown)$/);
      expect(pkg.api).toBe(1);
      console.log('luci-app-xvpn', pkg.version, 'api', pkg.api);
    }
    catch (e) {
      // a package without luci.xvpn version (before #83) must give exactly this code
      expect(e).toMatchObject({ code: 'old_package' });
      console.log('luci-app-xvpn without luci.xvpn version: old_package');
    }
  });

  it('calls the read methods of luci.xvpn', async () => {
    const { xvpn } = client();
    const status = await xvpn.status();
    expect(typeof status.enabled).toBe('boolean');
    expect(status.time).toBeGreaterThan(1e9);
    if (status.running) {
      expect(status.state).toMatch(/^[a-z_]+$/);
      expect(Array.isArray(status.servers)).toBe(true);
    }
    const servers = await xvpn.servers();
    expect(servers.servers.map((s) => s.name)).toEqual(expect.arrayContaining(['manual-live', 'manual-dead']));
    // the subscription of a fresh stand may not be downloaded yet
    if (!(await xvpn.subscriptions()).subscriptions[0]?.userinfo)
      expect(await xvpn.update()).toMatchObject({ ok: true });
    const subs = await until(async () => {
      const r = await xvpn.subscriptions();
      return r.subscriptions[0]?.userinfo ? r : null;
    }, 30_000);
    expect(subs.subscriptions[0]?.name).toBe('Test subscription');
    expect(subs.subscriptions[0]?.userinfo?.total).toBe(100000000000);
    await expect(xvpn.accessPoints()).resolves.toHaveProperty('networks');
    await expect(xvpn.stats()).resolves.toHaveProperty('traffic');
    await expect(xvpn.log()).resolves.toBeTypeOf('object');
    await expect(xvpn.firewall()).resolves.toBeTypeOf('object');
    await expect(xvpn.split()).resolves.toHaveProperty('ru');
    const parsed = await xvpn.parseLinks(['vless://11111111-2222-3333-4444-555555555555@10.0.0.1:443?type=tcp#x', 'nope']);
    expect(parsed.links?.[0]).toMatchObject({ proto: 'vless', address: '10.0.0.1', port: 443 });
    expect(parsed.links?.[1]).toHaveProperty('error');
  });

  it('reads and stages uci without applying', async () => {
    const { uci, ubus } = client();
    expect(await uci.get('xvpn', 'main', 'enabled')).toBe('1');
    const subs = await uci.sections('xvpn', 'subscription');
    expect(subs[0]?.name).toBe('Test subscription');
    expect(await uci.get('xvpn', 'main', 'no_such_option')).toBeNull();
    // staged in this session only; never applied, gone with the session (the ACL of
    // luci-base has no uci revert / commit)
    await uci.set('xvpn', 'main', { desktop_itest: '1' });
    expect(await uci.changes('xvpn')).toContainEqual(['set', 'main', 'desktop_itest', '1']);
    expect(await client().uci.get('xvpn', 'main', 'desktop_itest')).toBeNull();
    ubus.logout();
  });

  it('rejects a wrong password', async () => {
    await expect(client('wrong-password').xvpn.status()).rejects.toMatchObject({ code: 'wrong_password' });
  });

  it('rpcd tells a live session from a dead one (session access)', async () => {
    const { ubus, xvpn } = client();
    await xvpn.status();
    const alive = (sid: string) => (ubus as unknown as { alive(s: string): Promise<boolean> }).alive(sid);
    expect(await alive(ubus.session!)).toBe(true);
    expect(await alive('ffffffffffffffffffffffffffffffff')).toBe(false);
  });

  it('staged uci changes lost with the session: session_lost, not an empty apply', async () => {
    const { ubus, uci } = client();
    await uci.set('xvpn', 'main', { desktop_itest: '1' });
    (ubus as unknown as { sid: string }).sid = 'ffffffffffffffffffffffffffffffff';
    await expect(uci.apply()).rejects.toMatchObject({ code: 'session_lost' });
    ubus.logout();
  });

  it('logs in again when the session is gone', async () => {
    const { ubus, xvpn } = client();
    await xvpn.status();
    const first = ubus.session;
    // a session the router does not know, as after it expired
    (ubus as unknown as { sid: string }).sid = 'ffffffffffffffffffffffffffffffff';
    await xvpn.status();
    expect(ubus.session).not.toBe(first);
    expect(ubus.session).not.toBe('ffffffffffffffffffffffffffffffff');
  });

  it.skipIf(!CONTAINER)('the poller renews the session after rpcd restart and reports router down/up', async () => {
    const { ubus, xvpn } = client();
    const bus = new Bus<PollerEvents>();
    const events: string[] = [];
    bus.on('router-down', () => events.push('down'));
    bus.on('router-up', () => events.push('up'));
    bus.on('poll-error', ({ error }) => events.push(`error:${error.code}`));
    const poller = new StatusPoller(xvpn, bus, { intervalMs: 300 });
    poller.start();
    try {
      await until(() => poller.status, 10_000);
      const sid = ubus.session;
      inStand('/etc/init.d/rpcd restart');
      await until(() => ubus.session !== sid, 15_000);
      inStand('/etc/init.d/uhttpd stop');
      await until(() => events.includes('down'), 15_000);
      inStand('/etc/init.d/rpcd restart; /etc/init.d/uhttpd start');
      await until(() => events.includes('up'), 30_000);
      expect(events.filter((e) => e.startsWith('error:') && !/unreachable|timeout/.test(e))).toEqual([]);
    }
    finally {
      poller.stop();
    }
  });

  it.skipIf(!CONTAINER)('survives rpcd restart and uhttpd going away (router reboot)', async () => {
    const profile: Profile = { id: 'stand', name: 'stand', url: URL, username: USER };
    // a package without luci.xvpn version stops the connection at old_package (the unit
    // tests cover that); the rest needs a package with it
    if (await checkPackage(client().xvpn).then(() => false, () => true))
      return console.log('skipped: the stand has no luci.xvpn version');
    const conn = new Connection({ transport: () => new NodeTransport(URL, USER, PASS), intervalMs: 500, retryMs: 500 });
    const events: string[] = [];
    conn.bus.on('router-down', () => events.push('down'));
    conn.bus.on('router-up', () => events.push('up'));
    expect((await conn.connect(profile)).phase).not.toBe('failed');
    await until(() => conn.context?.poller.status, 10_000);
    const sid = conn.context!.ubus.session;

    // all sessions dropped
    inStand('/etc/init.d/rpcd restart');
    await until(() => conn.context!.ubus.session !== sid && conn.context!.poller.status, 15_000);

    // no answers at all, then back
    inStand('/etc/init.d/uhttpd stop');
    await until(() => events.includes('down'), 15_000);
    expect(['offline']).toContain(conn.state.get().phase);
    inStand('/etc/init.d/rpcd restart; /etc/init.d/uhttpd start');
    await until(() => events.includes('up') && conn.state.get().phase !== 'offline', 30_000);
    expect(conn.state.get().error).toBeNull();
    conn.disconnect();
  });
});
