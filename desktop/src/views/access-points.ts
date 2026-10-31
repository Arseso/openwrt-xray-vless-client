// Tab «Точки доступа»: TODO(#79).

import { t } from '../i18n/access-points';
import { placeholder } from './placeholder';
import { registerView } from './registry';

registerView({
  id: 'access-points',
  order: 40,
  title: () => t('title'),
  mount(el) {
    placeholder(el, t('title'), 79);
  },
});
