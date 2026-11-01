// The latest GitHub release with the router package (src-tauri/src/routerpkg.rs). The PC
// downloads it, not the router: the router needs no access to GitHub. Rust keeps the
// URLs; the web view names an asset of the last latest() and gets its bytes, checked
// against the sha256 the API gives. Tests and the stand put another source in place.

import { invokeRust } from './transport';

export interface ReleaseAsset {
  /** luci-app-xvpn_<version>_all.ipk, luci-i18n-xvpn-<lang>_<version>_all.ipk */
  name: string;
  size: number;
  /** the API gives its sha256; false: it is not downloaded (release_no_digest) */
  verified: boolean;
}

export interface Release {
  tag: string;
  /** the page of the release */
  url: string;
  /** the ipk assets of the package only */
  assets: ReleaseAsset[];
}

export interface ReleaseSource {
  latest(): Promise<Release>;
  /** an asset of the last latest(), base64 */
  download(name: string): Promise<string>;
}

export const githubRelease: ReleaseSource = {
  latest: () => invokeRust<Release>('pkg_latest'),
  download: (name) => invokeRust<string>('pkg_download', { name }),
};
