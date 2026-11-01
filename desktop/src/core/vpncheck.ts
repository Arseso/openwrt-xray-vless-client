// "Am I behind the VPN" (#78): the public IPv4 and IPv6 of this PC against the exit of the
// active server, each family on its own. Neither the router nor the daemon knows the exit
// address, so the exit is taken as the address of the server itself (resolved on the PC):
// right for the usual single-host server, wrong for a relay or CDN front whose exit
// differs from its entry (then "direct" is shown with both addresses and that caveat).
// Checked only on demand: the public address comes from a third-party echo service
// (src-tauri/src/vpncheck.rs), api4/api6.ipify.org, icanhazip.com only when asked for.

import { invokeRust } from '../api/transport';
import { StatusUp } from '../api/xvpn';
import { toXvpnError } from '../api/errors';

export type Verdict = 'vpn' | 'direct';
export type Family = 'v4' | 'v6';

export interface FamilyCheck {
  family: Family;
  /** the public address over this family; null: no answer (no such connectivity) */
  ip: string | null;
  source: string | null;
  error: string | null;
  /** null without an address to compare */
  verdict: Verdict | null;
}

export interface VpnCheck {
  server: string;
  serverIps: string[];
  /** the server name did not resolve */
  resolveError: string | null;
  v4: FamilyCheck;
  v6: FamilyCheck;
}

export interface VpnCheckDeps {
  publicIp(v6: boolean, other: boolean): Promise<{ ip: string; source: string }>;
  resolve(host: string): Promise<string[]>;
}

export const rustDeps: VpnCheckDeps = {
  publicIp: (v6, other) => invokeRust('vpn_public_ip', { v6, other }),
  resolve: (host) => invokeRust('vpn_resolve', { host }),
};

/** the services asked, for the window to name them */
export const SERVICES = { main: 'api4.ipify.org, api6.ipify.org', other: 'ipv4.icanhazip.com, ipv6.icanhazip.com' };

/** IPv6 written in different ways compares equal */
function norm(ip: string): string {
  const s = ip.trim().toLowerCase().replace(/^\[|\]$/g, '');
  if (!s.includes(':'))
    return s;
  const [head, tail = ''] = s.split('::');
  const h = head ? head.split(':') : [], t = tail ? tail.split(':') : [];
  const parts = s.includes('::') ? [...h, ...Array(8 - h.length - t.length).fill('0'), ...t] : h;
  return parts.map((p) => p.replace(/^0+(?=.)/, '')).join(':');
}

export function verdict(publicIp: string, serverIps: string[]): Verdict {
  const p = norm(publicIp);
  return serverIps.some((ip) => norm(ip) === p) ? 'vpn' : 'direct';
}

/** null without an active server; every part that fails is reported, the rest shown */
export async function checkVpn(status: StatusUp, deps: VpnCheckDeps = rustDeps, other = false): Promise<VpnCheck | null> {
  const active = status.servers.find((s) => s.id === status.active);
  if (!active)
    return null;
  const [r4, r6, rs] = await Promise.allSettled([deps.publicIp(false, other), deps.publicIp(true, other), deps.resolve(active.address)]);
  const serverIps = rs.status === 'fulfilled' ? rs.value : [];
  const fam = (family: Family, r: PromiseSettledResult<{ ip: string; source: string }>): FamilyCheck => r.status === 'fulfilled'
    ? { family, ip: r.value.ip, source: r.value.source, error: null, verdict: rs.status === 'fulfilled' ? verdict(r.value.ip, serverIps) : null }
    : { family, ip: null, source: null, error: toXvpnError(r.reason).message, verdict: null };
  return {
    server: active.name,
    serverIps,
    resolveError: rs.status === 'rejected' ? toXvpnError(rs.reason).message : null,
    v4: fam('v4', r4),
    v6: fam('v6', r6),
  };
}
