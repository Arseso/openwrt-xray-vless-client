// Updates of the app itself (src-tauri/src/updater.rs): latest.json of the latest GitHub
// release, the package checked against the public key of tauri.conf.json. The web view has
// these two commands only, not the plugin's own API.

import { invoke } from '@tauri-apps/api/core';

export interface Available {
  version: string;
  /** RFC 3339 */
  date: string | null;
  notes: string | null;
  /** false: a deb installation, updated with the deb of the release */
  installable: boolean;
}

export interface CheckResult {
  /** the running version */
  current: string;
  available: Available | null;
}

export interface UpdaterApi {
  check(): Promise<CheckResult>;
  /** downloads, checks, installs and restarts the app: only after the user agreed */
  install(version: string): Promise<void>;
}

export const tauriUpdater: UpdaterApi = {
  check: () => invoke<CheckResult>('updater_check'),
  install: (version) => invoke<void>('updater_install', { version }),
};
