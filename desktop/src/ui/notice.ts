// Short messages for the window from parts without a view of their own (the tray): the
// shell shows them in its banner until closed. Notifications of the system are #80's.

export type NoticeKind = 'error' | 'info';

export interface Notice {
  id: number;
  kind: NoticeKind;
  text: string;
}

let seq = 0;
let notices: Notice[] = [];
const listeners = new Set<(n: Notice[]) => void>();

export function notice(kind: NoticeKind, text: string): void {
  // the same text again is not a second line
  notices = [...notices.filter((n) => n.text !== text), { id: ++seq, kind, text }].slice(-3);
  listeners.forEach((fn) => fn(notices));
}

export function dismiss(id: number): void {
  notices = notices.filter((n) => n.id !== id);
  listeners.forEach((fn) => fn(notices));
}

export function onNotices(fn: (n: Notice[]) => void): () => void {
  listeners.add(fn);
  return () => {
    listeners.delete(fn);
  };
}

export function currentNotices(): Notice[] {
  return notices;
}
