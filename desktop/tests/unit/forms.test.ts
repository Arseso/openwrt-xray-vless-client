// The checks of the form fields (src/forms/validate.ts) against what the router accepts
// (util.uc load_config, split.uc) and what the form writes to UCI (src/forms/diff.ts).

import { describe, expect, it } from 'vitest';
import { UciSection } from '../../src/api/uci';
import { changedSince, editsFor, uciBool } from '../../src/forms/diff';
import { nameFromUrl } from '../../src/views/subscriptions';
import {
  cidr, dnsServer, domain, eachLine, httpUrl, integer, ipv6, number, regex, required, secondUrl, shareLink,
  subscriptionUrl, timeoutShorter,
} from '../../src/forms/validate';

const ok = null;

describe('numbers', () => {
  it('reads decimal and 0x hex, only whole numbers', () => {
    expect(number('30')).toBe(30);
    expect(number(' 0x10 ')).toBe(16);
    expect(number('12abc')).toBeNaN();
    expect(number('1.5')).toBeNaN();
    expect(number('-1')).toBeNaN();
  });

  it('checks the range; empty is the default', () => {
    expect(integer('', 5, 3600)).toBe(ok);
    expect(integer('5', 5, 3600)).toBe(ok);
    expect(integer('4', 5, 3600)).toMatch(/5 to 3600/);
    expect(integer('3601', 5, 3600)).not.toBe(ok);
    expect(integer('ten', 5, 3600)).not.toBe(ok);
  });

  it('wants the timeout shorter than the interval, with the defaults for empty fields', () => {
    expect(timeoutShorter('5', '30')).toBe(ok);
    expect(timeoutShorter('', '')).toBe(ok);
    expect(timeoutShorter('30', '30')).not.toBe(ok);
    expect(timeoutShorter('40', '')).not.toBe(ok);
    expect(timeoutShorter('', '5')).not.toBe(ok);
  });
});

describe('check URLs', () => {
  it('takes http(s) only, as util.uc valid_url', () => {
    expect(httpUrl('https://www.gstatic.com/generate_204')).toBe(ok);
    expect(httpUrl('')).toBe(ok);
    expect(httpUrl('ftp://x')).not.toBe(ok);
    expect(httpUrl('https://')).not.toBe(ok);
    expect(httpUrl('https://a b')).not.toBe(ok);
    // an option of curl, not a URL
    expect(httpUrl('-o/etc/passwd')).not.toBe(ok);
    expect(httpUrl('off')).not.toBe(ok);
    expect(httpUrl('off', true)).toBe(ok);
  });

  it('wants url2 other than url, the defaults counted', () => {
    expect(secondUrl('', '')).toBe(ok);
    expect(secondUrl('off', 'https://cp.cloudflare.com/generate_204')).toBe(ok);
    expect(secondUrl('https://a.example/x', 'https://a.example/x')).not.toBe(ok);
    // empty url2 is the cloudflare default
    expect(secondUrl('', 'https://cp.cloudflare.com/generate_204')).not.toBe(ok);
    expect(secondUrl('https://www.gstatic.com/generate_204', '')).not.toBe(ok);
  });
});

describe('DNS server', () => {
  it('takes what dns_server() keeps: IP, host, https:// and tcp://', () => {
    for (const v of ['', '1.1.1.1', '2606:4700::1111', 'dns.example', 'https://cloudflare-dns.com/dns-query', 'tcp://1.1.1.1:53'])
      expect(dnsServer(v), v).toBe(ok);
  });

  it('rejects what the router would replace by the default', () => {
    for (const v of ['https+local://1.1.1.1/dns-query', 'quic+local://dns.adguard.com', 'HTTPS://dns.google/dns-query', 'udp://1.1.1.1',
      '256.1.1.1', '1::2::3', 'bad host', '-x'])
      expect(dnsServer(v), v).not.toBe(ok);
  });

  it('ipv6 as split.uc', () => {
    expect(ipv6('::')).toBe(true);
    expect(ipv6('2001:db8::1')).toBe(true);
    expect(ipv6('::ffff:1.2.3.4')).toBe(true);
    expect(ipv6('1:2:3:4:5:6:7:8')).toBe(true);
    expect(ipv6('1:2:3:4:5:6:7')).toBe(false);
    expect(ipv6('1:2:3:4:5:6:7:8:9')).toBe(false);
    expect(ipv6('12345::')).toBe(false);
  });
});

describe('split tunneling', () => {
  it('addresses and networks', () => {
    for (const v of ['203.0.113.0/24', '10.0.0.1', '2001:db8::/32', '::1/128'])
      expect(cidr(v), v).toBe(ok);
    for (const v of ['10.0.0.0/33', '10.0.0.0/0', '2001:db8::/129', 'example.com', '1.2.3', '10.0.0.0/'])
      expect(cidr(v), v).not.toBe(ok);
  });

  it('domains with the prefixes of xray', () => {
    for (const v of ['example.ru', 'ru', 'full:www.example.ru', 'domain:example.ru', '*.example.ru', '.example.ru', 'xn--p1ai'])
      expect(domain(v), v).toBe(ok);
    for (const v of ['пример.рф', 'a..b', '-a.ru', 'regexp:.*', 'a_b.ru'])
      expect(domain(v), v).not.toBe(ok);
  });

  it('names the first bad line', () => {
    expect(eachLine('10.0.0.0/8\n\n  1.2.3.4  \n', cidr)).toBe(ok);
    expect(eachLine('10.0.0.0/8\n\nnope', cidr)).toMatch(/^Line 3: /);
  });
});

describe('subscriptions', () => {
  it('URL of a subscription', () => {
    expect(subscriptionUrl('https://sub.example/api/sub/abc')).toBe(ok);
    expect(subscriptionUrl('')).not.toBe(ok);
    expect(subscriptionUrl('sub.example/x')).not.toBe(ok);
    expect(subscriptionUrl(`https://x.example/${'a'.repeat(2048)}`)).toMatch(/longer than 2048/);
  });

  it('name, regular expressions, share links', () => {
    expect(required('  ')).not.toBe(ok);
    expect(required('My VPN')).toBe(ok);
    expect(regex('')).toBe(ok);
    expect(regex('^(NL|DE)')).toBe(ok);
    expect(regex('(')).toMatch(/Invalid regular expression/);
    // POSIX ERE of ucode regexp(): the router would drop these filters silently
    for (const v of ['^(?!.*RU)', 'a.*?b', 'x+?', '\\d+', 'NL\\b', '\\w', '(a)\\1', '(?<=x)y'])
      expect(regex(v), v).toMatch(/POSIX/);
    for (const v of ['^(NL|DE)', '[0-9]+', 'a(b)?c', '[[:alnum:]_]+', '\\.ru$', '[(?]', 'x{2,3}', '\\*?', 'a|b'])
      expect(regex(v), v).toBe(ok);
    expect(nameFromUrl('https://TOKEN@panel.example.com:8443/sub/abc')).toBe('panel.example.com');
    expect(nameFromUrl('not a url')).toBe('');
    expect(shareLink('vless://uuid@host:443#x')).toBe(ok);
    expect(shareLink('VMESS://eyJ2IjoyfQ==')).toBe(ok);
    expect(shareLink('hysteria2://x@h:1')).not.toBe(ok);
    expect(shareLink('https://sub.example')).not.toBe(ok);
  });
});

const sec = (name: string, type: string, opts: Record<string, string | string[]>): UciSection =>
  ({ '.name': name, '.type': type, '.anonymous': false, ...opts });

describe('what a form writes', () => {
  const loaded = {
    health: sec('health', 'health', { url: 'https://a.example/x', interval: '30', auto_best: '0' }),
    access: sec('access', 'access', { network: ['lan'] }),
  };

  it('writes changed fields, deletes emptied ones, skips the rest', () => {
    const edits = editsFor(loaded, [
      { section: 'health', type: 'health', option: 'url', value: 'https://a.example/x' },
      { section: 'health', type: 'health', option: 'interval', value: '' },
      { section: 'health', type: 'health', option: 'timeout', value: '7' },
      { section: 'health', type: 'health', option: 'auto_best', value: '1', def: '0', flag: true },
      { section: 'access', type: 'access', option: 'network', value: ['lan'] },
      { section: 'access', type: 'access', option: 'port', value: [] },
    ]);
    expect(edits).toEqual([
      { section: 'health', type: 'health', add: false, set: { timeout: '7', auto_best: '1' }, unset: ['interval'] },
    ]);
  });

  it('a flag is read as util.uc bool(): an untouched one is never rewritten', () => {
    const s = { access: sec('access', 'access', { killswitch: 'yes', dns_hijack: 'on', ipv6: 'block', sniffing: '', bad: 'maybe' }) };
    const flag = (option: string, value: string, def: string) => ({ section: 'access', type: 'access', option, value, def, flag: true });
    // what the checkboxes show for them, saved untouched: nothing to write
    expect(editsFor(s, [flag('killswitch', '1', '1'), flag('dns_hijack', '1', '1'), flag('sniffing', '1', '1'),
      flag('bad', '0', '1'), flag('missing', '0', '0')])).toEqual([]);
    // turned off: '0'; turned on where the router reads false: '1'
    expect(editsFor(s, [flag('killswitch', '0', '1'), flag('bad', '1', '1')])).toEqual([
      { section: 'access', type: 'access', add: false, set: { killswitch: '0', bad: '1' }, unset: [] },
    ]);
    expect(uciBool('enabled', '0')).toBe(true);
    expect(uciBool('0', '1')).toBe(false);
    expect(uciBool(undefined, '1')).toBe(true);
    expect(uciBool('', '0')).toBe(false);
    expect(uciBool('no', '1')).toBe(false);
  });

  it('a flag left at its default is not written; a list changes as a whole', () => {
    const edits = editsFor(loaded, [
      { section: 'access', type: 'access', option: 'killswitch', value: '1', def: '1', flag: true },
      { section: 'access', type: 'access', option: 'dns_hijack', value: '0', def: '1', flag: true },
      { section: 'access', type: 'access', option: 'network', value: ['lan', 'guest'] },
    ]);
    expect(edits).toEqual([
      { section: 'access', type: 'access', add: false, set: { dns_hijack: '0', network: ['lan', 'guest'] }, unset: [] },
    ]);
  });

  it('adds a missing section with its type', () => {
    expect(editsFor({}, [
      { section: 'sub_0a0b0c0d', type: 'subscription', option: 'name', value: 'x' },
      { section: 'sub_0a0b0c0d', type: 'subscription', option: 'url', value: 'https://s.example/1' },
      { section: 'sub_0a0b0c0d', type: 'subscription', option: 'include', value: '' },
    ])).toEqual([
      { section: 'sub_0a0b0c0d', type: 'subscription', add: true, set: { name: 'x', url: 'https://s.example/1' }, unset: [] },
    ]);
  });

  it('notices a value changed on the router (in LuCI) since the form was loaded', () => {
    const edits = editsFor(loaded, [{ section: 'health', type: 'health', option: 'interval', value: '60' }]);
    expect(changedSince(loaded, loaded, edits)).toEqual([]);
    const now = { ...loaded, health: sec('health', 'health', { url: 'https://a.example/x', interval: '45', auto_best: '0' }) };
    expect(changedSince(loaded, now, edits)).toEqual(['health.interval']);
    // another option of the section does not matter
    const other = { ...loaded, health: sec('health', 'health', { url: 'https://b.example/', interval: '30', auto_best: '0' }) };
    expect(changedSince(loaded, other, edits)).toEqual([]);
    expect(changedSince(loaded, { access: loaded.access }, edits)).toEqual(['health']);
  });
});
