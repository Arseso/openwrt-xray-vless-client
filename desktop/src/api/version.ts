// What luci-app-xvpn the router has and whether this app can work with it. Checked once
// after connecting (and after the router comes back): an incompatible package gets one
// clear message instead of failing calls on every screen.

import { XvpnError, isXvpnError } from './errors';
import { OBJECT, XvpnApi } from './xvpn';

/** the luci.xvpn API generation this app speaks; raised by the plugin on breaking changes */
export const SUPPORTED_API = 1;

export interface PackageInfo {
  /** PKG_VERSION-rPKG_RELEASE */
  version: string;
  api: number;
}

/**
 * The package info, or XvpnError: no_package (no luci.xvpn on ubus), old_package (no
 * method version: older than the desktop app), incompatible (another api), acl (the
 * user may not call luci.xvpn), or a transport error.
 */
export async function checkPackage(api: XvpnApi): Promise<PackageInfo> {
  let v;
  try {
    v = await api.version();
  }
  catch (e) {
    // an old ACL does not list version (access denied), an old plugin has no such method
    if (!isXvpnError(e, 'acl', 'no_method', 'no_object'))
      throw e;
    throw await whyNoVersion(api, e);
  }
  if (typeof v?.version !== 'string' || typeof v?.api !== 'number')
    throw new XvpnError('bad_response', 'luci.xvpn version: unexpected answer');
  if (v.api !== SUPPORTED_API)
    throw new XvpnError('incompatible', `luci.xvpn api ${v.api}, the app supports ${SUPPORTED_API}`,
      { version: v.version, api: v.api, supported: SUPPORTED_API });
  return { version: v.version, api: v.api };
}

async function whyNoVersion(api: XvpnApi, cause: XvpnError): Promise<XvpnError> {
  let objects;
  try {
    objects = await api.ubus.list(OBJECT);
  }
  catch {
    objects = null;
  }
  if (objects && !(OBJECT in objects))
    return new XvpnError('no_package', 'luci-app-xvpn is not installed (no luci.xvpn on ubus)');
  // the object is there: an old package if its other methods work
  try {
    await api.status();
  }
  catch (e) {
    if (isXvpnError(e, 'acl'))
      return e;
    if (isXvpnError(e, 'no_object'))
      return new XvpnError('no_package', 'luci-app-xvpn is not installed (no luci.xvpn on ubus)');
    if (!objects)
      return cause;
    throw e;
  }
  return new XvpnError('old_package', 'luci-app-xvpn on the router is older than this app (no luci.xvpn version)',
    { supported: SUPPORTED_API });
}
