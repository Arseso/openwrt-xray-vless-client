// The update flow of the tab «О программе» (src/views/about.ts): nothing is checked or
// installed by itself. check() runs on the button; an update found is installed only
// through ask() and then confirm() (the user agreed), and only the version that was shown.

import { Available, UpdaterApi } from '../api/updater';

export type UpdateState =
  | { phase: 'idle' }
  | { phase: 'checking' }
  | { phase: 'latest'; current: string }
  | { phase: 'available'; current: string; update: Available }
  | { phase: 'confirm'; current: string; update: Available }
  | { phase: 'installing'; current: string; update: Available }
  | { phase: 'error'; message: string };

export class UpdateFlow {
  private current: UpdateState = { phase: 'idle' };
  private listeners = new Set<(s: UpdateState) => void>();

  constructor(private readonly api: UpdaterApi) {}

  get(): UpdateState {
    return this.current;
  }

  /** returns the function that unsubscribes */
  subscribe(fn: (s: UpdateState) => void): () => void {
    this.listeners.add(fn);
    return () => {
      this.listeners.delete(fn);
    };
  }

  private set(s: UpdateState): void {
    this.current = s;
    for (const fn of [...this.listeners])
      fn(s);
  }

  async check(): Promise<void> {
    const s = this.get().phase;
    if (s === 'checking' || s === 'installing')
      return;
    this.set({ phase: 'checking' });
    try {
      const r = await this.api.check();
      this.set(r.available
        ? { phase: 'available', current: r.current, update: r.available }
        : { phase: 'latest', current: r.current });
    }
    catch (e) {
      this.set({ phase: 'error', message: message(e) });
    }
  }

  /** the user pressed «Install»: ask before anything is downloaded */
  ask(): void {
    const s = this.get();
    if (s.phase === 'available' && s.update.installable)
      this.set({ ...s, phase: 'confirm' });
  }

  cancel(): void {
    const s = this.get();
    if (s.phase === 'confirm')
      this.set({ ...s, phase: 'available' });
  }

  /** the user agreed: the app restarts when it is installed */
  async confirm(): Promise<void> {
    const s = this.get();
    if (s.phase !== 'confirm')
      return;
    this.set({ ...s, phase: 'installing' });
    try {
      await this.api.install(s.update.version);
    }
    catch (e) {
      this.set({ phase: 'error', message: message(e) });
    }
  }
}

function message(e: unknown): string {
  return e instanceof Error ? e.message : String(e);
}
