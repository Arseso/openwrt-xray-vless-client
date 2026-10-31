// Typed event bus. A handler that throws does not stop the others (logged).

export type Handler<T> = (payload: T) => void;

/** the side of a bus that publishes: the poller takes it, so any bus with its events fits */
export interface Emitter<E> {
  emit<K extends keyof E>(event: K, payload: E[K]): void;
}

export class Bus<E extends object> implements Emitter<E> {
  private handlers = new Map<keyof E, Set<Handler<never>>>();

  /** returns the function that unsubscribes */
  on<K extends keyof E>(event: K, fn: Handler<E[K]>): () => void {
    let set = this.handlers.get(event);
    if (!set)
      this.handlers.set(event, set = new Set());
    set.add(fn as Handler<never>);
    return () => {
      set.delete(fn as Handler<never>);
    };
  }

  once<K extends keyof E>(event: K, fn: Handler<E[K]>): () => void {
    const off = this.on(event, (p) => {
      off();
      fn(p);
    });
    return off;
  }

  emit<K extends keyof E>(event: K, payload: E[K]): void {
    for (const fn of [...(this.handlers.get(event) ?? [])]) {
      try {
        (fn as Handler<E[K]>)(payload);
      }
      catch (e) {
        console.error(`bus: handler of ${String(event)} failed`, e);
      }
    }
  }

  clear(): void {
    this.handlers.clear();
  }
}
