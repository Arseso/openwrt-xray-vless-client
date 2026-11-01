// Saving UCI changes of the xvpn config like LuCI does: stage them in the session, apply
// with rollback, check that the router still answers, then confirm. The check waits for
// the services to reload (holdoff, as apply_holdoff of LuCI) and needs two answers in a
// row over new connections: a kept-alive connection may outlive a firewall change that
// cuts off new ones. Without them in time, the app rolls back itself (or rpcd does after
// the timeout when the router stays unreachable) — the form is not reloaded before that.
// rpcd keeps the staged changes and the pending confirm in the session; a new login in
// between gives session_lost (api/ubus.ts). A rollback puts the reverted changes back
// into the session of the apply as staged ones (LuCI shows them as unsaved again): they
// are dropped, else uci get in this session would show the rolled-back values and the
// next apply would send them again.
//
// All views share one rpcd session (AppContext.uci): stage → apply → confirm and the
// revert of loadConfig() run one at a time (exclusive), or a revert could hit the middle
// of another save and an apply could carry the half of another form.

import { XvpnError, isXvpnError, toXvpnError } from '../api/errors';
import { UciApi, UciSection, UciValue } from '../api/uci';
import { XvpnApi } from '../api/xvpn';

export const CONFIG = 'xvpn';

/** a change of one section */
export interface Edit {
  section: string;
  /** section type, for add */
  type: string;
  /** add the section (a missing named section such as health, or a new subscription) */
  add?: boolean;
  /** delete the whole section */
  remove?: boolean;
  set?: Record<string, UciValue>;
  /** options to delete */
  unset?: string[];
}

export type ApplyResult = 'nothing' | 'applied' | 'rolled_back';

const locks = new WeakMap<object, Promise<unknown>>();
const running = new WeakSet<object>();

/** a save of this session is under way (a loadConfig does not count) */
export function saving(uci: UciApi): boolean {
  return running.has(uci.ubus);
}

/** runs fn after the other UCI work of this session (keyed by its UbusClient); isSave: saving() is true meanwhile */
export function exclusive<T>(uci: UciApi, fn: () => Promise<T>, isSave = true): Promise<T> {
  const key = uci.ubus;
  const prev = locks.get(key) ?? Promise.resolve();
  const next = prev.catch(() => {}).then(async () => {
    if (isSave)
      running.add(key);
    try {
      return await fn();
    }
    finally {
      if (isSave)
        running.delete(key);
    }
  });
  locks.set(key, next);
  return next;
}

export interface ApplyOptions {
  /** the rollback timer of rpcd, s */
  timeout?: number;
  /** pause after apply before the first check, ms (services reload; LuCI apply_holdoff 4 s) */
  holdoffMs?: number;
  /** pause between checks, ms */
  intervalMs?: number;
  /** after the confirm time ran out: how long to try the rollback beyond the timeout, s */
  graceS?: number;
  /** after apply, while the router is being checked */
  onWaiting?: () => void;
}

// rpcd uci confirm without a pending apply: UBUS_STATUS_NO_DATA
const UBUS_NO_DATA = 5;

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

export function isEmpty(e: Edit): boolean {
  return !e.add && !e.remove && !Object.keys(e.set ?? {}).length && !(e.unset ?? []).length;
}

/** stages the edits in the session; on a failure drops what was staged (where allowed) */
export async function stage(uci: UciApi, edits: Edit[]): Promise<void> {
  try {
    for (const e of edits) {
      if (e.remove) {
        await uci.delete(CONFIG, e.section);
        continue;
      }
      if (e.add)
        await uci.add(CONFIG, e.type, e.set ?? {}, e.section);
      else if (Object.keys(e.set ?? {}).length)
        await uci.set(CONFIG, e.section, e.set!);
      if (e.unset?.length)
        await uci.delete(CONFIG, e.section, e.unset);
    }
  }
  catch (e) {
    await revertQuietly(uci);
    throw e;
  }
}

/** the ACL of luci-base has no uci revert: then the staged changes stay until a new login */
async function revertQuietly(uci: UciApi): Promise<void> {
  try {
    await uci.revert(CONFIG);
  }
  catch {
    // nothing more to do
  }
}

/**
 * the config as the router has it, for a form: changes left staged in this session (put
 * back by a rollback, or of a save that failed halfway) are dropped first
 */
export function loadConfig(uci: UciApi): Promise<Record<string, UciSection>> {
  return exclusive(uci, () => readConfig(uci), false);
}

/** loadConfig inside exclusive() */
export async function readConfig(uci: UciApi): Promise<Record<string, UciSection>> {
  try {
    if ((await uci.changes(CONFIG)).length)
      await revertQuietly(uci);
  }
  catch {
    // changes not allowed: the values are read as they are
  }
  return uci.getAll(CONFIG);
}

function noData(e: unknown): boolean {
  return e instanceof XvpnError && e.code === 'ubus' && e.detail.ubusStatus === UBUS_NO_DATA;
}

/**
 * The confirm did not come in time: roll back now, so that the form reads the old values
 * and not those rpcd is about to revert. While the router does not answer, tried until
 * the rollback timer of rpcd has surely run out; then rpcd has reverted by itself and the
 * changes are staged in the session again (the next uci call or loadConfig drops them).
 */
async function rollBack(uci: UciApi, until: number, intervalMs: number): Promise<void> {
  for (;;) {
    try {
      await uci.rollback();
      break;
    }
    catch (e) {
      // status 5: rpcd has reverted already
      if (noData(e) || !toXvpnError(e).offline)
        break;
    }
    if (Date.now() >= until) {
      uci.ubus.setStaged(true);
      return;
    }
    await sleep(intervalMs);
  }
  await revertQuietly(uci);
}

/**
 * apply with rollback, then confirm once the router answers twice in a row over new
 * connections. rolled_back: no such answers before the confirm time ran out (the app
 * rolled back, or rpcd did) or rpcd had already reverted when confirm came.
 */
export async function applyStaged(uci: UciApi, xvpn: XvpnApi, opts: ApplyOptions = {}): Promise<ApplyResult> {
  const timeout = opts.timeout ?? 60;
  const interval = opts.intervalMs ?? 2000;
  if (!(await uci.changes(CONFIG)).length)
    return 'nothing';
  try {
    await uci.apply({ rollback: true, timeout });
  }
  catch (e) {
    // status 6 from apply: another session waits for its confirm (LuCI), or no rights
    if (isXvpnError(e, 'acl'))
      await revertQuietly(uci);
    throw e;
  }
  const start = Date.now();
  opts.onWaiting?.();
  // the confirm has to arrive before the timer of rpcd runs out
  const confirmBy = start + Math.max(1, timeout - 10) * 1000;
  const rollBackUntil = start + (timeout + (opts.graceS ?? 15)) * 1000;
  await sleep(opts.holdoffMs ?? 4000);
  let answers = 0;
  while (answers < 2) {
    if (Date.now() >= confirmBy) {
      await rollBack(uci, rollBackUntil, interval);
      return 'rolled_back';
    }
    try {
      await xvpn.version({ fresh: true, timeoutMs: 5000 });
      answers++;
    }
    catch {
      // no answer, or not the right one (http, bad_response ...): the check starts over
      answers = 0;
    }
    if (answers < 2)
      await sleep(interval);
  }
  try {
    await uci.confirm();
  }
  catch (e) {
    if (noData(e)) {
      await revertQuietly(uci);
      return 'rolled_back';
    }
    if (toXvpnError(e).offline) {
      await rollBack(uci, rollBackUntil, interval);
      return 'rolled_back';
    }
    throw e;
  }
  return 'applied';
}

/** stage + applyStaged one at a time per session; nothing to do: 'nothing' without a call */
export async function save(uci: UciApi, xvpn: XvpnApi, edits: Edit[], opts: ApplyOptions = {}): Promise<ApplyResult> {
  const todo = edits.filter((e) => !isEmpty(e));
  if (!todo.length)
    return 'nothing';
  return exclusive(uci, async () => {
    await stage(uci, todo);
    return applyStaged(uci, xvpn, opts);
  });
}
