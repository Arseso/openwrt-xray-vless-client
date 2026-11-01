import { afterEach, describe, expect, it } from 'vitest';
import { setLang } from '../../src/core/i18n';
import { bytes, dur, ms, speed } from '../../src/ui/format';
import { matches } from '../../src/views/servers';
import { STATUS_UP } from './fake';

describe('format', () => {
  afterEach(() => setLang('en'));

  it('speeds in bits, sizes in bytes', () => {
    setLang('en');
    expect(speed(1_540_000)).toBe('12.3 Mbit/s');
    expect(speed(0)).toBe('0 bit/s');
    expect(bytes(1536)).toBe('1.50 KiB');
    expect(ms(40.4)).toBe('40 ms');
    expect(dur(3725)).toBe('1h 2m');
    setLang('ru');
    expect(speed(137_500)).toBe('1,1 Мбит/с');
    expect(dur(90061)).toBe('1 д 1 ч');
  });

  it('server filter by words', () => {
    const s = { ...STATUS_UP.servers[0], sub_name: 'Test subscription' };
    expect(matches(s, '')).toBe(true);
    expect(matches(s, 'a vless')).toBe(true);
    expect(matches(s, 'test 1.1.1.1:443')).toBe(true);
    expect(matches(s, 'trojan')).toBe(false);
  });
});
