# xvpn desktop

Пульт управления luci-app-xvpn для Windows и Linux (эпик #82). Своего туннеля на ПК
нет: приложение ходит к роутеру через uhttpd `/ubus` (JSON-RPC) и rpcd-объект
`luci.xvpn`, как вкладки LuCI.

## Стек

- **Tauri 2** (Rust) — окно, HTTP(S) к роутеру, закрепление сертификата, пароли в
  системном хранилище, трей и уведомления.
- **TypeScript + Vite без фреймворка** (vanilla TS). Экранов немного, состояние живёт
  в общем поллере и шине событий, а не в дереве компонентов; DOM строится хелпером
  `h()` (`src/ui/dom.ts`), строки всегда как текст, не HTML — имена серверов приходят
  с роутера. Фреймворк не тянем, пока он не нужен: меньше бандл и меньше зависимостей
  для релизов.
- **vitest** — unit-тесты клиента с подменой транспорта; `cargo test` — пиннинг и транспорт.

## Структура

```
desktop/
  src/
    main.ts            вход: startApp(#app, connection)
    app.ts             оболочка: шапка, вкладки из реестра, хэш-роутер #/<id>
    api/               клиент роутера, без DOM
      transport.ts     Transport (интерфейс) и TauriTransport (команды Rust)
      ubus.ts          UbusClient: session login, повторный вход, коды ubus → ErrorCode
      errors.ts        XvpnError с code (unreachable, wrong_password, acl, no_package ...)
      xvpn.ts          типы и вызовы luci.xvpn (status, servers, ... split_update, version)
      uci.ts           uci get/set/add/delete/changes/revert/commit/apply/confirm/rollback
      version.ts       checkPackage(): версия пакета и совместимость API
      profiles.ts      профили роутеров (команды Rust)
      updater.ts       обновление приложения (команды updater_*)
    core/
      bus.ts           типизированная шина событий
      store.ts         наблюдаемый стор
      poller.ts        общий поллер status
      connection.ts    подключение к профилю: фазы, AppContext для вкладок
      i18n.ts          strings({ en, ru }), lang(), setLang()
      updater.ts       UpdateFlow: проверка по кнопке, установка после подтверждения
    i18n/<name>.ts     словари RU/EN: один файл на вкладку (+ common, connect, tray, notifications)
    views/
      registry.ts      registerView(), интерфейс View
      index.ts         по строке import на вкладку
      <name>.ts        вкладка: status, servers, subscriptions, access-points, settings, log
      connect.ts       экран роутеров и решений о сертификате (не вкладка)
      about.ts         «О программе»: версии, обновление приложения (#81)
    ui/                dom.ts (h, clear), errors.ts (errorText)
  src-tauri/src/
    lib.rs             сборка приложения, маршрутизация команд по префиксу
    commands.rs        команды ядра: ubus_request, ubus_login, profile_*, default_gateway
    transport.rs       HTTP(S) к /ubus, таймауты, клиент на профиль
    pin.rs             TOFU: проверка SHA-256 сертификата uhttpd
    profiles.rs        profiles.json + keyring
    gateway.rs         шлюз по умолчанию (Linux /proc/net/route, Windows route print)
    tray.rs            трей — TODO(#78)
    notifications.rs   уведомления — TODO(#80)
    updater.rs         обновление приложения: tauri-plugin-updater (#81)
  tests/unit/          vitest, фейковый роутер (fake.ts)
  tests/stand/         тот же клиент против стенда scripts/luci.sh
  docker/Dockerfile    окружение сборки: Linux и кросс-сборка Windows (cargo-xwin, NSIS)
```

## Контракты для вкладок, трея и уведомлений

### Вкладка

Модуль `src/views/<name>.ts` регистрирует себя, в `src/views/index.ts` — одна строка
`import './<name>';`. Строки — в `src/i18n/<name>.ts`.

```ts
registerView({
  id: 'servers',            // хэш #/servers
  order: 20,                // место в панели вкладок
  title: () => t('title'),
  mount(el, ctx) {          // при каждом открытии, после смены профиля или языка
    const off = ctx.bus.on('status', ({ status }) => render(status));
    return () => off();     // очистка при закрытии
  },
});
```

`ctx: AppContext` — `profile`, `pkg` (версия пакета), `xvpn` (`XvpnApi`), `uci`
(`UciApi`), `ubus`, `poller`, `bus`. Контекст живёт до смены профиля; после неё
вкладка монтируется заново с новым.

### Поллер и шина

Один `StatusPoller` на приложение: `luci.xvpn status` раз в `interval` мс (3 с),
запросы не перекрываются. Сами вкладки status не опрашивают — подписываются:

| событие         | данные                       | когда |
|-----------------|------------------------------|-------|
| `status`        | `{ status, at }`             | каждый ответ |
| `state-change`  | `{ prev, next }`             | первый ответ и смена running / enabled / state / active / passthrough |
| `poll-error`    | `{ error, failures }`        | каждый неудачный опрос |
| `router-down`   | `{ error, since }`           | 2 подряд «роутер не отвечает» (unreachable / timeout), один раз |
| `router-up`     | `{ downForMs }`              | первый ответ после router-down |
| `connection`    | `ConnectionState`            | смена фазы подключения |

`connection.bus` (`src/core/connection.ts`) живёт всё время работы приложения, через
смены профиля: трей (#78) и уведомления (#80) подписываются на него один раз при
старте. `ctx.poller.status` — последний ответ, `ctx.poller.refresh()` — опросить сразу
(после `select`, `service` ...), `ctx.poller.setInterval(ms)`.

После `stop()` поллер ничего не пишет в шину, даже ответ запроса, который был в пути
(старый профиль при переключении). `refresh()` во время опроса ждёт его и опрашивает
ещё раз; сколько бы `refresh()` ни пришло, это один дополнительный опрос, параллельно
никогда не идут два.

Фазы подключения: `disconnected` → `connecting` → `online`; `offline` — роутер не
отвечает (при старте подключение повторяется само, после online поллер продолжает и
возвращает online; после возврата пакет проверяется заново); `failed` — нужно действие
пользователя, без повторов. В `failed` переходит и работающее подключение, если опрос
получил ошибку из `NEEDS_USER` (неверный или нет пароля, keyring, acl, tls_*, пакет):
поллер останавливается, экран роутеров открывает форму пароля.

### Ошибки

Всё, что бросают `api/*`, — `XvpnError` с `code` (`src/api/errors.ts`); текст для
пользователя — `errorText(e)` (`src/ui/errors.ts`), для каждого кода есть строка RU/EN.

### Rust-модули

Команды маршрутизируются по префиксу имени: `tray_*` → `tray::handler()`,
`notify_*` → `notifications::handler()`, `updater_*` → `updater::handler()`, остальное — ядро (`commands.rs`). Новая команда
трея или уведомлений добавляется в свой модуль (`tauri::generate_handler!` в его
`handler()`), `lib.rs` не трогается. У каждого модуля есть `init(app)`, вызывается из
`setup`.

## Подключение

- Профиль: имя, адрес `https://host[:port]` (по умолчанию `https://<шлюз ПК>`; без
  схемы — https), пользователь. Хранятся в `profiles.json` каталога настроек приложения.
- HTTP — только если пользователь явно написал `http://`; форма предупреждает, что
  пароль уйдёт открытым текстом. **При запуске приложение само подключается только к
  HTTPS-профилю**: закреплённый сертификат доказывает, что это тот роутер. По HTTP
  сохранённый пароль ушёл бы любому хосту с тем же адресом (ноутбук в чужой сети с
  таким же шлюзом), поэтому к HTTP-профилю — только по кнопке «Подключиться».
  (Сверка MAC шлюза не выбрана: её не видно из web view, а на Windows и в VPN-сетях
  она ненадёжна.)
- Пароль — в системном хранилище (Windows Credential Manager, Secret Service на Linux,
  crate `keyring`), сервис `io.github.arseso.xvpn`, учётка `profile:<id>`. С
  «не запоминать» — только в памяти до выхода. В web view пароль не возвращается:
  `session login` с ним отправляет Rust (`ubus_login`).
- HTTPS: самоподписанный сертификат uhttpd закрепляется по SHA-256 (TOFU). Первое
  подключение — отказ `tls_unknown` с отпечатком, пользователь сверяет и подтверждает;
  другой сертификат — `tls_changed` с обоими отпечатками и отказ, пока пользователь
  явно не подтвердит новый. Ошибка пина едет внутри TLS-ошибки своего соединения,
  параллельные запросы её не перехватывают. Пин сбрасывается только при смене схемы,
  хоста или порта (адреса сравниваются нормализованными: регистр, слэш, `:443` не в счёт).
- Сессия: при `Access denied` (-32002) или ubus-статусе 6 сначала `session access` с
  текущей сессией. Жива — это ACL: `acl`, без повторного входа (staged-изменения UCI и
  ожидающий confirm остаются). Мертва — один повторный вход и повтор вызова. Статус 6 от
  `uci` (нет прав на этот конфиг) — сразу `acl`. Сессия rpcd продлевается каждым
  вызовом, поллер держит её живой. Пользователю приложения на роутере нужен доступ к
  `session access` (ACL-группа `unauthenticated`, у root есть); без него живую сессию не
  отличить от мёртвой и отказ ACL будет стоить лишнего входа.
- UCI: rpcd хранит staged-изменения и ожидающий `confirm` в сессии. Если повторный вход
  случился, пока они были, следующий вызов uci (кроме `get`) падает с `session_lost` —
  вместо `apply` пустоты или `confirm`, которого роутер уже не ждёт.
- Версия: `luci.xvpn version` → `{ version: "<PKG_VERSION>-r<PKG_RELEASE>", api }`,
  поддерживается `api` = `SUPPORTED_API` (1, `src/api/version.ts`). Нет метода (старый
  ACL или плагин) при работающем `status` — `old_package`; нет объекта `luci.xvpn` —
  `no_package`; другой api — `incompatible`.

## Разработка

```sh
cd desktop
npm ci
npm test               # vitest, unit
npx tsc --noEmit
npm run tauri dev      # нужен Rust и webkit2gtk-4.1 на хосте
```

Сборка и тесты в docker (на хосте ничего, кроме docker):

```sh
sh scripts/desktop-build.sh        # dist/desktop: xvpn, xvpn_*.deb, xvpn_*.AppImage, xvpn_*_x64-setup.exe
sh scripts/desktop-build.sh test   # tsc, vitest, cargo test
sh scripts/desktop-itest.sh        # клиент против стенда scripts/luci.sh (node на хосте)
```

Кэш cargo, npm, target и MSVC SDK cargo-xwin — в docker-томах `xvpn-desktop-cargo`,
`xvpn-desktop-npm`, `xvpn-desktop-target`, `xvpn-desktop-xwin`, инструменты бандлера — `xvpn-desktop-tools`. `TARGETS=linux` — без
Windows. Хост слабый: тяжёлые команды параллельные сессии запускают под общим замком
`flock ~/.cache/xvpn-heavy.lock <команда>`.

### Версия

Одна на пакет роутера и приложение — `PKG_VERSION` из `luci-app-xvpn/Makefile` (только
`x.y.z`). `desktop-build.sh` подставляет её в копию для сборки: `tauri.conf.json` через
`--config`, `Cargo.toml`/`Cargo.lock` (User-Agent). Версии в самих файлах `desktop/`
сборка не использует.

### Windows

NSIS-установщик собирается кросс-сборкой из Linux, как описано у Tauri: target
`x86_64-pc-windows-msvc`, `cargo-xwin` (скачивает CRT и Windows SDK от Microsoft в свой
кэш), clang/lld, `makensis` из Debian. Сборка проверяет, что `xvpn.exe` — PE32+ GUI x86-64
и что он есть в установщике (`7z l`); запуск под Windows/wine в CI нет. WebView2 ставит
установщик сам (bootstrapper, нужен интернет), на Windows 10/11 он обычно уже есть.

MSI (WiX) собирается только на Windows. Там же можно собрать и NSIS:

```powershell
winget install Rustlang.Rustup OpenJS.NodeJS.LTS
# Visual Studio Build Tools 2022 с «Desktop development with C++» (MSVC и Windows SDK)
cd desktop
npm ci
npx tauri build --bundles msi,nsis          # src-tauri\target\release\bundle\{msi,nsis}
```

Версию из `PKG_VERSION` на Windows подставьте сами: `npx tauri build --config '{"version":"0.1.0"}'`.

### Обновления

`tauri-plugin-updater` (`src-tauri/src/updater.rs`, вкладка «О программе»): проверка — только
по кнопке, установка — только после подтверждения, той версии, что показана. Манифест —
`latest.json` последнего релиза
(`https://github.com/Arseso/openwrt-xray-vless-client/releases/latest/download/latest.json`),
пакет проверяется подписью по публичному ключу из `tauri.conf.json` (`plugins.updater.pubkey`).
Обновляются установка из NSIS (Windows, `installMode: passive`) и AppImage (Linux); установка
из deb не обновляется сама — приложение показывает новую версию и просит поставить deb
из релиза. JS-API плагина web view не выдан: у неё только команды `updater_check` и
`updater_install`.

Ключ подписи — вне репозитория: `~/.config/xvpn-desktop/updater.key` (600), пароль — в
`updater.pass` рядом (нет файла — пустой). Создан так:

```sh
npx tauri signer generate --ci -p "" -w ~/.config/xvpn-desktop/updater.key
```

С ключом `desktop-build.sh` подписывает AppImage и установщик (`*.sig`) и пишет
`dist/desktop/latest.json` со ссылками на релиз `TAG` (по умолчанию `v<PKG_VERSION>`, как
тег `scripts/ci.sh release`). Без ключа ничего не подписывается, а `ci.sh release` отказывается
выпускать релиз. Потеря ключа — новый ключ и новый `pubkey`: установленные версии со старым
ключом новые подписи не примут, их придётся обновить вручную.

### CI и релиз

`sh scripts/ci.sh` — шаг `desktop`: `desktop-build.sh test`, затем сборка Linux и Windows
(`DESKTOP_TARGETS=linux` — только Linux) в `dist/desktop/`; `DESKTOP_ITEST=1` добавляет
`desktop-itest.sh` (по умолчанию нет: стенд LuCI — ещё один контейнер, а itest и так
идёт ~12 мин). `sh scripts/ci.sh release` кладёт в тот же GitHub Release, что и ipk: deb,
AppImage, установщик, их `.sig` и `latest.json`, проверив, что всё подписано и `latest.json`
ссылается на этот тег.
