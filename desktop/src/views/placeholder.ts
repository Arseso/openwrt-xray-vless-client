// Body of a tab that is not written yet.

import { h } from '../ui/dom';
import { t } from '../i18n/common';

export function placeholder(el: HTMLElement, title: string, issue: number): void {
  el.replaceChildren(h('section', { class: 'placeholder' },
    h('h2', {}, title),
    h('p', { class: 'muted' }, `${t('soon')} (#${issue})`)));
}
