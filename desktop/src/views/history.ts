// History tab: ping of the active server and the tunnel speed over the run of the app
// (src/core/history.ts), as SVG lines without a chart library. A null sample breaks the
// line (the router away, no measure).

import { Sample, historySource, onHistorySourceChange } from '../core/history';
import { t } from '../i18n/history';
import { h } from '../ui/dom';
import { registerView } from './registry';

const SVG = 'http://www.w3.org/2000/svg';
const W = 900, H = 180, PAD_L = 64, PAD_B = 20, PAD_T = 8;
const RANGES = [5, 15, 60, 0] as const; // minutes, 0: all

function svg<K extends keyof SVGElementTagNameMap>(tag: K, attrs: Record<string, string | number>, ...children: (SVGElement | string)[]): SVGElementTagNameMap[K] {
  const el = document.createElementNS(SVG, tag);
  for (const [k, v] of Object.entries(attrs))
    el.setAttribute(k, String(v));
  for (const c of children)
    el.append(c);
  return el;
}

/** 1, 2, 5 × 10^n not below v: a round top of the axis */
export function niceMax(v: number): number {
  if (!(v > 0))
    return 1;
  const p = 10 ** Math.floor(Math.log10(v));
  return ([1, 2, 5, 10].find((m) => m * p >= v) ?? 10) * p;
}

export function rate(bps: number): string {
  const units = ['B/s', 'KB/s', 'MB/s', 'GB/s'];
  let v = bps, i = 0;
  while (v >= 1000 && i < units.length - 1) {
    v /= 1000;
    i++;
  }
  return `${v >= 100 || i === 0 ? Math.round(v) : v.toFixed(1)} ${units[i]}`;
}

function clock(ms: number): string {
  return new Date(ms).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', second: '2-digit' });
}

/**
 * The "d" of a path: one M..L run per stretch of numbers between nulls; a lone point
 * becomes a dot (a zero-length segment with round caps)
 */
export function linePath(xs: number[], ys: (number | null)[]): string {
  let d = '';
  for (let i = 0; i < xs.length; i++) {
    const y = ys[i];
    if (y === null)
      continue;
    const open = i > 0 && ys[i - 1] !== null;
    d += `${open ? 'L' : 'M'}${xs[i].toFixed(1)},${y.toFixed(1)}`;
    if (!open && (i === xs.length - 1 || ys[i + 1] === null))
      d += 'h0';
  }
  return d;
}

interface Series {
  label: string;
  cls: string;
  values: (number | null)[];
}

function chart(samples: readonly Sample[], series: Series[], fmt: (v: number) => string, from: number, to: number): SVGSVGElement {
  const all = series.flatMap((s) => s.values).filter((v): v is number => v !== null);
  const top = niceMax(Math.max(0, ...all));
  const span = Math.max(1, to - from);
  const x = (at: number) => PAD_L + (at - from) / span * (W - PAD_L - 4);
  const y = (v: number) => PAD_T + (1 - v / top) * (H - PAD_T - PAD_B);
  const xs = samples.map((s) => x(s.at));
  const grid = [0, 0.5, 1].map((f) => {
    const gy = y(top * f);
    return [
      svg('line', { x1: PAD_L, x2: W - 4, y1: gy, y2: gy, class: 'grid' }),
      svg('text', { x: PAD_L - 6, y: gy + 4, 'text-anchor': 'end', class: 'axis' }, fmt(top * f)),
    ];
  }).flat();
  return svg('svg', { viewBox: `0 0 ${W} ${H}`, class: 'chart', role: 'img' },
    ...grid,
    svg('text', { x: PAD_L, y: H - 4, class: 'axis' }, clock(from)),
    svg('text', { x: W - 4, y: H - 4, 'text-anchor': 'end', class: 'axis' }, clock(to)),
    ...series.map((s) => svg('path', { d: linePath(xs, s.values.map((v) => (v === null ? null : y(v)))), class: `line ${s.cls}` },
      svg('title', {}, s.label))));
}

/** the newest value; none while the newest sample is a gap (the router away) */
export function last(values: (number | null)[]): number | null {
  return values.length ? values[values.length - 1] : null;
}

registerView({
  id: 'history',
  order: 70,
  title: () => t('title'),
  mount(el) {
    let range: number = 15;
    let pending = false;
    const body = h('div');
    const select = h('select', {
      onchange: (e: Event) => {
        range = Number((e.target as HTMLSelectElement).value);
        render();
      },
    }, RANGES.map((m) => h('option', { value: m, selected: m === range }, m ? t('range_min', { n: m }) : t('range_all'))));
    el.replaceChildren(h('section', { class: 'history' },
      h('h2', {}, t('title')),
      h('p', { class: 'muted' }, t('hint'), ' ', select),
      body));

    const legend = (s: Series, fmt: (v: number) => string) => {
      const v = last(s.values);
      return h('span', { class: `legend ${s.cls}` }, `${s.label}: ${v === null ? '—' : fmt(v)}`);
    };

    const render = () => {
      pending = false;
      const all = historySource().samples();
      const to = all.length ? all[all.length - 1].at : Date.now();
      const from = range ? to - range * 60_000 : (all[0]?.at ?? to);
      const samples = all.filter((s) => s.at >= from && s.at <= to);
      if (!samples.length) {
        body.replaceChildren(h('p', { class: 'muted' }, t('empty')));
        return;
      }
      const ms = (v: number) => `${Math.round(v)} ${t('ms')}`;
      const ping: Series = { label: t('ping'), cls: 'series-ping', values: samples.map((s) => s.ping) };
      const down: Series = { label: t('down'), cls: 'series-down', values: samples.map((s) => s.down) };
      const up: Series = { label: t('up'), cls: 'series-up', values: samples.map((s) => s.up) };
      body.replaceChildren(
        h('div', { class: 'card' },
          h('h3', {}, t('ping_title'), ' ', legend(ping, ms)),
          chart(samples, [ping], ms, from, to)),
        h('div', { class: 'card' },
          h('h3', {}, t('speed_title'), ' ', legend(down, rate), ' ', legend(up, rate)),
          chart(samples, [down, up], rate, from, to)));
    };

    // at most one redraw per frame, whatever the poll interval
    const later = () => {
      if (!pending) {
        pending = true;
        requestAnimationFrame(render);
      }
    };
    let off = historySource().subscribe(later);
    const offSource = onHistorySourceChange(() => {
      off();
      off = historySource().subscribe(later);
      render();
    });
    render();
    return () => {
      off();
      offSource();
    };
  },
});
