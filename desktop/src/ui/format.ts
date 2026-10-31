// Numbers for people: speeds in bits, sizes in bytes, with the decimal comma in Russian.

import { lang } from '../core/i18n';

function num(n: number, digits = 1): string {
  return n.toLocaleString(lang() === 'ru' ? 'ru-RU' : 'en-US', { maximumFractionDigits: digits, minimumFractionDigits: n < 10 && n % 1 ? digits : 0 });
}

const BIT_UNITS = { en: ['bit/s', 'kbit/s', 'Mbit/s', 'Gbit/s'], ru: ['бит/с', 'кбит/с', 'Мбит/с', 'Гбит/с'] };
const BYTE_UNITS = { en: ['B', 'KB', 'MB', 'GB', 'TB'], ru: ['Б', 'КБ', 'МБ', 'ГБ', 'ТБ'] };

/** bytes per second as bits: 1 540 000 B/s → 12,3 Мбит/с */
export function speed(bytesPerSec: number): string {
  let v = bytesPerSec * 8, i = 0;
  while (v >= 1000 && i < 3) {
    v /= 1000;
    i++;
  }
  return `${num(v, i ? 1 : 0)} ${BIT_UNITS[lang()][i]}`;
}

export function bytes(n: number): string {
  let v = n, i = 0;
  while (v >= 1024 && i < 4) {
    v /= 1024;
    i++;
  }
  return `${num(v, i ? 1 : 0)} ${BYTE_UNITS[lang()][i]}`;
}

export function ms(n: number): string {
  return lang() === 'ru' ? `${Math.round(n)} мс` : `${Math.round(n)} ms`;
}

/** latency of a server: absent — not tested yet, negative — the last test failed */
export function ping(latency: number | null | undefined): string {
  if (latency == null)
    return '—';
  if (latency < 0)
    return lang() === 'ru' ? 'нет ответа' : 'failed';
  return ms(latency);
}

/** 3725 → 1 h 2 min */
export function duration(sec: number): string {
  const ru = lang() === 'ru';
  const d = Math.floor(sec / 86400), h = Math.floor(sec % 86400 / 3600), m = Math.floor(sec % 3600 / 60);
  if (d)
    return ru ? `${d} д ${h} ч` : `${d} d ${h} h`;
  if (h)
    return ru ? `${h} ч ${m} мин` : `${h} h ${m} min`;
  if (m)
    return ru ? `${m} мин` : `${m} min`;
  return ru ? `${Math.max(0, Math.floor(sec))} с` : `${Math.max(0, Math.floor(sec))} s`;
}
