// The tray: started once in main.ts, lives on connection.bus across profiles. Each poll
// (and each change of the connection) gives a new TrayModel, sent to Rust when it
// differs from the last; clicks in the menu come back as TrayAction.

import { invoke } from '@tauri-apps/api/core';
import { listen } from '@tauri-apps/api/event';
import { ServiceAction } from '../api/xvpn';
import { AppContext, Connection } from '../core/connection';
import { onLangChange } from '../core/i18n';
import { t } from '../i18n/tray';
import { errorText } from '../ui/errors';
import { notice } from '../ui/notice';
import { TrayModel, trayModel } from './model';

/** what tray.rs emits as the event tray-action; open window, LuCI and quit stay in Rust */
export type TrayAction =
  | { action: 'select'; id: string }
  /** true: back to auto selection; false: keep the active server (chosen by hand) */
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

/** the error of an action the user just clicked: a system notification (notify_show of
 * #80, not filtered by quiet hours: the user is right there) and a line in the window */
export function notifyError(text: string): void {
  notice('error', text);
  invoke('notify_show', { title: 'xvpn', body: text }).catch((e) => console.error('notify_show', e));
}

/** polls failing this many intervals in a row: the last status is not shown as current */
export const STALE_INTERVALS = 3;

export interface TrayOptions {
  now?: () => number;
  /** where the error of a menu action goes besides the menu (notifyError by default) */
  onError?: (text: string) => void;
}

export function startTray(conn: Connection, backend: TrayBackend = tauriTray, opts: TrayOptions = {}): () => void {
  const now = opts.now ?? Date.now;
  const onError = opts.onError ?? notifyError;
  let last = '';
  let error: string | null = null;
  let busy = false;
  let lastOk = now();
  let pollError: string | null = null;
  let killswitch: boolean | null = null;
  let ksFor: AppContext | null = null;

  const stale = (ctx: AppContext | null) => {
    if (!ctx || !pollError)
      return null;
    return now() - lastOk > STALE_INTERVALS * ctx.poller.interval ? pollError : null;
  };

  const push = () => {
    const ctx = conn.context;
    if (ctx && ksFor !== ctx) {
      // asked once per connection: Stop from the tray asks for confirmation unless it is off
      ksFor = ctx;
      killswitch = null;
      void ctx.uci.get('xvpn', 'access', 'killswitch').then((v) => {
        if (conn.context === ctx) {
          killswitch = v == null || ['1', 'true', 'yes', 'on'].includes(String(v));
          push();
        }
      }, () => {});
    }
    const model = trayModel({ conn: conn.state.get(), status: ctx?.poller.status ?? null, stale: stale(ctx), error, busy, killswitch });
    const json = JSON.stringify(model);
    if (json === last)
      return;
    last = json;
    backend.update(model).catch((e) => console.error('tray_update', e));
  };

  const run = async (ctx: AppContext, a: TrayAction): Promise<{ ok: boolean; error?: string } | null> => {
    const st = ctx.poller.status;
    switch (a.action) {
    case 'select':
      return ctx.xvpn.select(a.id);
    case 'auto':
      if (a.value)
        return ctx.xvpn.auto();
      // manual: the active server stays, chosen by hand
      if (!st?.running || !st.active)
        return { ok: false, error: t('no_active') };
      return ctx.xvpn.select(st.active);
    case 'test':
      return ctx.xvpn.test();
    case 'service':
      return ctx.xvpn.service(a.value);
    case 'refresh':
      return null;
    }
  };

  const act = async (a: TrayAction) => {
    const ctx = conn.context;
    // one action at a time: a double click is not two restarts
    if (!ctx || (busy && a.action !== 'refresh'))
      return;
    if (a.action !== 'refresh') {
      busy = true;
      error = null;
      push();
    }
    try {
      const r = await run(ctx, a);
      if (r && !r.ok)
        error = r.error ?? 'failed';
    }
    catch (e) {
      error = errorText(e);
    }
    if (a.action !== 'refresh')
      busy = false;
    // the profile changed meanwhile: its poller is not ours to refresh
    if (conn.context !== ctx) {
      error = null;
      push();
      return;
    }
    if (error)
      onError(error);
    await ctx.poller.refresh();
    push();
  };

  const offs = [
    conn.bus.on('status', ({ at }) => {
      lastOk = at;
      pollError = null;
      push();
    }),
    conn.bus.on('poll-error', ({ error: e }) => {
      pollError = errorText(e);
      push();
    }),
    conn.bus.on('connection', (st) => {
      if (st.phase !== 'online')
        error = null;
      lastOk = now();
      pollError = null;
      push();
    }),
    onLangChange(push),
    backend.onAction((a) => void act(a)),
  ];
  push();
  return () => offs.forEach((off) => off());
}
