// Transport over Node fetch for running the client against a router without Tauri
// (HTTP only: the certificate pin is Rust's and has its own cargo tests).

import { XvpnError } from '../../src/api/errors';
import { RpcRequest, RpcResponse, Transport } from '../../src/api/transport';
import { ANON_SID } from '../../src/api/ubus';

export class NodeTransport implements Transport {
  constructor(readonly url: string, readonly username: string, public password: string) {}

  async request(body: RpcRequest, timeoutMs: number): Promise<RpcResponse> {
    let res: Response;
    try {
      res = await fetch(`${this.url}/ubus`, {
        method: 'POST', body: JSON.stringify(body), headers: { 'content-type': 'application/json' },
        signal: AbortSignal.timeout(timeoutMs), redirect: 'manual',
      });
    }
    catch (e) {
      const name = (e as Error).name;
      throw new XvpnError(name === 'TimeoutError' ? 'timeout' : 'unreachable', String(e));
    }
    if (res.status !== 200)
      throw new XvpnError('http', `HTTP ${res.status}`, { status: res.status });
    try {
      return await res.json() as RpcResponse;
    }
    catch (e) {
      throw new XvpnError('bad_response', String(e));
    }
  }

  login(timeoutMs: number): Promise<RpcResponse> {
    return this.request({
      jsonrpc: '2.0', id: 0, method: 'call',
      params: [ANON_SID, 'session', 'login', { username: this.username, password: this.password }],
    }, timeoutMs);
  }
}
