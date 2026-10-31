// Tab «Статус»: the package version and the state from the shared poller. The full
// tab (traffic, ping, kill switch, "am I behind the VPN") is TODO(#78).

import { Status } from '../api/xvpn';
import { t } from '../i18n/status';
import { h } from '../ui/dom';
import { registerView } from './registry';

function stateText(s: Status): string {
  if (!s.running)
    return s.timeout ? t('not_answering') : t('stopped');
  return t(`state.${s.state}`);
}

registerView({
  id: 'status',
  order: 10,
  title: () => t('title'),
  mount(el, ctx) {
    const state = h('dd', {}, t('waiting'));
    const active = h('dd', {}, '—');
    const error = h('dd', {}, '—');
    el.replaceChildren(h('section', {},
      h('h2', {}, t('title')),
      h('dl', { class: 'props' },
        h('dt', {}, t('router')), h('dd', {}, `${ctx.profile.name} (${ctx.profile.url})`),
        h('dt', {}, t('package')), h('dd', { id: 'pkg-version' }, ctx.pkg.version),
        h('dt', {}, t('state')), state,
        h('dt', {}, t('active')), active,
        h('dt', {}, t('error')), error)));

    const render = (s: Status) => {
      state.textContent = stateText(s);
      state.dataset.state = s.running ? s.state : 'stopped';
      const srv = s.running ? s.servers.find((x) => x.id === s.active) : undefined;
      active.textContent = srv ? `${srv.name}${srv.latency != null ? ` · ${srv.latency} ms` : ''}` : '—';
      error.textContent = (s.running && s.last_error) || '—';
    };
    if (ctx.poller.status)
      render(ctx.poller.status);
    return ctx.bus.on('status', ({ status }) => render(status));
  },
});
