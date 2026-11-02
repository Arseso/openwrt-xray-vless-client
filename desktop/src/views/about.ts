// Tab «О программе»: the versions and the update of the app (#81). Updates are checked
// on the button only and installed only after the user said yes in the native dialog of
// the install command (src/core/updater.ts). Below, luci-app-xvpn on the router from the
// same latest release (src/core/routerpkg.ts): check on the button, install after a yes.
// Last, xray-core of the router from the releases of XTLS (src/core/xraycore.ts): the router
// downloads it itself, the same way.

import { getVersion } from '@tauri-apps/api/app';
import { githubRelease } from '../api/release';
import { tauriUpdater } from '../api/updater';
import { AppContext, connection } from '../core/connection';
import { lang } from '../core/i18n';
import { PkgFlow, PkgState, compareVersions, flowFor } from '../core/routerpkg';
import { UpdateFlow, UpdateState } from '../core/updater';
import { XrayFlow, compareXray, runningVersion, xrayFlowFor } from '../core/xraycore';
import { t } from '../i18n/about';
import { h } from '../ui/dom';
import { errorText } from '../ui/errors';
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
    rows.push(h('p', {}, t('available', { version: s.update.version, current: s.current })));
    if (s.update.notes)
      rows.push(h('pre', { class: 'notes' }, s.update.notes));
    if (s.update.installable)
      rows.push(h('button', { class: 'primary', onclick: () => void flow.install(lang()) }, t('install')));
    else
      rows.push(h('p', { class: 'muted' }, t('manual'), ' ', RELEASES));
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

// one flow per router profile (src/core/routerpkg.ts flowFor): an install goes on when the
// tab is closed, and a reconnect meanwhile gets the same flow, not a second install
function pkgFlow(ctx: AppContext): PkgFlow {
  return flowFor(ctx.profile.id, ctx, () => new PkgFlow({
    ubus: ctx.ubus, xvpn: ctx.xvpn, source: githubRelease, poller: ctx.poller,
    refresh: () => connection.refreshPackage(),
    current: () => connection.context === ctx,
  }));
}

function renderPkg(box: HTMLElement, ctx: AppContext, flow: PkgFlow, s: PkgState, app: string | null): void {
  let confirming: 'install' | 'reinstall' | null = null;
  const draw = () => {
    const rows: (Node | string)[] = [
      h('p', {}, h('button', { onclick: () => void flow.check(), disabled: flow.busy }, t('pkg_check'))),
    ];
    switch (s.phase) {
    case 'checking':
      rows.push(h('p', { class: 'muted' }, t('pkg_checking')));
      break;
    case 'ready': {
      const c = s.check;
      rows.push(h('p', {}, t('pkg_versions', { installed: c.installed ?? `${ctx.pkg.version} (${t('pkg_not_opkg')})`, available: c.available, tag: c.tag })));
      if (c.langs.length)
        rows.push(h('p', { class: 'muted' }, t('pkg_langs', { langs: c.langs.join(', ') })));
      // the package and the app of a release go together: the app may be too old for it
      if (c.cmp > 0 && app && compareVersions(app, c.available.replace(/-r\d+$/, '')) < 0)
        rows.push(h('p', { class: 'warn' }, t('pkg_app_first', { app })));
      const ask = (what: 'install' | 'reinstall') => () => {
        confirming = what;
        draw();
      };
      if (confirming) {
        rows.push(h('p', {}, t(confirming === 'install' ? 'pkg_confirm' : 'pkg_confirm_reinstall', { version: c.available, router: ctx.profile.name })),
          h('p', {},
            h('button', { class: 'primary', onclick: () => void flow.install(confirming === 'reinstall') }, t('pkg_yes')), ' ',
            h('button', { onclick: () => { confirming = null; draw(); } }, t('pkg_cancel'))));
      }
      else if (c.cmp > 0)
        rows.push(h('p', {}, h('button', { class: 'primary', onclick: ask('install') }, t('pkg_newer', { version: c.available }))));
      else if (c.cmp === 0) {
        rows.push(h('p', {}, t('pkg_same')));
        rows.push(c.canReinstall
          ? h('p', {}, h('button', { onclick: ask('reinstall') }, t('pkg_reinstall')))
          : h('p', { class: 'muted' }, t('pkg_no_reinstall')));
      }
      else
        rows.push(h('p', {}, t('pkg_older')));
      break;
    }
    case 'installing':
      rows.push(h('p', {}, h('progress', {}), ' ', t(`pkg_step.${s.step}`, { n: s.n, of: s.of })));
      break;
    case 'done':
      rows.push(h('p', {}, t('pkg_done', { version: s.version })));
      for (const w of s.warnings)
        rows.push(h('p', { class: 'warn' }, t('pkg_warning', { message: w })));
      break;
    case 'error':
      rows.push(h('p', { class: 'error' }, t('pkg_error', { message: errorText(s.error) })));
      break;
    }
    box.replaceChildren(...rows);
  };
  draw();
}

function xrayFlow(ctx: AppContext): XrayFlow {
  return xrayFlowFor(ctx.profile.id, ctx, () => new XrayFlow(ctx.xvpn));
}

function renderXray(box: HTMLElement, ctx: AppContext, flow: XrayFlow): void {
  let confirming: 'install' | 'rollback' | null = null;
  const draw = () => {
    const s = flow.get();
    const info = s.info;
    const rows: (Node | string)[] = [];
    if (info) {
      const v = runningVersion(info);
      rows.push(h('p', {}, info.source === 'github' ? t('xray_github', { version: v ?? '?' })
        : info.source === 'feed' ? t('xray_feed', { version: v ?? '?' }) : t('xray_other', { bin: info.bin })));
      if (!info.asset)
        rows.push(h('p', { class: 'muted' }, t('xray_no_asset', { arch: info.arch ?? '?' })));
      if (s.latest) {
        const cmp = compareXray(s.latest, v);
        rows.push(h('p', {}, t(cmp > 0 ? 'xray_newer' : cmp === 0 ? 'xray_same' : 'xray_older', { tag: s.latest })));
      }
    }
    if (s.busy === 'install' && s.job)
      rows.push(h('p', {}, h('progress', {}), ' ', t(`xray_step.${s.job.step ?? 'start'}`, { tag: s.job.tag })));
    else if (s.busy === 'install')
      rows.push(h('p', {}, h('progress', {}), ' ', t('xray_step.start', { tag: s.latest ?? '' })));
    else if (s.busy === 'check')
      rows.push(h('p', { class: 'muted' }, t('xray_checking')));
    else if (s.busy === 'rollback')
      rows.push(h('p', {}, h('progress', {})));
    else if (!s.error && s.job?.state === 'done') {
      rows.push(h('p', {}, t('xray_done', { version: s.job.version ?? s.job.tag })));
      const sv = s.job.servers;
      if (sv && sv.after < sv.before)
        rows.push(h('p', { class: 'warn' }, t('xray_rejects', { n: sv.before - sv.after, of: sv.before })));
    }
    if (s.error)
      rows.push(h('p', { class: 'error' }, t('xray_error', { message: errorText(s.error) })));

    const tag = flow.installable;
    if (confirming === 'install' && tag)
      rows.push(h('p', {}, t('xray_confirm', { tag, router: ctx.profile.name, arch: info?.arch ?? '?' })),
        h('p', {},
          h('button', { class: 'primary', onclick: () => { confirming = null; void flow.install(); } }, t('pkg_yes')), ' ',
          h('button', { onclick: () => { confirming = null; draw(); } }, t('pkg_cancel'))));
    else if (confirming === 'rollback')
      rows.push(h('p', {}, t('xray_confirm_rollback', { version: info?.feed?.version ?? '?', router: ctx.profile.name })),
        h('p', {},
          h('button', { class: 'primary', onclick: () => { confirming = null; void flow.rollback(); } }, t('xray_rollback_yes')), ' ',
          h('button', { onclick: () => { confirming = null; draw(); } }, t('pkg_cancel'))));
    else {
      const ask = (what: 'install' | 'rollback') => () => {
        confirming = what;
        draw();
      };
      const buttons: (Node | string)[] = [];
      if (info?.asset)
        buttons.push(h('button', { onclick: () => void flow.check(), disabled: flow.busy }, t('xray_check')));
      if (tag)
        buttons.push(' ', h('button', { class: 'primary', onclick: ask('install'), disabled: flow.busy }, t('xray_install', { tag })));
      if (info?.source === 'github' && info.feed)
        buttons.push(' ', h('button', { onclick: ask('rollback'), disabled: flow.busy }, t('xray_rollback', { version: info.feed.version ?? '' })));
      if (buttons.length)
        rows.push(h('p', {}, ...buttons));
    }
    box.replaceChildren(...rows);
  };
  draw();
}

registerView({
  id: 'about',
  order: 90,
  title: () => t('title'),
  mount(el, ctx) {
    const app = h('dd', {}, '—');
    const version = h('dd', {}, ctx.pkg.version);
    const box = h('div', {});
    const pkgBox = h('div', {});
    const xrayBox = h('div', {});
    el.replaceChildren(h('section', {},
      h('h2', {}, t('title')),
      h('dl', { class: 'props' },
        h('dt', {}, t('app')), app,
        h('dt', {}, t('package')), version),
      box,
      h('h3', {}, t('pkg_title')),
      pkgBox,
      h('h3', {}, t('xray_title')),
      xrayBox));
    const pf = pkgFlow(ctx);
    let appVersion: string | null = null;
    const drawPkg = () => renderPkg(pkgBox, ctx, pf, pf.get(), appVersion);
    getVersion().then((v) => {
      app.textContent = appVersion = v;
      drawPkg();
    }, () => {});
    render(box, flow.get());
    drawPkg();
    const xf = xrayFlow(ctx);
    const drawXray = () => renderXray(xrayBox, ctx, xf);
    drawXray();
    void xf.load();
    const offs = [
      flow.subscribe((s) => render(box, s)),
      pf.subscribe(drawPkg),
      xf.subscribe(drawXray),
      ctx.bus.on('connection', (st) => {
        if (st.pkg)
          version.textContent = st.pkg.version;
      }),
    ];
    return () => offs.forEach((off) => off());
  },
});
