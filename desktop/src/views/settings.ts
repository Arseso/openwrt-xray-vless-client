// Tab «Настройки»: TODO(#79).

import { t } from '../i18n/settings';
import { placeholder } from './placeholder';
import { registerView } from './registry';

registerView({
  id: 'settings',
  order: 50,
  title: () => t('title'),
  mount(el) {
    placeholder(el, t('title'), 79);
  },
});
