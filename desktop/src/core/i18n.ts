// i18n: a dictionary per screen (src/i18n/<name>.ts), English and Russian. A missing
// Russian string is a type error; at run time it falls back to English, then the key.
//
//   export const t = strings({
//     en: { title: 'Servers', count: '{n} servers' },
//     ru: { title: 'Серверы', count: 'Серверов: {n}' },
//   });
//   t('count', { n: 3 })

export type Lang = 'en' | 'ru';
export const LANGS: readonly Lang[] = ['en', 'ru'];

const KEY = 'xvpn.lang';
const listeners = new Set<(l: Lang) => void>();
let current: Lang = detect();

function detect(): Lang {
  try {
    const saved = localStorage.getItem(KEY);
    if (saved === 'en' || saved === 'ru')
      return saved;
  }
  catch {
    // no storage (tests, private mode)
  }
  const nav = typeof navigator !== 'undefined' ? navigator.language : '';
  return /^ru\b/i.test(nav) ? 'ru' : 'en';
}

export function lang(): Lang {
  return current;
}

export function setLang(l: Lang): void {
  if (l === current)
    return;
  current = l;
  try {
    localStorage.setItem(KEY, l);
  }
  catch {
    // kept for this run only
  }
  for (const fn of [...listeners])
    fn(l);
}

/** the app re-renders on a change; returns the function that unsubscribes */
export function onLangChange(fn: (l: Lang) => void): () => void {
  listeners.add(fn);
  return () => {
    listeners.delete(fn);
  };
}

export type Params = Record<string, string | number>;
export type Translate<K extends string> = (key: K, params?: Params) => string;

export function format(s: string, params?: Params): string {
  return params ? s.replace(/\{(\w+)\}/g, (m, k: string) => (k in params ? String(params[k]) : m)) : s;
}

export function strings<const T extends Record<string, string>>(d: { en: T; ru: { [K in keyof T]: string } }): Translate<keyof T & string> {
  return (key, params) => {
    const table = d[current] as Record<string, string | undefined>;
    return format(table[key] ?? d.en[key] ?? key, params);
  };
}
