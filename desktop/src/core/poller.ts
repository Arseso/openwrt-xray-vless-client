// Shared poller of luci.xvpn status: one request every intervalMs for the whole app
// (tabs, tray #78, notifications #80 listen to the bus instead of polling themselves).
// Requests never overlap: the next one is scheduled after the answer. After stop()
// nothing more reaches the bus, not even the answer of a request still on its way.
//
// Events (PollerEvents):
//   status        every answer
//   state-change  the first answer and each one where running, enabled, state, active
//                 or passthrough differ from the previous
//   poll-error    every failed poll
//   router-down   after downAfter failures in a row with the router not answering
//                 (unreachable/timeout), once until it answers again
//   router-up     the first answer after router-down

import { XvpnError, toXvpnError } from '../api/errors';
import { Status } from '../api/xvpn';
import { Emitter } from './bus';

export interface StateChange {
  prev: Status | null;
  next: Status;
}

export interface PollerEvents {
  status: { status: Status; at: number };
  'state-change': StateChange;
  'poll-error': { error: XvpnError; failures: number };
  'router-down': { error: XvpnError; since: number };
  'router-up': { downForMs: number };
}

export interface PollerOptions {
  intervalMs?: number;
  /** failures in a row before router-down; one failure may be a lost packet */
  downAfter?: number;
  now?: () => number;
}

export const DEFAULT_INTERVAL_MS = 3000;

export class StatusPoller {
  private timer: ReturnType<typeof setTimeout> | null = null;
  private running = false;
  private inFlight: Promise<void> | null = null;
  /** the poll refresh() asked for while one was running */
  private again: Promise<void> | null = null;
  /** bumped by stop(): a poll of an older epoch emits nothing */
  private epoch = 0;
  private failures = 0;
  private downSince: number | null = null;
  private last: Status | null = null;
  private intervalMs: number;
  private readonly downAfter: number;
  private readonly now: () => number;

  constructor(
    private readonly source: { status(): Promise<Status> },
    private readonly bus: Emitter<PollerEvents>,
    opts: PollerOptions = {},
  ) {
    this.intervalMs = opts.intervalMs ?? DEFAULT_INTERVAL_MS;
    this.downAfter = opts.downAfter ?? 2;
    this.now = opts.now ?? Date.now;
  }

  /** the last answer, null before the first */
  get status(): Status | null {
    return this.last;
  }

  get down(): boolean {
    return this.downSince !== null;
  }

  get interval(): number {
    return this.intervalMs;
  }

  start(): void {
    if (this.running)
      return;
    this.running = true;
    void this.tick();
  }

  /** a poll still running when stopped emits nothing (another profile may be on the bus) */
  stop(): void {
    this.running = false;
    this.epoch++;
    this.again = null;
    if (this.timer)
      clearTimeout(this.timer);
    this.timer = null;
  }

  setInterval(ms: number): void {
    this.intervalMs = ms;
    if (this.running && this.timer) {
      clearTimeout(this.timer);
      this.schedule();
    }
  }

  /**
   * polls now (after select, service...) and resolves with that poll. During a poll it
   * waits for it and polls once more; any number of such calls share that one poll.
   */
  refresh(): Promise<void> {
    // a stopped poller belongs to a profile left behind: nothing of it reaches the bus
    if (!this.running)
      return Promise.resolve();
    if (!this.inFlight) {
      if (this.timer)
        clearTimeout(this.timer);
      return this.tick();
    }
    if (!this.again) {
      const epoch = this.epoch;
      const again: Promise<void> = this.inFlight.then(() => {
        if (this.again === again)
          this.again = null;
        return epoch === this.epoch ? this.tick() : undefined;
      });
      this.again = again;
    }
    return this.again;
  }

  private schedule(): void {
    if (this.running)
      this.timer = setTimeout(() => void this.tick(), this.intervalMs);
  }

  private tick(): Promise<void> {
    this.timer = null;
    const p: Promise<void> = this.poll(this.epoch).finally(() => {
      if (this.inFlight === p)
        this.inFlight = null;
      // a refresh waiting for this poll starts the next one
      if (!this.timer && !this.again)
        this.schedule();
    });
    this.inFlight = p;
    return p;
  }

  private async poll(epoch: number): Promise<void> {
    let status: Status;
    try {
      status = await this.source.status();
    }
    catch (e) {
      if (epoch === this.epoch)
        this.failed(toXvpnError(e));
      return;
    }
    if (epoch !== this.epoch)
      return;
    this.failures = 0;
    if (this.downSince !== null) {
      const downForMs = this.now() - this.downSince;
      this.downSince = null;
      this.bus.emit('router-up', { downForMs });
    }
    const prev = this.last;
    this.last = status;
    this.bus.emit('status', { status, at: this.now() });
    if (!prev || changed(prev, status))
      this.bus.emit('state-change', { prev, next: status });
  }

  private failed(error: XvpnError): void {
    this.failures++;
    this.bus.emit('poll-error', { error, failures: this.failures });
    if (error.offline && this.downSince === null && this.failures >= this.downAfter) {
      this.downSince = this.now();
      this.bus.emit('router-down', { error, since: this.downSince });
    }
  }
}

/** the fields a state change is about; latency, counters and the clock are not */
export function changed(a: Status, b: Status): boolean {
  if (a.enabled !== b.enabled)
    return true;
  if (!a.running && !b.running)
    return a.timeout !== b.timeout;
  if (!a.running || !b.running)
    return true;
  return a.state !== b.state || (a.active ?? null) !== (b.active ?? null) || a.passthrough !== b.passthrough;
}
