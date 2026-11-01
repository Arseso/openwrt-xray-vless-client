// The upgrade of luci-app-xvpn from the app (src/core/routerpkg.ts) against the stand. It
// installs packages on the stand, so it runs only when asked:
//   XVPN_PKG_OLD  a directory with the ipk files installed by opkg first (the release
//                 v0.2.0: no helper yet, the upgrade goes through LuCI's package manager)
//   XVPN_PKG_NEW  the ipk files the test serves as the latest release (built with a newer
//                 PKG_RELEASE: sh scripts/build.sh); the signature of SHA256SUMS is Rust's
//                 (cargo test), the sha256 of each file the helper checks on the router
//   XVPN_CONTAINER the stand container
// The app reconnects by itself: the Connection of the app sees the new version.

import { execFileSync } from 'node:child_process';
import { createHash, randomBytes } from 'node:crypto';
import { readFileSync, readdirSync } from 'node:fs';
import { join } from 'node:path';
import { describe, expect, it } from 'vitest';
import { Release, ReleaseSource } from '../../src/api/release';
import { UbusClient } from '../../src/api/ubus';
import { XvpnApi } from '../../src/api/xvpn';
import { Connection } from '../../src/core/connection';
import { PkgFlow, PkgState } from '../../src/core/routerpkg';
import { NodeTransport } from './node-transport';

const URL = process.env.XVPN_URL ?? 'http://127.0.0.1:8019';
const PASS = process.env.XVPN_PASS ?? 'xvpn-luci-test';
const CONTAINER = process.env.XVPN_CONTAINER;
const OLD = process.env.XVPN_PKG_OLD;
const NEW = process.env.XVPN_PKG_NEW;
const DOCKER = (process.env.DOCKER ?? 'docker --context default').split(' ');

function inStand(cmd: string, input?: string | Buffer): string {
  return execFileSync(DOCKER[0], [...DOCKER.slice(1), 'exec', '-i', CONTAINER!, 'sh', '-c', cmd], { input, encoding: 'utf8' });
}

function dirSource(dir: string): ReleaseSource {
  const names = readdirSync(dir).filter((n) => n.endsWith('.ipk'));
  const sha = (n: string) => createHash('sha256').update(readFileSync(join(dir, n))).digest('hex');
  const release: Release = {
    tag: 'v-stand', url: 'file://' + dir, assets: names.map((name) => ({ name, size: 0, verified: true, sha256: sha(name) })),
  };
  return {
    latest: async () => release,
    download: async (name) => readFileSync(join(dir, name)).toString('base64'),
  };
}

function client(user = 'root', password = PASS) {
  const ubus = new UbusClient(new NodeTransport(URL, user, password), { timeoutMs: 15_000 });
  return { ubus, xvpn: new XvpnApi(ubus) };
}

function installed(): string {
  return inStand(`opkg list-installed 'luci-*xvpn*'`);
}

const newVersion = () => readdirSync(NEW!).find((n) => n.startsWith('luci-app-xvpn_'))!.split('_')[1];

describe.skipIf(!CONTAINER || !OLD || !NEW)(`router package upgrade against ${URL}`, () => {
  it('upgrades an old package through LuCI (the answer may get lost) and the app reconnects', async () => {
    // not docker cp: /tmp of the stand is a tmpfs, docker cp writes under it
    inStand('mkdir -p /tmp/xvpn-old');
    for (const n of readdirSync(OLD!).filter((x) => x.endsWith('.ipk')))
      inStand(`cat >/tmp/xvpn-old/${n}`, readFileSync(join(OLD!, n)));
    inStand('opkg install /tmp/xvpn-old/*.ipk >/dev/null && rm -rf /tmp/xvpn-old');
    const before = installed();
    console.log(before);
    expect(before).toMatch(/^luci-app-xvpn - 0\.2\.0-r1$/m);

    const conn = new Connection({ intervalMs: 1000, transport: () => new NodeTransport(URL, 'root', PASS) });
    const st = await conn.connect({ id: 'stand', name: 'stand', url: URL, username: 'root' });
    expect(st.phase).toBe('online');
    const ctx = conn.context!;
    const flow = new PkgFlow({ ubus: ctx.ubus, xvpn: ctx.xvpn, source: dirSource(NEW!), poller: ctx.poller, refresh: () => conn.refreshPackage() });
    const seen: PkgState['phase'][] = [];
    flow.subscribe((s) => {
      if (seen.at(-1) !== s.phase)
        seen.push(s.phase);
      if (s.phase === 'installing')
        console.log('step', s.step, s.n, s.of);
    });
    await flow.check();
    expect(flow.get()).toMatchObject({ phase: 'ready', check: { method: 'luci', installed: '0.2.0-r1', available: newVersion(), cmp: 1, langs: ['ru'], canReinstall: false } });
    await flow.install();
    const end = flow.get();
    if (end.phase === 'error')
      console.log(end.error);
    expect(end).toMatchObject({ phase: 'done', version: newVersion() });
    expect(installed()).toContain(`luci-app-xvpn - ${newVersion()}`);
    // the connection took the new version, the poller runs again
    expect(conn.state.get()).toMatchObject({ phase: 'online', pkg: { version: newVersion() } });
    expect(ctx.pkg.version).toBe(newVersion());
    const polls = ctx.poller.status;
    await new Promise((r) => setTimeout(r, 2500));
    expect(ctx.poller.status).not.toBe(polls);
    expect(inStand('ls /tmp/upload.ipk 2>/dev/null || true').trim()).toBe('');
    conn.disconnect();
  }, 300_000);

  it('a new login has the helper of the new package: reinstall of the same version', async () => {
    const { ubus, xvpn } = client();
    const flow = new PkgFlow({ ubus, xvpn, source: dirSource(NEW!) });
    await flow.check();
    expect(flow.get()).toMatchObject({ phase: 'ready', check: { method: 'helper', cmp: 0, canReinstall: true } });
    await flow.install(true);
    const end = flow.get();
    if (end.phase === 'error')
      console.log(end.error);
    expect(end).toMatchObject({ phase: 'done', version: newVersion() });
    expect(JSON.parse(inStand('cat /tmp/xvpn-pkg.json'))).toMatchObject({ state: 'done', code: 0 });
    expect(inStand('cat /tmp/xvpn-pkg.out')).toMatch(/Installing luci-app-xvpn|Reinstalling/);
    expect(inStand('ls /tmp/xvpn-pkg-*.ipk 2>/dev/null || true').trim()).toBe('');
  }, 300_000);

  it('pkg.sh: lists only the xvpn packages, checks the sha256, one job at a time', async () => {
    const list = inStand('/usr/share/xvpn/pkg.sh list');
    expect(list).toMatch(/^Package: luci-app-xvpn$/m);
    expect([...list.matchAll(/^Package: (.*)$/gm)].map((m) => m[1]).every((n) => /^luci-(app-xvpn|i18n-(xvpn|base)-)/.test(n))).toBe(true);
    const before = inStand('/usr/share/xvpn/pkg.sh status');
    const run = (args: string) => {
      try {
        inStand(`/usr/share/xvpn/pkg.sh install ${args} 2>&1`);
        return 'ok';
      }
      catch (e) {
        return String((e as { stdout?: string }).stdout ?? e);
      }
    };
    inStand('echo x >/tmp/xvpn-pkg-abc-x.ipk');
    expect(run(`abc /tmp/xvpn-pkg-abc-x.ipk ${'0'.repeat(64)}`)).toContain('sha256 mismatch');
    expect(run('abc /tmp/xvpn-pkg-abd-x.ipk 00')).toContain('bad file');
    expect(run('abc /etc/passwd 00')).toContain('bad file');
    // a live job holds the lock; a dead one does not
    inStand('mkdir /tmp/xvpn-pkg.lock; sleep 30 </dev/null >/dev/null 2>&1 & echo $! >/tmp/xvpn-pkg.lock/pid');
    expect(run(`abc /tmp/xvpn-pkg-abc-x.ipk ${'0'.repeat(64)}`)).toContain('an install is running');
    inStand('kill $(cat /tmp/xvpn-pkg.lock/pid)');
    expect(run(`abc /tmp/xvpn-pkg-abc-x.ipk ${'0'.repeat(64)}`)).toContain('sha256 mismatch');
    // refusals touch neither the lock nor the state of the last job
    expect(inStand('ls -d /tmp/xvpn-pkg.lock 2>/dev/null || true').trim()).toBe('');
    expect(inStand('/usr/share/xvpn/pkg.sh status')).toBe(before);
    inStand('rm -f /tmp/xvpn-pkg-abc-x.ipk');
  });

  it('the rpcd user without root may not: need_root, nothing uploaded', async () => {
    const pass = randomBytes(12).toString('hex');
    inStand('sh /usr/share/xvpn/rpcd-user.sh add xvpnpkg -', `${pass}\n`);
    try {
      const { ubus, xvpn } = client('xvpnpkg', pass);
      const flow = new PkgFlow({ ubus, xvpn, source: dirSource(NEW!) });
      await flow.check();
      expect(flow.get()).toMatchObject({ phase: 'error', error: { code: 'need_root' } });
    }
    finally {
      inStand('sh /usr/share/xvpn/rpcd-user.sh del xvpnpkg');
    }
  });
});
