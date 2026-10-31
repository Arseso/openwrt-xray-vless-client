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
    core/
      bus.ts           типизированная шина событий
      store.ts         наблюдаемый стор
      poller.ts        общий поллер status
      connection.ts    подключение к профилю: фазы, AppContext для вкладок
      notify.ts        уведомления: переходы → уведомления, дедупликация, тихие часы, настройки
      history.ts       история пинга и скорости: кольцевой буфер, заменяемый источник
      i18n.ts          strings({ en, ru }), lang(), setLang()
    i18n/<name>.ts     словари RU/EN: один файл на вкладку (+ common, connect, tray, notifications)
    views/
      registry.ts      registerView(), интерфейс View
      index.ts         по строке import на вкладку
      <name>.ts        вкладка: status, servers, subscriptions, access-points, settings, log,
                       history, notifications
      connect.ts       экран роутеров и решений о сертификате (не вкладка)
    ui/                dom.ts (h, clear), errors.ts (errorText)
  src-tauri/src/
    lib.rs             сборка приложения, маршрутизация команд по префиксу
    commands.rs        команды ядра: ubus_request, ubus_login, profile_*, default_gateway
    transport.rs       HTTP(S) к /ubus, таймауты, клиент на профиль
    pin.rs             TOFU: проверка SHA-256 сертификата uhttpd
    profiles.rs        profiles.json + keyring
    gateway.rs         шлюз по умолчанию (Linux /proc/net/route, Windows route print)
    tray.rs            трей — TODO(#78)
    notifications.rs   уведомления: tauri-plugin-notification, команда notify_show
  tests/unit/          vitest, фейковый роутер (fake.ts)
  tests/stand/         тот же клиент против стенда scripts/luci.sh
  docker/Dockerfile    окружение сборки Linux
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
`notify_*` → `notifications::handler()`, остальное — ядро (`commands.rs`). Новая команда
трея или уведомлений добавляется в свой модуль (`tauri::generate_handler!` в его
`handler()`), `lib.rs` не трогается. У каждого модуля есть `init(app)`, вызывается из
`setup`.

## Уведомления и история

`startNotifications(connection)` и `liveHistory.attach(connection)` подключаются к
`connection.bus` один раз в `main.ts`. Решения принимает TS (`src/core/notify.ts`),
Rust только показывает (`notify_show`).

| тип            | когда | ключ (одно уведомление на событие) |
|----------------|-------|------|
| `vpn`          | рабочее (connected, degraded) → нерабочее (no_servers, xray_down, wan_down, error, passthrough, служба остановлена) и обратно; starting/failover — переходные, не в счёт; выключенный пользователем — не «упал» | номер сбоя |
| `failover`     | новый `last_switch` не по выбору пользователя и не «faster server»: с какого на какой | `at` + `to` |
| `router`       | `router-down` / первый ответ после него (или новое подключение к тому же роутеру) | `since` |
| `subscription` | `subscription-userinfo`: до `expire` меньше N дней, израсходовано ≥ P % | `expire`, `total` |
| `sub_error`    | у подписки `error` | `last_attempt` |

Переходы помнятся по профилю, поэтому переподключение к тому же роутеру не повторяет
сказанное. Ключи подписок хранятся между запусками (`xvpn.notify.sent`, 60 дней).
Уведомление выключенного типа или в тихие часы не показывается и потом не догоняет.
`luci.xvpn subscriptions` опрашивается отдельно от поллера: через 15 с после
подключения, раз в 30 мин и сразу после конца обновления (`updating` true → false).
Настройки (интервал поллера, тихие часы, типы, пороги) — вкладка «Уведомления»,
`localStorage` `xvpn.notify`, общие для всех роутеров.

История: каждый ответ поллера — отсчёт `{ at, ping, up, down }` (пинг активного
сервера, `speed` из status), ошибка опроса — разрыв линии. Кольцевой буфер на 9600
отсчётов (8 ч при 3 с), при смене роутера начинается заново. Вкладка читает
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
sh scripts/desktop-build.sh        # dist/desktop/xvpn и dist/desktop/xvpn_*.deb
sh scripts/desktop-build.sh test   # tsc, vitest, cargo test
sh scripts/desktop-itest.sh        # клиент против стенда scripts/luci.sh (node на хосте)
```

Кэш cargo, npm и target — в docker-томах `xvpn-desktop-cargo`, `xvpn-desktop-npm`,
`xvpn-desktop-target`. Windows-сборка, AppImage, автообновление и шаг в
`scripts/ci.sh` — #81.
