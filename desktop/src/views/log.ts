// Tab «Журнал»: TODO(#79).

import { t } from '../i18n/log';
import { placeholder } from './placeholder';
import { registerView } from './registry';

registerView({
  id: 'log',
  order: 60,
  title: () => t('title'),
  mount(el) {
    placeholder(el, t('title'), 79);
  },
});
