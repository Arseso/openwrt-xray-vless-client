// A form over sections of the xvpn config: fields bound to section.option, checks shown
// under the field while typing, and saving with apply / confirm / rollback
// (src/core/apply.ts). Before staging, the sections are read again: a value changed on
// the router meanwhile (in LuCI) is not overwritten, the form is reloaded instead.

import { isXvpnError } from '../api/errors';
import { UciSection, UciValue } from '../api/uci';
import { ApplyResult, Edit, applyStaged, exclusive, isEmpty, readConfig, saving, stage } from '../core/apply';
import { AppContext } from '../core/connection';
import { t } from '../i18n/forms';
import { Child, h } from '../ui/dom';
import { errorText } from '../ui/errors';
import { FieldValue, changedSince, editsFor, optionValue, uciBool } from './diff';
import { Check, lines } from './validate';

interface Bound {
  section: string;
  type: string;
  option: string;
  def?: string;
  flag?: boolean;
  get(): UciValue;
  check(): Check;
  error: HTMLElement;
  row: HTMLElement;
  visible?: () => boolean;
}

export interface FieldOpts {
  label: string;
  help?: string;
  placeholder?: string;
  /** suggestions (a datalist) */
  suggest?: string[];
  check?: (v: string) => Check;
  /** shown only while true; the value stays in the config while hidden */
  visible?: () => boolean;
}

let seq = 0;

export class UciForm {
  private fields: Bound[] = [];
  private onChange = new Set<() => void>();

  /** types: section name → type, for sections missing from the config */
  constructor(public sections: Record<string, UciSection>, private readonly types: Record<string, string>) {}

  private stored(section: string, option: string): UciValue | undefined {
    return optionValue(this.sections[section], option);
  }

  private bind(b: Omit<Bound, 'error' | 'row'>, label: string, input: Child, help?: string): HTMLElement {
    const error = h('small', { class: 'field-error' });
    const row = h('div', { class: 'field' },
      h('label', {}, label), input, help ? h('small', { class: 'muted' }, help) : null, error);
    const bound: Bound = { ...b, error, row };
    this.fields.push(bound);
    return row;
  }

  private changed(): void {
    for (const f of this.fields) {
      if (f.visible)
        f.row.hidden = !f.visible();
    }
    for (const fn of this.onChange)
      fn();
  }

  /** current value of a field (as the form has it, a list joined by newlines) */
  value(section: string, option: string): string {
    const f = this.fields.find((x) => x.section === section && x.option === option);
    const v = f ? f.get() : this.stored(section, option) ?? '';
    return Array.isArray(v) ? v.join('\n') : v;
  }

  text(section: string, option: string, o: FieldOpts): HTMLElement {
    const list = o.suggest?.length ? `dl${++seq}` : undefined;
    const input = h('input', {
      type: 'text', value: String(this.stored(section, option) ?? ''), placeholder: o.placeholder ?? '', list,
      spellcheck: false, oninput: () => this.validateAll(),
    });
    const row = this.bind({
      section, type: this.types[section], option,
      get: () => input.value.trim(),
      check: () => o.check?.(input.value) ?? null,
      visible: o.visible,
    }, o.label, [input, list ? h('datalist', { id: list }, o.suggest!.map((s) => h('option', { value: s }))) : null], o.help);
    return row;
  }

  /** a list option, one value per line; lower: stored in lower case */
  lines(section: string, option: string, o: FieldOpts & { rows?: number; lower?: boolean; check?: (v: string) => Check }): HTMLElement {
    const v = this.stored(section, option);
    const area = h('textarea', {
      rows: o.rows ?? 5, spellcheck: false, placeholder: o.placeholder ?? '', oninput: () => this.validateAll(),
    });
    area.value = (v == null ? [] : Array.isArray(v) ? v : [v]).join('\n');
    return this.bind({
      section, type: this.types[section], option,
      get: () => lines(o.lower ? area.value.toLowerCase() : area.value),
      check: () => o.check?.(area.value) ?? null,
      visible: o.visible,
    }, o.label, area, o.help);
  }

  flag(section: string, option: string, o: FieldOpts & { def: '0' | '1' }): HTMLElement {
    const v = this.stored(section, option);
    const box = h('input', {
      type: 'checkbox', checked: uciBool(v, o.def), onchange: () => this.validateAll(),
    });
    const error = h('small', { class: 'field-error' });
    const row = h('div', { class: 'field' },
      h('label', { class: 'check' }, box, o.label), o.help ? h('small', { class: 'muted' }, o.help) : null, error);
    this.fields.push({
      section, type: this.types[section], option, def: o.def, flag: true, error, row, visible: o.visible,
      get: () => (box.checked ? '1' : '0'),
      check: () => null,
    });
    return row;
  }

  select(section: string, option: string, o: FieldOpts & { def: string; choices: [string, string][] }): HTMLElement {
    const v = this.stored(section, option);
    const cur = typeof v === 'string' ? v : o.def;
    const choices = o.choices.some(([k]) => k === cur) ? o.choices : [...o.choices, [cur, cur] as [string, string]];
    const sel = h('select', { onchange: () => this.validateAll() },
      choices.map(([k, label]) => h('option', { value: k, selected: k === cur }, label)));
    return this.bind({
      section, type: this.types[section], option, def: o.def, get: () => sel.value, check: () => null, visible: o.visible,
    }, o.label, sel, o.help);
  }

  /** a list option as checkboxes; a configured value the router does not offer stays selectable */
  checks(section: string, option: string, o: FieldOpts & { choices: { value: string; label: Child }[] }): HTMLElement {
    const v = this.stored(section, option);
    const values = v == null ? [] : Array.isArray(v) ? v : [v];
    const choices = [...o.choices];
    for (const x of values)
      if (!choices.some((c) => c.value === x))
        choices.push({ value: x, label: h('span', {}, h('strong', {}, x), ' ', h('span', { class: 'warn-text' }, t('not_found'))) });
    const boxes = choices.map((c) => ({ c, box: h('input', { type: 'checkbox', checked: values.includes(c.value), onchange: () => this.validateAll() }) }));
    const body = boxes.length
      ? h('div', { class: 'checks' }, boxes.map(({ c, box }) => h('label', { class: 'check' }, box, c.label)))
      : h('em', { class: 'muted' }, t('none_found'));
    return this.bind({
      section, type: this.types[section], option, check: () => null, visible: o.visible,
      get: () => boxes.filter((b) => b.box.checked).map((b) => b.c.value),
    }, o.label, body, o.help);
  }

  /** after any change of a field (validation runs before) */
  watch(fn: () => void): void {
    this.onChange.add(fn);
  }

  validateAll(): boolean {
    let ok = true;
    for (const f of this.fields) {
      const r = f.visible && !f.visible() ? null : f.check();
      f.error.textContent = r ?? '';
      f.row.classList.toggle('invalid', !!r);
      ok &&= !r;
    }
    this.changed();
    return ok;
  }

  edits(): Edit[] {
    const values: FieldValue[] = this.fields.map((f) => ({ section: f.section, type: f.type, option: f.option, value: f.get(), def: f.def, flag: f.flag }));
    return editsFor(this.sections, values);
  }
}

export type SaveOutcome = ApplyResult | 'invalid' | 'changed' | 'busy' | 'error';

/**
 * The save button row of a form: validates, re-reads the config, stages extra edits
 * (beside the form's) and applies, one save of the session at a time (exclusive in
 * src/core/apply.ts): while another runs, it says so and saves nothing. reload() is
 * called after applied, rolled_back, changed and session_lost: the form is drawn again
 * from the router.
 */
export function saveBar(ctx: AppContext, o: {
  form: () => UciForm | null;
  extra?: () => Edit[] | Promise<Edit[]>;
  reload: () => void;
  /** also checks of the view itself (pending link checks ...) */
  ready?: () => Check;
  /** false: only the message, for save(edits) of quick actions (a toggle, a delete) */
  buttons?: boolean;
  label?: string;
  /** after each save from the button */
  onDone?: (r: SaveOutcome) => void;
}): { el: HTMLElement; save: (edits?: Edit[]) => Promise<SaveOutcome> } {
  const msg = h('span', { class: 'save-msg' });
  const say = (text: string, cls = 'muted') => {
    msg.textContent = text;
    msg.className = `save-msg ${cls}`;
  };
  const btn = h('button', { class: 'primary', onclick: () => void save().then((r) => o.onDone?.(r)) }, o.label ?? t('save'));
  const reset = h('button', { onclick: () => o.reload() }, t('reset'));

  const save = async (only?: Edit[]): Promise<SaveOutcome> => {
    if (saving(ctx.uci)) {
      say(t('busy'), 'warn-text');
      return 'busy';
    }
    const form = o.form();
    if (!only && form && !form.validateAll()) {
      say(t('invalid'), 'error-text');
      return 'invalid';
    }
    const pending = only ? null : o.ready?.();
    if (pending) {
      say(pending, 'error-text');
      return 'invalid';
    }
    btn.disabled = reset.disabled = true;
    say(t('saving'));
    try {
      const edits = only ?? [...(form?.edits() ?? []), ...(await o.extra?.() ?? [])].filter((e) => !isEmpty(e));
      if (!edits.length) {
        say(t('nothing'));
        return 'nothing';
      }
      const r = await exclusive(ctx.uci, async (): Promise<SaveOutcome> => {
        if (form && changedSince(form.sections, await readConfig(ctx.uci), edits).length)
          return 'changed';
        await stage(ctx.uci, edits);
        return applyStaged(ctx.uci, ctx.xvpn, { onWaiting: () => say(t('waiting')) });
      });
      if (r === 'changed')
        say(t('changed'), 'warn-text');
      else
        say(r === 'applied' ? t('applied') : r === 'nothing' ? t('nothing') : t('rolled_back'),
          r === 'rolled_back' ? 'error-text' : 'ok-text');
      ctx.poller.refresh();
      o.reload();
      return r;
    }
    catch (e) {
      say(isXvpnError(e, 'acl') && e.detail.object === 'uci' && e.detail.method === 'apply' ? t('apply_busy') : errorText(e), 'error-text');
      if (isXvpnError(e, 'session_lost'))
        o.reload();
      return 'error';
    }
    finally {
      btn.disabled = reset.disabled = false;
    }
  };

  const el = o.buttons === false ? h('div', { class: 'row save-bar' }, msg) : h('div', { class: 'row save-bar' }, btn, reset, msg);
  return { el, save };
}
