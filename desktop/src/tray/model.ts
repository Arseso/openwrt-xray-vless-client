// What the tray shows for a connection state and the last status: a pure function, the
// Rust side (src-tauri/src/tray.rs) only puts it on the screen. Same field names there.

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
  /** inactive lines at the top of the menu */
  info: string[];
  /** the Server submenu; empty: disabled */
  servers: TrayServer[];
  /** the active server takes part in auto selection; null: no active server */
  auto: boolean | null;
  /** connected: the actions are enabled */
  online: boolean;
  /** LuCI of the router, Open LuCI */
  luciUrl: string | null;
  labels: Record<'server' | 'auto' | 'test' | 'service' | 'start' | 'stop' | 'restart' | 'open' | 'luci' | 'quit', string>;
}

/** the menu would be too long for a subscription of a hundred servers */
export const MAX_SERVERS = 40;

export function trayIcon(conn: ConnectionState, status: Status | null): TrayIcon {
  if (conn.phase !== 'online' || !status)
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

/** chosen by the user (select) rather than by the daemon */
export function byHand(s: StatusUp): boolean {
  const sw = s.last_switch;
  return !!sw && sw.to === s.active && /manual|by hand/.test(sw.reason);
}

function stateLine(conn: ConnectionState, status: Status | null): string {
  if (conn.phase === 'offline')
    return t('router_down');
  if (conn.phase === 'connecting')
    return t('connecting');
  if (conn.phase !== 'online' || !status)
    return t('not_connected');
  if (!status.running)
    return !status.enabled ? t('stopped') : status.timeout ? t('daemon_busy') : t('daemon_down');
  return `${ts(`state.${status.state}`)} · ${status.state === 'xray_down' ? t('xray_down') : t('xray_ok')}`;
}

export function trayModel(conn: ConnectionState, status: Status | null, error?: string | null): TrayModel {
  const online = conn.phase === 'online' && !!status;
  const up = online && status?.running ? status : null;
  const active = up?.servers.find((s) => s.id === up.active) ?? null;
  const info = [`● ${stateLine(conn, status)}`];
  let tooltip = `xvpn · ${stateLine(conn, status)}`;
  if (up) {
    info.push(active ? t('server', { name: `${active.name} (${byHand(up) ? t('by_hand') : t('by_auto')})` }) : t('server_none'));
    const pingText = ping(active?.latency);
    info.push(t('ping', { ping: pingText }));
    if (active)
      tooltip += `\n${active.name} · ${pingText}`;
    if (up.speed) {
      const line = t('speed', { down: speed(up.speed.down), up: speed(up.speed.up) });
      info.push(line);
      tooltip += `\n↓ ${speed(up.speed.down)}  ↑ ${speed(up.speed.up)}`;
    }
  }
  if (error)
    info.push(t('error', { error }));
  const all = up?.servers ?? [];
  const servers: TrayServer[] = all.slice(0, MAX_SERVERS).map((s) => ({
    id: s.id,
    active: s.id === up?.active,
    label: [s.name, ping(s.latency), s.quarantined ? t('quarantined') : null].filter(Boolean).join(' · '),
  }));
  // the active one is always there
  if (active && !servers.some((s) => s.active))
    servers.push({ id: active.id, active: true, label: `${active.name} · ${ping(active.latency)}` });
  if (all.length > MAX_SERVERS)
    servers.push({ id: '', active: false, label: t('more', { n: all.length - MAX_SERVERS }) });
  return {
    icon: trayIcon(conn, status),
    tooltip: tooltip.length > 120 ? `${tooltip.slice(0, 119)}…` : tooltip,
    info,
    servers,
    auto: active ? active.auto : null,
    online,
    luciUrl: conn.profile ? `${conn.profile.url}/cgi-bin/luci/admin/services/xvpn` : null,
    labels: {
      server: t('m_server'), auto: t('m_auto'), test: t('m_test'), service: t('m_service'),
      start: t('m_start'), stop: t('m_stop'), restart: t('m_restart'), open: t('m_open'), luci: t('m_luci'), quit: t('m_quit'),
    },
  };
}
