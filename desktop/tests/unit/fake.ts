// A fake router behind the Transport interface: sessions that can expire, a password,
// luci.xvpn methods as functions, and transport failures on demand.

import { XvpnError } from '../../src/api/errors';
import { RequestOptions, RpcRequest, RpcResponse, Transport } from '../../src/api/transport';

type Method = (args: Record<string, unknown>) => [number, unknown?] | unknown;

export class FakeRouter implements Transport {
  password = 'secret';
  given = 'secret';
  sessions = new Set<string>();
  logins = 0;
  calls: { object: string; method: string; args: Record<string, unknown>; fresh?: boolean }[] = [];
  /** object.method → handler; [code, data] is a ubus answer, anything else is data */
  methods = new Map<string, Method>();
  /** object.method the ACL of the user does not allow */
  denied = new Set<string>();
  /** objects present but missing from methods answer status 3 */
  objects = new Set<string>(['luci.xvpn', 'uci', 'session']);
  /** the next requests fail with these transport errors */
  failures: XvpnError[] = [];
  /** uhttpd answers a dead session with -32002 like LuCI sees it; false: ubus status 6 */
  rpcDenied = true;
  private n = 0;

  constructor() {
    // rpcd: any live session may ask about itself
    this.methods.set('session.access', () => ({ access: true }));
  }

  on(name: string, fn: Method): this {
    this.methods.set(name, fn);
    return this;
  }

  expireSessions(): void {
    this.sessions.clear();
  }

  async login(): Promise<RpcResponse> {
    const f = this.failures.shift();
    if (f)
      throw f;
    this.logins++;
    if (this.given !== this.password)
      return { jsonrpc: '2.0', id: 0, result: [6] };
    const sid = `sid${++this.n}`.padEnd(32, '0');
    this.sessions.add(sid);
    return { jsonrpc: '2.0', id: 0, result: [0, { ubus_rpc_session: sid, timeout: 300 }] };
  }

  async request(body: RpcRequest, _timeoutMs?: number, opts?: RequestOptions): Promise<RpcResponse> {
    const f = this.failures.shift();
    if (f)
      throw f;
    if (body.method === 'list') {
      const pattern = body.params[0] as string;
      const res: Record<string, unknown> = {};
      for (const o of this.objects)
        if (pattern === '*' || pattern === o)
          res[o] = {};
      return { jsonrpc: '2.0', id: body.id, result: res };
    }
    const [sid, object, method, args] = body.params as [string, string, string, Record<string, unknown>];
    const name = `${object}.${method}`;
    this.calls.push({ object, method, args, ...(opts?.fresh ? { fresh: true } : {}) });
    if (!this.sessions.has(sid) || this.denied.has(name)) {
      if (this.rpcDenied)
        return { jsonrpc: '2.0', id: body.id, error: { code: -32002, message: 'Access denied' } };
      return { jsonrpc: '2.0', id: body.id, result: [6] };
    }
    if (!this.objects.has(object))
      return { jsonrpc: '2.0', id: body.id, error: { code: -32000, message: 'Object not found' } };
    const fn = this.methods.get(name);
    if (!fn)
      return { jsonrpc: '2.0', id: body.id, result: [3] };
    const r = fn(args);
    if (Array.isArray(r) && typeof r[0] === 'number')
      return { jsonrpc: '2.0', id: body.id, result: r };
    return { jsonrpc: '2.0', id: body.id, result: [0, r] };
  }
}

export const STATUS_UP = {
  enabled: true, time: 1000, running: true, state: 'connected', active: 'a', since: 900, fails: 0,
  testing: false, tests: 1, updating: false, passthrough: false, xray_restarts: 0, servers: [
    { id: 'a', name: 'A', proto: 'vless', address: '1.1.1.1', port: 443, latency: 40, quarantined: false, auto: true, limited: false },
  ],
};
