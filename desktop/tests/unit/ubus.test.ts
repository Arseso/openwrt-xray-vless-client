import { describe, expect, it } from 'vitest';
import { XvpnError } from '../../src/api/errors';
import { UbusClient } from '../../src/api/ubus';
import { XvpnApi } from '../../src/api/xvpn';
import { FakeRouter } from './fake';

function setup() {
  const router = new FakeRouter().on('luci.xvpn.servers', () => ({ servers: [], active: null }));
  const ubus = new UbusClient(router);
  return { router, ubus, xvpn: new XvpnApi(ubus) };
}

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

  it('reports acl when a fresh session is denied too', async () => {
    const { router, xvpn } = setup();
    router.denied.add('luci.xvpn.servers');
    const e = await xvpn.servers().catch((x) => x);
    expect(e).toBeInstanceOf(XvpnError);
    expect(e.code).toBe('acl');
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
    expect(router.calls.map((c) => c.args)).toEqual([{}, { sid: 'sub1' }, { updating: false }]);
  });
});
