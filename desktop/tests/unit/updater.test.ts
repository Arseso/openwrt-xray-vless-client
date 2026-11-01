import { describe, expect, it, vi } from 'vitest';
import { Available, UpdaterApi } from '../../src/api/updater';
import { UpdateFlow } from '../../src/core/updater';

const UPDATE: Available = { version: '0.2.0', date: null, notes: 'fixes', installable: true };

function api(available: Available | null = UPDATE): UpdaterApi & { install: ReturnType<typeof vi.fn> } {
  return { check: vi.fn(async () => ({ current: '0.1.0', available })), install: vi.fn(async () => {}) };
}

describe('UpdateFlow', () => {
  it('checks only when asked and reports the latest version', async () => {
    const a = api(null), f = new UpdateFlow(a);
    expect(a.check).not.toHaveBeenCalled();
    await f.check();
    expect(f.get()).toEqual({ phase: 'latest', current: '0.1.0' });
  });

  it('installs nothing before a check, then only the version shown, in the app language', async () => {
    const a = api(), f = new UpdateFlow(a);
    await f.install('ru');
    expect(a.install).not.toHaveBeenCalled();
    await f.check();
    await f.install('ru');
    expect(a.install).toHaveBeenCalledExactlyOnceWith('0.2.0', 'ru');
    expect(f.get().phase).toBe('installing');
  });

  it('a «no» in the native dialog brings the update back', async () => {
    const a = api();
    a.install = vi.fn(async () => { throw 'cancelled'; });
    const f = new UpdateFlow(a);
    await f.check();
    await f.install('en');
    expect(f.get()).toMatchObject({ phase: 'available', update: UPDATE });
  });

  it('an installation the app cannot update is not installed', async () => {
    const a = api({ ...UPDATE, installable: false }), f = new UpdateFlow(a);
    await f.check();
    await f.install('en');
    expect(a.install).not.toHaveBeenCalled();
    expect(f.get().phase).toBe('available');
  });

  it('errors of the check and the install are shown', async () => {
    const a = api();
    a.check = vi.fn(async () => { throw new Error('offline'); });
    const f = new UpdateFlow(a);
    await f.check();
    expect(f.get()).toEqual({ phase: 'error', message: 'offline' });
    const b = api();
    b.install = vi.fn(async () => { throw 'bad signature'; });
    const g = new UpdateFlow(b);
    await g.check();
    await g.install('en');
    expect(g.get()).toEqual({ phase: 'error', message: 'bad signature' });
  });
});
