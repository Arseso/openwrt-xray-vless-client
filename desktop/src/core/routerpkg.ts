// Installing or upgrading luci-app-xvpn on the router from the latest GitHub release
// (the tab «О программе»). The PC downloads the ipk files (src/api/release.ts: Rust checks
// their sha256), uploads them with ubus file write and has opkg install them
// (src/api/opkg.ts). Nothing happens by itself: check() on a button, install() after the
// user confirmed.
//
// Installing a LuCI package re-executes rpcd (its postinst), xvpn restarts: the answer of
// the install may never come, or the router stops answering for a while. So the result
// is not that answer: the app waits for the router and asks luci.xvpn version until it
// says the new version (or gives up: pkg_lost). The poller is stopped meanwhile — a poll
// while rpcd loads its plugins would see no luci.xvpn and take the package for removed.

import { XvpnError, isXvpnError, toXvpnError } from '../api/errors';
import { Job, Method, PM_FILE, RouterPackages, helperPath } from '../api/opkg';
import { Release, ReleaseAsset, ReleaseSource } from '../api/release';
import { UbusClient } from '../api/ubus';
import { XvpnApi } from '../api/xvpn';

export const MAIN = 'luci-app-xvpn';
const I18N = 'luci-i18n-xvpn-';

// --- versions: the comparison of opkg (epoch:version-revision, verrevcmp of dpkg) ---

function order(c: string | undefined): number {
  if (c === undefined || /\d/.test(c))
    return 0;
  if (c === '~')
    return -1;
  if (/[A-Za-z]/.test(c))
    return c.charCodeAt(0);
  return c.charCodeAt(0) + 256;
}

function isDigit(c: string | undefined): boolean {
  return c !== undefined && c >= '0' && c <= '9';
}

function verrevcmp(a: string, b: string): number {
  let i = 0;
  let j = 0;
  while (i < a.length || j < b.length) {
    while ((i < a.length && !isDigit(a[i])) || (j < b.length && !isDigit(b[j]))) {
      const d = order(a[i]) - order(b[j]);
      if (d)
        return d;
      i++;
      j++;
    }
    while (a[i] === '0')
      i++;
    while (b[j] === '0')
      j++;
    let first = 0;
    while (isDigit(a[i]) && isDigit(b[j])) {
      if (!first)
        first = a.charCodeAt(i) - b.charCodeAt(j);
      i++;
      j++;
    }
    if (isDigit(a[i]))
      return 1;
    if (isDigit(b[j]))
      return -1;
    if (first)
      return first;
  }
  return 0;
}

function split(v: string): [number, string, string] {
  const colon = v.indexOf(':');
  const epoch = colon > 0 && /^\d+$/.test(v.slice(0, colon)) ? Number(v.slice(0, colon)) : 0;
  const rest = colon > 0 ? v.slice(colon + 1) : v;
  const dash = rest.lastIndexOf('-');
  return dash > 0 ? [epoch, rest.slice(0, dash), rest.slice(dash + 1)] : [epoch, rest, ''];
}

/** < 0: a is older than b, 0: the same, > 0: newer (as opkg compares them) */
export function compareVersions(a: string, b: string): number {
  const [ea, va, ra] = split(a);
  const [eb, vb, rb] = split(b);
  const d = ea - eb || verrevcmp(va, vb) || verrevcmp(ra, rb);
  return Math.sign(d);
}

// --- what is installed, what the release has ---

/** package → version of the opkg status file, installed ones only */
export function parseStatus(text: string): Map<string, string> {
  const res = new Map<string, string>();
  for (const block of text.split(/\n\s*\n/)) {
    const field = (k: string) => block.match(new RegExp(`^${k}: *(.*)$`, 'm'))?.[1]?.trim();
    const name = field('Package');
    const version = field('Version');
    if (name && version && /\binstalled\b/.test(field('Status') ?? '') && !/not-installed/.test(field('Status') ?? ''))
      res.set(name, version);
  }
  return res;
}

/** the languages the router has: its translations of xvpn and of LuCI itself */
export function routerLangs(installed: Map<string, string>): string[] {
  const langs = new Set<string>();
  for (const name of installed.keys()) {
    const m = name.match(/^luci-i18n-(?:xvpn|base)-([a-z]{2,3}(?:-[a-z0-9]+)*)$/);
    if (m)
      langs.add(m[1]);
  }
  return [...langs].sort();
}

/** luci-app-xvpn_0.2.0-r1_all.ipk → { pkg: 'luci-app-xvpn', version: '0.2.0-r1' } */
export function parseAssetName(name: string): { pkg: string; version: string } | null {
  const m = name.match(/^([a-z0-9][a-z0-9.+-]*)_([^_/]+)_all\.ipk$/);
  return m ? { pkg: m[1], version: m[2] } : null;
}

export interface Selection {
  /** the version of luci-app-xvpn in the release */
  version: string;
  /** luci-app-xvpn first, then the translations */
  files: ReleaseAsset[];
  /** the translations among files */
  langs: string[];
}

/** the newest asset of each package the router needs; release_no_asset, release_no_digest */
export function selectAssets(release: Release, langs: string[]): Selection {
  const newest = new Map<string, { asset: ReleaseAsset; version: string }>();
  for (const asset of release.assets) {
    const p = parseAssetName(asset.name);
    if (!p)
      continue;
    const cur = newest.get(p.pkg);
    if (!cur || compareVersions(p.version, cur.version) > 0)
      newest.set(p.pkg, { asset, version: p.version });
  }
  const main = newest.get(MAIN);
  if (!main)
    throw new XvpnError('release_no_asset', `${release.tag}: no ${MAIN} ipk`);
  const files = [main.asset];
  const found: string[] = [];
  for (const l of langs) {
    const a = newest.get(I18N + l);
    if (a) {
      files.push(a.asset);
      found.push(l);
    }
  }
  const bad = files.find((f) => !f.verified);
  if (bad)
    throw new XvpnError('release_no_digest', `${bad.name}: the release gives no sha256`);
  return { version: main.version, files, langs: found };
}

// --- the flow ---

export interface PkgCheck {
  method: Method;
  /** luci-app-xvpn as opkg knows it; null: not installed by opkg (copied files) */
  installed: string | null;
  available: string;
  tag: string;
  url: string;
  files: ReleaseAsset[];
  langs: string[];
  /** compareVersions(available, installed); 1 when nothing is installed by opkg */
  cmp: number;
  /** the same version can be installed again (the helper; LuCI's call drops the flag) */
  canReinstall: boolean;
}

export type Step = 'download' | 'upload' | 'install' | 'reconnect';

export type PkgState =
  | { phase: 'idle' }
  | { phase: 'checking' }
  | { phase: 'ready'; check: PkgCheck }
  | { phase: 'installing'; check: PkgCheck; step: Step; n: number; of: number }
  | { phase: 'done'; check: PkgCheck; version: string }
  | { phase: 'error'; error: XvpnError; check?: PkgCheck };

export interface PkgDeps {
  ubus: UbusClient;
  xvpn: XvpnApi;
  source: ReleaseSource;
  /** stopped while installing, started again after it */
  poller?: { stop(): void; start(): void };
  /** after the install: the app takes the new package info (Connection.refreshPackage) */
  refresh?: () => Promise<unknown>;
}

export interface PkgOptions {
  /** pause between questions while waiting for the router */
  pollMs?: number;
  /** how long the router may take to come back with the new version */
  waitMs?: number;
}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

export class PkgFlow {
  private current: PkgState = { phase: 'idle' };
  private listeners = new Set<(s: PkgState) => void>();
  private readonly pk: RouterPackages;
  private readonly pollMs: number;
  private readonly waitMs: number;

  constructor(private readonly deps: PkgDeps, opts: PkgOptions = {}) {
    this.pk = new RouterPackages(deps.ubus);
    this.pollMs = opts.pollMs ?? 2000;
    this.waitMs = opts.waitMs ?? 180_000;
  }

  get(): PkgState {
    return this.current;
  }

  subscribe(fn: (s: PkgState) => void): () => void {
    this.listeners.add(fn);
    return () => {
      this.listeners.delete(fn);
    };
  }

  get busy(): boolean {
    return this.current.phase === 'checking' || this.current.phase === 'installing';
  }

  private set(s: PkgState): void {
    this.current = s;
    for (const fn of [...this.listeners])
      fn(s);
  }

  /** the rights first (need_root: nothing else is done), then the router and the release */
  async check(): Promise<void> {
    if (this.busy)
      return;
    this.set({ phase: 'checking' });
    try {
      const method = await this.pk.method();
      const installed = parseStatus(await this.pk.status(method));
      const release = await this.deps.source.latest();
      const sel = selectAssets(release, routerLangs(installed));
      const have = installed.get(MAIN) ?? null;
      const cmp = have === null ? 1 : compareVersions(sel.version, have);
      this.set({
        phase: 'ready', check: {
          method, installed: have, available: sel.version, tag: release.tag, url: release.url,
          files: sel.files, langs: sel.langs, cmp, canReinstall: method === 'helper' && cmp === 0,
        },
      });
    }
    catch (e) {
      this.set({ phase: 'error', error: toXvpnError(e) });
    }
  }

  /** after the user confirmed: an upgrade, or the same version again with reinstall */
  async install(reinstall = false): Promise<void> {
    const s = this.current;
    if (s.phase !== 'ready')
      return;
    const check = s.check;
    if (!(check.cmp > 0 || (reinstall && check.canReinstall)))
      return;
    const step = (st: Step, n = 0, of = 0) => this.set({ phase: 'installing', check, step: st, n, of });
    try {
      // every file is downloaded and checked before anything reaches the router
      const data: string[] = [];
      for (const [i, f] of check.files.entries()) {
        step('download', i + 1, check.files.length);
        data.push(await this.deps.source.download(f.name));
      }
      this.deps.poller?.stop();
      try {
        if (check.method === 'helper')
          await this.viaHelper(check, data, reinstall, step);
        else
          await this.viaLuci(check, data, step);
        step('reconnect');
        const version = await this.waitVersion(check.available);
        this.set({ phase: 'done', check, version });
      }
      finally {
        this.deps.poller?.start();
        await this.deps.refresh?.().catch(() => {});
      }
    }
    catch (e) {
      this.set({ phase: 'error', error: toXvpnError(e), check });
    }
  }

  private async viaHelper(check: PkgCheck, data: string[], reinstall: boolean, step: (s: Step, n?: number, of?: number) => void): Promise<void> {
    const paths = check.files.map((f) => helperPath(f.name));
    try {
      for (const [i, p] of paths.entries()) {
        step('upload', i + 1, paths.length);
        await this.pk.upload(p, data[i]);
      }
      step('install');
      await this.pk.start(paths, reinstall);
    }
    catch (e) {
      // refused, or never started: nothing installs the files
      if (!lostAnswer(e)) {
        for (const p of paths)
          await this.pk.remove(p);
        throw e;
      }
      // the answer of start got lost: the job may be running
    }
    const job = await this.waitJob();
    if (job.state === 'done' && job.code !== 0)
      throw new XvpnError('pkg_failed', `opkg: ${job.code}`, { output: job.output ?? `code ${job.code}` });
    // idle / lost: whether it got installed tells the version below
  }

  private async viaLuci(check: PkgCheck, data: string[], step: (s: Step, n?: number, of?: number) => void): Promise<void> {
    try {
      for (const [i, f] of check.files.entries()) {
        step('upload', i + 1, check.files.length);
        await this.pk.upload(PM_FILE, data[i]);
        step('install', i + 1, check.files.length);
        try {
          await this.pk.pmInstall();
        }
        catch (e) {
          if (!lostAnswer(e))
            throw e;
          // rpcd re-executed under the call: on with the next file once the router answers
          step('reconnect', i + 1, check.files.length);
          await this.waitRouter(f.name);
        }
      }
    }
    finally {
      await this.pk.remove(PM_FILE);
    }
  }

  /** helper: its job until it is not running */
  private async waitJob(): Promise<Job> {
    const end = Date.now() + this.waitMs;
    let last: unknown = null;
    for (;;) {
      try {
        const j = await this.pk.job();
        if (j.state !== 'running')
          return j;
      }
      catch (e) {
        last = e;
        if (!lostAnswer(e))
          throw e;
      }
      if (Date.now() > end)
        throw new XvpnError('pkg_lost', `the install did not end in time: ${toXvpnError(last ?? 'running').message}`);
      await sleep(this.pollMs);
    }
  }

  /** luci: until the router answers luci.xvpn version (any) */
  private async waitRouter(what: string): Promise<void> {
    const end = Date.now() + this.waitMs;
    for (;;) {
      try {
        await this.deps.xvpn.version({ fresh: true, timeoutMs: 5000 });
        return;
      }
      catch (e) {
        if (!lostAnswer(e))
          throw e;
      }
      if (Date.now() > end)
        throw new XvpnError('pkg_lost', `${what}: the router did not come back`);
      await sleep(this.pollMs);
    }
  }

  /** until luci.xvpn version says want; the result of the install */
  private async waitVersion(want: string): Promise<string> {
    const end = Date.now() + this.waitMs;
    let seen: string | undefined;
    for (;;) {
      try {
        const v = await this.deps.xvpn.version({ fresh: true, timeoutMs: 5000 });
        seen = v.version;
        if (v.version === want)
          return v.version;
      }
      catch (e) {
        if (!lostAnswer(e))
          throw e;
      }
      if (Date.now() > end)
        throw new XvpnError('pkg_lost', `luci.xvpn version: ${seen ?? 'no answer'}, expected ${want}`, { version: seen });
      await sleep(this.pollMs);
    }
  }
}

/**
 * an error that does not say what happened on the router: no answer, rpcd away or
 * loading its plugins (no object, no method yet). A refusal (acl, pkg_*, need_root) or a
 * bad argument is an answer. A session rpcd lost is logged in again by UbusClient.
 */
export function lostAnswer(e: unknown): boolean {
  return isXvpnError(e, 'unreachable', 'timeout', 'http', 'bad_response', 'no_object', 'no_method', 'ubus');
}
