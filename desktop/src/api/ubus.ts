// JSON-RPC client of uhttpd /ubus: session login, the call itself and a new login when
// the session is gone (expired, or rpcd restarted with the router). uhttpd answers a
// call with a dead session as JSON-RPC -32002 "Access denied", the same as a call the
// ACL does not allow, and rpcd answers a call it does not allow with ubus status 6.
// So a denied call first asks whether the session is alive (session access): alive,
// the denial is the ACL (acl, the session and what it staged stay); dead, one new
// login and a second try. uci answers 6 for a config without rights: acl at once.
// A user without session access (an older luci-app-xvpn-remote) cannot tell the two
// apart: whether it may is checked once after login, and without it a denial while
// changes are staged is acl at once — a new login would lose them.
//
// rpcd keeps staged UCI changes and the pending confirm of apply in the session: a new
// login loses them. UciApi marks them (staged); after a new login with staged changes
// the next uci call other than get fails with session_lost instead of going on with
// nothing staged (an apply of nothing, a confirm the router no longer waits for).

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
  /** over a new connection (Transport RequestOptions.fresh) */
  fresh?: boolean;
}

/** marks a denied call that may be a dead session: retried once after a new login */
class Denied extends XvpnError {}

export class UbusClient {
  private sid: string | null = null;
  private loginPromise: Promise<string> | null = null;
  private seq = 0;
  /** the session has staged UCI changes or an apply waiting for confirm */
  private staged = false;
  /** a new login dropped them; reported by the next uci call */
  private lost = false;
  /** session access is allowed for this user; null: not known (the check failed) */
  private canAsk: boolean | null = null;
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
    if (this.sid && this.staged) {
      this.lost = true;
      this.staged = false;
    }
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
    this.canAsk = await this.mayAsk(sid);
    return sid;
  }

  /** whether this user may call session access: true, false, null when unknown */
  private async mayAsk(sid: string): Promise<boolean | null> {
    try {
      await this.callWith(sid, 'session', 'access', {}, {});
      return true;
    }
    catch (e) {
      return e instanceof Denied ? false : null;
    }
  }

  /** drops the session (and what it staged), the next call logs in */
  logout(): void {
    this.sid = null;
    this.staged = this.lost = false;
  }

  /** UciApi: the session holds staged changes (true) or nothing to lose any more */
  setStaged(staged: boolean): void {
    this.staged = staged;
    if (staged)
      this.lost = false;
  }

  get hasStaged(): boolean {
    return this.staged;
  }

  async call<T = Record<string, unknown>>(object: string, method: string, args: Record<string, unknown> = {}, opts: CallOptions = {}): Promise<T> {
    this.checkLost(object, method);
    const sid = this.sid ?? await this.login();
    let denied: Denied;
    try {
      return await this.callWith<T>(sid, object, method, args, opts);
    }
    catch (e) {
      if (!(e instanceof Denied))
        throw e;
      denied = e;
    }
    const acl = () => new XvpnError('acl', `access denied: ${object}.${method}`, denied.detail);
    // rpcd uci: no rights for this config
    if (object === 'uci' && denied.detail.ubusStatus === UBUS_PERMISSION_DENIED)
      throw acl();
    let fresh: string;
    if (this.sid && this.sid !== sid)
      fresh = this.sid; // another call logged in meanwhile
    else if (this.canAsk === false) {
      // no way to ask: keep what the session holds rather than log in on a guess
      if (this.staged)
        throw acl();
      fresh = await this.login();
    }
    else if (await this.alive(sid))
      throw acl();
    else
      fresh = await this.login();
    this.checkLost(object, method);
    try {
      return await this.callWith<T>(fresh, object, method, args, opts);
    }
    catch (e) {
      if (e instanceof Denied)
        throw acl();
      throw e;
    }
  }

  private checkLost(object: string, method: string): void {
    if (object === 'uci' && method !== 'get' && this.lost) {
      this.lost = false;
      throw new XvpnError('session_lost', 'the router session changed, staged changes are lost', { object, method });
    }
  }

  /** whether rpcd still knows the session; a transport error propagates */
  private async alive(sid: string): Promise<boolean> {
    try {
      await this.callWith(sid, 'session', 'access', {}, {});
      return true;
    }
    catch (e) {
      if (e instanceof Denied)
        return false;
      throw e;
    }
  }

  private async callWith<T>(sid: string, object: string, method: string, args: Record<string, unknown>, opts: CallOptions): Promise<T> {
    const r = await this.transport.request(this.body('call', [sid, object, method, args]), opts.timeoutMs ?? this.timeoutMs,
      opts.fresh ? { fresh: true } : undefined);
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
