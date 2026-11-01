import { describe, expect, it, vi } from 'vitest';
import { XvpnError } from '../../src/api/errors';
import { CHUNK, HELPER, PM, PM_FILE } from '../../src/api/opkg';
import { Release, ReleaseSource } from '../../src/api/release';
import { UbusClient } from '../../src/api/ubus';
import { XvpnApi } from '../../src/api/xvpn';
import {
  PkgFlow, compareVersions, flowFor, parseAssetName, parseStatus, routerLangs, selectAssets,
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

Package: luci-i18n-xvpn-de
Version: 0.261101.12641
Status: install ok half-configured
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

const ASSET = (name: string, verified = true) => ({ name, size: 100, verified, sha256: verified ? 'ab'.repeat(32) : null });
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

const NEW = '0.3.0-r1';
const MAIN_FILE = 'luci-app-xvpn_0.3.0-r1_all.ipk';
const RU_FILE = 'luci-i18n-xvpn-ru_0.261201.100_all.ipk';

interface Job { id?: string; state: string; code?: number; output?: string }

/**
 * a router with the helper of luci-app-xvpn and/or LuCI's package manager behind
 * FakeRouter; hooks decide what an install does (it may throw: the answer is lost)
 */
function router(opts: { helper?: boolean; luci?: boolean; root?: boolean } = {}) {
  const { helper = true, luci = true, root = true } = opts;
  const r = new FakeRouter();
  r.objects.add('file');
  const state = {
    version: '0.2.0-r1', mainState: 'installed', files: new Map<string, string>(),
    job: { state: 'idle' } as Job, pmLock: 0,
  };
  const allowed = (scope: string, object: string, fn: string) => {
    if (!root)
      return false;
    if (scope === 'ubus')
      return object === 'file';
    if (helper && (/^\/tmp\/xvpn-pkg-.*\.ipk$/.test(object) || object.startsWith(`${HELPER} install `)))
      return fn === 'write' || fn === 'exec';
    if (luci && (object === PM_FILE || object === `${PM} install ${PM_FILE}`))
      return true;
    return false;
  };
  r.on('session.access', (a) => (a.scope ? { access: allowed(a.scope as string, a.object as string, a.function as string) } : { access: true }));
  const fileWrite = (a: Record<string, unknown>) => {
    const p = a.path as string;
    state.files.set(p, (a.append ? state.files.get(p) ?? '' : '') + (a.data as string));
    return [0];
  };
  r.on('file.write', fileWrite);
  r.on('file.remove', (a) => (state.files.delete(a.path as string) ? [0] : [4]));
  r.on('file.list', (a) => {
    if (a.path === '/usr/lib/opkg/info')
      return { entries: ['luci-app-xvpn.control', 'luci-app-xvpn.list', 'luci-i18n-base-ru.control'].map((name) => ({ name, type: 'file' })) };
    if (a.path === '/tmp')
      return { entries: state.pmLock-- > 0 ? [{ name: 'ipkg.lock', type: 'file' }] : [] };
    return [4];
  });
  r.on('luci.xvpn.version', () => ({ version: state.version, api: 1 }));
  const installs: string[][] = [];
  /** the job of the helper ends as opkg would after a good install */
  const finish = (job: { id?: string }, files: string[]) => {
    state.version = NEW;
    state.job = { id: job.id, state: 'done', code: 0 };
    for (const f of files)
      state.files.delete(f);
  };
  const hooks = {
    /** helper install after the checks; default: done at once */
    helper(id: string, files: string[]): void {
      finish({ id }, files);
    },
    /** package-manager-call install; default: installs the main package */
    pm(): unknown {
      state.version = NEW;
      return { code: 0, stdout: JSON.stringify({ code: 0, stdout: 'Configuring' }) };
    },
  };
  r.on('file.exec', (a) => {
    const params = a.params as string[];
    if (a.command === HELPER && params[0] === 'list')
      return { code: 0, stdout: `Package: luci-app-xvpn\nVersion: ${state.version}\nStatus: install user ${state.mainState}\n\nPackage: luci-i18n-base-ru\nVersion: 1\nStatus: install ok installed\n` };
    if (a.command === HELPER && params[0] === 'status')
      return { code: 0, stdout: JSON.stringify(state.job) };
    if (a.command === HELPER && params[0] === 'install') {
      installs.push(params);
      if (state.job.state === 'running')
        return { code: 1, stderr: 'an install is running\n' };
      const id = params[1];
      const rest = params.slice(params[2] === '--force-reinstall' ? 3 : 2);
      const files = rest.filter((_, i) => i % 2 === 0);
      for (const f of files)
        if (!f.startsWith(`/tmp/xvpn-pkg-${id}-`) || !state.files.has(f))
          return { code: 1, stderr: `bad file: ${f}\n` };
      state.job = { id, state: 'running' };
      hooks.helper(id, files);
      return { code: 0, stdout: `{"id":"${id}","state":"running"}` };
    }
    if (a.command === PM && params[0] === 'install') {
      installs.push(params);
      return hooks.pm();
    }
    return { code: 1, stderr: 'unknown' };
  });
  const ubus = new UbusClient(r);
  const source: ReleaseSource & { downloads: string[] } = {
    downloads: [],
    latest: async () => RELEASE,
    async download(name) {
      this.downloads.push(name);
      return name === MAIN_FILE ? 'A'.repeat(CHUNK + 8) : 'QUJD';
    },
  };
  const poller = { stop: vi.fn(), start: vi.fn() };
  const refresh = vi.fn(async () => {});
  const deps = { ubus, xvpn: new XvpnApi(ubus), source, poller, refresh, current: () => true };
  const flow = new PkgFlow(deps, { pollMs: 1, waitMs: 200 });
  const writes = () => r.calls.filter((c) => c.method === 'write');
  return { r, state, installs, source, poller, refresh, deps, flow, hooks, finish, fileWrite, writes };
}

describe('PkgFlow: the helper', () => {
  it('shows installed and available, installs only after install()', async () => {
    const t = router();
    await t.flow.check();
    expect(t.flow.get()).toMatchObject({
      phase: 'ready', check: { method: 'helper', installed: '0.2.0-r1', available: NEW, cmp: 1, langs: ['ru'] },
    });
    expect(t.source.downloads).toEqual([]);
    await t.flow.install();
    expect(t.flow.get()).toMatchObject({ phase: 'done', version: NEW, warnings: [] });
    // both files of one job with their sha256, in pieces of CHUNK, without reinstall
    const [args] = t.installs;
    const id = args[1];
    expect(id).toMatch(/^[0-9a-f]{16}$/);
    expect(args).toEqual(['install', id,
      `/tmp/xvpn-pkg-${id}-${MAIN_FILE}`, 'ab'.repeat(32), `/tmp/xvpn-pkg-${id}-${RU_FILE}`, 'ab'.repeat(32)]);
    expect(t.writes()).toHaveLength(3);
    expect(t.state.files.size).toBe(0);
    expect(t.poller.stop).toHaveBeenCalledOnce();
    expect(t.poller.start).toHaveBeenCalledOnce();
    expect(t.refresh).toHaveBeenCalledOnce();
    // another install: another id, other files
    const u = router();
    await u.flow.check();
    await u.flow.install();
    expect(u.installs[0][1]).not.toBe(id);
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
    t.state.version = NEW;
    await t.flow.check();
    expect(t.flow.get()).toMatchObject({ phase: 'ready', check: { cmp: 0, canReinstall: true } });
    await t.flow.install();
    expect(t.installs).toEqual([]);
    await t.flow.install(true);
    expect(t.installs[0][2]).toBe('--force-reinstall');
    expect(t.flow.get()).toMatchObject({ phase: 'done' });

    const l = router({ helper: false });
    l.state.version = NEW;
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

  it('a job running on the router (another PC, an earlier try): pkg_busy before any upload, its files stay', async () => {
    const t = router();
    await t.flow.check();
    t.state.job = { id: 'beef', state: 'running' };
    t.state.files.set(`/tmp/xvpn-pkg-beef-${MAIN_FILE}`, 'theirs');
    await t.flow.install();
    expect(t.flow.get()).toMatchObject({ phase: 'error', error: { code: 'pkg_busy' } });
    expect(t.writes()).toEqual([]);
    expect(t.installs).toEqual([]);
    expect(t.state.files.get(`/tmp/xvpn-pkg-beef-${MAIN_FILE}`)).toBe('theirs');
  });

  it('the answer of start is lost (rpcd re-executes): the job of this id, then the installed version', async () => {
    const t = router();
    let polls = 0;
    t.hooks.helper = (id, files) => {
      t.r.on('file.exec', ((orig) => (a: Record<string, unknown>) => {
        // the third status: done; the router away for two requests, rpcd restarted
        if ((a.params as string[])[0] === 'status' && ++polls === 3) {
          t.finish({ id }, files);
          t.r.failures.push(new XvpnError('unreachable'), new XvpnError('unreachable'));
          t.r.expireSessions();
        }
        return orig(a);
      })(t.r.methods.get('file.exec')!));
      throw new XvpnError('timeout');
    };
    const logins = t.r.logins;
    await t.flow.check();
    await t.flow.install();
    expect(t.flow.get()).toMatchObject({ phase: 'done', version: NEW });
    expect(t.r.logins).toBeGreaterThan(logins);
  });

  it('start lost before it reached the router: an old job of another id is no result, own files go', async () => {
    const t = router();
    t.state.version = NEW;
    t.state.job = { id: 'old', state: 'done', code: 0 };
    await t.flow.check();
    t.r.on('file.exec', ((orig) => (a: Record<string, unknown>) => {
      if ((a.params as string[])[0] === 'install')
        throw new XvpnError('timeout');
      return orig(a);
    })(t.r.methods.get('file.exec')!));
    await t.flow.install(true);
    expect(t.flow.get()).toMatchObject({ phase: 'error', error: { code: 'pkg_lost' } });
    expect(t.state.files.size).toBe(0);
  });

  it('an upload cut off is an error with the files removed, nothing is started', async () => {
    const t = router();
    await t.flow.check();
    let n = 0;
    t.r.on('file.write', (a) => {
      if (++n === 2)
        throw new XvpnError('timeout');
      return t.fileWrite(a);
    });
    await t.flow.install();
    expect(t.flow.get()).toMatchObject({ phase: 'error', error: { code: 'timeout' } });
    expect(t.installs).toEqual([]);
    expect(t.state.files.size).toBe(0);
    expect(t.poller.start).toHaveBeenCalledOnce();
  });

  it('a job killed on the way (lost): only an installed luci-app-xvpn of the release is a success', async () => {
    const t = router();
    t.hooks.helper = (id) => {
      t.state.version = NEW; // the control file is there, the postinst did not run
      t.state.mainState = 'half-configured';
      t.state.job = { id, state: 'lost' };
    };
    await t.flow.check();
    await t.flow.install();
    expect(t.flow.get()).toMatchObject({ phase: 'error', error: { code: 'pkg_lost' } });
    expect(t.state.files.size).toBe(0);

    const u = router();
    u.hooks.helper = (id) => {
      u.state.version = NEW;
      u.state.job = { id, state: 'lost' };
    };
    await u.flow.check();
    await u.flow.install();
    expect(u.flow.get()).toMatchObject({ phase: 'done', version: NEW });
    expect(u.state.files.size).toBe(0);
  });

  it('opkg fails: its output; with luci-app-xvpn installed it is a warning', async () => {
    const t = router();
    t.hooks.helper = (id, files) => {
      t.state.job = { id, state: 'done', code: 255, output: ' * check_data_file_clashes: ...' };
      for (const f of files)
        t.state.files.delete(f);
    };
    await t.flow.check();
    await t.flow.install();
    expect(t.flow.get()).toMatchObject({ phase: 'error', error: { code: 'pkg_failed', detail: { output: ' * check_data_file_clashes: ...' } } });

    const u = router();
    u.hooks.helper = (id) => {
      u.state.version = NEW;
      u.state.job = { id, state: 'done', code: 255, output: 'luci-i18n-xvpn-ru: failed' };
    };
    await u.flow.check();
    await u.flow.install();
    expect(u.flow.get()).toMatchObject({ phase: 'done', warnings: ['luci-i18n-xvpn-ru: failed'] });
  });

  it('a download that fails the check: nothing reaches the router', async () => {
    const t = router();
    t.source.download = async () => {
      throw new XvpnError('release_digest');
    };
    await t.flow.check();
    await t.flow.install();
    expect(t.flow.get()).toMatchObject({ phase: 'error', error: { code: 'release_digest' } });
    expect(t.writes()).toEqual([]);
    expect(t.poller.stop).not.toHaveBeenCalled();
  });
});

describe('PkgFlow: LuCI package manager', () => {
  it('waits for its lock, one file at a time, on after a lost answer once that opkg ended', async () => {
    const t = router({ helper: false });
    await t.flow.check();
    expect(t.flow.get()).toMatchObject({ phase: 'ready', check: { method: 'luci', installed: '0.2.0-r1', langs: ['ru'] } });
    // LuCI installs something: the lock is there for three looks
    t.state.pmLock = 3;
    let n = 0;
    t.hooks.pm = () => {
      if (++n === 1) {
        // rpcd re-executes under the call; opkg holds its lock a little longer
        t.state.version = NEW;
        t.state.pmLock = 2;
        t.r.failures.push(new XvpnError('unreachable'));
        throw new XvpnError('timeout');
      }
      if (n === 2) // the translation meets another install once
        return { code: 0, stdout: JSON.stringify({ code: 255, stderr: 'Failed to acquire lock' }) };
      return { code: 0, stdout: JSON.stringify({ code: 0 }) };
    };
    const firstWrite = () => t.r.calls.findIndex((c) => c.method === 'write');
    await t.flow.install();
    expect(t.flow.get()).toMatchObject({ phase: 'done', version: NEW, warnings: [] });
    expect(t.installs).toHaveLength(3);
    // nothing written while the lock was there
    const lists = t.r.calls.slice(0, firstWrite()).filter((c) => c.method === 'list' && c.args.path === '/tmp');
    expect(lists.length).toBeGreaterThanOrEqual(4);
    expect(t.state.files.has(PM_FILE)).toBe(false);
  });

  it('a failed translation is a warning, a failed package an error', async () => {
    const t = router({ helper: false });
    let n = 0;
    t.hooks.pm = () => (++n === 1
      ? (t.state.version = NEW, { code: 0, stdout: JSON.stringify({ code: 0 }) })
      : { code: 0, stdout: JSON.stringify({ code: 1, stderr: 'ru: broken' }) });
    await t.flow.check();
    await t.flow.install();
    expect(t.flow.get()).toMatchObject({ phase: 'done', warnings: [expect.stringContaining('ru: broken')] });

    const u = router({ helper: false });
    u.hooks.pm = () => ({ code: 0, stdout: JSON.stringify({ code: 1, stderr: 'clash' }) });
    await u.flow.check();
    await u.flow.install();
    expect(u.flow.get()).toMatchObject({ phase: 'error', error: { code: 'pkg_failed' } });
    expect(u.installs).toHaveLength(1);
  });
});

describe('PkgFlow and the app', () => {
  it('another profile or connection meanwhile: the poller of the old one stays stopped', async () => {
    const t = router();
    let current = true;
    t.deps.current = () => current;
    await t.flow.check();
    t.hooks.helper = (id, files) => {
      current = false;
      t.finish({ id }, files);
    };
    await t.flow.install();
    expect(t.flow.get()).toMatchObject({ phase: 'done' });
    expect(t.poller.start).not.toHaveBeenCalled();
    expect(t.refresh).not.toHaveBeenCalled();
  });

  it('one flow per router profile: a busy one is kept for a new context', async () => {
    const t = router();
    const ctxA = {}, ctxB = {};
    const a = flowFor('p-busy', ctxA, () => t.flow);
    expect(flowFor('p-busy', ctxA, () => router().flow)).toBe(a);
    let release!: () => void;
    t.source.latest = () => new Promise((r) => { release = () => r(RELEASE); });
    const checking = a.check();
    await new Promise((r) => setTimeout(r, 10));
    expect(a.busy).toBe(true);
    // reconnected while busy: still the same flow, no second install next to it
    expect(flowFor('p-busy', ctxB, () => router().flow)).toBe(a);
    release();
    await checking;
    const b = flowFor('p-busy', ctxB, () => router().flow);
    expect(b).not.toBe(a);
    expect(flowFor('p-other', ctxB, () => router().flow)).not.toBe(b);
  });
});
