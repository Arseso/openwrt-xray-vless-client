// Package installs on the router through rpcd file write / file exec. The ACL of rpcd
// gives even root only the commands its groups list, not /bin/opkg itself, so there are
// two ways, both allowed to root only (an rpcd user of luci-app-xvpn-remote has neither:
// need_root):
//   helper  /usr/share/xvpn/pkg.sh of luci-app-xvpn (ACL group luci-app-xvpn-pkg, newer
//           than 0.2.0-r1): one job of all files, each checked against its sha256 there,
//           --force-reinstall, opkg in the background — the postinst of a LuCI package
//           re-executes rpcd and rpcd kills an exec after 30 s — so the app asks status
//           until its job (its id) is done; files /tmp/xvpn-pkg-<id>-<name>, one job at a time;
//   luci    /usr/libexec/package-manager-call of luci-app-package-manager (LuCI «Software»),
//           for an older luci-app-xvpn: one file at a time through /tmp/upload.ipk, the
//           answer comes when opkg ends (or not at all, when rpcd re-executes), no reinstall.
//           Its flock is /tmp/ipkg.lock (removed when it ends): the app waits for it to go.

import { XvpnError, isXvpnError } from './errors';
import { UbusClient } from './ubus';

export const HELPER = '/usr/share/xvpn/pkg.sh';
export const PM = '/usr/libexec/package-manager-call';
export const PM_FILE = '/tmp/upload.ipk';
const PM_LOCK = 'ipkg.lock';
const OPKG_INFO = '/usr/lib/opkg/info';
/** base64 characters per file write: uhttpd takes a request body up to 64 KiB */
export const CHUNK = 32 * 1024;

export type Method = 'helper' | 'luci';

/** where the helper takes a file of job id from (its ACL: /tmp/xvpn-pkg-*.ipk) */
export function helperPath(id: string, name: string): string {
  return `/tmp/xvpn-pkg-${id}-${name}`;
}

/** a job id: hex, unique enough that two PCs never share one */
export function jobId(): string {
  const b = new Uint8Array(8);
  crypto.getRandomValues(b);
  return [...b].map((x) => x.toString(16).padStart(2, '0')).join('');
}

export interface Job {
  /** absent with idle */
  id?: string;
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
        const f = helperPath('0', 'a.ipk');
        if (await this.may('file', `${HELPER} install 0 ${f} 0`, 'exec') && await this.may('file', f, 'write'))
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

  /** helper: the opkg status blocks of luci-app-xvpn and the translations */
  async list(): Promise<string> {
    const r = await this.exec(HELPER, ['list']);
    if (r.code !== 0)
      throw new XvpnError('pkg_unsupported', `${HELPER} list: ${r.stderr ?? ''}`);
    return r.stdout ?? '';
  }

  /**
   * luci: the names of the installed packages (the control files opkg keeps; listing is
   * allowed by luci-base). The status file itself is not readable there, and
   * package-manager-call would pass all of it, more than the output rpcd forwards.
   */
  async names(): Promise<string[]> {
    const r = await this.ubus.call<{ entries?: { name: string }[] }>('file', 'list', { path: OPKG_INFO });
    const names = (r.entries ?? []).map((e) => e.name).filter((n) => n.endsWith('.control')).map((n) => n.slice(0, -8));
    if (!names.length)
      throw new XvpnError('pkg_unsupported', `no packages in ${OPKG_INFO}`);
    return names;
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

  /** helper: starts job id: opkg install of files [path, sha256] in the background */
  async start(id: string, files: [string, string][], reinstall: boolean): Promise<void> {
    const r = await this.exec(HELPER, ['install', id, ...(reinstall ? ['--force-reinstall'] : []), ...files.flat()]);
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

  /** luci: an install of package-manager-call is running (its lock file is there) */
  async pmBusy(): Promise<boolean> {
    const r = await this.ubus.call<{ entries?: { name: string }[] }>('file', 'list', { path: '/tmp' });
    return (r.entries ?? []).some((e) => e.name === PM_LOCK);
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
