import { describe, expect, it } from 'vitest';
import { UbusClient } from '../../src/api/ubus';
import { XrayJob, XrayReply, XvpnApi } from '../../src/api/xvpn';
import { XrayFlow, compareXray, runningVersion } from '../../src/core/xraycore';
import { FakeRouter } from './fake';

describe('compareXray', () => {
  it('compares tags and package versions', () => {
    expect(compareXray('v26.10.31', '25.1.30')).toBe(1);
    expect(compareXray('v25.1.30', '25.1.30-r1')).toBe(0);
    expect(compareXray('26.9.1', 'v26.10.1')).toBe(-1);
    expect(compareXray('v1.8.24', null)).toBe(1);
  });
});

const FEED: XrayReply = { bin: '/usr/bin/xray', source: 'feed', feed: { version: '25.1.30' }, arch: 'aarch64_cortex-a53', asset: 'Xray-linux-arm64-v8a.zip' };

function router() {
  const r = new FakeRouter();
  let info: XrayReply = { ...FEED };
  let job: XrayJob | null = null;
  // the job of the router: running for `ticks` questions, then the result
  let ticks = 0;
  let result: Partial<XrayJob> = { state: 'done', version: '26.10.31' };
  const st = {
    r,
    installs: [] as string[],
    set info(v: XrayReply) { info = v; },
    set result(v: Partial<XrayJob>) { result = v; },
    set ticks(v: number) { ticks = v; },
    set job(v: XrayJob | null) { job = v; },
    latest: { tag: 'v26.10.31', via: 'direct' } as Record<string, string>,
    install: { ok: true } as Record<string, unknown>,
  };
  r.on('luci.xvpn.xray', () => {
    if (job?.state === 'running' && ticks-- <= 0) {
      job = { ...job, ...result, step: null } as XrayJob;
      if (job.state === 'done')
        info = { ...info, bin: '/usr/lib/xvpn/xray', source: 'github', github: { tag: job.tag, version: job.version ?? '', installed: 1 } };
    }
    return job ? { ...info, job } : info;
  });
  r.on('luci.xvpn.xray_latest', () => st.latest);
  r.on('luci.xvpn.xray_install', (a) => {
    st.installs.push(a.tag as string);
    if (!st.install.ok)
      return st.install;
    job = { id: 'j1', state: 'running', step: 'download', tag: a.tag as string };
    return { ok: true, id: 'j1' };
  });
  r.on('luci.xvpn.xray_rollback', () => {
    info = { ...FEED };
    return { ok: true, bin: '/usr/bin/xray' };
  });
  const flow = new XrayFlow(new XvpnApi(new UbusClient(r)), { pollMs: 1, waitMs: 500 });
  return { st, flow };
}

describe('XrayFlow', () => {
  it('checks GitHub through the router and installs the newer release', async () => {
    const { st, flow } = router();
    await flow.load();
    expect(runningVersion(flow.get().info!)).toBe('25.1.30');
    expect(flow.installable).toBe(null);
    await flow.check();
    expect(flow.get().latest).toBe('v26.10.31');
    expect(flow.installable).toBe('v26.10.31');
    st.ticks = 2;
    const steps: (string | null | undefined)[] = [];
    flow.subscribe((s) => steps.push(s.job?.step));
    await flow.install();
    expect(st.installs).toEqual(['v26.10.31']);
    const s = flow.get();
    expect([s.busy, s.error, s.job?.state, s.info?.source]).toEqual([null, null, 'done', 'github']);
    expect(steps).toContain('download');
    // the same release again: nothing to install
    expect(flow.installable).toBe(null);
  });

  it('reports the reason of a failed job', async () => {
    const { st, flow } = router();
    await flow.load();
    await flow.check();
    st.result = { state: 'failed', error: 'not enough space: 20.0 MB free in /usr/lib/xvpn, 34.5 MB needed' };
    await flow.install();
    const e = flow.get().error;
    expect(e?.code).toBe('xray_failed');
    expect(e?.detail.output).toMatch(/not enough space/);
    expect(flow.get().info?.source).toBe('feed');
  });

  it('a job that dies is lost', async () => {
    const { st, flow } = router();
    await flow.load();
    await flow.check();
    st.result = { state: 'lost' };
    await flow.install();
    expect(flow.get().error?.code).toBe('xray_lost');
  });

  it('the router cannot reach GitHub', async () => {
    const { st, flow } = router();
    st.latest = { error: 'Could not resolve host: github.com' };
    await flow.check();
    expect(flow.get().error?.code).toBe('xray_latest');
    expect(flow.get().error?.detail.output).toMatch(/resolve/);
    expect(flow.installable).toBe(null);
  });

  it('install needs root, an old package has no xray', async () => {
    const { st, flow } = router();
    await flow.load();
    await flow.check();
    st.r.denied.add('luci.xvpn.xray_install');
    await flow.install();
    expect(flow.get().error?.code).toBe('need_root');

    const old = router();
    old.st.r.methods.delete('luci.xvpn.xray');
    await old.flow.load();
    expect(old.flow.get().error?.code).toBe('xray_old_package');
  });

  it('another install is running', async () => {
    const { st, flow } = router();
    await flow.check();
    st.install = { ok: false, error: 'busy' };
    await flow.install();
    expect(flow.get().error?.code).toBe('xray_busy');
  });

  it('follows a job started elsewhere and goes back to the package', async () => {
    const { st, flow } = router();
    st.job = { id: 'luci', state: 'running', step: 'restart', tag: 'v26.10.31' };
    st.ticks = 1;
    await flow.load();
    expect([flow.get().job?.state, flow.get().info?.source]).toEqual(['done', 'github']);
    await flow.rollback();
    expect([flow.get().error, flow.get().info?.source]).toEqual([null, 'feed']);
  });
});
