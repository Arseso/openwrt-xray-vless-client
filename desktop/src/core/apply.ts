// Saving UCI changes of the xvpn config like LuCI does: stage them in the session, apply
// with rollback, check that the router still answers, then confirm. If the PC cannot
// reach the router after the apply (a setting cut it off), no confirm comes and rpcd
// reverts the changes itself after the timeout. rpcd keeps the staged changes and the
// pending confirm in the session; a new login in between gives session_lost (api/ubus.ts).
// A rollback puts the reverted changes back into the session of the apply as staged ones
// (LuCI shows them as unsaved again): they are dropped, else uci get in this session would
// show the rolled-back values and the next apply would send them again.

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

export interface ApplyOptions {
  /** the rollback timer of rpcd, s */
  timeout?: number;
  /** pause after apply before the first check, ms (services reload) */
  holdoffMs?: number;
  /** pause between checks, ms */
  intervalMs?: number;
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
export async function loadConfig(uci: UciApi): Promise<Record<string, UciSection>> {
  try {
    if ((await uci.changes(CONFIG)).length)
      await revertQuietly(uci);
  }
  catch {
    // changes not allowed: the values are read as they are
  }
  return uci.getAll(CONFIG);
}

/**
 * apply with rollback, then confirm once the router answers. rolled_back: the router did
 * not answer in time (it reverts by itself) or had already reverted when confirm came.
 */
export async function applyStaged(uci: UciApi, xvpn: XvpnApi, opts: ApplyOptions = {}): Promise<ApplyResult> {
  const timeout = opts.timeout ?? 60;
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
  opts.onWaiting?.();
  // leave the confirm time to arrive before the timer runs out
  const deadline = Date.now() + Math.max(1, timeout - 10) * 1000;
  await sleep(opts.holdoffMs ?? 2000);
  for (;;) {
    try {
      await xvpn.version();
      break;
    }
    catch (e) {
      if (!toXvpnError(e).offline)
        throw e;
    }
    if (Date.now() >= deadline) {
      // the rollback will stage the changes again: the next uci call checks them
      uci.ubus.setStaged(true);
      return 'rolled_back';
    }
    await sleep(opts.intervalMs ?? 2000);
  }
  try {
    await uci.confirm();
  }
  catch (e) {
    if (e instanceof XvpnError && e.code === 'ubus' && e.detail.ubusStatus === UBUS_NO_DATA) {
      await revertQuietly(uci);
      return 'rolled_back';
    }
    throw e;
  }
  return 'applied';
}

/** stage + applyStaged; nothing to do: 'nothing' without a call */
export async function save(uci: UciApi, xvpn: XvpnApi, edits: Edit[], opts: ApplyOptions = {}): Promise<ApplyResult> {
  const todo = edits.filter((e) => !isEmpty(e));
  if (!todo.length)
    return 'nothing';
  await stage(uci, todo);
  return applyStaged(uci, xvpn, opts);
}
