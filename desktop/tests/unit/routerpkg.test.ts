import { describe, expect, it, vi } from 'vitest';
import { XvpnError } from '../../src/api/errors';
import { CHUNK, HELPER, PM, PM_FILE, helperPath } from '../../src/api/opkg';
import { Release, ReleaseSource } from '../../src/api/release';
import { UbusClient } from '../../src/api/ubus';
import { XvpnApi } from '../../src/api/xvpn';
import {
  PkgFlow, compareVersions, parseAssetName, parseStatus, routerLangs, selectAssets,
} from '../../src/core/routerpkg';
import { FakeRouter } from './fake';

describe('compareVersions', () => {
  it('compares as opkg does', () => {
    expect(compareVersions('0.2.1-r1', '0.2.0-r1')).toBe(1);
    expect(compareVersions('0.2.0-r2', '0.2.0-r1')).toBe(1);
    expect(compareVersions('0.2.0-r1', '0.2.0-r1')).toBe(0);
    expect(compareVersions('0.10.0-r1', '0.9.9-r9')).toBe(1);
    expect(compareVersions('0.2.0-r10', '0.2.0-r9')).toBe(1);
    expect(compareVersions('0.2.0', '0.2.0-r1')).toBe(-1);
    expect(compareVersions('1.0~rc1', '1.0')).toBe(-1);
    expect(compareVersions('1:0.1', '0.9')).toBe(1);
    // the date versions of the LuCI translations
    expect(compareVersions('0.261201.1000', '0.261101.12641')).toBe(1);
    expect(compareVersions('0.2.0', '0.2')).toBe(1);
  });
});

const STATUS = `Package: luci-app-xvpn
Version: 0.2.0-r1
Depends: libc, luci-base
Status: install user installed
Architecture: all

Package: luci-i18n-base-ru
Version: 25.292.66247~75e41cb
Status: install user installed

Package: luci-i18n-firewall-de
Version: 25.292.66247~75e41cb
Status: install user installed

Package: luci-i18n-base-pt-br
Version: 25.292.66247~75e41cb
Status: deinstall hold not-installed

Package: luci-i18n-xvpn-uk
Version: 0.261101.12641
Status: install user installed
`;

describe('what the router has', () => {
  it('parses the opkg status file, installed packages only', () => {
    const m = parseStatus(STATUS);
    expect(m.get('luci-app-xvpn')).toBe('0.2.0-r1');
    expect(m.has('luci-i18n-base-pt-br')).toBe(false);
    expect(routerLangs(m)).toEqual(['ru', 'uk']);
    expect(parseStatus('')).toEqual(new Map());
  });
});

const ASSET = (name: string, verified = true) => ({ name, size: 100, verified });
const RELEASE: Release = {
  tag: 'v0.3.0', url: 'https://github.com/x/releases/tag/v0.3.0', assets: [
    ASSET('luci-app-xvpn_0.3.0-r1_all.ipk'),
    ASSET('luci-i18n-xvpn-ru_0.261101.12641_all.ipk'),
    ASSET('luci-i18n-xvpn-ru_0.261201.100_all.ipk'),
    ASSET('luci-i18n-xvpn-de_0.261201.100_all.ipk'),
    ASSET('luci-i18n-xvpn-pt-br_0.261201.100_all.ipk'),
  ],
};

describe('selectAssets', () => {
  it('takes the package and the newest translation of each router language', () => {
    expect(parseAssetName('luci-i18n-xvpn-pt-br_0.261201.100_all.ipk')).toEqual({ pkg: 'luci-i18n-xvpn-pt-br', version: '0.261201.100' });
    expect(parseAssetName('xvpn_0.3.0_amd64.deb')).toBeNull();
    const s = selectAssets(RELEASE, ['ru', 'pt-br', 'fr']);
    expect(s.version).toBe('0.3.0-r1');
    expect(s.files.map((f) => f.name)).toEqual([
      'luci-app-xvpn_0.3.0-r1_all.ipk', 'luci-i18n-xvpn-ru_0.261201.100_all.ipk', 'luci-i18n-xvpn-pt-br_0.261201.100_all.ipk',
    ]);
    expect(s.langs).toEqual(['ru', 'pt-br']);
    expect(selectAssets(RELEASE, []).files).toHaveLength(1);
  });

  it('refuses a release without the package or without a sha256', () => {
    expect(() => selectAssets({ ...RELEASE, assets: RELEASE.assets.slice(1) }, [])).toThrow(expect.objectContaining({ code: 'release_no_asset' }));
    const noDigest = { ...RELEASE, assets: [ASSET('luci-app-xvpn_0.3.0-r1_all.ipk'), ASSET('luci-i18n-xvpn-de_0.1_all.ipk', false)] };
    expect(selectAssets(noDigest, []).files).toHaveLength(1);
    expect(() => selectAssets(noDigest, ['de'])).toThrow(expect.objectContaining({ code: 'release_no_digest' }));
  });
});

/** a router with the helper of luci-app-xvpn or LuCI's package manager behind FakeRouter */
function router(opts: { helper?: boolean; luci?: boolean; root?: boolean } = {}) {
  const { helper = true, luci = true, root = true } = opts;
  const r = new FakeRouter();
  r.objects.add('file');
  const state = { version: '0.2.0-r1', files: new Map<string, string>(), job: { state: 'idle' } as Record<string, unknown> };
  const allowed = (scope: string, object: string, fn: string) => {
    if (!root)
      return false;
    if (scope === 'ubus')
      return object === 'file';
    if (helper && (object === helperPath('a.ipk') || object.startsWith(`${HELPER} install `)))
      return fn === 'write' || fn === 'exec';
    if (luci && (object === PM_FILE || object === `${PM} install ${PM_FILE}`))
      return true;
    return false;
  };
  r.on('session.access', (a) => (a.scope ? { access: allowed(a.scope as string, a.object as string, a.function as string) } : { access: true }));
  r.on('file.write', (a) => {
    const p = a.path as string;
    state.files.set(p, (a.append ? state.files.get(p) ?? '' : '') + (a.data as string));
    return [0];
  });
  r.on('file.remove', (a) => (state.files.delete(a.path as string) ? [0] : [4]));
  r.on('luci.xvpn.version', () => ({ version: state.version, api: 1 }));
  const installs: { args: string[] }[] = [];
  /** what an install does on the router; may throw (the answer is lost) */
  let onInstall = (args: string[]): unknown => {
    state.version = '0.3.0-r1';
    state.job = { state: 'done', code: 0 };
    for (const f of args.filter((x) => x.startsWith('/tmp/')))
      state.files.delete(f);
    return null;
  };
  r.on('file.exec', (a) => {
    const params = a.params as string[];
    if (a.command === HELPER && params[0] === 'list')
      return { code: 0, stdout: `Package: luci-app-xvpn\nVersion: ${state.version}\nStatus: install user installed\n\nPackage: luci-i18n-base-ru\nVersion: 1\nStatus: install ok installed\n` };
    if (a.command === HELPER && params[0] === 'status')
      return { code: 0, stdout: JSON.stringify(state.job) };
    if (a.command === HELPER && params[0] === 'install') {
      installs.push({ args: params });
      onInstall(params);
      return { code: 0, stdout: '{"state":"running"}' };
    }
    if (a.command === PM && params[0] === 'list-installed')
      return { code: 0, stdout: `Package: luci-app-xvpn\nVersion: ${state.version}\nStatus: install user installed\n` };
    if (a.command === PM && params[0] === 'install') {
      installs.push({ args: params });
      onInstall(params);
      return { code: 0, stdout: JSON.stringify({ code: 0, stdout: 'Configuring' }) };
    }
    return { code: 1, stderr: 'unknown' };
  });
  const ubus = new UbusClient(r);
  const source: ReleaseSource & { downloads: string[] } = {
    downloads: [],
    latest: async () => RELEASE,
    async download(name) {
      this.downloads.push(name);
      return name === RELEASE.assets[0].name ? 'A'.repeat(CHUNK + 8) : 'QUJD';
    },
  };
  const poller = { stop: vi.fn(), start: vi.fn() };
  const refresh = vi.fn(async () => {});
  const flow = new PkgFlow({ ubus, xvpn: new XvpnApi(ubus), source, poller, refresh }, { pollMs: 1, waitMs: 200 });
  return {
    r, state, installs, source, poller, refresh, flow,
    set onInstall(fn: (args: string[]) => unknown) {
      onInstall = fn;
    },
  };
}

describe('PkgFlow', () => {
  it('shows installed and available, installs only after install()', async () => {
    const t = router();
    await t.flow.check();
    expect(t.flow.get()).toMatchObject({
      phase: 'ready', check: { method: 'helper', installed: '0.2.0-r1', available: '0.3.0-r1', cmp: 1, langs: ['ru'] },
    });
    expect(t.source.downloads).toEqual([]);
    await t.flow.install();
    expect(t.flow.get()).toMatchObject({ phase: 'done', version: '0.3.0-r1' });
    // both files, in pieces of CHUNK, in one opkg call, without reinstall
    expect(t.installs).toEqual([{ args: ['install', helperPath('luci-app-xvpn_0.3.0-r1_all.ipk'), helperPath('luci-i18n-xvpn-ru_0.261201.100_all.ipk')] }]);
    expect(t.r.calls.filter((c) => c.method === 'write')).toHaveLength(3);
    expect(t.poller.stop).toHaveBeenCalledOnce();
    expect(t.poller.start).toHaveBeenCalledOnce();
    expect(t.refresh).toHaveBeenCalledOnce();
  });

  it('a user without the rights gets need_root and nothing else happens', async () => {
    const t = router({ root: false });
    await t.flow.check();
    expect(t.flow.get()).toMatchObject({ phase: 'error', error: { code: 'need_root' } });
    expect(t.r.calls.some((c) => c.object === 'file')).toBe(false);
    // no session access at all (an older rpcd user): the same
    const u = router();
    u.r.denied.add('session.access');
    await u.flow.check();
    expect(u.flow.get()).toMatchObject({ phase: 'error', error: { code: 'need_root' } });
  });

  it('reinstalls the same version only when asked and only with the helper', async () => {
    const t = router();
    t.state.version = '0.3.0-r1';
    await t.flow.check();
    expect(t.flow.get()).toMatchObject({ phase: 'ready', check: { cmp: 0, canReinstall: true } });
    await t.flow.install();
    expect(t.installs).toEqual([]);
    await t.flow.install(true);
    expect(t.installs[0].args.slice(0, 2)).toEqual(['install', '--force-reinstall']);

    const l = router({ helper: false });
    l.state.version = '0.3.0-r1';
    await l.flow.check();
    expect(l.flow.get()).toMatchObject({ phase: 'ready', check: { method: 'luci', canReinstall: false } });
    await l.flow.install(true);
    expect(l.installs).toEqual([]);
  });

  it('a newer package on the router is not downgraded', async () => {
    const t = router();
    t.state.version = '0.4.0-r1';
    await t.flow.check();
    expect(t.flow.get()).toMatchObject({ phase: 'ready', check: { cmp: -1 } });
    await t.flow.install(true);
    expect(t.installs).toEqual([]);
  });

  it('the answer of the install is lost (rpcd re-executes): the version after reconnecting is the result', async () => {
    const t = router();
    let jobPolls = 0;
    t.onInstall = () => {
      t.state.job = { state: 'running' };
      throw new XvpnError('timeout');
    };
    // the router is away for a few requests, then the job is done
    t.r.on('file.exec', ((orig) => (a: Record<string, unknown>) => {
      const params = a.params as string[];
      if (params[0] === 'status' && ++jobPolls === 3) {
        t.state.job = { state: 'done', code: 0 };
        t.state.version = '0.3.0-r1';
        t.r.failures.push(new XvpnError('unreachable'), new XvpnError('unreachable'));
        t.r.expireSessions(); // rpcd restarted: a new login
      }
      return orig(a);
    })(t.r.methods.get('file.exec')!));
    const loginsBefore = t.r.logins;
    await t.flow.check();
    await t.flow.install();
    expect(t.flow.get()).toMatchObject({ phase: 'done', version: '0.3.0-r1' });
    expect(t.r.logins).toBeGreaterThan(loginsBefore);
  });

  it('a lost answer and an old version after the wait: pkg_lost, the poller runs again', async () => {
    const t = router();
    t.onInstall = () => {
      t.state.job = { state: 'lost' };
      throw new XvpnError('unreachable');
    };
    await t.flow.check();
    await t.flow.install();
    expect(t.flow.get()).toMatchObject({ phase: 'error', error: { code: 'pkg_lost', detail: { version: '0.2.0-r1' } } });
    expect(t.poller.start).toHaveBeenCalledOnce();
  });

  it('opkg fails: its output, the uploaded files are not left behind', async () => {
    const t = router();
    t.onInstall = (args) => {
      t.state.job = { state: 'done', code: 255, output: ' * check_data_file_clashes: ...' };
      for (const f of args.filter((x) => x.startsWith('/tmp/')))
        t.state.files.delete(f);
    };
    await t.flow.check();
    await t.flow.install();
    expect(t.flow.get()).toMatchObject({ phase: 'error', error: { code: 'pkg_failed', detail: { output: ' * check_data_file_clashes: ...' } } });

    const b = router();
    b.r.on('file.exec', ((orig) => (a: Record<string, unknown>) =>
      ((a.params as string[])[0] === 'install' ? { code: 1, stderr: 'an install is running\n' } : orig(a)))(b.r.methods.get('file.exec')!));
    await b.flow.check();
    await b.flow.install();
    expect(b.flow.get()).toMatchObject({ phase: 'error', error: { code: 'pkg_busy' } });
    expect([...b.state.files.keys()]).toEqual([]);
  });

  it('a download that fails the check: nothing reaches the router', async () => {
    const t = router();
    t.source.download = async () => {
      throw new XvpnError('release_digest');
    };
    await t.flow.check();
    await t.flow.install();
    expect(t.flow.get()).toMatchObject({ phase: 'error', error: { code: 'release_digest' } });
    expect(t.r.calls.some((c) => c.method === 'write')).toBe(false);
    expect(t.poller.stop).not.toHaveBeenCalled();
  });

  it('LuCI package manager: one file at a time, on after a lost answer once the router is back', async () => {
    const t = router({ helper: false });
    let n = 0;
    t.onInstall = () => {
      if (++n === 1) {
        t.state.version = '0.3.0-r1';
        t.r.failures.push(new XvpnError('unreachable'));
        throw new XvpnError('timeout');
      }
    };
    await t.flow.check();
    expect(t.flow.get()).toMatchObject({ phase: 'ready', check: { method: 'luci', langs: [] } });
    await t.flow.install();
    expect(t.flow.get()).toMatchObject({ phase: 'done', version: '0.3.0-r1' });
    expect(t.installs).toEqual([{ args: ['install', PM_FILE] }]);
    expect(t.state.files.has(PM_FILE)).toBe(false);
  });
});
