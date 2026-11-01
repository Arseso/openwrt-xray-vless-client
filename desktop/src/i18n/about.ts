// Strings of the tab «О программе» (src/views/about.ts).

import { strings } from '../core/i18n';

export const t = strings({
  en: {
    title: 'About',
    app: 'App version',
    package: 'luci-app-xvpn on the router',
    check: 'Check for updates',
    checking: 'Checking…',
    latest: 'This is the latest version ({current}).',
    available: 'Version {version} is available (this one is {current}).',
    install: 'Install…',
    manual: 'This installation is not updated by the app: install the package of the release.',
    installing: 'Version {version}: answer the question of the app; it downloads, installs and restarts then.',
    error: 'Update failed: {message}',
  },
  ru: {
    title: 'О программе',
    app: 'Версия приложения',
    package: 'luci-app-xvpn на роутере',
    check: 'Проверить обновления',
    checking: 'Проверка…',
    latest: 'Установлена последняя версия ({current}).',
    available: 'Доступна версия {version} (сейчас {current}).',
    install: 'Установить…',
    manual: 'Эта установка не обновляется приложением: поставьте пакет из релиза.',
    installing: 'Версия {version}: ответьте на вопрос приложения, после этого оно скачает её, установит и перезапустится.',
    error: 'Не удалось обновить: {message}',
  },
});
