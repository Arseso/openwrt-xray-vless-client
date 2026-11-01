// What the tray shows for a connection state and the last status: a pure function, the
// Rust side (src-tauri/src/tray.rs) only puts it on the screen. Same field names there.
//
// The menu has a fixed shape: four info lines (state, server, ping, speed) always, so an
// open menu is never rebuilt under the mouse; only the server list changes its length.

import { Status, StatusUp } from '../api/xvpn';
import { ConnectionState } from '../core/connection';
import { t } from '../i18n/tray';
import { t as ts } from '../i18n/status';
import { ping, speed } from '../ui/format';

/** the icon files src-tauri/icons/tray/<icon>.png */
export type TrayIcon = 'connected' | 'failover' | 'wan_down' | 'xray_down' | 'offline' | 'stopped';

export interface TrayServer {
  id: string;
  label: string;
  active: boolean;
}

export interface TrayModel {
  icon: TrayIcon;
  /** hover text (Windows cuts it at 127 characters) */
  tooltip: string;
  /** the inactive lines at the top of the menu: always INFO_LINES of them */
  info: string[];
  /** the Server submenu; empty: disabled */
  servers: TrayServer[];
  /** Auto selection: the daemon chooses (true) or a server chosen by hand stays (false);
   * null: unknown (a package before #78) or no status */
  auto: boolean | null;
  /** connected with a fresh status: the actions are enabled */
  online: boolean;
  /** an action from the menu is running: the actions are disabled */
  busy: boolean;
  /** the profile whose LuCI Open LuCI opens; Rust builds the address itself */
  profileId: string | null;
  /** asked before Stop (kill switch on: the clients lose the internet); null: no question */
  confirmStop: string | null;
  labels: Record<'server' | 'auto' | 'test' | 'service' | 'start' | 'stop' | 'restart' | 'open' | 'luci' | 'quit', string>;
}

export interface TrayInput {
  conn: ConnectionState;
  status: Status | null;
  /** the last status is too old (polls fail): why, shown instead of it */
  stale?: string | null;
  /** the last action from the menu failed */
  error?: string | null;
  busy?: boolean;
  /** xvpn.access.killswitch; null: unknown (asked as if on) */
  killswitch?: boolean | null;
}

export const INFO_LINES = 4;
/** the menu would be too long for a subscription of a hundred servers */
export const MAX_SERVERS = 40;

export function trayIcon(conn: ConnectionState, status: Status | null, stale?: string | null): TrayIcon {
  if (conn.phase !== 'online' || !status || stale)
    return 'offline';
  if (!status.running)
    return !status.enabled ? 'stopped' : status.timeout ? 'failover' : 'xray_down';
  switch (status.state) {
  case 'connected':
    return status.passthrough ? 'xray_down' : 'connected';
  case 'wan_down':
    return 'wan_down';
  case 'xray_down':
  case 'no_servers':
  case 'error':
    return 'xray_down';
  default: // degraded, failover, starting, waiting_time
    return 'failover';
  }
}

/** chosen by the user (select): true / false, null with a package before #78 */
export function byHand(s: StatusUp): boolean | null {
  return typeof s.manual === 'boolean' ? s.manual : null;
}

function stateLine(i: TrayInput): string {
  const { conn, status } = i;
  if (conn.phase === 'offline' || (conn.phase === 'online' && i.stale))
    return t('router_down');
  if (conn.phase === 'connecting')
    return t('connecting');
  if (conn.phase !== 'online' || !status)
    return t('not_connected');
  if (!status.running)
    return !status.enabled ? t('stopped') : status.timeout ? t('daemon_busy') : t('daemon_down');
  return `${ts(`state.${status.state}`)} · ${status.state === 'xray_down' ? t('xray_down') : t('xray_ok')}`;
}

export function trayModel(i: TrayInput): TrayModel {
  const { conn, status } = i;
  const online = conn.phase === 'online' && !!status && !i.stale;
  const up = online && status?.running ? status : null;
  const active = up?.servers.find((s) => s.id === up.active) ?? null;
  const hand = up ? byHand(up) : null;

  let state = `● ${stateLine(i)}`;
  if (i.stale)
    state += ` · ${i.stale}`;
  if (i.error)
    state += ` · ⚠ ${i.error}`;
  const server = active
    ? t('server', { name: hand == null ? active.name : `${active.name} (${hand ? t('by_hand') : t('by_auto')})` })
    : t('server_none');
  const pingText = ping(active?.latency);
  const speedText = up?.speed ? t('speed', { down: speed(up.speed.down), up: speed(up.speed.up) }) : t('speed_none');
  const info = [state, server, t('ping', { ping: active ? pingText : '—' }), speedText];

  let tooltip = `xvpn · ${stateLine(i)}`;
  if (active)
    tooltip += `\n${active.name} · ${pingText}`;
  if (up?.speed)
    tooltip += `\n↓ ${speed(up.speed.down)}  ↑ ${speed(up.speed.up)}`;
  if (i.error)
    tooltip += `\n⚠ ${i.error}`;

  const all = up?.servers ?? [];
  const servers: TrayServer[] = all.slice(0, MAX_SERVERS).map((s) => ({
    id: s.id,
    active: s.id === up?.active,
    label: [s.name, ping(s.latency), s.quarantined ? t('quarantined') : null].filter(Boolean).join(' · '),
  }));
  // the active one is always there
  if (active && !servers.some((s) => s.active))
    servers.push({ id: active.id, active: true, label: `${active.name} · ${pingText}` });
  if (all.length > MAX_SERVERS)
    servers.push({ id: '', active: false, label: t('more', { n: all.length - MAX_SERVERS }) });

  return {
    icon: trayIcon(conn, status, i.stale),
    tooltip: tooltip.length > 120 ? `${tooltip.slice(0, 119)}…` : tooltip,
    info,
    servers,
    auto: up && hand != null ? !hand : null,
    online,
    busy: !!i.busy,
    profileId: conn.profile?.id ?? null,
    confirmStop: i.killswitch === false ? null : t('confirm_stop'),
    labels: {
      server: t('m_server'), auto: t('m_auto'), test: t('m_test'), service: t('m_service'),
      start: t('m_start'), stop: t('m_stop'), restart: t('m_restart'), open: t('m_open'), luci: t('m_luci'), quit: t('m_quit'),
    },
  };
}
