import { describe, expect, it } from 'vitest';
import { format, lang, setLang, strings } from '../../src/core/i18n';
import { t } from '../../src/i18n/common';

describe('i18n', () => {
  it('formats and switches language', () => {
    const tt = strings({ en: { n: '{n} servers' }, ru: { n: 'Серверов: {n}' } });
    setLang('en');
    expect(tt('n', { n: 3 })).toBe('3 servers');
    setLang('ru');
    expect(lang()).toBe('ru');
    expect(tt('n', { n: 3 })).toBe('Серверов: 3');
    expect(format('{a} {b}', { a: 1 })).toBe('1 {b}');
    setLang('en');
  });

  it('has a message for every error code', async () => {
    const src = await import('node:fs').then((fs) => fs.readFileSync(new URL('../../src/api/errors.ts', import.meta.url), 'utf8'));
    const codes = [...src.matchAll(/^\s+\| '(\w+)'/gm)].map((m) => m[1]);
    expect(codes.length).toBeGreaterThan(15);
    for (const l of ['en', 'ru'] as const) {
      setLang(l);
      for (const c of codes)
        expect(t(`error.${c}` as never), `${l} error.${c}`).not.toBe(`error.${c}`);
    }
    setLang('en');
  });
});
