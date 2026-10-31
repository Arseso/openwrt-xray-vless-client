// Tab «Серверы»: TODO(#78).

import { t } from '../i18n/servers';
import { placeholder } from './placeholder';
import { registerView } from './registry';

registerView({
  id: 'servers',
  order: 20,
  title: () => t('title'),
  mount(el) {
    placeholder(el, t('title'), 78);
  },
});
