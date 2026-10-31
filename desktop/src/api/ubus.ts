// JSON-RPC client of uhttpd /ubus: session login, the call itself and a new login when
// the session is gone (expired, or rpcd restarted with the router). uhttpd answers a
// call with a dead session as JSON-RPC -32002 "Access denied", the same as a call the
// ACL does not allow, and rpcd answers some calls with ubus status 6: both get one new
// login and a second try, still denied with a fresh session means no rights (acl).

import { XvpnError } from './errors';
import { RpcRequest, RpcResponse, Transport } from './transport';

export const ANON_SID = '00000000000000000000000000000000';

// ubus status codes (libubus UBUS_STATUS_*)
export const UBUS_OK = 0;
export const UBUS_INVALID_ARGUMENT = 2;
export const UBUS_METHOD_NOT_FOUND = 3;
export const UBUS_NOT_FOUND = 4;
export const UBUS_PERMISSION_DENIED = 6;
export const UBUS_TIMEOUT = 7;

// JSON-RPC errors of uhttpd-mod-ubus
const RPC_OBJECT_NOT_FOUND = -32000;
const RPC_SESSION_NOT_FOUND = -32001;
const RPC_ACCESS_DENIED = -32002;
const RPC_TIMEOUT = -32003;

export interface UbusOptions {
  /** default timeout of a call, ms */
  timeoutMs?: number;
}

export interface CallOptions {
  timeoutMs?: number;
}

/** marks a denied call that may be a dead session: retried once after a new login */
class Denied extends XvpnError {}

export class UbusClient {
  private sid: string | null = null;
  private loginPromise: Promise<string> | null = null;
  private seq = 0;
  readonly timeoutMs: number;

  constructor(private readonly transport: Transport, opts: UbusOptions = {}) {
    this.timeoutMs = opts.timeoutMs ?? 10_000;
  }

  get session(): string | null {
    return this.sid;
  }

  /** logs in again even with a live session; concurrent callers share one login */
  login(): Promise<string> {
    if (!this.loginPromise) {
      this.loginPromise = this.doLogin().finally(() => {
        this.loginPromise = null;
      });
    }
    return this.loginPromise;
  }

  private async doLogin(): Promise<string> {
    this.sid = null;
    const r = await this.transport.login(this.timeoutMs);
    if (r.error)
      throw rpcError(r.error, 'session', 'login');
    const [code, data] = result(r, 'session', 'login');
    if (code === UBUS_PERMISSION_DENIED)
      throw new XvpnError('wrong_password', 'wrong user name or password');
    if (code !== UBUS_OK)
      throw statusError(code, 'session', 'login');
    const sid = (data as { ubus_rpc_session?: unknown } | undefined)?.ubus_rpc_session;
    if (typeof sid !== 'string' || !sid)
      throw new XvpnError('bad_response', 'session login returned no session');
    this.sid = sid;
    return sid;
  }

  /** drops the session, the next call logs in */
  logout(): void {
    this.sid = null;
  }

  async call<T = Record<string, unknown>>(object: string, method: string, args: Record<string, unknown> = {}, opts: CallOptions = {}): Promise<T> {
    const sid = this.sid ?? await this.login();
    try {
      return await this.callWith<T>(sid, object, method, args, opts);
    }
    catch (e) {
      if (!(e instanceof Denied))
        throw e;
    }
    // another call may have logged in meanwhile: take its session
    const fresh = (this.sid && this.sid !== sid) ? this.sid : await this.login();
    try {
      return await this.callWith<T>(fresh, object, method, args, opts);
    }
    catch (e) {
      if (e instanceof Denied)
        throw new XvpnError('acl', `access denied: ${object}.${method}`, e.detail);
      throw e;
    }
  }

  private async callWith<T>(sid: string, object: string, method: string, args: Record<string, unknown>, opts: CallOptions): Promise<T> {
    const r = await this.transport.request(this.body('call', [sid, object, method, args]), opts.timeoutMs ?? this.timeoutMs);
    if (r.error) {
      if (r.error.code === RPC_ACCESS_DENIED || r.error.code === RPC_SESSION_NOT_FOUND)
        throw new Denied('acl', r.error.message, { rpcCode: r.error.code, object, method });
      throw rpcError(r.error, object, method);
    }
    const [code, data] = result(r, object, method);
    if (code === UBUS_PERMISSION_DENIED)
      throw new Denied('acl', 'permission denied', { ubusStatus: code, object, method });
    if (code !== UBUS_OK)
      throw statusError(code, object, method);
    return (data ?? {}) as T;
  }

  /**
   * ubus objects matching pattern (uhttpd "list" needs no session), e.g.
   * list('luci.xvpn') → { 'luci.xvpn': { status: {}, ... } } or {} without it
   */
  async list(pattern = '*'): Promise<Record<string, Record<string, unknown>>> {
    const r = await this.transport.request(this.body('list', [pattern]), this.timeoutMs);
    if (r.error) {
      if (r.error.code === RPC_OBJECT_NOT_FOUND)
        return {};
      throw rpcError(r.error, pattern, 'list');
    }
    if (!r.result || typeof r.result !== 'object' || Array.isArray(r.result))
      return {};
    return r.result as Record<string, Record<string, unknown>>;
  }

  private body(method: RpcRequest['method'], params: unknown[]): RpcRequest {
    return { jsonrpc: '2.0', id: ++this.seq, method, params };
  }
}

function result(r: RpcResponse, object: string, method: string): [number, unknown] {
  if (!Array.isArray(r.result) || typeof r.result[0] !== 'number')
    throw new XvpnError('bad_response', `${object}.${method}: not a ubus answer`, { object, method });
  return [r.result[0], r.result[1]];
}

function rpcError(err: { code: number; message: string }, object: string, method: string): XvpnError {
  const detail = { rpcCode: err.code, object, method };
  switch (err.code) {
  case RPC_OBJECT_NOT_FOUND:
    return new XvpnError('no_object', `${object}: ${err.message}`, detail);
  case RPC_TIMEOUT:
    return new XvpnError('timeout', `${object}.${method}: ${err.message}`, detail);
  case RPC_ACCESS_DENIED:
  case RPC_SESSION_NOT_FOUND:
    return new XvpnError('acl', `${object}.${method}: ${err.message}`, detail);
  default:
    return new XvpnError('ubus', `${object}.${method}: ${err.message}`, detail);
  }
}

function statusError(code: number, object: string, method: string): XvpnError {
  const detail = { ubusStatus: code, object, method };
  switch (code) {
  case UBUS_INVALID_ARGUMENT:
    return new XvpnError('invalid_argument', `${object}.${method}: invalid argument`, detail);
  case UBUS_METHOD_NOT_FOUND:
    return new XvpnError('no_method', `${object}.${method}: method not found`, detail);
  case UBUS_NOT_FOUND:
    return new XvpnError('no_object', `${object}: not found`, detail);
  case UBUS_TIMEOUT:
    return new XvpnError('timeout', `${object}.${method}: ubus timeout`, detail);
  default:
    return new XvpnError('ubus', `${object}.${method}: ubus status ${code}`, detail);
  }
}
