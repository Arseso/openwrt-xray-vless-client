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
    deb: 'This installation (deb) is not updated by the app: install the deb of the release.',
    confirm: 'Download version {version}, install it and restart the app?',
    yes: 'Install and restart',
    cancel: 'Cancel',
    installing: 'Downloading and installing {version}… the app restarts when it is done.',
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
    deb: 'Установка из deb не обновляется приложением: поставьте deb из релиза.',
    confirm: 'Скачать версию {version}, установить и перезапустить приложение?',
    yes: 'Установить и перезапустить',
    cancel: 'Отмена',
    installing: 'Скачивание и установка {version}… приложение перезапустится само.',
    error: 'Не удалось обновить: {message}',
  },
});
