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
      notify.ts        уведомления: переходы → уведомления, дедупликация, тихие часы, настройки
      history.ts       история пинга и скорости: кольцевой буфер, заменяемый источник
      i18n.ts          strings({ en, ru }), lang(), setLang()
      updater.ts       UpdateFlow: проверка по кнопке, установка после нативного вопроса Rust
      apply.ts         сохранение UCI: stage → apply с откатом → проверка связи → confirm
      diagnostics.ts   файл диагностики вкладки «Журнал» и маскировка секретов
    forms/             формы вкладок: validate.ts (проверки как в LuCI и load_config),
                       diff.ts (что форма пишет в UCI), form.ts (UciForm, saveBar)
    i18n/<name>.ts     словари RU/EN: один файл на вкладку (+ common, connect, tray, notifications)
    views/
      registry.ts      registerView(), интерфейс View
      index.ts         по строке import на вкладку
      <name>.ts        вкладка: status, servers, subscriptions, access-points, settings, log,
                       history, notifications
      connect.ts       экран роутеров и решений о сертификате (не вкладка)
      about.ts         «О программе»: версии, обновление приложения (#81)
    tray/              модель меню трея (model.ts) и контроллер на connection.bus (index.ts)
    ui/                dom.ts (h, clear), errors.ts (errorText), format.ts (скорость, байты, сроки),
                       native.ts (буфер обмена, диалог сохранения через плагины)
  src-tauri/src/
    lib.rs             сборка приложения, маршрутизация команд по префиксу
    commands.rs        команды ядра: ubus_request, ubus_login, profile_*, default_gateway
    transport.rs       HTTP(S) к /ubus, таймауты, клиент на профиль
    pin.rs             TOFU: проверка SHA-256 сертификата uhttpd
    profiles.rs        profiles.json + keyring
    gateway.rs         шлюз по умолчанию (Linux /proc/net/route, Windows route print)
    tray.rs            трей, автозапуск, закрытие окна в трей (#78)
    vpncheck.rs        «иду ли я через VPN»: внешний IP ПК, адреса сервера (#78)
    notifications.rs   уведомления — TODO(#80)
    tray.rs            трей — TODO(#78)
    notifications.rs   уведомления: tauri-plugin-notification, команда notify_show
    updater.rs         обновление приложения: tauri-plugin-updater (#81)
    screens.rs         плагины вкладок #79: clipboard-manager, dialog, fs
                       (права — capabilities/screens.json)
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

### Сохранение настроек

Вкладки «Подписки», «Точки доступа» и «Настройки» пишут конфиг `xvpn` так же, как LuCI:
изменения ставятся в сессию (`uci set/add/delete`), `uci apply` с `rollback: true` и таймером
60 с, затем, после паузы 4 с на перезагрузку служб (как `apply_holdoff` LuCI), приложение
ждёт двух ответов `luci.xvpn version` подряд по новым соединениям (`fresh`: keep-alive
соединение может пережить правило firewall, которое режет новые) и шлёт `confirm`. Нет
таких ответов за 50 с — приложение само вызывает `uci rollback` (пока роутер недоступен —
до истечения таймера rpcd с запасом) и только потом перечитывает форму. Откат возвращает
изменения в сессию как staged: формы читают конфиг через `loadConfig()`, который их
сбрасывает (`revert`). Сохранения и `loadConfig()` одной сессии идут по одному
(`exclusive`): пока идёт одно, кнопки других форм говорят «сохраняется другое изменение».
Перед записью форма перечитывает конфиг: если изменённое поле тем временем поменяли в LuCI,
форма не перезаписывает его, а показывает текущие значения. Флаги сравниваются так, как их
читает роутер (`bool()`: 1/true/yes/on/enabled, пусто — умолчание): нетронутый флаг не
переписывается. `apply`, пока роутер ждёт `confirm` от другой сессии (LuCI), получает
статус 6 (`acl`) — форма просит повторить позже. Общий код: `src/core/apply.ts` (`save`,
`applyStaged`, `loadConfig`, `exclusive`), `src/forms/form.ts` (`UciForm`, `saveBar`).
Порты, метки и таблица маршрутизации в приложении не правятся — только в LuCI.

Диагностика (вкладка «Журнал», `src/core/diagnostics.ts`): версии, `status`, `firewall`,
подписки, раздельное туннелирование, точки доступа, конфиг `xvpn` и журнал одним текстовым
файлом через диалог сохранения. Ссылки серверов становятся `scheme://***@host:port`, у URL
остаются схема и хост (путь и query URL подписки — её токен), UUID заменяются; URL проверок
`health.*` публичны и остаются. `system board` — только под root: остальным его не даёт ACL.

### Rust-модули

Команды маршрутизируются по префиксу имени: `tray_*` → `tray::handler()`,
`notify_*` → `notifications::handler()`, `updater_*` → `updater::handler()`, остальное — ядро (`commands.rs`). Новая команда
трея или уведомлений добавляется в свой модуль (`tauri::generate_handler!` в его
`handler()`), `lib.rs` не трогается. У каждого модуля есть `init(app)`, вызывается из
`setup`; плагины Tauri модуль регистрирует там же (`app.handle().plugin(...)`, как
`screens.rs`), их права — в своём файле `capabilities/<модуль>.json`.

### Трей (#78)

`src/tray/model.ts` — чистая функция `trayModel(состояние подключения, status, ошибка)` →
`TrayModel`: иконка (`connected`, `failover`, `wan_down`, `xray_down`, `offline`, `stopped` —
файлы `src-tauri/icons/tray/<icon>.png`), подсказка, информационные строки меню, подменю
серверов (не больше 40, активный всегда есть), «Автовыбор», подписи. `src/tray/index.ts`
считает модель на каждом `status` и `connection` и шлёт `tray_update`, только если она
изменилась; `tray.rs` меняет тексты пунктов на месте и пересобирает меню, только когда
меняется его форма (другие серверы, другой язык). Клики возвращаются событием
`tray-action` (`select`, `auto`, `test`, `service`, `refresh` — при открытии меню на
Windows); «Открыть окно», «Открыть LuCI» и «Выход» Rust делает сам.

- «Автовыбор» — режим демона: `status.manual` (активный выбран вручную, `by_hand` в
  xvpnd). Галочка снята — активный сервер остаётся выбранным вручную (`select` его же),
  поставлена — `luci.xvpn auto` сбрасывает ручной выбор и демон выбирает заново. «(авто)/
  (вручную)» в строке сервера — тоже по `manual`; у пакета без него пункт выключен.
- Четыре информационные строки всегда (состояние, сервер, пинг, скорость): открытое
  меню не пересоздаётся; тексты меняются только у изменившихся пунктов.
- Пока действие из меню идёт, действия выключены (двойной клик — не два рестарта).
  Отказ — строкой в состоянии, системным уведомлением (`notify_show` из #80) и
  сообщением в окне (`src/ui/notice.ts`). Ответы старше 3 интервалов опроса при сбоях — «роутер не отвечает».
- «Стоп» из трея при включённом (или неизвестном) kill switch — с нативным подтверждением.
- «Открыть LuCI»: адрес строит Rust из профиля (`http(s)://хост[:порт]` из
  profiles.json + фиксированный путь) и открывает как URL (`tauri-plugin-opener`),
  из web view приходит только id профиля.
- Закрытие окна прячет его в трей, если есть хост StatusNotifierItem
  (`org.kde.StatusNotifierWatcher` на сессионной шине; проверяется в момент закрытия —
  при автозапуске хост может появиться позже). Без хоста (GNOME без AppIndicator) окно
  закрывается и приложение выходит.
- Один экземпляр (`tauri-plugin-single-instance`): второй запуск показывает окно первого.
- Окно с `backgroundThrottling: disabled`: спрятанное в трей, оно продолжает опрос в
  обычном темпе (иначе WebView2 через 5 минут растягивает таймеры до минуты).
- Автозапуск — `tauri-plugin-autostart` с аргументом `--minimized` (старт в трее),
  переключатель на вкладке «Статус».

### «Иду ли я через VPN»

Внешние IPv4 и IPv6 ПК (Rust спрашивает `api4.ipify.org` и `api6.ipify.org`; другой сервис,
`icanhazip.com`, — только по кнопке; HTTPS с корнями webpki, без User-Agent) сравниваются
с адресами активного сервера, разрешёнными на ПК (не дольше 5 с), — каждое семейство
отдельно: IPv6 мимо туннеля видно, даже если IPv4 идёт через него. IP выхода сервера
роутер не знает: ни демон, ни `luci.xvpn` его не отдают, а узнать его дёшево можно было бы
только запросом с роутера через тестовый SOCKS-порт сервера (новый метод rpcd). Поэтому
выход считается равным адресу сервера — верно для обычного сервера на одном хосте; у
ретранслятора или CDN-фронта выход другой, тогда показывается «нет» с обоими адресами и
этой оговоркой. Проверка — только по кнопке: это запрос к стороннему сервису, он назван
в окне. Внешний адрес показывается, даже если имя сервера не разрешилось.
## Уведомления и история

`startNotifications(connection)` и `liveHistory.attach(connection)` подключаются к
`connection.bus` один раз в `main.ts`. Решения принимает TS (`src/core/notify.ts`),
Rust только показывает (`notify_show`).

| тип            | когда | ключ (одно уведомление на событие) |
|----------------|-------|------|
| `vpn`          | рабочее (connected, degraded) → нерабочее (no_servers, xray_down, wan_down, error, passthrough, служба остановлена) и обратно; starting/failover — переходные; выключенный пользователем — не «упал»; служба не запущена — сбой только через 45 с, остановка из приложения (`service stop`) и 2 мин после возврата роутера — не сбой; «восстановился» — только после показанного «упал» | номер сбоя |
| `failover`     | новый `last_switch` с `failover: true` (демон ставит его в `failover()`; у старого демона без поля — если поллер видел state failover); не старше 2 мин и не с прошлого подключения; если VPN был «упал», переключение говорит «восстановился» | `at` + `to` |
| `router`       | `router-down` / первый ответ после него; при подключении — 2 неудачные попытки `connect()` и затем online | `since` |
| `subscription` | `subscription-userinfo`: до `expire` меньше N дней / уже истекла, израсходовано ≥ P % | `expire` + фаза, `total` |
| `sub_error`    | у подписки `error`: одно уведомление до следующего успешного обновления | `error` + `last_ok` |

Переходы помнятся по профилю, поэтому переподключение к тому же роутеру не повторяет
сказанное. Ключи подписок хранятся между запусками (`xvpn.notify.sent`, 60 дней).
Уведомление выключенного типа или в тихие часы не показывается и не помечается
отправленным: условие (подписка) скажется на следующем опросе после тихих часов, переход
(VPN, роутер, failover) — нет. Окно `main` без `backgroundThrottling`: таймеры поллера
не замедляются, пока окно скрыто в трей.
`luci.xvpn subscriptions` опрашивается отдельно от поллера: через 15 с после
подключения, раз в 30 мин и сразу после конца обновления (`updating` true → false).
Настройки (интервал поллера, тихие часы, типы, пороги) — вкладка «Уведомления»,
`localStorage` `xvpn.notify`, общие для всех роутеров.

История: каждый ответ поллера — отсчёт `{ at, ping, up, down }` (пинг активного
сервера, `speed` из status), ошибка опроса — разрыв линии. Кольцевой буфер на 9600
отсчётов (8 ч при 3 с), при смене роутера или переводе часов ПК назад начинается заново. Вкладка читает
`historySource()`; история с роутера (#34) подменит источник через
`setHistorySource()`. Графики — SVG без библиотек.

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
  `session access` (у root есть, у rpcd-пользователя `luci-app-xvpn-remote` — с этой
  версии пакета). Есть ли он, клиент проверяет сразу после входа; без него живую сессию не
  отличить от мёртвой: отказ стоит повторного входа, а пока в сессии staged-изменения или
  ожидающий confirm — сразу `acl`, без входа, чтобы их не потерять.
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
`xvpn-desktop-npm`, `xvpn-desktop-target`, `xvpn-desktop-xwin`. `TARGETS=linux` — без
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
по кнопке; установку команда `updater_install` начинает с нативного диалога со своим текстом
(`tauri-plugin-dialog`) — без «Установить» в нём ничего не скачивается, и ни один скрипт в
web view этот вопрос не обойдёт. Ставится только версия, найденная последней проверкой.
Манифест — `latest.json` последнего релиза
(`https://github.com/Arseso/openwrt-xray-vless-client/releases/latest/download/latest.json`),
пакет проверяется подписью по публичному ключу из `tauri.conf.json` (`plugins.updater.pubkey`).
Обновляются установка из NSIS (Windows, `installMode: passive`), AppImage и deb (Linux: плагин
ставит deb через `dpkg` с `pkexec`); тип установки плагин берёт из бинаря (сборщик Tauri его туда
записывает). MSI, собранный вручную, rpm и голый бинарь не обновляются — приложение показывает
новую версию и ссылку на релиз. JS-API плагинов web view не выдан: у неё только команды
`updater_check` и `updater_install`.

Ключ подписи — вне репозитория: `~/.config/xvpn-desktop/updater.key` (600; другой каталог —
`KEYS`), пароль — в `updater.pass` рядом (нет файла — пустой). Создан так:

```sh
npx tauri signer generate --ci -p "" -w ~/.config/xvpn-desktop/updater.key
```

Сборка ключа не видит: в ней работают npm-скрипты, `build.rs` сотен крейтов и скачанные
инструменты. Готовые AppImage, deb и установщик подписывает второй контейнер того же образа
(`desktop/docker/sign.sh`) — без сети, без томов, смонтирован только файл ключа — и там же
пишет `dist/desktop/latest.json` со ссылками на релиз `TAG` (по умолчанию `v<PKG_VERSION>`, как
тег `scripts/ci.sh release`) и проверяет каждую подпись `minisign` по ключу из `tauri.conf.json`.
`sh scripts/desktop-build.sh verify` — только проверка. Без ключа ничего не подписывается, а
`ci.sh release` отказывается выпускать релиз. Потеря ключа — новый ключ и новый `pubkey`:
установленные версии со старым ключом новые подписи не примут, их придётся обновить вручную.

### Воспроизводимость

Образ сборки (`desktop/docker/Dockerfile`) закреплён: базовые образы node и rust — по digest,
cargo-xwin и tauri CLI — по версии, MSVC CRT и Windows SDK — `XWIN_CRT_VERSION`/`XWIN_SDK_VERSION`,
инструменты AppImage (AppRun, linuxdeploy, linuxdeploy-plugin-appimage), которые сборщик Tauri
иначе качал бы при каждой сборке, а plugin-appimage — с движущегося тега `continuous`, лежат в
образе по фиксированным URL с `sha256sum -c`. Плагины NSIS сборщик проверяет по хэшу сам.

### CI и релиз

`sh scripts/ci.sh` — шаг `desktop`: `desktop-build.sh test`, затем сборка Linux и Windows
(`DESKTOP_TARGETS=linux` — только Linux) в `dist/desktop/`; `DESKTOP_ITEST=1` добавляет
`desktop-itest.sh` (по умолчанию нет: стенд LuCI — ещё один контейнер, а itest и так
идёт ~12 мин). `sh scripts/ci.sh release` кладёт в тот же GitHub Release, что и ipk: deb, AppImage, установщик,
их `.sig` и `latest.json` — проверив подписи по ключу из `tauri.conf.json` и что `latest.json`
ссылается на этот тег. Релиз сначала создаётся черновиком (тег GitHub ставит при публикации),
поэтому сбой загрузки не оставляет тега без релиза, а повторный запуск догружает в тот же
черновик и публикует. Версия приложения — `PKG_VERSION` без `PKG_RELEASE`: релиз `-rN`, в котором
изменился `desktop/`, `ci.sh release` не выпустит — обновление с той же версией updater не увидит.
