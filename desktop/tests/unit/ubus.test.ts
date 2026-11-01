import { describe, expect, it } from 'vitest';
import { XvpnError } from '../../src/api/errors';
import { UbusClient } from '../../src/api/ubus';
import { UciApi } from '../../src/api/uci';
import { XvpnApi } from '../../src/api/xvpn';
import { FakeRouter } from './fake';

function setup() {
  const router = new FakeRouter().on('luci.xvpn.servers', () => ({ servers: [], active: null }));
  const ubus = new UbusClient(router);
  return { router, ubus, xvpn: new XvpnApi(ubus) };
}

describe('UCI and the session', () => {
  function uciSetup() {
    const { router, ubus } = setup();
    router.on('uci.set', () => ({})).on('uci.apply', () => ({})).on('uci.confirm', () => ({}))
      .on('uci.get', () => ({ value: '1' }));
    return { router, ubus, uci: new UciApi(ubus) };
  }

  it('uci status 6 (no rights for that config) is acl and keeps the session and staged changes', async () => {
    const { router, ubus, uci } = uciSetup();
    router.rpcDenied = false;
    await uci.set('xvpn', 'main', { a: '1' });
    router.denied.add('uci.set');
    await expect(uci.set('network', 'lan', { a: '1' })).rejects.toMatchObject({ code: 'acl' });
    expect(router.logins).toBe(1);
    expect(ubus.hasStaged).toBe(true);
    await expect(uci.apply()).resolves.toBeUndefined();
  });

  it('a new login with staged changes: the next write fails with session_lost, not an apply of nothing', async () => {
    const { router, uci, ubus } = uciSetup();
    await uci.set('xvpn', 'main', { a: '1' });
    router.expireSessions();
    await expect(uci.get('xvpn', 'main', 'a')).resolves.toBe('1'); // reads go on
    await expect(uci.apply()).rejects.toMatchObject({ code: 'session_lost' });
    expect(router.calls.filter((c) => c.method === 'apply')).toEqual([]);
    expect(ubus.hasStaged).toBe(false);
    // reported once: the user stages again
    await uci.set('xvpn', 'main', { a: '1' });
    await expect(uci.apply()).resolves.toBeUndefined();
  });

  it('a user without session access: a denial with staged changes is acl, no new login loses them', async () => {
    const { router, ubus, uci } = uciSetup();
    router.denied.add('session.access');
    await uci.set('xvpn', 'main', { a: '1' });
    router.denied.add('luci.xvpn.service');
    await expect(ubus.call('luci.xvpn', 'service', { action: 'stop' })).rejects.toMatchObject({ code: 'acl' });
    expect(router.logins).toBe(1);
    expect(ubus.hasStaged).toBe(true);
    await expect(uci.apply()).resolves.toBeUndefined();
  });

  it('a user without session access and nothing staged: a denial still tries one new login', async () => {
    const { router, ubus } = uciSetup();
    router.denied.add('session.access');
    router.on('luci.xvpn.status', () => ({}));
    await ubus.call('luci.xvpn', 'status');
    router.expireSessions();
    await expect(ubus.call('luci.xvpn', 'status')).resolves.toEqual({});
    expect(router.logins).toBe(2);
  });

  it('the relogin of the failing write itself reports session_lost', async () => {
    const { router, uci } = uciSetup();
    await uci.set('xvpn', 'main', { a: '1' });
    router.expireSessions();
    await expect(uci.set('xvpn', 'main', { b: '2' })).rejects.toMatchObject({ code: 'session_lost' });
  });

  it('the confirm of an apply with rollback after the session changed: session_lost', async () => {
    const { router, uci } = uciSetup();
    await uci.set('xvpn', 'main', { a: '1' });
    await uci.apply({ rollback: true });
    router.expireSessions();
    await expect(uci.confirm()).rejects.toMatchObject({ code: 'session_lost' });
  });

  it('nothing staged: a new login is silent', async () => {
    const { router, uci } = uciSetup();
    await uci.set('xvpn', 'main', { a: '1' });
    await uci.apply({ rollback: false });
    router.expireSessions();
    await expect(uci.set('xvpn', 'main', { a: '2' })).resolves.toBeUndefined();
  });
});

describe('UbusClient', () => {
  it('logs in on the first call and keeps the session', async () => {
    const { router, xvpn, ubus } = setup();
    await xvpn.servers();
    await xvpn.servers();
    expect(router.logins).toBe(1);
    expect(ubus.session).toMatch(/^sid1/);
  });

  it.each([true, false])('logs in again once the session expired (rpc error: %s)', async (rpc) => {
    const { router, xvpn } = setup();
    router.rpcDenied = rpc;
    await xvpn.servers();
    router.expireSessions();
    await expect(xvpn.servers()).resolves.toEqual({ servers: [], active: null });
    expect(router.logins).toBe(2);
  });

  it('shares one login between concurrent calls after expiry', async () => {
    const { router, xvpn } = setup();
    await xvpn.servers();
    router.expireSessions();
    await Promise.all([xvpn.servers(), xvpn.servers(), xvpn.servers()]);
    expect(router.logins).toBe(2);
  });

  it('a denial with a live session is acl, without a new login', async () => {
    const { router, xvpn, ubus } = setup();
    router.denied.add('luci.xvpn.servers');
    const e = await xvpn.servers().catch((x) => x);
    expect(e).toBeInstanceOf(XvpnError);
    expect(e.code).toBe('acl');
    expect(router.logins).toBe(1);
    expect(ubus.session).toMatch(/^sid1/);
  });

  it('reports acl when a fresh session is denied too', async () => {
    const { router, xvpn } = setup();
    await xvpn.servers();
    router.expireSessions();
    router.denied.add('luci.xvpn.servers');
    await expect(xvpn.servers()).rejects.toMatchObject({ code: 'acl' });
    expect(router.logins).toBe(2);
  });

  it('reports a wrong password', async () => {
    const { router, xvpn } = setup();
    router.given = 'nope';
    await expect(xvpn.servers()).rejects.toMatchObject({ code: 'wrong_password' });
  });

  it('a password changed on the router shows up at the next login', async () => {
    const { router, xvpn } = setup();
    await xvpn.servers();
    router.password = 'changed';
    router.expireSessions();
    await expect(xvpn.servers()).rejects.toMatchObject({ code: 'wrong_password' });
  });

  it('passes transport errors through', async () => {
    const { router, xvpn } = setup();
    router.failures.push(new XvpnError('unreachable', 'connection refused'));
    await expect(xvpn.servers()).rejects.toMatchObject({ code: 'unreachable', offline: true });
    // and recovers on the next call
    await expect(xvpn.servers()).resolves.toBeTruthy();
  });

  it('maps ubus statuses', async () => {
    const { router, xvpn, ubus } = setup();
    router.on('luci.xvpn.select', () => [2]);
    await expect(xvpn.select('x')).rejects.toMatchObject({ code: 'invalid_argument' });
    await expect(xvpn.stats()).rejects.toMatchObject({ code: 'no_method' });
    router.objects.delete('luci.xvpn');
    await expect(xvpn.status()).rejects.toMatchObject({ code: 'no_object' });
    await expect(ubus.list('luci.xvpn')).resolves.toEqual({});
  });

  it('rejects an answer that is not JSON-RPC', async () => {
    const { router, xvpn } = setup();
    router.request = async () => ({ result: 'hello' });
    await expect(xvpn.servers()).rejects.toMatchObject({ code: 'bad_response' });
  });

  it('sends the arguments the plugin expects', async () => {
    const { router, xvpn } = setup();
    router.on('luci.xvpn.update', () => ({ ok: true })).on('luci.xvpn.subscriptions', () => ({ subscriptions: [], time: 1 }));
    await xvpn.update();
    await xvpn.update('sub1');
    await xvpn.subscriptions({ updating: false });
    // rpcd rejects null arguments: an absent sid is left out
    expect(router.calls.filter((c) => c.object === 'luci.xvpn').map((c) => c.args)).toEqual([{}, { sid: 'sub1' }, { updating: false }]);
  });
});
