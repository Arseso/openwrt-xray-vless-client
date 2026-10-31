// History of ping and tunnel speed for the History tab (#80): samples of the shared
// poller kept in memory for this run (a ring buffer, the oldest go first). The tab
// reads a HistorySource, not the buffer: when the daemon keeps its own history (#34),
// a source that reads it from the router replaces LiveHistory via setHistorySource().

import { Status } from '../api/xvpn';
import { Connection } from './connection';

export interface Sample {
  /** PC clock, ms */
  at: number;
  /** HTTP ping of the active server, ms; null: none or not measured */
  ping: number | null;
  /** tunnel speed, bytes/s; null: no measure yet or the router away (a gap) */
  up: number | null;
  down: number | null;
}

export interface HistorySource {
  /** oldest first */
  samples(): readonly Sample[];
  /** a new sample, or null when the samples were replaced (another router) */
  subscribe(fn: (s: Sample | null) => void): () => void;
}

export class Ring<T> {
  private buf: T[] = [];
  private start = 0;

  constructor(readonly capacity: number) {}

  get size(): number {
    return this.buf.length;
  }

  push(v: T): void {
    if (this.buf.length < this.capacity) {
      this.buf.push(v);
      return;
    }
    this.buf[this.start] = v;
    this.start = (this.start + 1) % this.capacity;
  }

  toArray(): T[] {
    return [...this.buf.slice(this.start), ...this.buf.slice(0, this.start)];
  }

  clear(): void {
    this.buf = [];
    this.start = 0;
  }
}

/** the speed fields of luci.xvpn status (#83); null before the second measure */
interface WithSpeed {
  speed?: { up: number; down: number } | null;
}

export function sampleOf(s: Status, at: number): Sample {
  if (!s.running)
    return { at, ping: null, up: null, down: null };
  const ping = s.servers.find((x) => x.id === s.active)?.latency ?? null;
  const speed = (s as WithSpeed).speed ?? null;
  return { at, ping, up: speed?.up ?? null, down: speed?.down ?? null };
}

/** 8 h at the poll interval of 3 s */
export const HISTORY_CAPACITY = 9600;

export class LiveHistory implements HistorySource {
  private ring: Ring<Sample>;
  private listeners = new Set<(s: Sample | null) => void>();
  private profile: string | null = null;

  constructor(capacity = HISTORY_CAPACITY) {
    this.ring = new Ring(capacity);
  }

  samples(): readonly Sample[] {
    return this.ring.toArray();
  }

  subscribe(fn: (s: Sample | null) => void): () => void {
    this.listeners.add(fn);
    return () => {
      this.listeners.delete(fn);
    };
  }

  /** the samples of the profile id; another profile starts over */
  add(profile: string, s: Sample): void {
    if (profile !== this.profile) {
      this.profile = profile;
      if (this.ring.size) {
        this.ring.clear();
        this.emit(null);
      }
    }
    this.ring.push(s);
    this.emit(s);
  }

  private emit(s: Sample | null): void {
    for (const fn of [...this.listeners]) {
      try {
        fn(s);
      }
      catch (e) {
        console.error('history: listener failed', e);
      }
    }
  }

  /** once at startup: samples from the poller, a gap while the router does not answer */
  attach(conn: Connection, now: () => number = Date.now): () => void {
    const offs = [
      conn.bus.on('status', ({ status, at }) => {
        const p = conn.context?.profile.id;
        if (p)
          this.add(p, sampleOf(status, at));
      }),
      conn.bus.on('poll-error', () => {
        const p = conn.context?.profile.id;
        if (p)
          this.add(p, { at: now(), ping: null, up: null, down: null });
      }),
    ];
    return () => offs.forEach((off) => off());
  }
}

export const liveHistory = new LiveHistory();
let source: HistorySource = liveHistory;
const sourceListeners = new Set<() => void>();

export function historySource(): HistorySource {
  return source;
}

export function setHistorySource(s: HistorySource): void {
  source = s;
  for (const fn of [...sourceListeners])
    fn();
}

export function onHistorySourceChange(fn: () => void): () => void {
  sourceListeners.add(fn);
  return () => {
    sourceListeners.delete(fn);
  };
}
