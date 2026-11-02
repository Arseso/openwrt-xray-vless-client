// xray-core of a GitHub release on the router (#31, the tab «О программе»). Unlike the
// package (src/core/routerpkg.ts) the router downloads it itself: luci.xvpn xray_install
// starts a job there, the app asks luci.xvpn xray until the job with its id is over. rpcd
// stays up meanwhile, only xvpn restarts. Nothing happens by itself: check() on a button,
// install() and rollback() after the user confirmed.

import { XvpnError, toXvpnError } from '../api/errors';
import { XrayJob, XrayReply, XvpnApi } from '../api/xvpn';

/** 26.10.31 or v26.10.31 against 25.1.30-r1: < 0 older, 0 the same, > 0 newer */
export function compareXray(a: string | null | undefined, b: string | null | undefined): number {
  const parts = (v: string | null | undefined) => (v ?? '').replace(/^v/, '').replace(/-.*/, '').split('.');
  const pa = parts(a);
  const pb = parts(b);
  for (let i = 0; i < 3; i++) {
    const d = (parseInt(pa[i], 10) || 0) - (parseInt(pb[i], 10) || 0);
    if (d)
      return Math.sign(d);
  }
  return 0;
}

/** the version of the xray the service runs; null for a path set by hand */
export function runningVersion(info: XrayReply): string | null {
  if (info.source === 'github')
    return info.github?.version ?? null;
  if (info.source === 'feed')
    return info.feed?.version ?? null;
  return null;
}

export interface XrayState {
  /** null until the first answer */
  info: XrayReply | null;
  /** the tag of the latest release, after check() */
  latest: string | null;
  busy: 'load' | 'check' | 'install' | 'rollback' | null;
  /** the job of the router: the running one, or the last one */
  job: XrayJob | null;
  error: XvpnError | null;
}

export interface XrayOptions {
  /** pause between questions while the job runs */
  pollMs?: number;
  /** how long a job may take: the download and the restart with the tests of the servers */
  waitMs?: number;
}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

export class XrayFlow {
  private current: XrayState = { info: null, latest: null, busy: null, job: null, error: null };
  private listeners = new Set<(s: XrayState) => void>();
  private readonly pollMs: number;
  private readonly waitMs: number;

  constructor(private readonly xvpn: XvpnApi, opts: XrayOptions = {}) {
    this.pollMs = opts.pollMs ?? 2000;
    this.waitMs = opts.waitMs ?? 300_000;
  }

  get(): XrayState {
    return this.current;
  }

  subscribe(fn: (s: XrayState) => void): () => void {
    this.listeners.add(fn);
    return () => {
      this.listeners.delete(fn);
    };
  }

  get busy(): boolean {
    return this.current.busy !== null;
  }

  /** the release newer or other than the one running can be installed */
  get installable(): string | null {
    const { info, latest } = this.current;
    if (!info?.asset || !latest)
      return null;
    if (info.source === 'github' && compareXray(latest, info.github?.version) === 0)
      return null;
    return latest;
  }

  private set(patch: Partial<XrayState>): void {
    this.current = { ...this.current, ...patch };
    for (const fn of [...this.listeners])
      fn(this.current);
  }

  private fail(e: unknown, root = false): void {
    let err = toXvpnError(e);
    if (err.code === 'acl')
      err = new XvpnError(root ? 'need_root' : 'xray_old_package', err.message, err.detail);
    else if (err.code === 'no_method')
      err = new XvpnError('xray_old_package', err.message, err.detail);
    this.set({ busy: null, error: err });
  }

  /** what the router has; a job started elsewhere (LuCI, another app) is followed */
  async load(): Promise<void> {
    if (this.busy)
      return;
    this.set({ busy: 'load', error: null });
    try {
      const info = await this.xvpn.xray();
      this.set({ info, job: info.job ?? null, busy: null });
      if (info.job?.state === 'running')
        await this.follow(info.job.id);
    }
    catch (e) {
      this.fail(e);
    }
  }

  async check(): Promise<void> {
    if (this.busy)
      return;
    this.set({ busy: 'check', error: null });
    try {
      const r = await this.xvpn.xrayLatest();
      if ('error' in r)
        throw new XvpnError('xray_latest', r.error, { output: r.error });
      const info = await this.xvpn.xray();
      this.set({ info, latest: r.tag, busy: null });
    }
    catch (e) {
      this.fail(e);
    }
  }

  /** after the user confirmed: the latest release of check() */
  async install(): Promise<void> {
    const tag = this.installable;
    if (this.busy || !tag)
      return;
    this.set({ busy: 'install', error: null, job: null });
    let r;
    try {
      r = await this.xvpn.xrayInstall(tag);
    }
    catch (e) {
      this.fail(e, true);
      return;
    }
    if (!r.ok || !r.id) {
      const msg = r.error ?? 'no job';
      this.set({ busy: null, error: msg === 'busy' ? new XvpnError('xray_busy', msg) : new XvpnError('xray_failed', msg, { output: msg }) });
      return;
    }
    await this.follow(r.id);
  }

  /** asks until the job id is over; the router may be slow to answer while xvpn restarts */
  private async follow(id: string): Promise<void> {
    this.set({ busy: 'install' });
    const end = Date.now() + this.waitMs;
    for (;;) {
      let info: XrayReply | null = null;
      try {
        info = await this.xvpn.xray();
      }
      catch (e) {
        if (!toXvpnError(e).offline || Date.now() > end) {
          this.fail(e);
          return;
        }
      }
      const job = info?.job?.id === id ? info.job : null;
      if (info)
        this.set({ info, job });
      if (job && job.state !== 'running') {
        const error = job.state === 'done' ? null
          : job.state === 'failed' ? new XvpnError('xray_failed', job.error ?? 'failed', { output: job.error ?? '' })
            : new XvpnError('xray_lost', `${job.tag}: the job died`);
        this.set({ busy: null, error });
        return;
      }
      if (Date.now() > end) {
        this.set({ busy: null, error: new XvpnError('xray_lost', `${id}: not over in ${this.waitMs / 1000} s`) });
        return;
      }
      await sleep(this.pollMs);
    }
  }

  /** after the user confirmed: back to xray-core of the package */
  async rollback(): Promise<void> {
    if (this.busy || this.current.info?.source !== 'github')
      return;
    this.set({ busy: 'rollback', error: null });
    try {
      const r = await this.xvpn.xrayRollback();
      if (!r.ok)
        throw r.error === 'busy' ? new XvpnError('xray_busy', r.error) : new XvpnError('xray_failed', r.error ?? 'failed', { output: r.error ?? '' });
      const info = await this.xvpn.xray();
      this.set({ info, job: null, busy: null });
    }
    catch (e) {
      this.fail(e, true);
    }
  }
}

// one flow per router profile, like flowFor of routerpkg.ts: a running install stays
const flows = new Map<string, { key: object; flow: XrayFlow }>();

export function xrayFlowFor(profileId: string, key: object, make: () => XrayFlow): XrayFlow {
  const cur = flows.get(profileId);
  if (cur && (cur.key === key || cur.flow.busy))
    return cur.flow;
  const flow = make();
  flows.set(profileId, { key, flow });
  return flow;
}
