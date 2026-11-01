// Package installs on the router through rpcd file write / file exec. The ACL of rpcd
// gives even root only the commands its groups list, not /bin/opkg itself, so there are
// two ways, both allowed to root only (an rpcd user of luci-app-xvpn-remote has neither:
// need_root):
//   helper  /usr/share/xvpn/pkg.sh of luci-app-xvpn (ACL group luci-app-xvpn-pkg, newer
//           than 0.2.0-r1): all files at once, --force-reinstall, opkg in the background — the
//           postinst of a LuCI package re-executes rpcd and rpcd kills an exec after 30 s,
//           so the app asks status until the job is done;
//   luci    /usr/libexec/package-manager-call of luci-app-package-manager (LuCI «Software»),
//           for an older luci-app-xvpn: one file at a time through /tmp/upload.ipk, the
//           answer comes when opkg ends (or not at all, when rpcd re-executes), no reinstall.

import { XvpnError, isXvpnError } from './errors';
import { UbusClient } from './ubus';

export const HELPER = '/usr/share/xvpn/pkg.sh';
export const PM = '/usr/libexec/package-manager-call';
export const PM_FILE = '/tmp/upload.ipk';
/** base64 characters per file write: uhttpd takes a request body up to 64 KiB */
export const CHUNK = 32 * 1024;

export type Method = 'helper' | 'luci';

/** where the helper takes a file from (its ACL: /tmp/xvpn-pkg-*.ipk) */
export function helperPath(name: string): string {
  return `/tmp/xvpn-pkg-${name}`;
}

export interface Job {
  state: 'idle' | 'running' | 'done' | 'lost';
  code?: number;
  output?: string;
}

interface ExecReply {
  code?: number;
  stdout?: string;
  stderr?: string;
}

export class RouterPackages {
  constructor(readonly ubus: UbusClient) {}

  private async may(scope: string, object: string, fn: string): Promise<boolean> {
    const r = await this.ubus.call<{ access?: boolean }>('session', 'access', { scope, object, function: fn });
    return r.access === true;
  }

  /** how this session may install, or need_root */
  async method(): Promise<Method> {
    try {
      if (await this.may('ubus', 'file', 'write') && await this.may('ubus', 'file', 'exec')) {
        const f = helperPath('a.ipk');
        if (await this.may('file', `${HELPER} install ${f}`, 'exec') && await this.may('file', f, 'write'))
          return 'helper';
        if (await this.may('file', `${PM} install ${PM_FILE}`, 'exec') && await this.may('file', PM_FILE, 'write'))
          return 'luci';
      }
    }
    catch (e) {
      // no session access at all: an rpcd user of an older package
      if (!isXvpnError(e, 'acl'))
        throw e;
    }
    throw new XvpnError('need_root', 'this session may not install packages');
  }

  private exec(command: string, params: string[], timeoutMs?: number): Promise<ExecReply> {
    return this.ubus.call<ExecReply>('file', 'exec', { command, params }, { timeoutMs });
  }

  /** the opkg status file: what is installed */
  async status(method: Method): Promise<string> {
    const r = method === 'helper' ? await this.exec(HELPER, ['list']) : await this.exec(PM, ['list-installed']);
    const out = r.stdout ?? '';
    // apk (OpenWrt 25) lists another format, and the release has ipk files only
    if (r.code !== 0 || (out.trim() && !/^Package: /m.test(out)))
      throw new XvpnError('pkg_unsupported', `the router lists no opkg packages: ${r.stderr ?? ''}`);
    return out;
  }

  /** writes base64 data to path in pieces; progress(bytes of base64 written) */
  async upload(path: string, data: string, progress?: (done: number) => void): Promise<void> {
    for (let i = 0; i < data.length || i === 0; i += CHUNK) {
      await this.ubus.call('file', 'write', { path, data: data.slice(i, i + CHUNK), base64: true, append: i > 0, mode: 0o600 });
      progress?.(Math.min(i + CHUNK, data.length));
    }
  }

  async remove(path: string): Promise<void> {
    try {
      await this.ubus.call('file', 'remove', { path });
    }
    catch {
      // gone already (the helper removes its files), or the router is away: /tmp is RAM
    }
  }

  /** helper: starts opkg install in the background */
  async start(paths: string[], reinstall: boolean): Promise<void> {
    const r = await this.exec(HELPER, ['install', ...(reinstall ? ['--force-reinstall'] : []), ...paths]);
    if (r.code === 0)
      return;
    const err = (r.stderr ?? '').trim();
    if (err.includes('is running'))
      throw new XvpnError('pkg_busy', err);
    if (err.includes('no opkg'))
      throw new XvpnError('pkg_unsupported', err);
    throw new XvpnError('pkg_failed', err, { output: err });
  }

  /** helper: the state of the last job */
  async job(): Promise<Job> {
    const r = await this.exec(HELPER, ['status']);
    try {
      const j = JSON.parse(r.stdout ?? '') as Job;
      if (typeof j?.state === 'string')
        return j;
    }
    catch {
      // below
    }
    throw new XvpnError('bad_response', `${HELPER} status: ${r.stdout ?? r.stderr ?? ''}`);
  }

  /** luci: opkg install of PM_FILE, the answer when it ends (none when rpcd re-executes) */
  async pmInstall(): Promise<void> {
    // rpcd kills an exec after 30 s (option timeout): no answer later than that
    const r = await this.exec(PM, ['install', PM_FILE], 40_000);
    let j: { code?: number; stdout?: string; stderr?: string } = {};
    try {
      j = JSON.parse(r.stdout ?? '{}');
    }
    catch {
      // not the JSON of package-manager-call: below with code
    }
    const code = j.code ?? r.code;
    if (code === 0)
      return;
    const output = [j.stdout, j.stderr, r.stderr].filter(Boolean).join('\n').trim();
    throw new XvpnError(code === 255 && output.includes('lock') ? 'pkg_busy' : 'pkg_failed', output, { output });
  }
}
