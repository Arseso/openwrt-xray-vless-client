// Tab «О программе»: the versions and the update of the app (#81). Updates are checked
// on the button only and installed only after the user confirmed (src/core/updater.ts).

import { getVersion } from '@tauri-apps/api/app';
import { tauriUpdater } from '../api/updater';
import { UpdateFlow, UpdateState } from '../core/updater';
import { t } from '../i18n/about';
import { h } from '../ui/dom';
import { registerView } from './registry';

const RELEASES = 'https://github.com/Arseso/openwrt-xray-vless-client/releases/latest';
// one flow for the app: a check or an install goes on when the tab is closed
const flow = new UpdateFlow(tauriUpdater);

function render(box: HTMLElement, s: UpdateState): void {
  const check = h('button', { onclick: () => void flow.check(), disabled: s.phase === 'checking' || s.phase === 'installing' }, t('check'));
  const rows: (Node | string)[] = [];
  switch (s.phase) {
  case 'checking':
    rows.push(h('p', { class: 'muted' }, t('checking')));
    break;
  case 'latest':
    rows.push(h('p', {}, t('latest', { current: s.current })));
    break;
  case 'available':
  case 'confirm':
    rows.push(h('p', {}, t('available', { version: s.update.version, current: s.current })));
    if (s.update.notes)
      rows.push(h('pre', { class: 'notes' }, s.update.notes));
    if (!s.update.installable)
      rows.push(h('p', { class: 'muted' }, t('deb'), ' ', RELEASES));
    else if (s.phase === 'available')
      rows.push(h('button', { class: 'primary', onclick: () => flow.ask() }, t('install')));
    else
      rows.push(h('p', {}, t('confirm', { version: s.update.version })),
        h('p', {},
          h('button', { class: 'primary', onclick: () => void flow.confirm() }, t('yes')), ' ',
          h('button', { onclick: () => flow.cancel() }, t('cancel'))));
    break;
  case 'installing':
    rows.push(h('p', {}, t('installing', { version: s.update.version })));
    break;
  case 'error':
    rows.push(h('p', { class: 'error' }, t('error', { message: s.message })));
    break;
  }
  box.replaceChildren(h('p', {}, check), ...rows);
}

registerView({
  id: 'about',
  order: 90,
  title: () => t('title'),
  mount(el, ctx) {
    const app = h('dd', {}, '—');
    const box = h('div', {});
    el.replaceChildren(h('section', {},
      h('h2', {}, t('title')),
      h('dl', { class: 'props' },
        h('dt', {}, t('app')), app,
        h('dt', {}, t('package')), h('dd', {}, ctx.pkg.version)),
      box));
    getVersion().then((v) => { app.textContent = v; }, () => {});
    render(box, flow.get());
    return flow.subscribe((s) => render(box, s));
  },
});
