// Updates of the app itself (src-tauri/src/updater.rs): latest.json of the latest GitHub
// release, the package checked against the public key of tauri.conf.json. The web view has
// these two commands only, not the plugin's own API; install asks the user in a native
// dialog of its own.

import { invoke } from '@tauri-apps/api/core';
import { Lang } from '../core/i18n';

export interface Available {
  version: string;
  /** RFC 3339 */
  date: string | null;
  notes: string | null;
  /** false: this installation (an MSI built by hand, an rpm) takes the package of the release */
  installable: boolean;
}

export interface CheckResult {
  /** the running version */
  current: string;
  available: Available | null;
}

export interface UpdaterApi {
  check(): Promise<CheckResult>;
  /**
   * asks the user in a native dialog (in lang), then downloads, checks, installs and
   * restarts the app; rejects with "cancelled" when the user said no
   */
  install(version: string, lang: Lang): Promise<void>;
}

export const tauriUpdater: UpdaterApi = {
  check: () => invoke<CheckResult>('updater_check'),
  install: (version, lang) => invoke<void>('updater_install', { version, lang }),
};
