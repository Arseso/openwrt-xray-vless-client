// The tray: started once in main.ts, lives on connection.bus across profiles. Each poll
// (and each change of the connection) gives a new TrayModel, sent to Rust when it
// differs from the last; clicks in the menu come back as TrayAction.

import { invoke } from '@tauri-apps/api/core';
import { listen } from '@tauri-apps/api/event';
import { ServiceAction } from '../api/xvpn';
import { Connection } from '../core/connection';
import { onLangChange } from '../core/i18n';
import { errorText } from '../ui/errors';
import { TrayModel, trayModel } from './model';

/** what tray.rs emits as the event tray-action; open window, LuCI and quit stay in Rust */
export type TrayAction =
  | { action: 'select'; id: string }
  | { action: 'auto'; value: boolean }
  | { action: 'test' }
  | { action: 'service'; value: ServiceAction }
  /** the menu is being opened (Windows): a fresh status */
  | { action: 'refresh' };

export interface TrayBackend {
  update(model: TrayModel): Promise<void>;
  onAction(fn: (a: TrayAction) => void): () => void;
}

export const tauriTray: TrayBackend = {
  update: (model) => invoke('tray_update', { model }),
  onAction(fn) {
    const off = listen<TrayAction>('tray-action', (e) => fn(e.payload));
    return () => void off.then((f) => f());
  },
};

/** an error of a menu action stays in the menu this long */
const ERROR_MS = 20_000;

export function startTray(conn: Connection, backend: TrayBackend = tauriTray, now = Date.now): () => void {
  let last = '';
  let error: { text: string; until: number } | null = null;

  const push = () => {
    const ctx = conn.context;
    if (error && now() > error.until)
      error = null;
    const model = trayModel(conn.state.get(), ctx?.poller.status ?? null, error?.text);
    const json = JSON.stringify(model);
    if (json === last)
      return;
    last = json;
    backend.update(model).catch((e) => console.error('tray_update', e));
  };

  const act = async (a: TrayAction) => {
    const ctx = conn.context;
    if (!ctx)
      return;
    try {
      const st = ctx.poller.status;
      let r: { ok: boolean; error?: string } | null = null;
      switch (a.action) {
      case 'select':
        r = await ctx.xvpn.select(a.id);
        break;
      case 'auto':
        if (st?.running && st.active)
          r = await ctx.xvpn.setAuto(st.active, a.value);
        break;
      case 'test':
        r = await ctx.xvpn.test();
        break;
      case 'service':
        r = await ctx.xvpn.service(a.value);
        break;
      case 'refresh':
        break;
      }
      if (r && !r.ok)
        error = { text: r.error ?? 'failed', until: now() + ERROR_MS };
    }
    catch (e) {
      error = { text: errorText(e), until: now() + ERROR_MS };
    }
    await ctx.poller.refresh();
    push();
  };

  const offs = [
    conn.bus.on('status', push),
    conn.bus.on('connection', push),
    onLangChange(push),
    backend.onAction((a) => void act(a)),
  ];
  push();
  return () => offs.forEach((off) => off());
}
