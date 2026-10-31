// Saving with apply / confirm / rollback (src/core/apply.ts) against a fake rpcd uci:
// committed values, changes staged in the session, apply with a rollback timer.

import { describe, expect, it } from 'vitest';
import { XvpnError } from '../../src/api/errors';
import { UbusClient } from '../../src/api/ubus';
import { UciApi } from '../../src/api/uci';
import { XvpnApi } from '../../src/api/xvpn';
import { save } from '../../src/core/apply';
import { FakeRouter } from './fake';

type Conf = Record<string, Record<string, unknown>>;

/** rpcd uci of one config with the rollback of apply */
function fakeUci(r: FakeRouter, initial: Conf) {
  const st = { committed: structuredClone(initial), staged: null as Conf | null, backup: null as Conf | null, timer: null as ReturnType<typeof setTimeout> | null, confirms: 0, reverts: 0, applyStatus: 0 };
  const work = () => (st.staged ??= structuredClone(st.committed));
  const changes = () => (st.staged && JSON.stringify(st.staged) !== JSON.stringify(st.committed) ? [['set', 'x']] : []);
  r.on('uci.get', () => ({ values: st.staged ?? st.committed }))
    .on('uci.set', (a) => {
      Object.assign(work()[a.section as string], a.values);
      return {};
    })
    .on('uci.add', (a) => {
      work()[a.name as string] = { '.name': a.name, '.type': a.type, ...(a.values as object) };
      return { section: a.name };
    })
    .on('uci.delete', (a) => {
      if (a.options)
        for (const o of a.options as string[])
          delete work()[a.section as string][o];
      else
        delete work()[a.section as string];
      return {};
    })
    .on('uci.changes', () => ({ changes: changes() }))
    .on('uci.revert', () => {
      st.reverts++;
      st.staged = null;
      return {};
    })
    .on('uci.apply', (a) => {
      if (st.applyStatus)
        return [st.applyStatus];
      st.backup = st.committed;
      st.committed = st.staged ?? st.committed;
      st.staged = null;
      if (a.rollback)
        st.timer = setTimeout(() => {
          st.committed = st.backup!;
          st.timer = null;
        }, (a.timeout as number) * 1000);
      return {};
    })
    .on('uci.confirm', () => {
      if (!st.timer)
        return [5];
      clearTimeout(st.timer);
      st.timer = null;
      st.confirms++;
      return {};
    });
  return st;
}

function setup(initial: Conf) {
  const r = new FakeRouter().on('luci.xvpn.version', () => ({ version: '0.2.0-r1', api: 1 }));
  const uciState = fakeUci(r, initial);
  const ubus = new UbusClient(r);
  return { r, st: uciState, uci: new UciApi(ubus), xvpn: new XvpnApi(ubus), ubus };
}

const fast = { timeout: 3, holdoffMs: 5, intervalMs: 20 };
const health = { health: { '.name': 'health', '.type': 'health', interval: '30' } };

describe('save with rollback', () => {
  it('stages, applies with rollback and confirms once the router answers', async () => {
    const { r, st, uci, xvpn, ubus } = setup(health);
    const res = await save(uci, xvpn, [{ section: 'health', type: 'health', set: { interval: '60' }, unset: [] }], fast);
    expect(res).toBe('applied');
    expect(st.confirms).toBe(1);
    expect(st.committed.health.interval).toBe('60');
    expect(r.calls.find((c) => c.method === 'apply')?.args).toEqual({ rollback: true, timeout: 3 });
    expect(ubus.hasStaged).toBe(false);
  });

  it('does not confirm when the router does not answer after apply: rpcd rolls back', async () => {
    const { r, st, uci, xvpn } = setup(health);
    r.on('luci.xvpn.version', () => {
      throw new Error('not reached');
    });
    const apply = r.methods.get('uci.apply')!;
    r.on('uci.apply', (a) => {
      const out = apply(a);
      // the PC lost the router: every request from now on
      r.failures.push(...Array.from({ length: 1000 }, () => new XvpnError('unreachable')));
      return out;
    });
    const res = await save(uci, xvpn, [{ section: 'health', type: 'health', set: { interval: '5' } }], fast);
    expect(res).toBe('rolled_back');
    expect(st.confirms).toBe(0);
    expect(r.calls.some((c) => c.method === 'confirm')).toBe(false);
    r.failures = [];
    await new Promise((ok) => setTimeout(ok, 2100));
    expect(st.committed.health.interval).toBe('30');
  }, 10_000);

  it('a confirm the router no longer waits for (status 5): rolled back, the re-staged changes dropped', async () => {
    const { r, st, uci, xvpn } = setup(health);
    r.on('uci.confirm', () => [5]);
    expect(await save(uci, xvpn, [{ section: 'health', type: 'health', set: { interval: '60' } }], fast)).toBe('rolled_back');
    expect(st.reverts).toBe(1);
  });

  it('adds a missing section and deletes options', async () => {
    const { st, uci, xvpn } = setup(health);
    expect(await save(uci, xvpn, [
      { section: 'health', type: 'health', unset: ['interval'] },
      { section: 'sub_01020304', type: 'subscription', add: true, set: { name: 'x', url: 'https://s.example/1' } },
    ], fast)).toBe('applied');
    expect(st.committed.health).not.toHaveProperty('interval');
    expect(st.committed.sub_01020304).toMatchObject({ '.type': 'subscription', name: 'x' });
  });

  it('nothing to save: no call at all', async () => {
    const { r, uci, xvpn } = setup(health);
    expect(await save(uci, xvpn, [{ section: 'health', type: 'health', set: {}, unset: [] }], fast)).toBe('nothing');
    expect(r.calls).toEqual([]);
  });

  it('apply refused (another session waits for its confirm): acl, the staged changes are reverted', async () => {
    const { st, uci, xvpn } = setup(health);
    st.applyStatus = 6;
    await expect(save(uci, xvpn, [{ section: 'health', type: 'health', set: { interval: '60' } }], fast)).rejects.toMatchObject({ code: 'acl' });
    expect(st.reverts).toBe(1);
    expect(st.committed.health.interval).toBe('30');
  });

  it('a new login between staging and apply: session_lost instead of an empty apply', async () => {
    const { r, uci, xvpn } = setup(health);
    r.on('uci.set', () => {
      r.expireSessions();
      return {};
    });
    await expect(save(uci, xvpn, [{ section: 'health', type: 'health', set: { interval: '60' } }], fast)).rejects.toMatchObject({ code: 'session_lost' });
    expect(r.calls.some((c) => c.method === 'apply')).toBe(false);
  });
});
