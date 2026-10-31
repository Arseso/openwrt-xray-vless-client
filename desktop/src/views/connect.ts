// The screen of router profiles: list, add/edit, connect, and the certificate decisions
// of the first HTTPS connection (trust on first use) and of a changed certificate.
// Not a tab: the shell shows it while there is no connection.

import { XvpnError } from '../api/errors';
import {
  Profile, defaultGateway, deleteProfile, listProfiles, newProfileId, saveProfile, setLastProfileId,
  setPassword, trustCertificate,
} from '../api/profiles';
import { Connection } from '../core/connection';
import { t } from '../i18n/connect';
import { clear, h } from '../ui/dom';
import { errorText } from '../ui/errors';

export function mountConnect(el: HTMLElement, conn: Connection): () => void {
  let profiles: Profile[] = [];
  let editing: Profile | null = null;
  let editingNew = false;
  let notice: string | null = null;

  const list = h('div', { class: 'profiles' });
  const form = h('div');
  const status = h('div', { class: 'connect-status' });
  el.replaceChildren(h('section', { class: 'connect' }, h('h2', {}, t('title')), status, list, form));

  // no or wrong password, or no credential store to read it from (also of the connection
  // at startup): the form of that profile, where "remember" can be turned off
  const askPassword = () => {
    const st = conn.state.get();
    if (st.phase === 'failed' && st.profile && st.error && ['no_password', 'wrong_password', 'keyring'].includes(st.error.code)) {
      editing = st.profile;
      editingNew = false;
    }
  };

  const connect = async (p: Profile) => {
    notice = null;
    setLastProfileId(p.id);
    await conn.connect(p);
    askPassword();
    render();
  };

  const renderStatus = () => {
    const st = conn.state.get();
    clear(status);
    if (st.phase === 'connecting' || st.phase === 'offline') {
      status.append(h('p', { class: st.phase === 'offline' ? 'warn' : 'muted' },
        st.phase === 'offline' ? `${t('retrying')} ${errorText(st.error)}` : t('connecting', { name: st.profile?.name ?? '' }),
        ' ', h('button', { onclick: () => conn.disconnect() }, t('stop'))));
      return;
    }
    if (notice)
      status.append(h('p', { class: 'error' }, notice));
    if (st.phase !== 'failed' || !st.error || !st.profile)
      return;
    const err = st.error, p = st.profile;
    if (err.code === 'tls_unknown' && err.detail.fingerprint)
      status.append(tofu(p, err));
    else if (err.code === 'tls_changed' && err.detail.fingerprint)
      status.append(changed(p, err));
    else
      status.append(h('p', { class: 'error' }, `${p.name}: ${errorText(err)}`));
  };

  const trust = async (p: Profile, fingerprint: string) => {
    try {
      const saved = await trustCertificate(p.id, fingerprint);
      await reload();
      await connect(saved);
    }
    catch (e) {
      notice = errorText(e);
      render();
    }
  };

  const tofu = (p: Profile, err: XvpnError) => h('div', { class: 'card warn-card' },
    h('h3', {}, t('tofu_title')),
    h('p', {}, t('tofu_text')),
    h('p', {}, `${t('fingerprint')}: `, h('code', { class: 'fp' }, err.detail.fingerprint)),
    h('button', { class: 'primary', onclick: () => trust(p, err.detail.fingerprint!) }, t('tofu_trust')));

  const changed = (p: Profile, err: XvpnError) => {
    const btn = h('button', { class: 'danger', disabled: true, onclick: () => trust(p, err.detail.fingerprint!) }, t('changed_trust'));
    const ack = h('input', { type: 'checkbox', onchange: () => { btn.disabled = !ack.checked; } });
    return h('div', { class: 'card error-card' },
      h('h3', {}, t('changed_title')),
      h('p', {}, t('changed_text')),
      h('p', {}, `${t('changed_old')}: `, h('code', { class: 'fp' }, err.detail.pinned ?? '—')),
      h('p', {}, `${t('changed_new')}: `, h('code', { class: 'fp' }, err.detail.fingerprint)),
      h('label', {}, ack, ' ', t('changed_ack')),
      h('p', {}, btn));
  };

  const renderList = () => {
    clear(list);
    if (!profiles.length) {
      list.append(h('p', { class: 'muted' }, t('empty')));
      return;
    }
    const busy = ['connecting', 'offline'].includes(conn.state.get().phase);
    for (const p of profiles) {
      list.append(h('div', { class: 'profile' },
        h('div', { class: 'profile-name' }, h('strong', {}, p.name), h('span', { class: 'muted' }, ` ${p.username}@${p.url}`)),
        h('div', { class: 'profile-actions' },
          h('button', { class: 'primary', disabled: busy, onclick: () => connect(p) }, t('connect')),
          h('button', { disabled: busy, onclick: () => { editing = p; editingNew = false; render(); } }, t('edit')),
          h('button', {
            disabled: busy,
            onclick: async () => {
              if (!confirm(t('confirm_delete', { name: p.name })))
                return;
              await deleteProfile(p.id).catch((e) => { notice = errorText(e); });
              await reload();
            },
          }, t('delete')))));
    }
  };

  const renderForm = () => {
    clear(form);
    if (!editing) {
      form.append(h('button', {
        onclick: async () => {
          const gw = await defaultGateway().catch(() => null);
          editing = { id: newProfileId(), name: t('default_name'), url: `http://${gw ?? '192.168.1.1'}`, username: 'root' };
          editingNew = true;
          render();
        },
      }, t('add')));
      return;
    }
    const p = editing;
    const name = h('input', { value: p.name, required: true });
    const url = h('input', { value: p.url, required: true, placeholder: 'http://192.168.1.1' });
    const user = h('input', { value: p.username, required: true, autocomplete: 'username' });
    const pass = h('input', { type: 'password', autocomplete: 'current-password', placeholder: editingNew ? '' : t('password_keep') });
    if (!editingNew)
      queueMicrotask(() => pass.focus());
    const remember = h('input', { type: 'checkbox', checked: true });
    const submit = async (ev: Event) => {
      ev.preventDefault();
      notice = null;
      try {
        // a new address is another certificate: the pin goes with the old one
        const fingerprint = url.value.trim() === p.url ? p.fingerprint : null;
        const saved = await saveProfile({ ...p, name: name.value.trim(), url: url.value.trim(), username: user.value.trim(), fingerprint });
        if (pass.value)
          await setPassword(saved.id, pass.value, remember.checked);
        editing = null;
        await reload();
        await connect(saved);
      }
      catch (e) {
        notice = errorText(e);
        render();
      }
    };
    form.append(h('form', { class: 'card profile-form', onsubmit: submit },
      h('h3', {}, t('edit_title')),
      h('label', {}, t('name'), name),
      h('label', {}, t('url'), url, h('small', { class: 'muted' }, t('url_hint'))),
      h('label', {}, t('username'), user),
      h('label', {}, t('password'), pass),
      h('label', { class: 'check' }, remember, ' ', t('remember')),
      h('div', { class: 'row' },
        h('button', { class: 'primary', type: 'submit' }, t('save_connect')),
        h('button', { type: 'button', onclick: () => { editing = null; render(); } }, t('cancel')))));
  };

  const render = () => {
    renderStatus();
    renderList();
    renderForm();
  };

  const reload = async () => {
    profiles = await listProfiles().catch((e) => {
      notice = errorText(e);
      return [];
    });
    render();
  };

  const off = conn.state.subscribe((st, prev) => {
    if (st.phase !== prev.phase)
      askPassword();
    render();
  });
  askPassword();
  void reload();
  return off;
}
