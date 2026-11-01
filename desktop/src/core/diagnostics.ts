// The diagnostics file of the Log tab: versions, status, firewall, subscriptions, split
// tunneling, access points, the xvpn config and the log in one text file to attach to an
// issue. Without secrets: share links (credentials of the servers) become scheme://***@host:port,
// URLs keep only scheme and host (the path or query of a subscription URL is its token),
// UUIDs are replaced. The check URLs of the health section are public and stay as they are.
// The app has no router password to leak: it stays in Rust (src-tauri/src/profiles.rs).

import { UciSection } from '../api/uci';
import { DEFAULTS } from '../forms/validate';
import { AppContext } from './connection';

const LINK = /\b(vless|vmess|trojan|ss|ssr|socks|hysteria2?|hy2|tuic|wireguard):\/\/[^\s"'<>]+/gi;
const URL_RE = /\bhttps?:\/\/[^\s"'<>]+/gi;
const UUID = /\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b/gi;
/** options that hold a secret whatever the section */
const SECRET_OPTION = /pass|secret|token|key|uuid/i;

/** scheme://, the authority (up to the first / ? #) and the rest; null: not scheme://… */
function split(url: string): { scheme: string; auth: string; rest: string } | null {
  const m = /^([a-z][a-z0-9+.-]*):\/\/([^/?#]*)(.*)$/is.exec(url.trim());
  return m ? { scheme: m[1], auth: m[2], rest: m[3] } : null;
}

/** the host:port of an authority: after its last @, as the parser of the router (links.uc) takes it */
function hostOf(auth: string): { host: string; userinfo: boolean } {
  const at = auth.lastIndexOf('@');
  return { host: auth.slice(at + 1), userinfo: at >= 0 };
}

/** scheme://***@host:port, or scheme://*** when the host is inside the encoded part (vmess, ss) */
export function maskLink(link: string): string {
  const u = split(link);
  if (!u)
    return '***';
  const { host, userinfo } = hostOf(u.auth);
  return userinfo && host ? `${u.scheme}://***@${host}` : `${u.scheme}://***`;
}

/** scheme://host/*** (no user info, path or query); a URL in keep stays as is */
export function maskUrl(url: string, keep: ReadonlySet<string> = new Set()): string {
  if (keep.has(url))
    return url;
  const u = split(url);
  if (!u)
    return '***';
  const { host } = hostOf(u.auth);
  return u.rest && u.rest !== '/' ? `${u.scheme}://${host}/***` : `${u.scheme}://${host}`;
}

export function maskText(text: string, keep: ReadonlySet<string> = new Set()): string {
  return text
    .replace(LINK, (l) => maskLink(l))
    .replace(URL_RE, (u) => {
      // the punctuation after a URL in a sentence is not a part of it
      const tail = /[).,;:!?]+$/.exec(u)?.[0] ?? '';
      const url = tail ? u.slice(0, -tail.length) : u;
      return maskUrl(url, keep) + tail;
    })
    .replace(UUID, '<uuid>');
}

/** strings anywhere in a value through maskText */
export function maskDeep<T>(v: T, keep: ReadonlySet<string>): T {
  if (typeof v === 'string')
    return maskText(v, keep) as T;
  if (Array.isArray(v))
    return v.map((x) => maskDeep(x, keep)) as T;
  if (v && typeof v === 'object')
    return Object.fromEntries(Object.entries(v).map(([k, x]) => [k, maskDeep(x, keep)])) as T;
  return v;
}

/** the public URLs of the config: the check URLs and their defaults */
export function publicUrls(sections: Record<string, UciSection>): Set<string> {
  const keep = new Set<string>([DEFAULTS.url, DEFAULTS.url2, DEFAULTS.dl_url]);
  const health = sections.health ?? {};
  for (const o of ['url', 'url2', 'dl_url', 'wan_url']) {
    const v = health[o];
    for (const u of Array.isArray(v) ? v : typeof v === 'string' ? [v] : [])
      keep.add(u.trim());
  }
  return keep;
}

/** the xvpn config without the secrets: subscription URLs, manual links, any password */
export function maskConfig(sections: Record<string, UciSection>, keep = publicUrls(sections)): Record<string, UciSection> {
  const out: Record<string, UciSection> = {};
  for (const [name, s] of Object.entries(sections)) {
    const c: UciSection = { ...s };
    for (const [o, v] of Object.entries(s)) {
      if (o.startsWith('.') || (typeof v !== 'string' && !Array.isArray(v)))
        continue;
      const each = (f: (x: string) => string) => (Array.isArray(v) ? v.map(f) : f(v));
      if (o === 'link')
        c[o] = each(maskLink);
      else if (s['.type'] === 'subscription' && o === 'url')
        c[o] = each((u) => maskUrl(u));
      else if (SECRET_OPTION.test(o))
        c[o] = each(() => '***');
      else
        c[o] = each((x) => maskText(x, keep));
    }
    out[name] = c;
  }
  return out;
}

export interface DiagnosticsInfo {
  app: string;
  /** PC time of the export */
  now?: Date;
}

async function part(title: string, fn: () => Promise<unknown>): Promise<string> {
  let body: string;
  try {
    const v = await fn();
    body = typeof v === 'string' ? v : JSON.stringify(v, null, 2);
  }
  catch (e) {
    body = `error: ${(e as Error).message ?? e}`;
  }
  return `===== ${title} =====\n${body.trimEnd()}\n`;
}

/** the whole file; every part is masked, a failing part says why instead */
export async function collectDiagnostics(ctx: AppContext, info: DiagnosticsInfo): Promise<string> {
  let config: Record<string, UciSection> = {};
  let configError: unknown = null;
  try {
    config = await ctx.uci.getAll('xvpn');
  }
  catch (e) {
    configError = e;
  }
  const keep = publicUrls(config);
  const masked = (fn: () => Promise<unknown>) => async () => maskDeep(await fn(), keep);

  const head = [
    'xvpn diagnostics',
    `generated: ${(info.now ?? new Date()).toISOString()}`,
    `app: ${info.app}`,
    `package: luci-app-xvpn ${ctx.pkg.version} (api ${ctx.pkg.api})`,
    `router: ${maskUrl(ctx.profile.url)}`,
    '',
  ].join('\n');
  const parts = await Promise.all([
    // system board: only root has it; for another user the denial would cost a new login
    // (and staged changes with it), the rpcd user of the app has no session access
    part('system', async () => {
      if (ctx.profile.username !== 'root' || ctx.ubus.hasStaged)
        return 'skipped';
      return ctx.ubus.call('system', 'board');
    }),
    part('status', masked(() => ctx.xvpn.status())),
    part('firewall', masked(() => ctx.xvpn.firewall())),
    part('subscriptions', masked(() => ctx.xvpn.subscriptions({ updating: false }))),
    part('split', masked(() => ctx.xvpn.split())),
    part('access points', masked(() => ctx.xvpn.accessPoints())),
    part('config xvpn', async () => {
      if (configError)
        throw configError;
      return maskConfig(config, keep);
    }),
    part('log', async () => maskText((await ctx.xvpn.log()).log ?? '', keep)),
  ]);
  return maskText(head, keep) + '\n' + parts.join('\n');
}
