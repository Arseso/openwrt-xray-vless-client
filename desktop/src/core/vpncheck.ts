// "Am I behind the VPN" (#78): the public IP of this PC against the exit of the active
// server. Neither the router nor the daemon knows the exit address, so the exit is taken
// as the address of the server itself (resolved on the PC): right for the usual
// single-host server, wrong for a relay or CDN front whose exit differs from its entry
// (then "direct" is shown with both addresses and that caveat). Checked only on demand:
// the public IP comes from a third-party echo service (src-tauri/src/vpncheck.rs).

import { invokeRust } from '../api/transport';
import { StatusUp } from '../api/xvpn';

export type Verdict = 'vpn' | 'direct';

export interface VpnCheck {
  verdict: Verdict;
  publicIp: string;
  /** the echo service that answered */
  source: string;
  server: string;
  serverIps: string[];
}

export interface VpnCheckDeps {
  publicIp(): Promise<{ ip: string; source: string }>;
  resolve(host: string): Promise<string[]>;
}

export const rustDeps: VpnCheckDeps = {
  publicIp: () => invokeRust('vpn_public_ip'),
  resolve: (host) => invokeRust('vpn_resolve', { host }),
};

/** IPv6 written in different ways compares equal */
function norm(ip: string): string {
  const s = ip.trim().toLowerCase().replace(/^\[|\]$/g, '');
  if (!s.includes(':'))
    return s;
  // expand :: so that 2001:db8::1 and 2001:db8:0:0:0:0:0:1 match
  const [head, tail = ''] = s.split('::');
  const h = head ? head.split(':') : [], t = tail ? tail.split(':') : [];
  const parts = s.includes('::') ? [...h, ...Array(8 - h.length - t.length).fill('0'), ...t] : h;
  return parts.map((p) => p.replace(/^0+(?=.)/, '')).join(':');
}

export function verdict(publicIp: string, serverIps: string[]): Verdict {
  const p = norm(publicIp);
  return serverIps.some((ip) => norm(ip) === p) ? 'vpn' : 'direct';
}

/** null without an active server */
export async function checkVpn(status: StatusUp, deps: VpnCheckDeps = rustDeps): Promise<VpnCheck | null> {
  const active = status.servers.find((s) => s.id === status.active);
  if (!active)
    return null;
  const [pub, serverIps] = await Promise.all([deps.publicIp(), deps.resolve(active.address)]);
  return { verdict: verdict(pub.ip, serverIps), publicIp: pub.ip, source: pub.source, server: active.name, serverIps };
}
