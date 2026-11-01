// Checks of the form fields: the same as the LuCI views (settings.js, access.js, split.js,
// subscriptions.js) and what util.uc load_config() / split.uc accept. The router replaces
// a bad value by the default and only logs it, so the app rejects it before saving.
// A check returns null or the message (src/i18n/forms.ts); an empty field is the default
// and always passes.

import { t } from '../i18n/forms';

export type Check = string | null;

/** the defaults of util.uc load_config(): an empty field means the default */
export const DEFAULTS = {
  url: 'https://www.gstatic.com/generate_204',
  url2: 'https://cp.cloudflare.com/generate_204',
  dl_url: 'https://speed.cloudflare.com/__down?bytes=65536',
  interval: '30',
  timeout: '5',
  fail_threshold: '3',
  rank_interval: '600',
  hysteresis: '150',
  auto_mode: 'ping',
  speedtest_url: 'https://proof.ovh.net/files/10Mb.dat',
  speedtest_interval: '21600',
  speed_hysteresis: '20',
  quarantine: '300',
  concurrency: '4',
  dns_server: 'https://cloudflare-dns.com/dns-query',
  loglevel: 'warning',
  ru_interval: '168',
  user_agent: 'v2rayN/7.0',
} as const;

export const URL_MAX = 2048;
export const SHARE_LINK = /^(vless|vmess|trojan|ss):\/\/\S+$/i;
const HTTP_URL = /^https?:\/\/[^\s/?#]+\S*$/i;

/** load_config() reads hex after 0x, else decimal; the UI takes only whole numbers */
export function number(v: string | null | undefined): number {
  const s = String(v ?? '').trim();
  return /^0x[0-9a-f]+$/i.test(s) ? parseInt(s, 16) : /^\d+$/.test(s) ? parseInt(s, 10) : NaN;
}

export function integer(v: string, min: number, max: number): Check {
  if (!v.trim())
    return null;
  const n = number(v);
  return Number.isNaN(n) || n < min || n > max ? t('integer', { min, max }) : null;
}

export function httpUrl(v: string, off = false): Check {
  const s = v.trim();
  if (!s || (off && s === 'off'))
    return null;
  // index() in util.uc valid_url: no line breaks
  return HTTP_URL.test(s) && !/\n/.test(s) ? null : t(off ? 'url_or_off' : 'url');
}

/** url2 must differ from url: the same URL would make the check say nothing */
export function secondUrl(url2: string, url: string): Check {
  const r = httpUrl(url2, true);
  if (r)
    return r;
  const a = url2.trim() || DEFAULTS.url2, b = url.trim() || DEFAULTS.url;
  return a === b ? t('url2_same') : null;
}

/** health.timeout shorter than health.interval (either may be empty: the default) */
export function timeoutShorter(timeout: string, interval: string): Check {
  const tm = number(timeout.trim() || DEFAULTS.timeout), iv = number(interval.trim() || DEFAULTS.interval);
  return Number.isNaN(tm) || Number.isNaN(iv) || tm < iv ? null : t('timeout_shorter');
}

const IPV4 = /^(25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)(\.(25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)){3}$/;
const LABEL = '[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?';
const DOMAIN = new RegExp(`^(${LABEL})(\\.${LABEL})*$`, 'i');

export function ipv6(a: string): boolean {
  if (!/^[0-9a-f:.]+$/i.test(a) || (a.match(/::/g) ?? []).length > 1)
    return false;
  const parts = a.split(':');
  let groups = 0;
  if (IPV4.test(parts[parts.length - 1])) {
    parts.pop();
    groups += 2;
  }
  for (const p of parts) {
    if (p !== '') {
      if (!/^[0-9a-f]{1,4}$/i.test(p))
        return false;
      groups++;
    }
  }
  return a.includes('::') ? groups < 8 : groups === 8;
}

/**
 * access.dns_server as util.uc dns_server() takes it: an IP or host name (port 53 through
 * the tunnel) or an https:// / tcp:// URL, the scheme in lower case; other schemes
 * (+local would query around the tunnel) it replaces by the default
 */
export function dnsServer(v: string): Check {
  const s = v.trim();
  if (!s)
    return null;
  if (/^(https|tcp):\/\/[^/\s]+\S*$/.test(s))
    return null;
  if (s.includes('://'))
    return t('dns_scheme');
  if (/^\d{1,3}(\.\d{1,3}){3}$/.test(s))
    return IPV4.test(s) ? null : t('ipv4');
  if (s.includes(':'))
    return ipv6(s) ? null : t('ipv6');
  return s.length <= 253 && DOMAIN.test(s) ? null : t('dns');
}

/** split.ip: split.uc cidr() */
export function cidr(v: string): Check {
  const m = /^([^/]+)(\/(\d{1,3}))?$/.exec(v.trim());
  if (m) {
    const v4 = IPV4.test(m[1]);
    if (v4 || ipv6(m[1])) {
      const n = m[3] != null ? +m[3] : 1;
      if (n >= 1 && n <= (v4 ? 32 : 128))
        return null;
    }
  }
  return t('cidr');
}

/** split.domain: split.uc domain_rule(); full:/domain: prefixes, a leading *. or . */
export function domain(v: string): Check {
  const d = v.trim().toLowerCase().replace(/^(full|domain):/, '').replace(/^\*?\./, '');
  return d.length <= 253 && DOMAIN.test(d) ? null : t('domain');
}

export function subscriptionUrl(v: string): Check {
  const s = v.trim();
  if (s.length > URL_MAX)
    return t('url_long', { max: URL_MAX });
  return HTTP_URL.test(s) ? null : t('url');
}

export function required(v: string): Check {
  return v.trim() ? null : t('required');
}

/**
 * include / exclude of a subscription: the router compiles them with ucode regexp(), POSIX
 * extended (ERE), and drops a filter it cannot compile without a word (subscription.uc).
 * So beside a valid JS RegExp: none of the Perl additions — (?…) groups and lookarounds,
 * lazy quantifiers, \d \w \s \b and the like, backreferences.
 */
export function regex(v: string): Check {
  if (!v)
    return null;
  try {
    new RegExp(v, 'i');
  }
  catch (e) {
    return t('regex', { message: (e as Error).message });
  }
  if (/\\[bBdDwWsSpPkK0-9]/.test(v))
    return t('regex_ere');
  // without escaped characters and bracket expressions, where ( ? * are literal
  const bare = v.replace(/\\./g, '').replace(/\[\^?\]?[^\]]*\]/g, '');
  return /\(\?|[*+?}]\?/.test(bare) ? t('regex_ere') : null;
}

/** one link per line: the scheme here, the rest by luci.xvpn parse_links */
export function shareLink(v: string): Check {
  return SHARE_LINK.test(v.trim()) ? null : t('link');
}

/** lines of a list field (manual links, split.ip, split.domain): trimmed, no empty ones */
export function lines(v: string): string[] {
  return v.split('\n').map((l) => l.trim()).filter((l) => l);
}

/** the first failing line as "Line N: message" */
export function eachLine(v: string, check: (line: string) => Check): Check {
  const all = v.split('\n');
  for (let i = 0; i < all.length; i++) {
    const l = all[i].trim();
    if (!l)
      continue;
    const r = check(l);
    if (r)
      return t('line', { n: i + 1, message: r });
  }
  return null;
}
