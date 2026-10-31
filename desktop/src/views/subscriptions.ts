// Tab «Подписки»: TODO(#79).

import { t } from '../i18n/subscriptions';
import { placeholder } from './placeholder';
import { registerView } from './registry';

registerView({
  id: 'subscriptions',
  order: 30,
  title: () => t('title'),
  mount(el) {
    placeholder(el, t('title'), 79);
  },
});
