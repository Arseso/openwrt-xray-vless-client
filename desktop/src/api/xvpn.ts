// Typed calls of the rpcd object luci.xvpn (luci-app-xvpn/root/usr/share/rpcd/ucode/luci.xvpn).
// The types follow that plugin and the status of the daemon (usr/share/xvpn/xvpnd.uc,
// status()). ubus drops null values on the way, so a field that may be null in the
// code is optional here as well. Times are seconds of the router clock (time in the
// answers), not of the PC.

import { UbusClient } from './ubus';

export const OBJECT = 'luci.xvpn';

/** state of the daemon; error: a firewall, reload or config error (last_error says which) */
export type DaemonState =
  | 'starting'
  | 'connected'
  | 'degraded'
  | 'failover'
  | 'no_servers'
  | 'wan_down'
  | 'xray_down'
  | 'waiting_time'
  | 'error';

export interface DaemonServer {
  id: string;
  name: string;
  proto: string;
  address: string;
  port: number;
  /** subscription id; absent for a manual link */
  sub?: string | null;
  sub_name?: string | null;
  /** last HTTP ping, ms; absent when not tested or dead */
  latency?: number | null;
  /** when latency was measured */
  tested?: number | null;
  quarantined: boolean;
  /** takes part in auto selection */
  auto: boolean;
  /** passes health.url but not health.url2 (restricted access) */
  limited: boolean;
}

export interface LastSwitch {
  from?: string | null;
  to: string;
  reason: string;
  at: number;
}

interface StatusBase {
  /** xvpn.main.enabled */
  enabled: boolean;
  /** router clock */
  time: number;
}

/** the daemon does not answer: stopped (timeout false) or busy for 2 s (timeout true) */
export interface StatusDown extends StatusBase {
  running: false;
  timeout: boolean;
}

export interface StatusUp extends StatusBase {
  running: true;
  state: DaemonState;
  /** active server id */
  active?: string | null;
  /** the state holds since */
  since: number;
  fails: number;
  testing: boolean;
  /** test runs finished; test() returns the run to wait for */
  tests: number;
  updating: boolean;
  /** no live servers and kill switch off: clients go direct */
  passthrough: boolean;
  lists_updating?: boolean;
  last_error?: string | null;
  last_switch?: LastSwitch | null;
  last_test?: number | null;
  xray_restarts: number;
  url2?: string | null;
  servers: DaemonServer[];
  /** UDP through the active server works; absent: not checked */
  udp?: boolean | null;
  /** no live servers: the next test of all and the pause before it */
  retry?: { at: number; delay: number } | null;
}

export type Status = StatusUp | StatusDown;

export interface Server {
  id: string;
  name: string;
  proto: string;
  address: string;
  port: number;
  sub?: string | null;
  sub_name?: string | null;
  auto: boolean;
}

export interface ServersReply {
  servers: Server[];
  active?: string | null;
}

export interface UserInfo {
  upload?: number;
  download?: number;
  total?: number;
  /** unix time */
  expire?: number;
}

export interface Subscription {
  id: string;
  name: string;
  enabled: boolean;
  count: number;
  skipped?: number | null;
  format?: string | null;
  title?: string | null;
  updated?: number | null;
  last_ok?: number | null;
  last_attempt?: number | null;
  error?: string | null;
  userinfo?: UserInfo | null;
  via?: 'tunnel' | 'direct' | null;
  /** seconds to the next automatic update; absent when disabled */
  due_in?: number | null;
}

export interface SubscriptionsReply {
  subscriptions: Subscription[];
  /** absent when asked with updating: false */
  updating?: boolean;
  time: number;
}

export interface AccessPointsReply {
  networks: { name: string; proto?: string; device?: string }[];
  ports: { name: string; bridge: string }[];
  wifi: {
    section: string;
    ssid?: string;
    radio: string;
    band?: string;
    network?: string | string[];
    disabled: boolean;
    ifname?: string;
  }[];
  flow_offloading: boolean;
  flow_offloading_hw: boolean;
}

export interface StatsReply {
  /** bytes through each server since xray started */
  traffic: Record<string, { up: number; down: number }>;
  time: number;
}

export interface LogReply {
  /** the last lines of xvpn, xvpnd and xray in the system log */
  log?: string;
}

/** contents of the files in /var/run/xvpn, absent when there is none */
export interface FirewallReply {
  want?: string | null;
  mode?: string | null;
  error?: string | null;
  warning?: string | null;
}

export type ParsedLink =
  | { error: string }
  | { id: string; name: string; proto: string; address: string; port: number };

export interface ParseLinksReply {
  links?: ParsedLink[];
  error?: string;
}

export interface SplitReply {
  ru: boolean;
  cached?: { v4: number; v6: number } | null;
  last_ok?: number | null;
  last_attempt?: number | null;
  error?: string | null;
  via?: 'tunnel' | 'direct' | null;
  due_in?: number | null;
  /** absent without the daemon */
  updating?: boolean | null;
  time: number;
}

export interface OkReply {
  ok: boolean;
  /** busy, timeout, not running, unknown server, invalid ... */
  error?: string;
}

export interface TestReply extends OkReply {
  /** done once status().tests >= run */
  run?: number;
}

/** luci.xvpn version: PKG_VERSION-rPKG_RELEASE and the API generation of this plugin */
export interface VersionReply {
  version: string;
  api: number;
}

export type ServiceAction = 'start' | 'stop' | 'restart';

export class XvpnApi {
  constructor(readonly ubus: UbusClient) {}

  private call<T>(method: string, args?: Record<string, unknown>): Promise<T> {
    return this.ubus.call<T>(OBJECT, method, args);
  }

  version(): Promise<VersionReply> {
    return this.call('version');
  }

  status(): Promise<Status> {
    return this.call('status');
  }

  servers(): Promise<ServersReply> {
    return this.call('servers');
  }

  /** updating: false skips asking the daemon (take the flag from status) */
  subscriptions(opts: { updating?: boolean } = {}): Promise<SubscriptionsReply> {
    return this.call('subscriptions', opts.updating === undefined ? {} : { updating: opts.updating });
  }

  accessPoints(): Promise<AccessPointsReply> {
    return this.call('access_points');
  }

  stats(): Promise<StatsReply> {
    return this.call('stats');
  }

  log(): Promise<LogReply> {
    return this.call('log');
  }

  firewall(): Promise<FirewallReply> {
    return this.call('firewall');
  }

  /** up to 200 share links, checked by the backend parser */
  parseLinks(links: string[]): Promise<ParseLinksReply> {
    return this.call('parse_links', { links });
  }

  split(): Promise<SplitReply> {
    return this.call('split');
  }

  /** tests all servers; wait for status().tests >= run */
  test(): Promise<TestReply> {
    return this.call('test');
  }

  select(id: string): Promise<OkReply> {
    return this.call('select', { id });
  }

  setAuto(id: string, auto: boolean): Promise<OkReply> {
    return this.call('set_auto', { id, auto });
  }

  /** one subscription, or all without sid (rpcd rejects a null sid: it is left out) */
  update(sid?: string): Promise<OkReply> {
    return this.call('update', sid ? { sid } : {});
  }

  service(action: ServiceAction): Promise<OkReply> {
    return this.call('service', { action });
  }

  splitUpdate(): Promise<OkReply> {
    return this.call('split_update');
  }
}
