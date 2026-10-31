// The diagnostics file (src/core/diagnostics.ts) has no secrets: share links, subscription
// URLs (their path and query are the token), UUIDs; and the log filter of the Log tab.

import { describe, expect, it } from 'vitest';
import { UbusClient } from '../../src/api/ubus';
import { UciApi, UciSection } from '../../src/api/uci';
import { XvpnApi } from '../../src/api/xvpn';
import { Bus } from '../../src/core/bus';
import { AppContext } from '../../src/core/connection';
import { collectDiagnostics, maskConfig, maskLink, maskText, maskUrl, publicUrls } from '../../src/core/diagnostics';
import { PollerEvents, StatusPoller } from '../../src/core/poller';
import { filterLog, matcher } from '../../src/views/log';
import { FakeRouter, STATUS_UP } from './fake';

const UUID = '6f1c2b3a-9d8e-4f70-a1b2-c3d4e5f60718';
const VLESS = `vless://${UUID}@vpn.example.net:443?type=tcp&security=reality&pbk=PUBKEYsecret&sid=ab12#NL%20Amsterdam`;
const VMESS = 'vmess://eyJ2IjoiMiIsImFkZCI6InZtZXNzLmV4YW1wbGUiLCJpZCI6InNlY3JldCJ9';
const SS = 'ss://YWVzLTI1Ni1nY206cGFzc3dvcmQ@ss.example:8388#ss';
const TROJAN = 'trojan://trojanPassw0rd@tr.example:443?sni=tr.example#tr';
const SUB = 'https://panel.example.com/api/sub/Zx9TokenSecret123?flag=v2ray';

const sec = (name: string, type: string, opts: Record<string, string | string[]>): UciSection =>
  ({ '.name': name, '.type': type, '.anonymous': false, ...opts });

const CONFIG = {
  main: sec('main', 'general', { enabled: '1', xray_bin: '/usr/bin/xray' }),
  health: sec('health', 'health', { url: 'https://check.example/ok', url2: 'off' }),
  access: sec('access', 'access', { dns_server: 'https://dns.example/dns-query', network: ['lan'] }),
  sub_1: sec('sub_1', 'subscription', { name: 'Provider', url: SUB, user_agent: 'v2rayN/7.0' }),
  manual: sec('manual', 'manual', { link: [VLESS, VMESS, SS, TROJAN] }),
};

const SECRETS = [UUID, 'PUBKEYsecret', 'Zx9TokenSecret123', 'api/sub', 'eyJ2Ijoi', 'YWVzLTI1Ni1nY206cGFzc3dvcmQ', 'trojanPassw0rd'];

describe('masking', () => {
  it('share links keep the scheme and the server, not the credentials', () => {
    expect(maskLink(VLESS)).toBe('vless://***@vpn.example.net:443');
    expect(maskLink(TROJAN)).toBe('trojan://***@tr.example:443');
    expect(maskLink(SS)).toBe('ss://***@ss.example:8388');
    expect(maskLink(VMESS)).toBe('vmess://***');
  });

  it('URLs keep the scheme and the host; the check URLs stay', () => {
    expect(maskUrl(SUB)).toBe('https://panel.example.com/***');
    expect(maskUrl('https://user:pw@panel.example.com/')).toBe('https://panel.example.com');
    expect(maskUrl('https://check.example/ok', new Set(['https://check.example/ok']))).toBe('https://check.example/ok');
  });

  it('text: links, URLs and UUIDs inside log lines', () => {
    const line = `Oct 27 10:00:00 2026 daemon.err xvpn: update ${SUB}: curl: (22) 403, link ${VLESS} user ${UUID}.`;
    const m = maskText(line, publicUrls(CONFIG));
    for (const s of SECRETS)
      expect(m).not.toContain(s);
    expect(m).toContain('https://panel.example.com/***:');
    expect(m).toContain('vless://***@vpn.example.net:443');
    expect(m).toContain('user <uuid>.');
    expect(maskText('check https://check.example/ok failed', publicUrls(CONFIG))).toBe('check https://check.example/ok failed');
  });

  it('the config: subscription URL, manual links; the rest as it is', () => {
    const c = maskConfig(CONFIG);
    expect(c.sub_1.url).toBe('https://panel.example.com/***');
    expect(c.manual.link).toEqual(['vless://***@vpn.example.net:443', 'vmess://***', 'ss://***@ss.example:8388', 'trojan://***@tr.example:443']);
    expect(c.health.url).toBe('https://check.example/ok');
    expect(c.access.network).toEqual(['lan']);
    expect(c.main.xray_bin).toBe('/usr/bin/xray');
    expect(JSON.stringify(c)).not.toMatch(new RegExp(SECRETS.join('|')));
    // the input stays as it was
    expect(CONFIG.sub_1.url).toBe(SUB);
  });
});

function context(username = 'root'): { ctx: AppContext; r: FakeRouter } {
  const r = new FakeRouter()
    .on('luci.xvpn.status', () => ({ ...STATUS_UP, last_error: `subscription ${SUB} failed` }))
    .on('luci.xvpn.firewall', () => ({ mode: 'tproxy', want: 'table inet xvpn { }' }))
    .on('luci.xvpn.subscriptions', () => ({
      subscriptions: [{ id: 'sub_1', name: 'Provider', enabled: true, count: 3, error: `curl: (6) ${SUB}`, userinfo: { total: 1e11, expire: 2e9 } }],
      time: 1000,
    }))
    .on('luci.xvpn.split', () => ({ ru: false, time: 1000 }))
    .on('luci.xvpn.access_points', () => ({ networks: [{ name: 'lan' }], ports: [], wifi: [], flow_offloading: false, flow_offloading_hw: false }))
    .on('luci.xvpn.log', () => ({ log: `Tue Oct 27 10:00:00 2026 user.notice xvpn: imported ${VLESS}\nTue Oct 27 10:00:01 2026 daemon.info xray[12]: from ${UUID} accepted` }))
    .on('uci.get', () => ({ values: CONFIG }))
    .on('system.board', () => ({ model: 'Test router', release: { description: 'OpenWrt 24.10.4' } }));
  r.objects.add('system');
  const ubus = new UbusClient(r);
  const xvpn = new XvpnApi(ubus);
  const bus = new Bus<PollerEvents>();
  const ctx = {
    profile: { id: 'p', name: 'Home', url: 'https://192.168.1.1', username },
    pkg: { version: '0.2.0-r1', api: 1 },
    ubus, xvpn, uci: new UciApi(ubus), poller: new StatusPoller(xvpn, bus), bus,
  } as unknown as AppContext;
  return { ctx, r };
}

describe('diagnostics file', () => {
  it('has every part and no secret', async () => {
    const { ctx } = context();
    const text = await collectDiagnostics(ctx, { app: '0.1.0', now: new Date('2026-10-31T10:00:00Z') });
    for (const part of ['system', 'status', 'firewall', 'subscriptions', 'split', 'access points', 'config xvpn', 'log'])
      expect(text).toContain(`===== ${part} =====`);
    expect(text).toContain('package: luci-app-xvpn 0.2.0-r1 (api 1)');
    expect(text).toContain('app: 0.1.0');
    expect(text).toContain('OpenWrt 24.10.4');
    expect(text).toContain('table inet xvpn');
    expect(text).toContain('https://check.example/ok');
    expect(text).toContain('xvpn: imported vless://***@vpn.example.net:443');
    for (const s of SECRETS)
      expect(text).not.toContain(s);
  });

  it('a part that fails says so; system board only for root', async () => {
    const { ctx, r } = context('xvpn');
    r.on('luci.xvpn.firewall', () => [3]);
    const text = await collectDiagnostics(ctx, { app: 'dev' });
    expect(text).toMatch(/===== firewall =====\nerror: /);
    expect(text).toMatch(/===== system =====\nskipped/);
    expect(r.calls.some((c) => c.object === 'system')).toBe(false);
    expect(text).toContain('===== log =====');
  });
});

describe('log filter', () => {
  const lines = [
    'Tue Oct 27 10:00:00 2026 user.notice xvpn: started',
    'Tue Oct 27 10:00:01 2026 daemon.err ucode[42]: Error: oops',
    'Tue Oct 27 10:00:02 2026 daemon.info xray[12]: accepted tcp:1.1.1.1:443',
    'Tue Oct 27 10:00:03 2026 daemon.warn xray[12]: dial failed',
  ];

  it('by source, errors and text or /regex/', () => {
    expect(filterLog(lines, { query: '', source: 'xvpn', errors: false })).toEqual(lines.slice(0, 2));
    expect(filterLog(lines, { query: '', source: 'xray', errors: false })).toEqual(lines.slice(2));
    expect(filterLog(lines, { query: '', source: '', errors: true })).toEqual([lines[1], lines[3]]);
    expect(filterLog(lines, { query: 'ACCEPTED', source: '', errors: false })).toEqual([lines[2]]);
    expect(filterLog(lines, { query: '/xray\\[\\d+\\]: d/', source: '', errors: false })).toEqual([lines[3]]);
    expect(() => matcher('/(/')).toThrow();
  });
});
