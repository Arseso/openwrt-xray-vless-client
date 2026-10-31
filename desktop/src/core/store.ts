// A small observable store: get() the state, set() a patch, subscribe() to changes.

export type Listener<S> = (state: S, prev: S) => void;

export class Store<S extends object> {
  private state: S;
  private listeners = new Set<Listener<S>>();

  constructor(initial: S) {
    this.state = initial;
  }

  get(): S {
    return this.state;
  }

  set(patch: Partial<S>): void {
    const prev = this.state;
    this.state = { ...prev, ...patch };
    for (const fn of [...this.listeners]) {
      try {
        fn(this.state, prev);
      }
      catch (e) {
        console.error('store: listener failed', e);
      }
    }
  }

  /** returns the function that unsubscribes */
  subscribe(fn: Listener<S>): () => void {
    this.listeners.add(fn);
    return () => {
      this.listeners.delete(fn);
    };
  }
}
