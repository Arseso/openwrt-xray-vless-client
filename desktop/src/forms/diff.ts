// What a form changes in UCI: the values of its fields against the sections it was
// loaded from. A field left empty (or a list without lines) deletes the option, as
// LuCI does; an unchanged one is not written. A flag that was not set and stays at its
// default is not written either.

import { UciSection, UciValue } from '../api/uci';
import { Edit } from '../core/apply';

export interface FieldValue {
  section: string;
  /** section type, to add the section when it is missing */
  type: string;
  option: string;
  /** '' or [] deletes the option */
  value: UciValue;
  /** the value the backend takes for a missing option (flags) */
  def?: string;
}

function same(a: UciValue | undefined, b: UciValue): boolean {
  if (Array.isArray(a) || Array.isArray(b)) {
    const x = a == null ? [] : Array.isArray(a) ? a : [a], y = Array.isArray(b) ? b : [b];
    return x.length === y.length && x.every((v, i) => v === y[i]);
  }
  return (a ?? '') === b;
}

function empty(v: UciValue): boolean {
  return Array.isArray(v) ? v.length === 0 : v === '';
}

export function optionValue(s: UciSection | undefined, option: string): UciValue | undefined {
  const v = s?.[option];
  return typeof v === 'string' || Array.isArray(v) ? v : undefined;
}

export function editsFor(sections: Record<string, UciSection>, fields: FieldValue[]): Edit[] {
  const edits = new Map<string, Edit>();
  const edit = (f: FieldValue) => {
    let e = edits.get(f.section);
    if (!e) {
      e = { section: f.section, type: f.type, add: !sections[f.section], set: {}, unset: [] };
      edits.set(f.section, e);
    }
    return e;
  };
  for (const f of fields) {
    const old = optionValue(sections[f.section], f.option);
    if (same(old, f.value))
      continue;
    if (old === undefined && f.def !== undefined && f.value === f.def)
      continue;
    if (empty(f.value)) {
      if (old !== undefined)
        edit(f).unset!.push(f.option);
    }
    else
      edit(f).set![f.option] = f.value;
  }
  return [...edits.values()];
}

/** the options whose value on the router differs from the one the form was loaded with */
export function changedSince(loaded: Record<string, UciSection>, now: Record<string, UciSection>, edits: Edit[]): string[] {
  const out: string[] = [];
  for (const e of edits) {
    if (!loaded[e.section] !== !now[e.section]) {
      out.push(e.section);
      continue;
    }
    for (const o of [...Object.keys(e.set ?? {}), ...(e.unset ?? [])]) {
      const a = optionValue(loaded[e.section], o), b = optionValue(now[e.section], o);
      if (!same(a, b ?? ''))
        out.push(`${e.section}.${o}`);
    }
  }
  return out;
}
