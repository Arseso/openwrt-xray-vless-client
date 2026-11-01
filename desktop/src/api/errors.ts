// Errors of the router connection. Each has a code the UI turns into a message with
// t(`error.${code}`) (src/i18n/common.ts), so a screen never shows a raw ubus status.

export type ErrorCode =
  // transport (Rust, src-tauri/src/transport.rs)
  | 'unreachable' // no connection: wrong address, router off or rebooting
  | 'timeout' // no answer in time
  | 'tls_unknown' // first HTTPS connection: the certificate is not pinned yet (fingerprint)
  | 'tls_changed' // the certificate differs from the pinned one (fingerprint, pinned)
  | 'tls' // another TLS failure
  | 'http' // HTTP status other than 200 (status)
  | 'bad_response' // not a JSON-RPC answer: not uhttpd /ubus there
  | 'no_password' // the profile has no stored password
  | 'keyring' // the system credential store failed
  | 'no_profile'
  | 'invalid_url'
  // ubus
  | 'wrong_password'
  | 'acl' // access denied with a live session: the user has no rights for the call
  | 'session_lost' // a new login dropped staged UCI changes / the pending confirm
  | 'no_package' // there is no luci.xvpn object: luci-app-xvpn is not installed
  | 'old_package' // luci-app-xvpn without the method version: too old for this app
  | 'incompatible' // luci.xvpn version answers another api (detail.api)
  | 'no_method' // ubus status 3
  | 'no_object' // ubus status 4 / JSON-RPC -32000
  | 'invalid_argument' // ubus status 2
  | 'ubus' // any other ubus status (detail.ubusStatus)
  // the router package from the GitHub release (src-tauri/src/routerpkg.rs, src/core/routerpkg.ts)
  | 'release_unreachable' // no connection to GitHub from this PC
  | 'release_http' // GitHub answered another HTTP status (status)
  | 'release_rate_limit' // the anonymous API limit of GitHub (60 an hour)
  | 'release_bad' // not a release in the API answer
  | 'release_no_asset' // the release has no luci-app-xvpn ipk
  | 'release_unsigned' // the release has no SHA256SUMS with its signature
  | 'release_signature' // SHA256SUMS is not signed with the key built into the app
  | 'release_no_digest' // the asset is not in SHA256SUMS: it is not installed
  | 'release_digest' // the downloaded file differs from SHA256SUMS (or from the API digest)
  | 'release_too_big' // the asset is larger than the limit or than the API said
  | 'need_root' // the session may not install packages: log in as root
  | 'pkg_unsupported' // the router has no opkg (apk) or no way to install
  | 'pkg_busy' // another install is running on the router
  | 'pkg_failed' // opkg failed (detail.output)
  | 'pkg_lost'; // the router did not come back with the new version in time

export interface ErrorDetail {
  /** SHA-256 of the certificate the router presented, AA:BB:... */
  fingerprint?: string;
  /** the pinned one, for tls_changed */
  pinned?: string;
  /** HTTP status */
  status?: number;
  ubusStatus?: number;
  /** JSON-RPC error code of uhttpd */
  rpcCode?: number;
  object?: string;
  method?: string;
  /** incompatible / old_package */
  version?: string;
  api?: number;
  supported?: number;
  /** pkg_failed: the end of the opkg output */
  output?: string;
}

export class XvpnError extends Error {
  readonly code: ErrorCode;
  readonly detail: ErrorDetail;

  constructor(code: ErrorCode, message?: string, detail: ErrorDetail = {}) {
    super(message ?? code);
    this.name = 'XvpnError';
    this.code = code;
    this.detail = detail;
  }

  /** the router does not answer at all: the poller reports it as router-down */
  get offline(): boolean {
    return this.code === 'unreachable' || this.code === 'timeout';
  }
}

export function isXvpnError(e: unknown, ...codes: ErrorCode[]): e is XvpnError {
  return e instanceof XvpnError && (codes.length === 0 || codes.includes(e.code));
}

/** any thrown value as XvpnError (a bug in the app shows up as ubus with its message) */
export function toXvpnError(e: unknown): XvpnError {
  if (e instanceof XvpnError)
    return e;
  return new XvpnError('ubus', e instanceof Error ? e.message : String(e));
}
