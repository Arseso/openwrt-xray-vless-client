// Router profiles (src-tauri/src/profiles.rs): kept in profiles.json of the app config
// directory; the password of each is in the system credential store (Windows Credential
// Manager, Secret Service on Linux), or in memory for this run only (remember: false).

import { invokeRust } from './transport';

export interface Profile {
  id: string;
  name: string;
  /** http(s)://host[:port], without /ubus */
  url: string;
  username: string;
  /** SHA-256 of the pinned uhttpd certificate (AA:BB:...), HTTPS only */
  fingerprint?: string | null;
}

export function listProfiles(): Promise<Profile[]> {
  return invokeRust('profiles_list');
}

/** adds or replaces by id; returns the profile as stored (normalized url) */
export function saveProfile(profile: Profile): Promise<Profile> {
  return invokeRust('profile_save', { profile });
}

/** also forgets its password */
export function deleteProfile(id: string): Promise<void> {
  return invokeRust('profile_delete', { id });
}

export function setPassword(id: string, password: string, remember = true): Promise<void> {
  return invokeRust('profile_set_password', { id, password, remember });
}

export function hasPassword(id: string): Promise<boolean> {
  return invokeRust('profile_has_password', { id });
}

/** pins the certificate the router presented (the fingerprint of tls_unknown/tls_changed) */
export function trustCertificate(id: string, fingerprint: string): Promise<Profile> {
  return invokeRust('profile_trust', { id, fingerprint });
}

/** default IPv4 gateway of the PC: the router address a new profile starts with */
export function defaultGateway(): Promise<string | null> {
  return invokeRust('default_gateway');
}

export function newProfileId(): string {
  return crypto.randomUUID();
}

const LAST = 'xvpn.lastProfile';

export function lastProfileId(): string | null {
  try {
    return localStorage.getItem(LAST);
  }
  catch {
    return null;
  }
}

export function setLastProfileId(id: string | null): void {
  try {
    if (id)
      localStorage.setItem(LAST, id);
    else
      localStorage.removeItem(LAST);
  }
  catch {
    // not remembered
  }
}
