// UCI over the rpcd object uci. Changes are staged in the session (set/add/delete) and
// take effect with apply: with rollback the router reverts them unless confirm() comes
// within timeout seconds — the safe way for settings that may cut the PC off (LuCI does
// the same). rpcd keeps the staged changes per session: a new login loses them.
// A new login loses them: the next call then fails with session_lost (src/api/ubus.ts).
// The ACL of luci-base (and so of a LuCI user) allows get, changes, set, add, delete,
// apply, confirm, rollback, but not revert and commit: a dedicated rpcd user of the app
// needs them in its ACL, or drops the staged changes with a new login instead.

import { UbusClient } from './ubus';

export type UciValue = string | string[];

/** a section as rpcd returns it: options plus .name, .type, .anonymous, .index */
export interface UciSection {
  '.name': string;
  '.type': string;
  '.anonymous': boolean;
  '.index'?: number;
  [option: string]: UciValue | boolean | number | undefined;
}

/** [operation, section, option?, value?] as uci changes lists them */
export type UciChange = [string, string, string?, UciValue?];

export class UciApi {
  constructor(readonly ubus: UbusClient) {}

  /** all sections of a config by name */
  async getAll(config: string): Promise<Record<string, UciSection>> {
    const r = await this.ubus.call<{ values?: Record<string, UciSection> }>('uci', 'get', { config });
    return r.values ?? {};
  }

  /** sections of one type (e.g. subscription) in order */
  async sections(config: string, type: string): Promise<UciSection[]> {
    const r = await this.ubus.call<{ values?: Record<string, UciSection> }>('uci', 'get', { config, type });
    return Object.values(r.values ?? {}).sort((a, b) => (a['.index'] ?? 0) - (b['.index'] ?? 0));
  }

  async getSection(config: string, section: string): Promise<UciSection | null> {
    try {
      const r = await this.ubus.call<{ values?: UciSection }>('uci', 'get', { config, section });
      return r.values ?? null;
    }
    catch (e) {
      if ((e as { code?: string }).code === 'no_object')
        return null;
      throw e;
    }
  }

  /** null when the option is not set */
  async get(config: string, section: string, option: string): Promise<UciValue | null> {
    try {
      const r = await this.ubus.call<{ value?: UciValue }>('uci', 'get', { config, section, option });
      return r.value ?? null;
    }
    catch (e) {
      // rpcd answers a missing section or option with UBUS_STATUS_NOT_FOUND
      if ((e as { code?: string }).code === 'no_object')
        return null;
      throw e;
    }
  }

  async set(config: string, section: string, values: Record<string, UciValue>): Promise<void> {
    await this.ubus.call('uci', 'set', { config, section, values });
    this.ubus.setStaged(true);
  }

  /** new section, returns its name */
  async add(config: string, type: string, values: Record<string, UciValue> = {}, name?: string): Promise<string> {
    const r = await this.ubus.call<{ section: string }>('uci', 'add', { config, type, values, ...(name ? { name } : {}) });
    this.ubus.setStaged(true);
    return r.section;
  }

  /** the section, or only options of it */
  async delete(config: string, section: string, options?: string[]): Promise<void> {
    await this.ubus.call('uci', 'delete', { config, section, ...(options ? { options } : {}) });
    this.ubus.setStaged(true);
  }

  async changes(config: string): Promise<UciChange[]> {
    const r = await this.ubus.call<{ changes?: UciChange[] }>('uci', 'changes', { config });
    return r.changes ?? [];
  }

  async revert(config: string): Promise<void> {
    await this.ubus.call('uci', 'revert', { config });
    this.ubus.setStaged(false);
  }

  /** commits without the rollback timer and without reloading services */
  async commit(config: string): Promise<void> {
    await this.ubus.call('uci', 'commit', { config });
    this.ubus.setStaged(false);
  }

  /** commits the staged changes of the session and reloads the services */
  async apply(opts: { rollback?: boolean; timeout?: number } = {}): Promise<void> {
    const rollback = opts.rollback ?? true;
    await this.ubus.call('uci', 'apply', { rollback, timeout: opts.timeout ?? 30 });
    // with rollback the router waits for confirm from this very session
    this.ubus.setStaged(rollback);
  }

  /** keeps the changes of apply({ rollback: true }) */
  async confirm(): Promise<void> {
    await this.ubus.call('uci', 'confirm', {});
    this.ubus.setStaged(false);
  }

  /** reverts apply({ rollback: true }) at once */
  async rollback(): Promise<void> {
    await this.ubus.call('uci', 'rollback', {});
    this.ubus.setStaged(false);
  }
}
