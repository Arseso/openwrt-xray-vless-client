// The shell of the main window: the header with the router and the connection phase,
// the tab bar from the registry (src/views/registry.ts) and a hash router #/<view id>.
// Without a connection it shows the router profiles (src/views/connect.ts).

import { listProfiles, lastProfileId } from './api/profiles';
import { AppContext, Connection, ConnectionState } from './core/connection';
import { LANGS, lang, onLangChange, setLang } from './core/i18n';
import { t } from './i18n/common';
import { clear, h } from './ui/dom';
import { errorText } from './ui/errors';
import { mountConnect } from './views/connect';
import { allViews, findView } from './views/registry';
import './views';

export function startApp(root: HTMLElement, conn: Connection): void {
  const header = h('header', { class: 'top' });
  const nav = h('nav', { class: 'tabs' });
  const banner = h('div', { class: 'banner' });
  const main = h('main');
  root.replaceChildren(header, nav, banner, main);

  let cleanup: (() => void) | null = null;
  let mounted: { view: string; ctx: AppContext | null } | null = null;
  // the routers screen asked for while connected
  let showProfiles = false;

  const unmount = () => {
    cleanup?.();
    cleanup = null;
    mounted = null;
  };

  const currentView = () => {
    const id = location.hash.replace(/^#\/?/, '');
    return findView(id) ?? allViews()[0];
  };

  const renderHeader = (st: ConnectionState) => {
    clear(header,
      h('span', { class: 'brand' }, t('app')),
      h('span', { class: `phase phase-${st.phase}` }, st.profile ? `${st.profile.name} · ` : '', t(`phase.${st.phase}`)),
      h('span', { class: 'spacer' }),
      h('button', {
        onclick: () => {
          showProfiles = !showProfiles || !conn.context;
          render(true);
        },
      }, t('switch_router')),
      h('select', {
        title: t('language'),
        onchange: (e: Event) => setLang((e.target as HTMLSelectElement).value as 'en' | 'ru'),
      }, LANGS.map((l) => h('option', { value: l, selected: l === lang() }, l.toUpperCase()))));
  };

  const render = (force = false) => {
    const st = conn.state.get();
    renderHeader(st);
    const ctx = conn.context;
    clear(banner);
    if (ctx && st.phase === 'offline')
      banner.append(h('p', { class: 'warn' }, `${t('phase.offline')} ${errorText(st.error)}`));

    if (!ctx || showProfiles) {
      clear(nav);
      if (force || mounted?.view !== '#connect') {
        unmount();
        mounted = { view: '#connect', ctx: null };
        cleanup = mountConnect(main, conn);
      }
      return;
    }
    const view = currentView();
    clear(nav, allViews().map((v) => h('a', { href: `#/${v.id}`, class: v === view ? 'active' : '' }, v.title())));
    if (!force && mounted?.view === view.id && mounted.ctx === ctx)
      return;
    unmount();
    main.replaceChildren();
    mounted = { view: view.id, ctx };
    cleanup = view.mount(main, ctx) ?? null;
  };

  conn.state.subscribe((st, prev) => {
    if (st.phase === 'online' && prev.phase !== 'online')
      showProfiles = false;
    render();
  });
  addEventListener('hashchange', () => render());
  onLangChange(() => render(true));
  render();

  // the last router at startup: HTTPS only. The pinned certificate proves it is that
  // router; over HTTP the stored password would go to any host with its address (a
  // laptop in another network with the same gateway IP), so that takes a click.
  void listProfiles().then((ps) => {
    const p = ps.find((x) => x.id === lastProfileId()) ?? (ps.length === 1 ? ps[0] : undefined);
    if (p && p.url.startsWith('https://') && conn.state.get().phase === 'disconnected')
      void conn.connect(p);
  }, () => {});
}
