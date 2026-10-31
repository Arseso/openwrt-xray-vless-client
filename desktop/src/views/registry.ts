// Tabs of the main window. A tab is a module src/views/<name>.ts that registers itself:
//
//   registerView({
//     id: 'servers', order: 20, title: () => t('title'),
//     mount(el, ctx) {
//       const off = ctx.bus.on('status', ({ status }) => render(status));
//       return () => off();   // cleanup: unsubscribe, stop timers
//     },
//   });
//
// and gets one line in src/views/index.ts. mount() runs each time the tab opens (and
// again after the profile or language changes); the cleanup it returns runs when it closes.

import { AppContext } from '../core/connection';

export interface View {
  /** the URL hash: #/<id> */
  id: string;
  /** position in the tab bar, ascending */
  order: number;
  title(): string;
  mount(el: HTMLElement, ctx: AppContext): void | (() => void);
}

const views = new Map<string, View>();

export function registerView(view: View): void {
  if (views.has(view.id))
    throw new Error(`view ${view.id} registered twice`);
  views.set(view.id, view);
}

export function allViews(): View[] {
  return [...views.values()].sort((a, b) => a.order - b.order);
}

export function findView(id: string): View | undefined {
  return views.get(id);
}
