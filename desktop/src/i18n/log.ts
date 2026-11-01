// Strings of the tab «Журнал» (src/views/log.ts).

import { strings } from '../core/i18n';

export const t = strings({
  en: {
    title: 'Log',
    intro: 'The last lines of the system log from the xvpn service, its daemon and xray. The log level of xray is set in the Settings tab.',
    filter: 'Filter, or /regex/',
    all_sources: 'xvpn and xray',
    errors_only: 'Errors only',
    auto: 'Refresh every {s} s',
    refresh: 'Refresh',
    copy: 'Copy',
    copied: 'Copied {n} lines.',
    count: '{n} of {total} lines',
    empty: 'The log has no lines of xvpn or xray.',
    diagnostics: 'Save diagnostics…',
    collecting: 'Collecting the diagnostics…',
    saved: 'Diagnostics saved: versions, status, firewall, config and log, without passwords, share links and subscription URLs.',
    save_failed: 'Could not save the diagnostics: {error}',
  },
  ru: {
    title: 'Журнал',
    intro: 'Последние строки системного журнала службы xvpn, её демона и xray. Уровень журнала xray задаётся на вкладке «Настройки».',
    filter: 'Фильтр или /regex/',
    all_sources: 'xvpn и xray',
    errors_only: 'Только ошибки',
    auto: 'Обновлять каждые {s} с',
    refresh: 'Обновить',
    copy: 'Копировать',
    copied: 'Скопировано строк: {n}.',
    count: '{n} из {total} строк',
    empty: 'В журнале нет строк xvpn или xray.',
    diagnostics: 'Сохранить диагностику…',
    collecting: 'Собираем диагностику…',
    saved: 'Диагностика сохранена: версии, статус, firewall, конфигурация и журнал — без паролей, ссылок серверов и URL подписок.',
    save_failed: 'Не удалось сохранить диагностику: {error}',
  },
});
