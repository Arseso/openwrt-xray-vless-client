import { describe, expect, it } from 'vitest';
import { UbusClient } from '../../src/api/ubus';
import { SUPPORTED_API, checkPackage } from '../../src/api/version';
import { XvpnApi } from '../../src/api/xvpn';
import { FakeRouter, STATUS_UP } from './fake';

function api(router: FakeRouter) {
  return new XvpnApi(new UbusClient(router));
}

describe('checkPackage', () => {
  it('returns version and api', async () => {
    const r = new FakeRouter().on('luci.xvpn.version', () => ({ version: '0.2.0-r1', api: SUPPORTED_API }));
    await expect(checkPackage(api(r))).resolves.toEqual({ version: '0.2.0-r1', api: SUPPORTED_API });
  });

  it('refuses another api with the versions in detail', async () => {
    const r = new FakeRouter().on('luci.xvpn.version', () => ({ version: '1.0.0-r1', api: 2 }));
    await expect(checkPackage(api(r))).rejects.toMatchObject({
      code: 'incompatible', detail: { version: '1.0.0-r1', api: 2, supported: SUPPORTED_API },
    });
  });

  it('an old package: the ACL has no version, status works', async () => {
    const r = new FakeRouter().on('luci.xvpn.status', () => STATUS_UP);
    r.denied.add('luci.xvpn.version');
    await expect(checkPackage(api(r))).rejects.toMatchObject({ code: 'old_package' });
  });

  it('an old package: no such method', async () => {
    const r = new FakeRouter().on('luci.xvpn.status', () => STATUS_UP);
    await expect(checkPackage(api(r))).rejects.toMatchObject({ code: 'old_package' });
  });

  it('no package: no luci.xvpn on ubus (root is denied an unknown object)', async () => {
    const r = new FakeRouter();
    r.objects.delete('luci.xvpn');
    r.denied.add('luci.xvpn.version');
    await expect(checkPackage(api(r))).rejects.toMatchObject({ code: 'no_package' });
  });

  it('no rights: luci.xvpn is there but denied', async () => {
    const r = new FakeRouter();
    r.denied.add('luci.xvpn.version').add('luci.xvpn.status');
    await expect(checkPackage(api(r))).rejects.toMatchObject({ code: 'acl' });
  });

  it('the router away is not a package problem', async () => {
    const r = new FakeRouter();
    const { XvpnError } = await import('../../src/api/errors');
    r.failures.push(new XvpnError('timeout'));
    await expect(checkPackage(api(r))).rejects.toMatchObject({ code: 'timeout' });
  });
});
