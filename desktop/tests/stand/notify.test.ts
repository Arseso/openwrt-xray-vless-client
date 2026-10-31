// Notifications (#80) against the stand of scripts/luci.sh: the active server blocked
// on the router gives one failover notice, uhttpd stopped and started one "unreachable"
// and one "reachable again". Needs XVPN_CONTAINER (see client.test.ts).

import { execFileSync } from 'node:child_process';
import { afterAll, describe, expect, it } from 'vitest';
import { Profile } from '../../src/api/profiles';
import { Connection } from '../../src/core/connection';
import { DEFAULT_SETTINGS, Notice, Notifier, saveSettings, startNotifications } from '../../src/core/notify';
import { NodeTransport } from './node-transport';

const URL = process.env.XVPN_URL ?? 'http://127.0.0.1:8019';
const USER = process.env.XVPN_USER ?? 'root';
const PASS = process.env.XVPN_PASS ?? 'xvpn-luci-test';
const CONTAINER = process.env.XVPN_CONTAINER;
const DOCKER = (process.env.DOCKER ?? 'docker --context default').split(' ');
const TAG = 'xvpn-desktop-notify';

function inStand(cmd: string): string {
  return execFileSync(DOCKER[0], [...DOCKER.slice(1), 'exec', CONTAINER!, 'sh', '-c', cmd], { encoding: 'utf8' });
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
    await sleep(250);
  }
}

/** the rules this test put in front of fw4 output */
function unblock(): void {
  inStand(`nft -a list chain inet fw4 output | sed -n 's/.*comment "${TAG}".*# handle \\([0-9]*\\)/\\1/p' `
    + '| while read h; do nft delete rule inet fw4 output handle $h; done');
}

describe.skipIf(!CONTAINER)(`notifications against ${URL}`, () => {
  const health = CONTAINER ? inStand('uci -q get xvpn.health.interval || echo 30').trim() : '30';

  afterAll(() => {
    unblock();
    inStand(`/etc/init.d/uhttpd start; uci set xvpn.health.interval=${health}; uci commit xvpn; /etc/init.d/xvpn restart`);
  });

  it('one failover for a blocked server, one down and one up for the router', async () => {
    // health checks every 3 s instead of 30: the failover in seconds
    inStand('uci set xvpn.health.interval=3; uci commit xvpn; /etc/init.d/xvpn restart');
    saveSettings({ ...structuredClone(DEFAULT_SETTINGS), intervalMs: 1000 });
    const notices: Notice[] = [];
    const notifier = new Notifier(() => {}, { store: null });
    const spy = {
      send: (n: Notice) => {
        const v = notifier.send(n);
        if (v === 'sent')
          notices.push(n);
        return v;
      },
    };
    const profile: Profile = { id: 'stand', name: 'stand', url: URL, username: USER };
    const conn = new Connection({ transport: () => new NodeTransport(URL, USER, PASS), retryMs: 500 });
    const stop = startNotifications(conn, { notifier: spy });
    try {
      expect((await conn.connect(profile)).phase).toBe('online');
      const before = await until(() => {
        const s = conn.context?.poller.status;
        return s?.running && s.state === 'connected' && s.active ? s : null;
      }, 60_000);
      const active = before.servers.find((s) => s.id === before.active)!;
      console.log('active', active.name, active.port);
      // what the restart of xvpn above may have told
      notices.length = 0;

      // before the "lo accept" of fw4: xray on the router cannot reach the server
      inStand(`nft insert rule inet fw4 output ip daddr 127.0.0.1 tcp dport ${active.port} counter reject comment "${TAG}"`);
      await until(() => notices.some((n) => n.type === 'failover'), 120_000);
      const after = conn.context!.poller.status!;
      expect(after.running && after.active).not.toBe(active.id);
      // the next checks and polls tell nothing more about it
      await sleep(10_000);
      unblock();
      expect(notices.map((n) => n.type)).toEqual(['failover']);
      console.log('failover:', notices[0].body);

      inStand('/etc/init.d/uhttpd stop');
      await until(() => notices.some((n) => n.key.startsWith('router-down')), 30_000);
      await sleep(5000);
      inStand('/etc/init.d/uhttpd start');
      await until(() => notices.some((n) => n.key.startsWith('router-up')), 60_000);
      await sleep(5000);
      expect(notices.map((n) => n.key.replace(/:.*/, ''))).toEqual(['failover', 'router-down', 'router-up']);
    }
    finally {
      stop();
      conn.disconnect();
    }
  });
});
