import { describe, expect, it } from 'vitest';
import { Status } from '../../src/api/xvpn';
import { LiveHistory, Ring, Sample, sampleOf } from '../../src/core/history';
import { last, linePath, niceMax, rate } from '../../src/views/history';
import { STATUS_UP } from './fake';

describe('history', () => {
  it('the ring keeps the newest, oldest first', () => {
    const r = new Ring<number>(3);
    for (let i = 1; i <= 5; i++)
      r.push(i);
    expect(r.toArray()).toEqual([3, 4, 5]);
    expect(r.size).toBe(3);
    r.clear();
    expect(r.toArray()).toEqual([]);
  });

  it('samples ping of the active server and the speed', () => {
    expect(sampleOf({ ...STATUS_UP, speed: { up: 10, down: 20 } } as unknown as Status, 5)).toEqual({ at: 5, ping: 40, up: 10, down: 20 });
    expect(sampleOf({ ...STATUS_UP, speed: null } as unknown as Status, 5)).toEqual({ at: 5, ping: 40, up: null, down: null });
    expect(sampleOf({ enabled: true, time: 1, running: false, timeout: false }, 5).ping).toBeNull();
  });

  it('another profile starts over', () => {
    const h = new LiveHistory(10);
    const got: (Sample | null)[] = [];
    h.subscribe((s) => got.push(s));
    const s = (at: number): Sample => ({ at, ping: 1, up: null, down: null });
    h.add('a', s(1));
    h.add('a', s(2));
    h.add('b', s(3));
    expect(h.samples().map((x) => x.at)).toEqual([3]);
    expect(got.map((x) => x?.at ?? null)).toEqual([1, 2, null, 3]);
  });

  it('the PC clock set back starts over', () => {
    const h = new LiveHistory(10);
    const s = (at: number): Sample => ({ at, ping: 1, up: null, down: null });
    h.add('a', s(100));
    h.add('a', s(200));
    h.add('a', s(50));
    expect(h.samples().map((x) => x.at)).toEqual([50]);
  });

  it('draws lines with gaps and round axes', () => {
    // a lone point is a dot
    expect(linePath([0, 1, 2, 3], [1, null, 2, 3])).toBe('M0.0,1.0h0M2.0,2.0L3.0,3.0');
    expect(linePath([0, 1, 2], [null, 5, null])).toBe('M1.0,5.0h0');
    expect(last([1, 2, null])).toBeNull();
    expect(last([1, 2])).toBe(2);
    expect(niceMax(0)).toBe(1);
    expect(niceMax(37)).toBe(50);
    expect(niceMax(120)).toBe(200);
    expect(rate(512)).toBe('512 B/s');
    expect(rate(1_500_000)).toBe('1.5 MB/s');
  });
});
