import { describe, expect, it } from 'vitest';
import { checkVpn, verdict } from '../../src/core/vpncheck';
import { StatusUp } from '../../src/api/xvpn';
import { STATUS_UP } from './fake';

describe('am I behind the VPN', () => {
  it('compares addresses, IPv6 written differently included', () => {
    expect(verdict('203.0.113.7', ['198.51.100.1', '203.0.113.7'])).toBe('vpn');
    expect(verdict('203.0.113.8', ['203.0.113.7'])).toBe('direct');
    expect(verdict('2001:db8::1', ['2001:0db8:0:0:0:0:0:1'])).toBe('vpn');
    expect(verdict('[2001:DB8::1]', ['2001:db8::1'])).toBe('vpn');
  });

  it('resolves the active server and asks the public address', async () => {
    const asked: string[] = [];
    const r = await checkVpn(STATUS_UP as StatusUp, {
      publicIp: async () => ({ ip: '1.1.1.1', source: 'https://api.ipify.org' }),
      resolve: async (h) => { asked.push(h); return ['1.1.1.1']; },
    });
    expect(asked).toEqual(['1.1.1.1']);
    expect(r).toMatchObject({ verdict: 'vpn', server: 'A', publicIp: '1.1.1.1' });
  });

  it('no active server: nothing to compare with', async () => {
    const r = await checkVpn({ ...STATUS_UP, active: null } as StatusUp, {
      publicIp: async () => ({ ip: '1', source: '' }), resolve: async () => [],
    });
    expect(r).toBeNull();
  });
});
