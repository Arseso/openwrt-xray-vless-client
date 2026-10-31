// The tray logic (src/tray) against the stand: a server chosen in the menu is applied on
// the router, a failover reaches the tray model within one poll interval. The menu
// itself is Rust's (tray.rs); here the backend only records the models.
//   needs XVPN_CONTAINER (stops the remote xray of the active server for a failover)

import { execFileSync } from 'node:child_process';
import { describe, expect, it } from 'vitest';
import { Profile } from '../../src/api/profiles';
import { StatusUp } from '../../src/api/xvpn';
import { Connection } from '../../src/core/connection';
import { TrayAction, startTray } from '../../src/tray';
import { TrayModel } from '../../src/tray/model';
import { NodeTransport } from './node-transport';

const URL = process.env.XVPN_URL ?? 'http://127.0.0.1:8019';
const USER = process.env.XVPN_USER ?? 'root';
const PASS = process.env.XVPN_PASS ?? 'xvpn-luci-test';
const CONTAINER = process.env.XVPN_CONTAINER;
const DOCKER = (process.env.DOCKER ?? 'docker --context default').split(' ');
const INTERVAL = 1000;

function inStand(cmd: string): void {
  execFileSync(DOCKER[0], [...DOCKER.slice(1), 'exec', CONTAINER!, 'sh', '-c', cmd], { stdio: 'inherit' });
}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

async function until<T>(fn: () => T | Promise<T>, ms: number, what: string): Promise<NonNullable<T>> {
  const end = Date.now() + ms;
  for (;;) {
    const v = await fn();
    if (v)
      return v as NonNullable<T>;
    if (Date.now() > end)
      throw new Error(`timed out: ${what}`);
    await sleep(100);
  }
}

describe.skipIf(!CONTAINER)(`tray against ${URL}`, () => {
  it('select from the menu is applied; a failover reaches the tray within one poll', async () => {
    const profile: Profile = { id: 'stand', name: 'stand', url: URL, username: USER };
    const conn = new Connection({ transport: () => new NodeTransport(URL, USER, PASS), intervalMs: INTERVAL });
    const models: { at: number; m: TrayModel }[] = [];
    let fire!: (a: TrayAction) => void;
    const stop = startTray(conn, {
      update: async (m) => void models.push({ at: Date.now(), m }),
      onAction: (fn) => { fire = fn; return () => {}; },
    });
    let stopped: number | null = null;
    try {
      expect((await conn.connect(profile)).phase).toBe('online');
      const st = await until(() => {
        const s = conn.context?.poller.status;
        // degraded: the stand often fails the DNS check of the outside world, the tunnel works
        return s?.running && (s.state === 'connected' || s.state === 'degraded') && s.active ? s : null;
      }, 60_000, 'connected') as StatusUp;
      // another live server: both manual-live (18443) and sub-live (18445) answer
      const target = st.servers.find((s) => s.id !== st.active && /live/.test(s.name))!;
      expect(target).toBeTruthy();

      fire({ action: 'select', id: target.id });
      await until(() => models.at(-1)?.m.servers.find((s) => s.active)?.id === target.id, 15_000, 'tray shows the new server');
      const after = conn.context!.poller.status as StatusUp;
      expect(after.active).toBe(target.id);
      expect(models.at(-1)!.m.info[1]).toContain(target.name);

      // failover: its remote end goes away
      stopped = target.port;
      const t0 = Date.now();
      // busybox of the stand has no pkill
      inStand(`kill $(ps w | grep '[r]emote-${target.port}.json' | awk '{print $1}')`);
      // the moment the router reports it, asked directly beside the poller
      const direct = new Connection({ transport: () => new NodeTransport(URL, USER, PASS), intervalMs: 200 });
      await direct.connect({ ...profile, id: 'direct' });
      const seen = await until(() => {
        const s = direct.context?.poller.status;
        // the same event on both sides: another server, or none left (degraded and failover
        // share the yellow icon with the DNS trouble of the stand)
        return s?.running && (s.active !== target.id || s.state === 'no_servers') ? Date.now() : null;
      }, 240_000, 'the router reports the failover'); // health interval 30 s x fail_threshold 3
      direct.disconnect();
      const trayAt = await until(() => {
        const last = models.at(-1);
        return last && last.at >= t0 && (last.m.icon === 'xray_down' || !last.m.servers.find((s) => s.id === target.id)?.active)
          ? last.at : null;
      }, 10_000, 'tray reacts');
      console.log(`failover: router ${seen - t0} ms after the stop, tray ${trayAt - seen} ms after the router`);
      // the direct poll runs every 200 ms, so the tray may also be a little ahead
      expect(trayAt - seen).toBeLessThanOrEqual(INTERVAL + 500);
      expect(trayAt - seen).toBeGreaterThan(-500);
    }
    finally {
      if (stopped)
        inStand(`ps w | grep -q '[r]emote-${stopped}.json' || start-stop-daemon -S -b -m -p /var/run/remote-${stopped}.pid -x /usr/bin/xray -- run -c /tmp/remote-${stopped}.json`);
      stop();
      conn.disconnect();
    }
  }, 330_000);
});
