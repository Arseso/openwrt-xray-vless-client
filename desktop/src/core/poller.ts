// Shared poller of luci.xvpn status: one request every intervalMs for the whole app
// (tabs, tray #78, notifications #80 listen to the bus instead of polling themselves).
// Requests never overlap: the next one is scheduled after the answer.
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

  stop(): void {
    this.running = false;
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

  /** polls now (after select, service...) and resolves with that poll; no overlap */
  async refresh(): Promise<void> {
    if (this.inFlight)
      await this.inFlight;
    if (this.timer)
      clearTimeout(this.timer);
    this.timer = null;
    await this.tick();
  }

  private schedule(): void {
    if (this.running)
      this.timer = setTimeout(() => void this.tick(), this.intervalMs);
  }

  private tick(): Promise<void> {
    this.timer = null;
    const p = this.poll().finally(() => {
      this.inFlight = null;
      if (!this.timer)
        this.schedule();
    });
    this.inFlight = p;
    return p;
  }

  private async poll(): Promise<void> {
    let status: Status;
    try {
      status = await this.source.status();
    }
    catch (e) {
      this.failed(toXvpnError(e));
      return;
    }
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
