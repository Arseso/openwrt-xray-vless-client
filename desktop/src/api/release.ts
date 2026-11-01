// The latest GitHub release with the router package (src-tauri/src/routerpkg.rs). The PC
// downloads it, not the router: the router needs no access to GitHub. Rust keeps the
// URLs and checks the signature of SHA256SUMS (the key of the app updater); the web view
// names an asset of the last latest() and gets its bytes, checked against SHA256SUMS.
// Tests and the stand put another source in place.

import { invokeRust } from './transport';

export interface ReleaseAsset {
  /** luci-app-xvpn_<version>_all.ipk, luci-i18n-xvpn-<lang>_<version>_all.ipk */
  name: string;
  /** null: unknown (the release found without the GitHub API) */
  size: number | null;
  /** in the signed SHA256SUMS of the release; false: it is not downloaded (release_no_digest) */
  verified: boolean;
  /** from SHA256SUMS: the router checks the uploaded file against it before opkg */
  sha256: string | null;
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
