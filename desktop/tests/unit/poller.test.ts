import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { XvpnError } from '../../src/api/errors';
import { Status, StatusUp } from '../../src/api/xvpn';
import { Bus } from '../../src/core/bus';
import { PollerEvents, StatusPoller, changed } from '../../src/core/poller';
import { STATUS_UP } from './fake';

const up = (patch: Partial<StatusUp> = {}) => ({ ...STATUS_UP, ...patch }) as StatusUp;

function setup(answers: (Status | XvpnError)[]) {
  const bus = new Bus<PollerEvents>();
  const events: [string, unknown][] = [];
  for (const k of ['status', 'state-change', 'poll-error', 'router-down', 'router-up'] as const)
    bus.on(k, (p) => events.push([k, p]));
  let i = 0;
  const source = {
    status: vi.fn(async () => {
      const a = answers[Math.min(i++, answers.length - 1)];
      if (a instanceof XvpnError)
        throw a;
      return a;
    }),
  };
  const poller = new StatusPoller(source, bus, { intervalMs: 1000, downAfter: 2 });
  const names = () => events.map(([k]) => k);
  return { poller, source, events, names };
}

describe('StatusPoller', () => {
  beforeEach(() => vi.useFakeTimers());
  afterEach(() => vi.useRealTimers());

  it('polls every interval without overlap and emits state-change on changes only', async () => {
    const { poller, source, names } = setup([up(), up({ time: 2000 }), up({ state: 'failover' })]);
    poller.start();
    await vi.advanceTimersByTimeAsync(0);
    await vi.advanceTimersByTimeAsync(1000);
    await vi.advanceTimersByTimeAsync(1000);
    poller.stop();
    await vi.advanceTimersByTimeAsync(5000);
    expect(source.status).toHaveBeenCalledTimes(3);
    expect(names()).toEqual(['status', 'state-change', 'status', 'status', 'state-change']);
  });

  it('router-down after downAfter offline failures, router-up when it answers', async () => {
    const off = new XvpnError('unreachable');
    const { poller, names, events } = setup([up(), off, off, off, up()]);
    poller.start();
    for (let k = 0; k < 5; k++)
      await vi.advanceTimersByTimeAsync(k ? 1000 : 0);
    poller.stop();
    expect(names()).toEqual([
      'status', 'state-change', 'poll-error', 'poll-error', 'router-down', 'poll-error', 'router-up', 'status',
    ]);
    expect(events.find(([k]) => k === 'router-up')![1]).toEqual({ downForMs: 2000 });
  });

  it('other errors are poll-error only', async () => {
    const { poller, names } = setup([new XvpnError('acl'), new XvpnError('acl'), new XvpnError('acl')]);
    poller.start();
    for (let k = 0; k < 3; k++)
      await vi.advanceTimersByTimeAsync(k ? 1000 : 0);
    poller.stop();
    expect(names()).toEqual(['poll-error', 'poll-error', 'poll-error']);
    expect(poller.down).toBe(false);
  });

  it('refresh polls at once and restarts the interval', async () => {
    const { poller, source } = setup([up()]);
    poller.start();
    await vi.advanceTimersByTimeAsync(500);
    await poller.refresh();
    expect(source.status).toHaveBeenCalledTimes(2);
    await vi.advanceTimersByTimeAsync(900);
    expect(source.status).toHaveBeenCalledTimes(2);
    await vi.advanceTimersByTimeAsync(100);
    expect(source.status).toHaveBeenCalledTimes(3);
    poller.stop();
  });
});

describe('changed', () => {
  const down = { enabled: true, time: 1, running: false, timeout: false } as const;
  it.each<[string, Status, Status, boolean]>([
    ['clock and latency', up(), up({ time: 5, fails: 3 }), false],
    ['state', up(), up({ state: 'degraded' }), true],
    ['active server', up(), up({ active: 'b' }), true],
    ['passthrough', up(), up({ passthrough: true }), true],
    ['daemon stops', up(), down, true],
    ['daemon busy', down, { ...down, timeout: true }, true],
    ['disabled', down, { ...down, enabled: false }, true],
    ['still down', down, { ...down, time: 9 }, false],
  ])('%s', (_, a, b, want) => expect(changed(a, b)).toBe(want));
});
