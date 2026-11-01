// Transport to uhttpd /ubus of one router profile. The HTTP(S) request, timeouts, the
// pinned certificate and the password live in Rust (src-tauri/src/transport.rs): the
// password never reaches the web view, login() asks Rust to send session login with it.
// Tests put a fake Transport in place of TauriTransport.

import { invoke } from '@tauri-apps/api/core';
import { ErrorCode, XvpnError } from './errors';

export interface RpcRequest {
  jsonrpc: '2.0';
  id: number;
  method: 'call' | 'list';
  params: unknown[];
}

export interface RpcResponse {
  jsonrpc?: '2.0';
  id?: number;
  /** call: [ubus status, data?]; list: { object: { method: signature } } */
  result?: unknown;
  error?: { code: number; message: string };
}

export interface RequestOptions {
  /** over a new connection, not a kept-alive one (the check after uci apply) */
  fresh?: boolean;
}

export interface Transport {
  /** one JSON-RPC request; rejects with XvpnError on transport failures only */
  request(body: RpcRequest, timeoutMs: number, opts?: RequestOptions): Promise<RpcResponse>;
  /** session login with the user and password of the profile; the answer as is */
  login(timeoutMs: number): Promise<RpcResponse>;
}

/** what a Rust command rejects with (TransportError in transport.rs) */
interface RustError {
  kind: ErrorCode;
  message: string;
  fingerprint?: string;
  pinned?: string;
  status?: number;
}

export function fromRustError(e: unknown): XvpnError {
  if (e && typeof e === 'object' && 'kind' in e) {
    const r = e as RustError;
    return new XvpnError(r.kind, r.message, { fingerprint: r.fingerprint, pinned: r.pinned, status: r.status });
  }
  return new XvpnError('ubus', String(e));
}

export async function invokeRust<T>(cmd: string, args?: Record<string, unknown>): Promise<T> {
  try {
    return await invoke<T>(cmd, args);
  }
  catch (e) {
    throw fromRustError(e);
  }
}

export class TauriTransport implements Transport {
  constructor(readonly profileId: string) {}

  request(body: RpcRequest, timeoutMs: number, opts: RequestOptions = {}): Promise<RpcResponse> {
    return invokeRust('ubus_request', { profileId: this.profileId, body, timeoutMs, fresh: opts.fresh ?? false });
  }

  login(timeoutMs: number): Promise<RpcResponse> {
    return invokeRust('ubus_login', { profileId: this.profileId, timeoutMs });
  }
}
