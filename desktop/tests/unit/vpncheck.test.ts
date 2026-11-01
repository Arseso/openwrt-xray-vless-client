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

  it('IPv4 and IPv6 each on their own; a failing part does not hide the rest', async () => {
    const asked: string[] = [];
    const r = await checkVpn(STATUS_UP as StatusUp, {
      publicIp: async (v6) => { if (v6) throw new Error('no IPv6'); return { ip: '1.1.1.1', source: 'https://api4.ipify.org' }; },
      resolve: async (h) => { asked.push(h); return ['1.1.1.1']; },
    });
    expect(asked).toEqual(['1.1.1.1']);
    expect(r?.v4).toMatchObject({ ip: '1.1.1.1', verdict: 'vpn', source: 'https://api4.ipify.org' });
    expect(r?.v6).toMatchObject({ ip: null, verdict: null, error: 'no IPv6' });
  });

  it('IPv6 past the tunnel is direct; the public address shows without the server name', async () => {
    const r = await checkVpn(STATUS_UP as StatusUp, {
      publicIp: async (v6) => ({ ip: v6 ? '2001:db8::7' : '1.1.1.1', source: '' }),
      resolve: async () => { throw new Error('timed out'); },
    });
    expect(r?.resolveError).toBe('timed out');
    expect(r?.v4).toMatchObject({ ip: '1.1.1.1', verdict: null });
    const r2 = await checkVpn(STATUS_UP as StatusUp, {
      publicIp: async (v6) => ({ ip: v6 ? '2001:db8::7' : '1.1.1.1', source: '' }),
      resolve: async () => ['1.1.1.1'],
    });
    expect(r2?.v6.verdict).toBe('direct');
  });

  it('the other service only when asked', async () => {
    const seen: boolean[] = [];
    await checkVpn(STATUS_UP as StatusUp, { publicIp: async (_, o) => { seen.push(o); return { ip: '1', source: '' }; }, resolve: async () => [] }, true);
    expect(seen).toEqual([true, true]);
  });

  it('no active server: nothing to compare with', async () => {
    const r = await checkVpn({ ...STATUS_UP, active: null } as StatusUp, {
      publicIp: async () => ({ ip: '1', source: '' }), resolve: async () => [],
    });
    expect(r).toBeNull();
  });
});
