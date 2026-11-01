// Numbers for the screens: sizes, durations, ages. Ages are counted from the router clock
// (time in the answers of luci.xvpn), not from the PC.

import { lang } from '../core/i18n';
import { t } from '../i18n/format';

export function bytes(n: number | null | undefined): string {
  let v = Math.max(0, n ?? 0);
  const units = ['B', 'KiB', 'MiB', 'GiB', 'TiB'];
  let i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  return `${i ? v.toFixed(v < 10 ? 2 : v < 100 ? 1 : 0) : v} ${units[i]}`;
}

/** the two largest units: 3d 4h, 2h 5m, 4m 10s, 7s */
export function dur(sec: number): string {
  const s = Math.max(0, Math.floor(sec));
  const d = Math.floor(s / 86400), hr = Math.floor(s / 3600) % 24, m = Math.floor(s / 60) % 60;
  if (d)
    return t('dh', { d, h: hr });
  if (hr)
    return t('hm', { h: hr, m });
  if (m)
    return t('ms', { m, s: s % 60 });
  return t('s', { s });
}

export function ago(now: number, at: number | null | undefined): string {
  return at ? t('ago', { d: dur(now - at) }) : t('never');
}

export function date(unix: number): string {
  return new Date(unix * 1000).toLocaleDateString(lang());
}

function num(n: number, digits = 1): string {
  return n.toLocaleString(lang() === 'ru' ? 'ru-RU' : 'en-US', { maximumFractionDigits: digits, minimumFractionDigits: n < 10 && n % 1 ? digits : 0 });
}

const BIT_UNITS = { en: ['bit/s', 'kbit/s', 'Mbit/s', 'Gbit/s'], ru: ['бит/с', 'кбит/с', 'Мбит/с', 'Гбит/с'] };

/** bytes per second as bits, as speeds are usually given: 1 540 000 B/s → 12,3 Мбит/с */
export function speed(bytesPerSec: number): string {
  let v = bytesPerSec * 8, i = 0;
  while (v >= 1000 && i < 3) {
    v /= 1000;
    i++;
  }
  return `${num(v, i ? 1 : 0)} ${BIT_UNITS[lang()][i]}`;
}

export function ms(n: number): string {
  return lang() === 'ru' ? `${Math.round(n)} мс` : `${Math.round(n)} ms`;
}

/** download speed of a server in Mbit/s (#95): absent — not measured, negative — failed */
export function mbit(v: number | null | undefined): string {
  if (v == null)
    return '—';
  if (v < 0)
    return lang() === 'ru' ? 'ошибка' : 'failed';
  return `${num(v)} ${BIT_UNITS[lang()][2]}`;
}

/** latency of a server: absent — not tested yet, negative — the last test failed */
export function ping(latency: number | null | undefined): string {
  if (latency == null)
    return '—';
  if (latency < 0)
    return lang() === 'ru' ? 'нет ответа' : 'failed';
  return ms(latency);
}
