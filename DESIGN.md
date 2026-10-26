# luci-app-xvpn — VPN-клиент на xray для OpenWrt 24.10

Проектный документ: требования, принятые решения, архитектура, план проверки и идеи на будущее.

## 1. Требования

| # | Требование | Как закрыто |
|---|------------|-------------|
| R1 | LuCI-приложение для OpenWrt 24.10, удобное | Пакет `luci-app-xvpn`, раздел «Сервисы → XVPN», 5 вкладок, RU/EN |
| R2 | VPN-клиент | xray-core (`xray-core 25.1.30` из штатного фида 24.10) + TPROXY |
| R3 | Сам обновляет подписку | Демон `xvpnd` по таймеру, интервал из настроек или из заголовка `profile-update-interval` |
| R4 | Сам подключается к серверу | При старте берётся последний рабочий сервер, иначе — лучший по HTTP-пингу |
| R5 | Если подключение легло — переключение на лучший сервер по HTTP-пингу | Health-check каждые 30 с, после 3 неудач — тест всех серверов и переход на минимальный пинг |
| R6 | VPN для одной или нескольких точек доступа (порты, Wi-Fi сети) | Выбор сетей OpenWrt, отдельных LAN-портов (DSA) и отдельных SSID |
| R7 | Доп.: kill switch и защита DNS (выбрано пользователем) | Правила nft не снимаются при падении xray, рестарте и до старта сервиса при загрузке; при ошибке nft клиенты блокируются; DNS клиентов VPN перехватывается и идёт через туннель; IPv6 не утекает |

### Ответы пользователя (2026-10-26)
- Режим маршрутизации: **только полный туннель** — весь трафик выбранных точек доступа идёт в VPN.
- Протоколы: **всё, что умеет xray** — `vless://` (Reality, XTLS-Vision, XHTTP, WS, gRPC, HTTPUpgrade, mKCP), `vmess://`, `trojan://`, `ss://`.
- Устройство: **Xiaomi AX3000T** (MediaTek MT7981B, target `mediatek/filogic`, arch `aarch64_cortex-a53`, 128 МБ NAND, 256 МБ ОЗУ, порты `lan1..lan3` + `wan`, радио 2.4 и 5 ГГц).
- Доп. функции в v1: **kill switch + защита DNS**.

## 2. Ключевые решения

1. **Ядро — xray-core из фида.** В 24.10.4 есть `xray-core 25.1.30` (ipk ≈ 9.8 МБ, ≈ 25 МБ на флеше). На AX3000T места хватает. Geo-файлы (`v2ray-geoip`/`v2ray-geosite`) для полного туннеля не нужны и не ставятся. Путь к бинарю настраивается (`main.xray_bin`) — можно положить свежий xray с GitHub, если нужны функции новее 25.1.30 (например, VLESS `encryption`/ML-KEM).
2. **Бэкенд на ucode** — родной язык скриптов OpenWrt 24.10 (как в `luci-app-homeproxy`): модули `/usr/share/ucode/xvpn/*.uc`, скрипты `/usr/share/xvpn/{cli,xvpnd}.uc`.
3. **Перехват — nftables TPROXY** (TCP+UDP) в собственных таблицах `inet xvpn` и `bridge xvpn`. fw4 удаляет только свою таблицу `inet fw4`, поэтому наши таблицы переживают `fw4 reload`.
4. **Выбор сервера и failover — в нашем демоне, а не в балансировщике xray.** Каждый сервер — отдельный outbound, у каждого свой loopback SOCKS-инбаунд `127.0.0.1:20000+i` («тестовый порт»). TPROXY- и DNS-инбаунды маршрутизируются на активный outbound. Плюсы: прозрачные замеры для UI, полный контроль над логикой (проверка WAN, карантин, гистерезис). Переключение = перегенерация конфига + `reload` сервиса, procd перезапускает только xray (~1 с).
5. **HTTP-пинг** = `time_starttransfer` запроса `GET https://www.gstatic.com/generate_204` через SOCKS сервера (`curl -x socks5h://…`), ответ 204/200 обязателен. Тесты идут параллельно (по умолчанию 8 одновременно) через `uloop.process`.
6. **Кэш подписок на флеше** (`/etc/xvpn/subs/<id>.json`) — VPN поднимается после перезагрузки без доступа к серверу подписки. Пишем только при изменении содержимого (экономия ресурса NAND).
7. **Один пакет** `luci-app-xvpn` (`PKGARCH:=all`), собирается через `luci.mk`.

## 3. Архитектура

```
 Клиенты VPN-точек ─┐
  (SSID / lan-порт /│   bridge xvpn: метка CLIENT для выбранных портов и SSID
   сеть br-guest)   │   inet  xvpn : метка CLIENT для выбранных сетей
                    ▼
            prerouting mangle: CLIENT && не приватный dst && не DNS → TPROXY :12345 (+метка TPROXY)
            prerouting dstnat: CLIENT && dport 53                     → redirect :10853
            forward          : CLIENT && не приватный dst → reject (kill switch / IPv6 block)
                    ▼
   ┌──────────────── xray (procd instance) ─────────────────┐
   │ inbound tproxy :12345 ─┐                                │
   │ inbound dns    :10853 ─┼─► outbound srv-<активный>  ──► │──► VPN-сервер
   │ inbound test-i 127.0.0.1:20000+i ─► outbound srv-i      │
   │ inbound api    127.0.0.1:10085 (stats)                  │
   └─────────────────────────────────────────────────────────┘
                    ▲ reload (новый активный)
   ┌──────────── xvpnd (procd instance, ucode+uloop) ───────┐
   │ health-check, failover, re-rank, обновление подписок   │
   │ ubus-объект `xvpn`: status / test / select / update /   │
   │ reindex                                                 │
   └─────────────────────────────────────────────────────────┘
                    ▲ ubus
   LuCI (JS-вьюхи) ──► rpcd ucode-плагин `luci.xvpn` (офлайн-операции;
                       обновление подписок — через `ubus xvpn update`;
                       status / test / select — прокси к демону)
```

### 3.1 Файлы пакета
```
luci-app-xvpn/
  Makefile
  htdocs/luci-static/resources/view/xvpn/{status,subscriptions,access,settings,log}.js
  po/templates/xvpn.pot, po/ru/xvpn.po
  root/etc/config/xvpn                         дефолтный UCI
  root/etc/init.d/xvpn                         procd-сервис (START=95)
  root/etc/init.d/xvpn-guard                   блокировка клиентов при загрузке (START=18, до fw4 и сети)
  root/etc/hotplug.d/net/50-xvpn               Wi-Fi поднялся или перезапустился → fw-refresh
  root/etc/hotplug.d/iface/50-xvpn             поднялась сеть из access.network → fw-refresh
  root/etc/uci-defaults/80_luci-xvpn           включение xvpn-guard, include для fw4, очистка кэша LuCI
  root/usr/share/luci/menu.d/luci-app-xvpn.json
  root/usr/share/rpcd/acl.d/luci-app-xvpn.json
  root/usr/share/rpcd/ucode/luci.xvpn          rpcd-плагин
  root/usr/share/ucode/xvpn/util.uc            общие функции (json, хэш, лог, shell-quote)
  root/usr/share/ucode/xvpn/links.uc           парсер ссылок и подписок → xray outbound
  root/usr/share/ucode/xvpn/subscription.uc    загрузка подписок, кэш, фильтры
  root/usr/share/ucode/xvpn/xrayconf.uc        генерация config.json и индекса серверов
  root/usr/share/ucode/xvpn/firewall.uc        nft-правила и ip rule/route
  root/usr/share/xvpn/cli.uc                   CLI: generate / ifnames / ifnames-wait / fw-apply / fw-guard / fw-refresh / fw-remove / update
  root/usr/share/xvpn/xvpnd.uc                 демон
  root/usr/share/xvpn/firewall.include         fw4 include: вернуть правила после fw4 flush
tests/                                         ucode-тесты + фикстуры
scripts/{test,itest,build,luci}.sh             тесты, сборка ipk и LuCI для ручной проверки в docker
```

### 3.2 Рантайм-файлы
| Путь | Что | Кто пишет |
|------|-----|-----------|
| `/etc/xvpn/subs/<sid>.json` | кэш подписки: серверы, `userinfo`, время, ошибка | `subscription.uc` (только при изменении) |
| `/etc/xvpn/active` | id последнего активного сервера | демон (только при смене) |
| `/etc/config/wireless`: `option ifname 'xvpn-apN'` | фиксированное имя VPN-SSID (§7.2); старый кэш `/etc/xvpn/ifnames.json` больше не используется и удаляется `uci-defaults` | `cli.uc ifnames` |
| `/var/etc/xvpn/config.json` | конфиг xray | `cli.uc generate` |
| `/var/etc/xvpn/index.json` | список серверов: id, имя, тестовый порт, активный | `cli.uc generate` |
| `/var/etc/xvpn/xvpn.nft` | правила nft | `cli.uc fw-apply` |
| `/var/run/xvpn/state.json` | состояние демона (для rpcd, когда демон занят) | демон |
| `/var/run/xvpn/fw_want` | запрошенный режим правил: `full` / `passthrough` / `block` | `cli.uc fw-*` |
| `/var/run/xvpn/fw_mode` | применённый режим: запрошенный или fallback `block` / `minimal` | `cli.uc fw-*` |
| `/var/run/xvpn/fw_error` | ошибка nft или ненайденного SSID; есть, пока запрошенный режим не применился; статус — `error` | `cli.uc fw-*` |
| `/var/run/xvpn/fw_warn` | предупреждение: имена VPN-SSID не зафиксированы из-за чужих незакоммиченных правок `wireless` | `cli.uc ifnames` |
| `/var/lock/xvpn-fw` | блокировка: `fw-*` выполняются по одному | `cli.uc fw-*` |
| `/var/run/xvpn/updating` | симлинк на pid идущего `cli.uc update` — единственный флаг «идёт обновление» | `cli.uc update` |

## 4. UCI-схема `/etc/config/xvpn`

```
config general 'main'
	option enabled '0'
	option xray_bin '/usr/bin/xray'
	option loglevel 'warning'          # debug|info|warning|error|none
	option tproxy_port '12345'
	option dns_port '10853'
	option api_port '10085'
	option test_port_base '20000'
	option client_mark '0x01000000'    # метка «клиент VPN» (вне масок mwan3 0x3F00 и pbr 0x00ff0000)
	option tproxy_mark '0x02000000'    # метка для ip rule → table 
	option route_table '100'
	option sniffing '0'                # 1 = подменять IP на домен (http/tls/quic)

config access 'access'
	list network 'guest'               # целые сети OpenWrt
	list port 'lan2'                   # отдельные порты моста (DSA)
	list wifi 'wifinet2'               # секции wifi-iface (SSID); получают option ifname 'xvpn-apN' (§7.2)
	option killswitch '1'
	option ipv6 'block'                # block | tunnel
	option dns_hijack '1'
	option dns_server '1.1.1.1'        # DNS, куда идут запросы клиентов через туннель

config health 'health'
	option url 'https://www.gstatic.com/generate_204'
	option interval '30'               # с, проверка активного
	option timeout '5'                 # с, таймаут одного замера
	option fail_threshold '3'          # неудач подряд до failover
	option rank_interval '600'         # с, фоновый тест всех
	option auto_best '0'               # переходить на заметно более быстрый
	option hysteresis '150'            # мс, насколько быстрее должен быть новый
	option quarantine '300'            # с, «мёртвый» сервер не выбирается
	option concurrency '8'

config subscription
	option name 'Мой VPN'
	option enabled '1'
	option url 'https://example.com/sub/xxxx'
	option user_agent 'v2rayN/7.0'     # провайдеры (Marzban/Remnawave/3x-ui) выбирают формат по UA
	option update_interval '12'        # часы; 0 = из profile-update-interval или 12
	option include ''                  # regex по имени сервера
	option exclude ''
	option via_tunnel '1'              # качать через активный сервер, при неудаче — напрямую

config manual 'manual'
	list link 'vless://…#Мой сервер'
```

## 5. Подписки и ссылки

- Загрузка: `curl -sSL --max-time 30 -A <UA> -D <headers> -o <body>`; через туннель — `-x socks5h://127.0.0.1:<тестовый порт активного>`, при неудаче — напрямую.
- Форматы тела: base64 (обычный и URL-safe, без паддинга) списка ссылок; plain-список; xray-JSON (массив полных конфигов или один конфиг — берётся первый outbound с протоколом vless/vmess/trojan/shadowsocks, имя из `remarks`). Clash YAML и sing-box JSON не поддерживаются → понятная ошибка «смените User-Agent».
- Заголовки: `subscription-userinfo` (upload/download/total/expire → показываем трафик и срок), `profile-update-interval`, `profile-title` (в т.ч. `base64:`).
- Ссылки → xray outbound:
  - `vless://uuid@host:port?type=&security=&flow=&sni=&fp=&alpn=&pbk=&sid=&spx=&host=&path=&serviceName=&mode=&headerType=&seed=&extra=&allowInsecure=#name`
  - `vmess://base64(JSON v2rayN)`
  - `trojan://password@host:port?…` (security по умолчанию tls)
  - `ss://base64(method:password)@host:port#name` (SIP002) и legacy `ss://base64(method:password@host:port)`; плагины (obfs/v2ray-plugin) — пропуск.
  - Транспорты: `tcp` (+ http-обфускация), `ws`, `grpc`, `xhttp`/`splithttp`, `httpupgrade`, `kcp`. Не поддерживаемые xray 25.1.30 (`h2`/`http`, `quic`) и протоколы (`hysteria2`, `tuic`) — пропускаются со счётчиком «пропущено».
- id сервера = FNV-1a от канонической строки (протокол, адрес, порт, учётка, транспорт, security, sni). Дубликаты между подписками отбрасываются. Фильтры include/exclude — регулярки по имени, без учёта регистра.

## 6. Логика демона xvpnd

1. Старт: загрузить индекс; если активный неизвестен — сразу тест всех и выбор лучшего.
2. Каждые `interval` с — HTTP-пинг активного через его тестовый порт.
3. Неудачная проверка → сначала проверка самого xray (п. 6.2): если не работает он, сервер не виноват — неудача не считается. `fail_threshold` неудач подряд → проверка прямого интернета (тот же URL без прокси):
   - нет прямого интернета → состояние `wan_down`, серверы не трогаем, ждём;
   - есть → `failover`: активный в карантин, тест всех, переход на минимальный пинг. Если живых нет и xray работает → `no_servers`, повтор на каждом тике; если не работает xray → `xray_down`, решение откладывается до его восстановления.
4. Каждые `rank_interval` с — фоновый тест всех (для UI). При `auto_best=1` переход, только если лучший быстрее текущего более чем на `hysteresis` мс.
5. Каждые 5 мин — проверка, не пора ли обновить подписки; обновление идёт отдельным процессом (`cli.uc update <sid…>`), при изменении списка серверов — `reload`.
6. Ручной выбор сервера в UI (`xvpn.select`) — сразу переключает; дальше работает обычный failover.
7. Kill switch выключен и живых серверов нет → правила TPROXY снимаются (клиенты идут напрямую) до появления живого сервера.

### 6.1 Обновления и устаревший индекс
- **Одна точка входа.** Подписки обновляет только демон: rpcd `luci.xvpn update` вызывает `ubus xvpn update`. Без демона (сервис выключен или procd его перезапускает) rpcd сам запускает `cli.uc update` и, если сервис запущен, `reload`. Взаимоисключение — в `cli.uc update`: лок `/var/run/xvpn/updating` берётся атомарным `symlink` на свой pid, лок умершего процесса снимается. `updating` в `status` демона и в `luci.xvpn subscriptions` — это один и тот же лок.
- **Индекс перечитывается при любом reload.** Сервис перезагружают и мимо демона (rpcd, UCI-триггеры `wireless`/`network`). `service_started()` в `init.d/xvpn` после `fw-apply` и передачи инстансов procd вызывает `ubus xvpn reindex` — пауза на перезапуск xray отсчитывается от этого момента, а сброс passthrough не опережает `fw-apply`; кроме того, демон сравнивает содержимое файла на каждом `check` и `status`. Изменение, сделанное не демоном, обрабатывается так же, как после своего `reload`: 3 с на перезапуск xray, затем синхронизация (активный пропал или xray ведёт трафик не туда → выбор лучшего, иначе — проверка активного).
- **Поколения замеров.** Тестовые порты позиционные (`20000+i`), поэтому каждое изменение индекса и каждый `reload` демона увеличивают номер поколения. Замер принимается, только если за время замера поколение не менялось и xray не перезапускался; иначе он отбрасывается, а в тесте всех — повторяется по новому индексу. Порт берётся по id сервера в момент запуска замера; замеры и карантин удалённых серверов удаляются.

### 6.2 xray не работает ≠ сервер недоступен
Если xray упал, завис, не стартует (битый конфиг или бинарь, занятый порт, OOM) или крутится в respawn, падают пинги всех серверов, хотя прямой интернет есть. Поэтому перед тем как засчитать неудачу серверу, демон проверяет xray:
- инстанс `xray` запущен по `ubus call service list '{"name":"xvpn"}'` и не остановлен (`T` в `/proc/<pid>/stat`, `kill -STOP`). Если procd не ответил (таймаут ubus 2 с), состояние xray неизвестно: неудача не засчитывается ни xray, ни серверу;
- xray отвечает на своём api-порту (`127.0.0.1:api_port`, dokodemo-door → gRPC API): ответ даёт сам xray, без удалённого сервера. curl: 7 (connection refused) — xray не слушает, 28 (таймаут) — завис, любой другой код — живой;
- тестовый SOCKS-порт не отказал в соединении (curl 7 на пинге; таймаут и ошибки TLS — это уже сервер).

Если xray не работает: серверы в карантин не идут (карантин активного снимается), passthrough не включается, замер не записывается. В тесте всех неудачи записываются (`ms: -1`), только если после теста xray работает; отказ тестового порта не записывается никогда. Первые `XRAY_GRACE` = 10 с — терпение (старт xray, respawn procd), состояние не меняется; затем `xray_down`. В `last_error` — что не так и, где это помогает, подробности, пересчитанные на каждой проверке: отсутствующий бинарь называется прямо; если инстанса нет (`cli.uc generate` не запустил xray) — вывод `xray run -test` (асинхронно, зависший бинарь убивается через 5 с); если xray не запущен или не слушает — последние строки его лога (procd пишет stdout/stderr в logd под именем бинаря; строки запущенного pid, иначе последнего процесса с этим именем, без баннера, `started` и предупреждений `deprecated`). У остановленного и зависшего xray строк лога нет. Демон сам перезапускает xray: до `XRAY_RESTARTS` = 3 раз с паузой `XRAY_RETRY` = 15 с, затем раз в `XRAY_BACKOFF` = 10 мин или сразу, как только бинарь изменился (inode, размер, mtime). Зависший перезапускается через `ubus call service signal` (SIGKILL, procd поднимает его заново), не запущенный — `reload` сервиса. После трёх неудач в `last_error` — «3 restarts did not help…». Как только xray снова отвечает, счётчик (`xray_restarts` в `status`) сбрасывается, отложенный выбор сервера выполняется, а ручной выбор (`select`) его отменяет. Во время reload и паузы после него (п. 6.1) проверок нет, так что перезапускающийся xray за отказ не считается. Отсчёты терпения и пауз идут по монотонным часам, их не сбивает NTP при загрузке.

`cli.uc generate` отбрасывает серверы, которые xray отвергает, но если xray отвергает и конфиг без серверов, сломан он сам: список серверов сохраняется (а не «нет серверов»), xray не запускается, демон показывает `xray_down` с выводом `xray run -test`.

ubus `xvpn`: `status` → `{state, active, since, fails, servers:[{id,name,proto,sub,latency,tested,quarantined}], testing, updating, passthrough, last_error, last_switch, last_test, xray_restarts}`; `test` (запустить тест всех); `select {id}`; `update {sid?}` (обновить подписки, `{ok:false, error:"busy"}`, если обновление уже идёт); `check` (проверить сейчас); `reindex` (перечитать индекс; вызывается из `service_started()` в `init.d/xvpn` после каждого start/reload).

Состояния (`state` в `status`; текст причины — в `last_error`):

| Состояние | Значение |
|-----------|----------|
| `starting` | демон только запущен, проверки ещё не было |
| `connected` | активный сервер отвечает |
| `degraded` | были неудачи, порог `fail_threshold` не достигнут |
| `failover` | активный в карантине, идёт тест всех и переход |
| `wan_down` | нет прямого интернета, серверы не трогаем |
| `no_servers` | в подписках нет серверов или ни один не отвечает (xray при этом работает) |
| `xray_down` | не работает сам xray (п. 6.2): серверы не в карантине, passthrough не включается; в `last_error` — причина и последние строки xray, `xray_restarts` — сколько перезапусков сделал демон |
| `error` | nft не принял правила, клиенты заблокированы |

## 7. nftables

```
table bridge xvpn {
  set ports { type ifname; flags interval; auto-merge;
              elements = { "lan2", "xvpn-ap0", "xvpn-ap0.*" } }        # порты + ifname SSID с маской
  chain pre { type filter hook prerouting priority -210;
              iifname @ports meta mark set meta mark | CLIENT }
}
table inet xvpn {
  set nets     { type ifname; flags interval; auto-merge;
                 elements = { "br-guest", "xvpn-ap0", "xvpn-ap0.*" } }   # сети + ifname SSID с маской
  set bypass4  { type ipv4_addr; flags interval; … RFC1918, CGNAT, loopback, link-local, multicast … }
  set bypass6  { type ipv6_addr; flags interval; ::1, fc00::/7, fe80::/10, ff00::/8 }
  chain mark     { prerouting, mangle-10: iifname @nets → mark |= CLIENT }
  chain tproxy   { prerouting, mangle: не CLIENT → return; dst local → return; dport 53 → return (hijack);
                   bypass → return; ipv6+block → return; tcp/udp → mark |= TPROXY, tproxy to :PORT }
  chain dns      { prerouting, dstnat-5: CLIENT && dport 53 → redirect to :DNS_PORT }
  chain forward  { forward, filter-5: CLIENT && не bypass → reject (kill switch; при ipv6=block — весь IPv6) }
  chain input    { input, filter-5: порты tproxy/dns не от CLIENT/TPROXY → drop }
}
ip rule add fwmark TPROXY/TPROXY table 100 ; ip route add local default dev lo table 100   (и -6)
```

Точки доступа → имена устройств (`resolve` в `firewall.uc`, при каждом `fw-*`):
- **Сеть** → L3-устройство и устройство из `network.interface dump` (когда netifd её поднял) плюс `network.<имя>.device` из UCI (до netifd — guard при загрузке); `@алиасы` пропускаются. У Wi-Fi-only сети (без `device`) L3-устройство — сам SSID, поэтому её SSID обрабатываются как выбранные SSID.
- **SSID** → фиксированный `ifname` из UCI (§7.2) и текущий ifname из `network.wireless status` (до того как netifd применил фиксированное имя). Имя SSID попадает и в `bridge @ports` (SSID в мосту: в `inet` iifname — мост), и в `inet @nets` (SSID — сам L3-интерфейс, мост его не видит). Вместе с именем в наборы идёт маска `имя.*`: станции WDS (`xvpn-ap0.sta1`) и динамические VLAN (`xvpn-ap0.5`) — отдельные интерфейсы, без маски их клиенты шли бы мимо VPN. Маска с точкой не задевает чужие имена (`xvpn-ap1.*` не совпадает с `xvpn-ap10`); для имён длиннее 13 символов её нет — подынтерфейс не уложится в 15. Маски — это интервалы, поэтому наборы с `flags interval` и `auto-merge` (имя внутри маски, например `xvpn-ap0.5` в сети, иначе даёт «conflicting intervals»). Fail-closed для SSID с WDS/VLAN отвергнут: эти режимы рабочие, а маска покрывает их без потери функции.
- **Порт** — как есть.

Сервис перезагружается по изменениям `xvpn`, `wireless`, `network`; правила перечитываются без перезагрузки по hotplug: `net`/`add` и `net`/`move` для `DEVTYPE=wlan` (ждёт до 15 с, пока ifname появится в `network.wireless status`) и `iface`/`ifup` для сетей из `access.network`.

Особенности:
- Метка, выставленная в `bridge`-таблице, сохраняется в skb и видна в `inet` prerouting — так один SSID/порт уходит в VPN без выделения отдельной сети.
- ICMP (ping) xray не проксирует: при kill switch пинг из VPN-сети в интернет не проходит — это ожидаемо.
- Flow offloading fw4 (на AX3000T есть аппаратный PPE): TPROXY-трафик доставляется локально и не офлоадится. Потоки, установленные до включения VPN, живут до завершения — UI предупреждает.

### 7.1 Режимы правил и жизненный цикл

| Режим | Что делает | Когда |
|-------|-----------|-------|
| `full` | перехват TPROXY + DNS, kill switch | xray работает (`fw-apply`) |
| `passthrough` | только метки и блок IPv6, клиенты идут напрямую | kill switch выключен и живых серверов нет (демон); `fw-guard` при выключенном kill switch |
| `block` | метки, reject forward в интернет и DNS клиентов к роутеру; без tproxy/fib/nat | `fw-guard` при kill switch; fallback при любой ошибке nft |
| `minimal` | только `inet`: reject forward для `iifname @nets`; отдельные порты и SSID не закрыты | последний fallback, если не принят и `block` (нет `kmod-nft-bridge`) |

Запрошенный режим (`fw_want`) и применённый (`fw_mode`) хранятся отдельно. `fw-refresh` применяет запрошенный, поэтому fallback и ошибка воспроизводятся сами, а `fw_error` удаляется только когда применился именно запрошенный режим. Все `fw-*` (init.d, демон, hotplug, include fw4) берут `/var/lock/xvpn-fw`, запрошенный режим читается уже под блокировкой. Устройства с именем длиннее 15 символов (IFNAMSIZ) отбрасываются с записью в лог: из-за них nft отверг бы весь файл. Без демона состояние правил отдаёт rpcd `luci.xvpn firewall` → `{want, mode, error, warning}` (`warning` — из `fw_warn`, §7.2).

Правила не исчезают, пока сервис включён (`main.enabled=1` и автозапуск `/etc/init.d/xvpn enable`):
- **Загрузка.** `xvpn-guard` (START=18, раньше fw4=19 и network=20) ставит `fw-guard`. `uci-defaults` включает `xvpn-guard` при каждой установке и апгрейде (postinst при апгрейде новые init-скрипты не включает): ручное `disable` действует только до следующего апгрейда. Имена устройств — без netifd: сети из UCI (`network.<имя>.device`), SSID — фиксированные `wireless.<секция>.ifname` (§7.2). `xvpn` (START=95) атомарно заменяет таблицу на `full`. `xvpn-guard start` (в т.ч. из postinst) ничего не делает — работает только `boot`.
- **stop / restart / upgrade / shutdown.** `stop_service` ставит `fw-guard`, `start` — `full`; `nft -f` атомарен, окна без правил нет. Если автозапуск `xvpn` выключен (`/etc/init.d/xvpn disable`) при `enabled=1`, `stop` снимает правила — `restart` даёт окно прямого доступа до `start`.
- **Выключение.** Правила снимаются (`fw-remove`) только при `enabled=0` или выключенном автозапуске; при удалении пакета `default_prerm` сначала делает `disable`, потом `stop`.
- **Ошибка nft (fail-closed).** `nft -f` не применяет файл частично — остаются прежние правила; затем `cli.uc` ставит `block`, пишет ошибку в `fw_error`, демон отдаёт `state: error`. Следующий успешный `fw-*` удаляет `fw_error`.
- **fw4 flush.** `service firewall stop` / `restart` (`fw4 flush`) удаляет все таблицы nft, в том числе наши. Include `firewall.xvpn` (type script, `fw4_compatible`) выполняется после каждого start/reload fw4 и, если есть `fw_want`, а таблицы `inet xvpn` нет, вызывает `fw-refresh`. Между `firewall stop` и следующим `start` правил нет. `postrm` удаляет include.
- **Wi-Fi поднялся позже, перезапуск радио, `wifi down; wifi up`.** У VPN-SSID фиксированное имя, оно в правилах с самого начала (guard берёт его из UCI) и при перезапуске не переходит к другому SSID — окна нет. hotplug `net` для `DEVTYPE=wlan` — `add` (интерфейс создан) и `move` (hostapd переименовал его на месте) — дожидается ifname в `network.wireless status` (до 15 с) и вызывает `fw-refresh`: убирает прежнее имя, которое мог занять другой SSID. Выключенный SSID (`disabled=1` или выключенное радио) остаётся в правилах только под своим фиксированным именем — его не займёт другой SSID.
- **Сеть поднялась.** hotplug `iface`/`ifup` для сети из `access.network` вызывает `fw-refresh`: L3-устройство (pppoe, Wi-Fi-only сеть) могло появиться или смениться.
- **SSID без имени (fail-closed).** Если у включённого VPN-SSID нет ни фиксированного, ни текущего имени (имя длиннее 15 символов, правка `wireless` не закоммичена), его клиентов правила не покрывают: `fw-*` ставит `block` для всех клиентов VPN (при запрошенном `passthrough` — `passthrough`: клиенты и так идут напрямую), пишет `access points not found: wifi "<секция>" (SSID "…") has no interface name` в `fw_error`, демон отдаёт `state: error`. Ошибка снимается следующим `fw-*`, когда имя нашлось или SSID выключен. Несуществующая секция или сеть ошибкой не считается — у неё нет клиентов.

### 7.2 Фиксированные имена SSID в `/etc/config/wireless`

netifd раздаёт имена `phy1-ap0`, `phy1-ap1`… по порядку при каждом запуске радио: имя VPN-SSID неизвестно до подъёма Wi-Fi (загрузка, `wifi up`) и может перейти к другому SSID после перезапуска. Поэтому xvpn меняет конфиг пользователя — только в этом месте:
- **Кому.** Выбранным SSID (`access.wifi`) и SSID Wi-Fi-only сетей из `access.network`. `cli.uc ifnames` (в начале каждого `start`/`reload` `init.d/xvpn`, в т.ч. при `enabled=0`) ставит им `option ifname 'xvpn-apN'` — наименьший свободный N. Своё имя, заданное пользователем (`option ifname` без префикса `xvpn-ap`), не трогается и используется как есть.
- **Пометка.** Секция, получившая имя от xvpn, помечается `option xvpn_ifname '1'`. Снимаются только помеченные имена; если пользователь потом сменил имя на своё (не `xvpn-apN`), удаляется только пометка.
- **Применение.** После `uci commit wireless` — `ubus call network reload` (то же, что `wifi reload`). netifd в 24.10 делает reconf: `hostapd.uc` сопоставляет BSS по хешу конфига и обычно переименовывает интерфейсы на месте (`bss.rename()`) без перезапуска радио; ядро шлёт `ACTION=move`. Переименовываться могут и соседние SSID: если VPN-SSID A (`phy1-ap0`) получил `xvpn-ap0`, домашний B может стать `phy1-ap0`. Поэтому: hotplug `net` реагирует и на `move`, а `ifnames` запускает в фоне `ifnames-wait` — ждёт (до 30 с), пока у всех включённых VPN-SSID в `network.wireless status` не появится фиксированное имя, и делает `fw-refresh`, убирая прежние имена. До этого правила содержат и фиксированное, и текущее имя (кратко в VPN может попасть и соседний SSID — это не утечка). Если hostapd всё же перезапускает радио, его клиенты переподключаются — только при выборе или снятии выбора SSID.
- **Откат.** SSID, снятые с выбора, теряют `xvpn-apN` при следующем `reload` (выбор в LuCI вызывает его сам). `postrm` снимает помеченные имена, но `network reload` не делает: пакет могут удалять через этот же Wi-Fi; прежние имена вернутся при следующем reload сети или перезапуске радио. Если в `wireless` есть чужие незакоммиченные изменения, `postrm` ничего не трогает.
- **Незакоммиченные правки.** Если в `wireless` есть чужие незакоммиченные изменения (`uci changes wireless`), а имена нужно выдать или снять, они не меняются (иначе `commit` закоммитил бы и чужое): предупреждение пишется в лог и в `fw_warn` (rpcd `luci.xvpn firewall` → `warning`), правила работают по текущим именам из netifd. Следующий `reload` после коммита правок снимает предупреждение.
- **Только точки доступа.** У Wi-Fi-only сети имена получают только её SSID с `mode` `ap` (или без `mode`); STA-аплинк той же сети (`wwan`) не трогается.

## 8. LuCI

| Вкладка | Содержимое |
|---------|-----------|
| Статус | состояние, активный сервер, пинг, аптайм, трафик через xray; подписки (трафик, срок); таблица серверов (пинг, «Использовать»); кнопки «Проверить все», «Обновить подписки», «Перезапустить», вкл/выкл |
| Подписки | таблица подписок (вкл., имя, URL, интервал, статус, трафик и срок; UA, фильтры, через туннель — в окне правки), «Обновить» у каждой и «Обновить все»; ручные ссылки с проверкой разбора |
| Точки доступа | сети / LAN-порты / SSID, kill switch, DNS, IPv6 |
| Настройки | проверка (URL, интервалы, порог, таймаут, авто-лучший, гистерезис, карантин, параллельность), порты, метки, лог-уровень, путь к xray |
| Журнал | `logread` по `xvpn`/`xray` |

LuCI обращается к демону только через rpcd `luci.xvpn`: uhttpd добавляет к аргументам каждого вызова `ubus_rpc_session`, а ubus-объект на ucode отклоняет аргументы вне своей политики (`INVALID_ARGUMENT`). Поэтому в `luci.xvpn` есть прокси `status` (ответ демона плюс `running: true`; без ответа — `{running: false}`; всегда — `enabled` из UCI и `time` роутера), `test` и `select {id}`, а в ACL нет объекта `xvpn`. rpcd ждёт демон не дольше 2 с (`connect(null, 2)`): зависший xvpnd не должен останавливать rpcd, а с ним и весь LuCI. Таймаут (ubus-код 7: демон есть, но занят или завис) отличается от отсутствия демона: `status` добавляет `timeout: true`, а `test`, `select` и `update` возвращают ошибку `timeout` вместо `not running` — действие могло и выполниться; `update` при таймауте не запускает `cli.uc update` сам. Аптайм, «N назад» и скорость считаются от `time` роутера, а не от часов браузера.

Вкладка «Статус» каждые 5 с (`poll`) вызывает `status`, `subscriptions {updating: false}` (флаг берётся из `status`), `firewall` и, только без демона, `servers`. `stats` запускает бинарник xray (`api statsquery`, синхронно в rpcd), поэтому вызывается не чаще раза в 30 с и только при работающем и включённом сервисе и не в `xray_down` (иначе rpcd ждал бы таймаута запроса); скорость — средняя между этими замерами (убрать запуск xray — #7). Страница перерисовывается целиком, но узлы кнопок и фокус сохраняются (кнопки серверов, ушедших из списка, выбрасываются), а при выделенном тексте перерисовка пропускается. Демон не ответил за 2 с — «демон не отвечает», а не «не запущен». «Отключить» и «Перезапустить» — с подтверждением. Неизвестное состояние демона показывается как есть.

Вкладка «Подписки» — `form.Map` над `xvpn`: `GridSection` секций `subscription` и `NamedSection` `manual`. Id подписки — имя её секции, под ним лежат кэш (`/etc/xvpn/subs/<sid>.json`) и статус (`/var/run/xvpn/sub-<sid>.json`). Имя анонимной секции зависит от её позиции: при перетаскивании или удалении подписки выше по списку оно меняется, а кэш и статус остались бы под старым. Поэтому новые подписки создаются именованными секциями `sub_<8 hex>`, а `uci-defaults` переименовывает старые анонимные (по одной, с коммитом после каждой) и переносит их кэш и статус. Кэш и статус подписок, которых больше нет в UCI, удаляет `cli.uc generate` (при каждом start/reload). curl качает подписку только по http/https, в том числе после редиректа. Статус каждой подписки (серверов, пропущено, формат, когда обновлена и как — через туннель или напрямую, ошибка, следующее обновление, profile-title) и трафик со сроком из `subscription-userinfo` берутся из `luci.xvpn subscriptions` и каждые 5 с обновляются в ячейках таблицы, не трогая форму. «Обновить» у подписки и «Обновить все» зовут `luci.xvpn update {sid}` и `update` без аргументов (`{"sid": null}` политика rpcd отклоняет) — только через демон, §6.1; пока идёт обновление, кнопки выключены, у неприменённой подписки — тоже. URL — http/https, не длиннее 2048 символов, записывается без пробелов по краям. Ручные ссылки — `textarea` по ссылке на строку (в UCI — `list link`); каждую строку разбирает `luci.xvpn parse_links` тем же `parse_link`, что и бэкенд (ответ без outbound — в нём учётные данные): под полем таблица — протокол, имя, адрес, ошибка или «дубликат строки N». Сохранить нельзя, пока есть ошибка разбора или строка без ответа проверки; если проверка не удалась (ошибка rpcd), повтор — только после правки текста. Имена, profile-title и ошибки выводятся только текстовыми узлами. Подпись состояния `error` и баннер `fw_error` зависят от применённого режима из `firewall`: `block`/`minimal` — клиенты VPN заблокированы, `passthrough` — идут напрямую; `fw_error` выводится с переносами строк, `warning` (из `fw_warn`, §7.2) — предупреждением.

## 9. Сборка и тесты

- Тесты (docker, образ `openwrt/rootfs:x86-64-24.10.4`): `scripts/test.sh` — парсер ссылок/подписок, генерация конфига, `xray run -test` на сгенерированном конфиге, рендер nft (все режимы) и `nft -c` (проверка синтаксиса), резолв сетей и SSID (UCI до netifd, живые имена, SSID в обоих наборах), фиксированные имена SSID (выдача, повторный запуск без изменений, откат при снятии выбора, своё имя пользователя, незакоммиченные правки), ошибка для SSID без имени, пометка `xvpn_ifname` (непомеченное `xvpn-ap0` не снимается), STA не получает имя, маски `имя.*` (нет маски для длинных имён), `ifnames_applied`, предупреждение при незакоммиченных правках; `nft -c` с маской, перекрывающей точное имя.
- Интеграционный тест `scripts/itest.sh` (procd в контейнере, `NAME=` для параллельных запусков): выбор сервера, failover, подписка; зависший xray (`kill -STOP`) и битый `xray_bin` → `xray_down` без карантина и passthrough, перезапуск, отказ после трёх и восстановление после починки бинаря без перезапуска демона; клиент в netns за портом моста и «интернет» в другом netns, fw4 запущен — туннель работает, прямого трафика нет при загрузке (guard), restart, stop, сломанном `nft` (fallback из passthrough, `state: error`, `fw-refresh` сохраняет ошибку, `minimal` без bridge); правила возвращаются после fw4 flush; SSID получают `xvpn-apN` (без радио — имена только из UCI) и попадают в оба набора, SSID без имени → `block` и `state: error`, при `passthrough` — клиенты напрямую и ошибка, выключенный — без ошибки; фоновое ожидание имён после выдачи; порт клиента, переименованный после правил в `xvpn-ap0` и `xvpn-ap0.sta1`, идёт в туннель, а `xvpn-ap10` — нет; hotplug `net` с `ACTION=add|move`; предупреждение и отказ от коммита при чужих правках `wireless` (и в `postrm`); `ifup` VPN-сети перечитывает правила; снятие выбора и `postrm` возвращают имена; `fw-remove` ждёт блокировку; правила снимаются при `enabled=0` и `disable`.
- LuCI для ручной проверки вкладок: `scripts/luci.sh` (procd в контейнере, `luci` + пакет из рабочей копии, два локальных VLESS-сервера — живой и мёртвый — и подписка с `subscription-userinfo` через CGI uhttpd) → http://127.0.0.1:8019, root / тестовый пароль из скрипта; `sync` — скопировать файлы пакета заново (с сохранением `/etc/config/xvpn`), `stop` — удалить контейнер. Переменные: `DOCKER` (по умолчанию `docker --context default`), `NAME`, `PORT`, `PASS`. `/etc/rc.d/S11sysctl` удаляется до `/sbin/init`: в `--privileged`-контейнере он менял бы sysctl хоста.
- Сборка ipk (docker, `openwrt/sdk:mediatek-filogic-24.10.4`): `scripts/build.sh` → `dist/luci-app-xvpn_*.ipk` (и `luci-i18n-xvpn-*.ipk`, когда появятся po-файлы). Из фида luci (ветка `openwrt-24.10`) берутся только `luci.mk`, `luci-base` и `csstidy`, и собираются лишь их host-утилиты; сам пакет собирается с `NO_DEPS=1` — иначе SDK компилировал бы все рантайм-зависимости (luci-base, xray-core вместе с Go), а пакету архитектуры `all` они нужны только в `Depends`. Пакет архитектуры `all`, так что SDK под другую архитектуру тоже подошёл бы. Переменные: `DOCKER` (по умолчанию `docker --context default`), `IMAGE`, `LUCI_FEED`.
- `XRAY_BIN=<путь к бинарю xray>` в `scripts/test.sh` проверяет конфиг этой сборкой вместо xray-core из фида.
- CI (`.github/workflows/ci.yml`, GitHub Actions): на каждый PR (проверяется его слияние с базовой веткой) и push в `main` — `test.sh` (матрица: xray из фида и последний релиз xray с GitHub, sha256 сверяется по `.dgst`; второй пока только предупреждает, см. #14), `itest.sh` (через 12 мин убивается с состоянием контейнера в логе), `build.sh` с ipk в артефакте `ipk` (хранится 30 дней). В Actions скрипты зовут обычный `docker`, локально — `DOCKER_CONTEXT=default` или `DOCKER=...`. `itest.sh` удаляет `S11sysctl` до запуска `/sbin/init`: в privileged-контейнере он записал бы sysctl хоста (`kernel.panic`, `core_pattern`). Все `ubus call` в itest ограничены `-t 5`, ожидания — дедлайном по часам; при `TIMEOUT` печатаются `xvpn status`, `service list`, список зависших вызовов и хвост `logread`.
- Релиз: тег `v<PKG_VERSION>` (при `PKG_RELEASE:=1`) или `v<PKG_VERSION>-r<PKG_RELEASE>`, например `v0.1.0`, `v0.1.0-r2`. Job `version` сверяет тег с Makefile и падает сразу; после зелёных `test`/`itest`/`build` публикуется GitHub Release с ipk. Pre-release-теги (`v0.2.0-rc1`) не поддерживаются — такой тег не совпадёт с Makefile. Сборка берёт голову ветки `openwrt-24.10` фида luci (`luci.mk`, host-утилиты luci-base/csstidy), а не зафиксированный коммит: ipk одного тега, собранный в разные дни, может немного отличаться; для точного воспроизведения — `LUCI_FEED='https://github.com/openwrt/luci.git^<коммит>'`.
- Установка на роутер:
  ```
  scp -O dist/luci-app-xvpn_*.ipk root@192.168.1.1:/tmp/   # -O: в 24.10 нет sftp-server
  ssh root@192.168.1.1 'opkg update && opkg install /tmp/luci-app-xvpn_*.ipk'
  ```

### Чек-лист проверки на AX3000T
1. Установка ipk тянет `xray-core`, `kmod-nft-tproxy`, `kmod-nft-socket`, `kmod-nft-bridge`, `curl`.
2. Добавить подписку → «Обновить» → серверы с пингами на вкладке «Статус».
3. Выбрать SSID и порт `lan2`, включить → с клиента на этом SSID/порту `curl ifconfig.me` = IP VPN-сервера; на `lan1` — IP провайдера.
4. `killall xray` → у клиентов VPN нет интернета (не утечка), procd поднимает xray за секунды. `killall -STOP xray` → на «Статусе» `xray_down`, через ~30–60 с демон перезапускает xray, серверы не в карантине.
5. `nft add rule inet fw4 output ip daddr <IP активного> drop` → через ~90 с переход на другой сервер.
6. dnsleaktest.com с клиента VPN — только DNS со стороны туннеля.
7. test-ipv6.com — IPv6 недоступен (режим block), утечки нет.
8. Перезагрузка роутера без доступа к подписке → VPN поднимается из кэша.
9. С клиента VPN-SSID `ping -i 0.2 1.1.1.1` во время `reboot`, `service xvpn restart`, `wifi down; wifi up` и перезапуска радио из LuCI — ни одного ответа (ICMP не туннелируется, ответ = утечка). `iw dev` — у VPN-SSID имя `xvpn-apN`.
10. `nft` без `kmod-nft-tproxy` (или испорченный `tproxy_port`) → клиенты без интернета, на «Статусе» ошибка.

## 10. Ограничения v1
- Только полный туннель (раздельная маршрутизация — в идеях).
- Трафик самого роутера в VPN не идёт.
- DNS клиентов VPN идёт на один `dns_server` через туннель — локальные имена (`*.lan`) у них не резолвятся.
- xray 25.1.30: нет VLESS `encryption` (ML-KEM), hysteria2, TUN. Решается подменой бинаря (`main.xray_bin`).

## 11. Идеи на будущее
- Мастер «VPN Wi-Fi сеть»: в пару кликов создать SSID и/или порты, отдельную сеть, DHCP, зону firewall.
- Исключения/включения по MAC/IP отдельных устройств.
- Уведомления в Telegram (переключение сервера, ошибки подписки, падение VPN).
- Раздельная маршрутизация (списки доменов/geosite, «Россия напрямую»).
- Обновление xray-core с GitHub (свежие версии, VLESS encryption, hysteria2).
- Горячее переключение без рестарта: balancer + `xray api bo`.
- LED-индикация статуса VPN на AX3000T.
- Импорт по QR, бэкап/восстановление настроек и кэша.
- Графики трафика и задержек.
- VPN для трафика самого роутера (опция).
