// An XvpnError as a sentence for the user.

import { XvpnError, toXvpnError } from '../api/errors';
import { t } from '../i18n/common';

export function errorText(e: unknown): string {
  const err: XvpnError = toXvpnError(e);
  const d = err.detail;
  switch (err.code) {
  case 'http':
    return t('error.http', { status: d.status ?? '?' });
  case 'incompatible':
    return t('error.incompatible', {
      version: d.version ?? '?', api: d.api ?? '?', supported: d.supported ?? '?',
      what: (d.api ?? 0) > (d.supported ?? 0) ? t('what_app') : t('what_package'),
    });
  case 'ubus':
    return t('error.ubus', { message: err.message });
  default:
    return t(`error.${err.code}`);
  }
}
