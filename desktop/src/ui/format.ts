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
