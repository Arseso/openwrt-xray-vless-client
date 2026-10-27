# luci-app-xvpn

VPN-клиент для OpenWrt 24.10 на [xray-core](https://github.com/XTLS/Xray-core) с LuCI-интерфейсом.
Сам обновляет подписки, подключается к лучшему серверу по HTTP-пингу и переключается на другой,
если текущий перестал отвечать. В VPN идёт весь трафик выбранных точек доступа — сетей OpenWrt,
отдельных LAN-портов или отдельных SSID; остальные клиенты роутера ходят напрямую.

- Ссылки `vless://` (Reality, XTLS-Vision, XHTTP, WS, gRPC, HTTPUpgrade, mKCP), `vmess://`,
  `trojan://`, `ss://` (без плагинов obfs/v2ray-plugin). WireGuard, SOCKS и HTTP-прокси не
  поддерживаются.
- Подписки: base64 или plain-список ссылок, xray-JSON (берётся первый outbound vless/vmess/trojan/
  shadowsocks, `sockopt` отбрасывается); заголовки `subscription-userinfo`,
  `profile-update-interval`, `profile-title`. Плюс ручные ссылки.
- Kill switch: при падении xray, рестарте, загрузке роутера и ошибке nftables клиенты VPN остаются
  без интернета, а не уходят мимо туннеля.
- Защита DNS: DNS-запросы клиентов VPN перехватываются и идут через туннель; IPv6 по умолчанию
  блокируется.

Устройство, под которое делается проект, — Xiaomi AX3000T (`mediatek/filogic`, 256 МБ ОЗУ).
Пакет архитектуры `all` и должен работать на любом роутере с OpenWrt 24.10, где хватает памяти.

Статус: версия 0.1.0, **до релиза**. Проверено в контейнере OpenWrt (тесты и интеграционный тест),
на реальном роутере — ещё нет ([#25](https://github.com/Arseso/openwrt-xray-vless-client/issues/25)). Из интерфейса готова только вкладка «Status», остальное
настраивается через `uci` (см. [Ограничения](#ограничения-и-известные-проблемы)).

Устройство и решения подробно описаны в [DESIGN.md](DESIGN.md).

## Требования

- OpenWrt **24.10** (тестируется на 24.10.4).
- Зависимости (ставятся `opkg` из штатных фидов автоматически): `luci-base`, `xray-core`, `curl`,
  `kmod-nft-tproxy`, `kmod-nft-socket`, `kmod-nft-bridge`, `ucode`, `ucode-mod-fs`,
  `ucode-mod-uci`, `ucode-mod-ubus`, `ucode-mod-uloop`.
- Флеш: `xray-core` 25.1.30 — ipk около 9.8 МБ, на флеше около 25 МБ; остальное — мелочь.
  Geo-файлы (`v2ray-geoip`/`v2ray-geosite`) не нужны.
- ОЗУ: xray — Go-процесс с заметным потреблением памяти. На 256 МБ работает, но запас небольшой,
  замеров на устройстве ещё нет ([#7](https://github.com/Arseso/openwrt-xray-vless-client/issues/7)). Роутеры со 128 МБ не рассматривались.

## Установка

### Готовый пакет

Релизы публикуются в
[GitHub Releases](https://github.com/Arseso/openwrt-xray-vless-client/releases) локальным CI
(`sh scripts/ci.sh release`) после зелёных тестов, интеграционного теста и сборки ipk
(`luci-app-xvpn_0.1.0-r1_all.ipk`). Релизов пока нет — соберите пакет сами (ниже).

Скопируйте ipk на роутер и установите (`-O`: в OpenWrt 24.10 нет sftp-server):

```bash
scp -O luci-app-xvpn_*.ipk root@192.168.1.1:/tmp/
```

```bash
ssh root@192.168.1.1 'opkg update && opkg install /tmp/luci-app-xvpn_*.ipk'
```

`opkg update` нужен, чтобы зависимости (в первую очередь `xray-core`) скачались из фидов.

### Сборка из исходников

Нужен docker. Сборка идёт в OpenWrt SDK 24.10.4 (`openwrt/sdk:mediatek-filogic-24.10.4`):

```bash
sh scripts/build.sh
```

Результат — `dist/luci-app-xvpn_*.ipk`; дальше как выше. По умолчанию скрипт вызывает
`docker --context default`, другой docker задаётся переменной `DOCKER`.

### После обновления прошивки (sysupgrade)

sysupgrade не сохраняет установленные пакеты: после обновления `luci-app-xvpn` (и `xray-core`)
нужно поставить заново. `/etc/config/xvpn` и `/etc/xvpn/` (кэш подписок) объявлены в conffiles
пакета; изменённый `/etc/config/xvpn` sysupgrade сохраняет. Сохранение кэша на устройстве не
проверялось — надёжнее добавить его в список сохраняемых файлов (без кэша подписки просто
скачаются заново):

```bash
echo /etc/xvpn/ >> /etc/sysupgrade.conf
```

Пока пакет не установлен, правил xvpn нет — клиенты VPN-точек ходят в интернет напрямую. Include
`firewall.xvpn` в `/etc/config/firewall` и имена `xvpn-apN` в `/etc/config/wireless` при этом
остаются и снова используются после установки.

С owut / Attended Sysupgrade пакет не проверялся.

## Настройка

Раздел в LuCI: **Services → XVPN**. Интерфейс пока на английском (переводов нет, [#22](https://github.com/Arseso/openwrt-xray-vless-client/issues/22)). Готова
только вкладка **Status**: состояние, активный сервер, подписки, таблица серверов с пингом и
кнопкой «Use», кнопки «Test all», «Update subscriptions», «Restart» и «Enable»/«Disable».

В меню уже есть вкладки Subscriptions, Access points, Settings и Log, но страниц для них ещё нет —
при открытии LuCI покажет ошибку. «Subscriptions» — [#20](https://github.com/Arseso/openwrt-xray-vless-client/issues/20) (PR [#45](https://github.com/Arseso/openwrt-xray-vless-client/pull/45) в работе), остальные — [#21](https://github.com/Arseso/openwrt-xray-vless-client/issues/21). Пока
подписки, ручные ссылки и точки доступа задаются через `uci` по SSH. Полная схема конфига — в
[DESIGN.md §4](DESIGN.md#4-uci-схема-etcconfigxvpn).

Простой `uci commit` по SSH сервис **не** перезагружает: триггеры procd срабатывают на
`reload_config` (его вызывает и LuCI). Поэтому после правок ниже выполните одно из:

```bash
reload_config
```

```bash
/etc/init.d/xvpn reload
```

### 1. Подписка или ссылки

```bash
uci add xvpn subscription
uci set xvpn.@subscription[-1].name='Мой VPN'
uci set xvpn.@subscription[-1].enabled='1'
uci set xvpn.@subscription[-1].url='https://example.com/sub/xxxx'
uci commit xvpn
```

Необязательные параметры подписки:

| Опция | По умолчанию | Значение |
|-------|--------------|----------|
| `user_agent` | `v2rayN/7.0` | по нему панели Marzban/Remnawave/3x-ui выбирают формат ответа |
| `update_interval` | `0` | часы; `0` — из заголовка `profile-update-interval`, иначе 12 |
| `include`, `exclude` | — | регулярки по имени сервера, без учёта регистра |
| `via_tunnel` | `1` | качать через активный сервер, при неудаче — напрямую; `0` — сразу напрямую |

Отдельные ссылки без подписки:

```bash
uci add_list xvpn.manual.link='vless://…#Мой сервер'
uci commit xvpn
```

### 2. Точки доступа

Что пускать в VPN — секция `xvpn.access`, можно сочетать:

```bash
uci add_list xvpn.access.network='guest'    # вся сеть OpenWrt (имя из `uci show network`)
uci add_list xvpn.access.port='lan2'        # отдельный LAN-порт моста (DSA)
uci add_list xvpn.access.wifi='wifinet2'    # отдельный SSID: имя секции wifi-iface из `uci show wireless`
uci commit xvpn
```

Выбранным SSID xvpn прописывает в `/etc/config/wireless` фиксированное имя интерфейса
`option ifname 'xvpn-apN'` (и пометку `xvpn_ifname`), чтобы правила знали его ещё до подъёма
Wi-Fi; при снятии выбора имя убирается. Своё `ifname`, заданное вами, не меняется. При выборе или
снятии SSID выполняется `ubus call network reload` — клиенты Wi-Fi могут переподключиться.
Подробности — [DESIGN.md §7.2](DESIGN.md#72-фиксированные-имена-ssid-в-etcconfigwireless).

### 3. Kill switch, DNS, IPv6

| Опция | По умолчанию | Значение |
|-------|--------------|----------|
| `xvpn.access.killswitch` | `1` | `0` — когда живых серверов нет, клиенты VPN идут напрямую; ICMP и всё, кроме TCP/UDP, идёт мимо туннеля всегда |
| `xvpn.access.dns_hijack` | `1` | DNS клиентов VPN перехватывается и уходит через туннель |
| `xvpn.access.dns_server` | `https://cloudflare-dns.com/dns-query` | DNS клиентов: URL — DoH через DNS-модуль xray (запрос идёт к серверу по домену; типы, кроме A/AAAA, отбрасываются), IP — пересылка на `<IP>:53` через туннель; схемы, кроме `https://` и `tcp://`, заменяются значением по умолчанию (`+local` ходили бы мимо туннеля). После обновления с версии, где было `sniffing '0'` и `dns_server '1.1.1.1'`, эти значения остаются в конфиге — поменяйте вручную |
| `xvpn.access.ipv6` | `block` | `block` — IPv6 клиентов VPN блокируется; `tunnel` — IPv6 TCP/UDP тоже идёт в туннель |

С `killswitch=1` в интернет из VPN-точек проходит только TCP/UDP через xray, остальное (в том числе
ICMP) отклоняется.

### 4. Включить

В LuCI — кнопка «Enable» на вкладке Status. Или:

```bash
uci set xvpn.main.enabled='1'
uci commit xvpn
/etc/init.d/xvpn enable
/etc/init.d/xvpn restart
```

Запуск сервиса зависит только от `main.enabled`, но автозапуск (`/etc/init.d/xvpn enable`) тоже
нужен: без него сервис не стартует при загрузке, клиентов не блокирует `xvpn-guard`, а `stop`/`restart` снимают
правила — до старта xray клиенты идут напрямую. Кнопка «Enable» ставит и то, и другое.

Если серверов ещё нет, демон сам скачивает подписки при старте. Принудительно обновить их позже —
кнопкой «Update subscriptions» или:

```bash
ubus call xvpn update
```

## Как это работает

- **Полный туннель через TPROXY.** Трафик клиентов выбранных точек доступа метится в своих
  таблицах nftables (`bridge xvpn` — порты и SSID, `inet xvpn` — сети и SSID) и TCP/UDP
  отправляется TPROXY в xray. Приватные адреса (LAN) идут как обычно. fw4 эти таблицы не трогает,
  после `fw4 flush` их возвращает include.
- **Failover в демоне.** Каждый сервер — отдельный outbound xray со своим тестовым SOCKS-портом.
  Демон `xvpnd` каждые 30 с проверяет активный сервер HTTP-пингом
  (`https://www.gstatic.com/generate_204`); после 3 неудач подряд проверяет прямой интернет и, если
  он есть, отправляет сервер в карантин и переходит на сервер с минимальным пингом. Переключение —
  перегенерация конфига и перезапуск xray (около секунды, соединения клиентов рвутся).
- **Kill switch.** Правила не снимаются при падении xray, рестарте и upgrade; при загрузке
  клиентов блокирует `xvpn-guard` ещё до fw4 и сети. Если nft не принял правила, они при любом
  значении `killswitch` откатываются на `block` (клиенты VPN без интернета), а если не принят и он —
  на `minimal` (закрыты только сети, отдельные порты и SSID — нет); статус — `error`.
- **Подписки** кэшируются в `/etc/xvpn/subs/`, поэтому VPN поднимается после перезагрузки без
  доступа к серверу подписки.

Подробно — [DESIGN.md](DESIGN.md): архитектура (§3), логика демона (§6), правила nftables и
жизненный цикл (§7).

## Ограничения и известные проблемы

- **Только полный туннель.** Раздельной маршрутизации (домены, «Россия напрямую») нет ([#30](https://github.com/Arseso/openwrt-xray-vless-client/issues/30)).
- **Трафик самого роутера идёт напрямую**, в том числе NTP, `opkg` и загрузка подписок с
  `via_tunnel=0` или после неудачи через туннель ([#35](https://github.com/Arseso/openwrt-xray-vless-client/issues/35)).
- **До синхронизации времени ряд протоколов не работает** ([#5](https://github.com/Arseso/openwrt-xray-vless-client/issues/5)). У AX3000T нет RTC; VMess (AEAD),
  Shadowsocks 2022, Reality и TLS чувствительны к расхождению часов. После загрузки все серверы
  могут не отвечать, и демон уходит в `no_servers`; VPN поднимается после синхронизации времени на
  следующем цикле проверки. Пока живых серверов нет, демон повторно тестирует все серверы каждые
  30–90 с ([#12](https://github.com/Arseso/openwrt-xray-vless-client/issues/12)).
- **Память.** xray занимает 25–35 МБ при 20–200 серверах (замер в контейнере x86-64, на AX3000T
  уточнится в [#25](https://github.com/Arseso/openwrt-xray-vless-client/issues/25)) и запускается с
  `GOMEMLIMIT=80MiB GOGC=50` (скрытые опции `xvpn.main.gomemlimit` / `gogc`). Второй xray
  (`xray run -test`) запускается, только когда меняется список серверов или бинарь, вкладка Status
  xray не запускает, тест серверов — до 4 `curl` одновременно. Под очень большой нагрузкой xray
  всё же может занять много памяти, и OOM-killer выберет его — обрыв у всех клиентов.
- **Проверено на AX3000T** (OpenWrt 24.10.5, в том числе с аппаратным offload PPE) по чек-листу
  [#25](https://github.com/Arseso/openwrt-xray-vless-client/issues/25), кроме VPN-SSID, dnsleaktest
  и IPv6 — их ещё нужно пройти на устройстве.
- **ICMP не проксируется.** С kill switch `ping` из VPN-сети в интернет не проходит — это ожидаемо.
  Без kill switch ICMP и прочее не-TCP/UDP идёт напрямую даже при работающем VPN.
- **Без kill switch при `xray_down`** клиенты остаются без интернета: напрямую их пускают, только
  когда xray работает, но живых серверов нет.
- **Серверы, которые не пускают к IP.** Многие серверы принимают только соединения по домену. Поэтому
  по умолчанию включён `xvpn.main.sniffing` (домен берётся из HTTP/TLS/QUIC), а DNS идёт по DoH. Трафик
  без домена (игры, VoIP по IP, прочий UDP) через такие серверы не пройдёт; DNS с `dns_hijack=0` — тоже.
- **Локальные имена.** DNS клиентов VPN уходит на один `dns_server` через туннель — имена `*.lan`
  у них не резолвятся.
- **Смена сервера рвёт все соединения** клиентов ([#13](https://github.com/Arseso/openwrt-xray-vless-client/issues/13)).
- **xray 25.1.30 из фида:** нет VLESS `encryption` (ML-KEM), hysteria2, tuic; транспорты `h2` и
  `quic` пропускаются. Путь к другому бинарю — `xvpn.main.xray_bin` (совместимость — [#14](https://github.com/Arseso/openwrt-xray-vless-client/issues/14)).
- Подписки в форматах Clash YAML и sing-box JSON не поддерживаются — смените `user_agent` ([#36](https://github.com/Arseso/openwrt-xray-vless-client/issues/36)).
- Прочие известные проблемы — в [issues](https://github.com/Arseso/openwrt-xray-vless-client/issues):
  - флаг `reloading` может зависнуть и остановить health-check ([#6](https://github.com/Arseso/openwrt-xray-vless-client/issues/6), PR [#46](https://github.com/Arseso/openwrt-xray-vless-client/pull/46));
  - health-check не замечает DPI-деградацию и ложно уходит в `wan_down` ([#11](https://github.com/Arseso/openwrt-xray-vless-client/issues/11));
  - DNS клиентов зависит от UDP через сервер, а health-check этого не видит ([#10](https://github.com/Arseso/openwrt-xray-vless-client/issues/10));
  - адреса серверов резолвит системный DNS — подмена у провайдера ломает подключение ([#16](https://github.com/Arseso/openwrt-xray-vless-client/issues/16));
  - нет настройки policy xray под UDP-нагрузку, например торренты ([#15](https://github.com/Arseso/openwrt-xray-vless-client/issues/15));
  - xray не стартует при выключенном IPv6 или занятом порту ([#9](https://github.com/Arseso/openwrt-xray-vless-client/issues/9));
  - большие подписки замедляют старт и раздувают конфиг ([#8](https://github.com/Arseso/openwrt-xray-vless-client/issues/8)).

## Диагностика

```bash
ubus call xvpn status
```

Состояние демона, активный сервер, пинги всех серверов, `last_error`. Поле `state`:

| Состояние | Значение |
|-----------|----------|
| `starting` | демон только запущен, проверки ещё не было |
| `connected` | активный сервер отвечает |
| `degraded` | были неудачные проверки, порог для переключения не достигнут |
| `failover` | активный в карантине, идёт тест всех и переход |
| `wan_down` | нет прямого интернета, серверы не трогаем |
| `no_servers` | серверов нет (тогда xray не запускается) или ни один не отвечает (xray при этом работает) |
| `xray_down` | не работает сам xray (упал, завис, битый конфиг или бинарь); причина и последние строки его лога — в `last_error`, демон сам перезапускает xray (`xray_restarts`) |
| `error` | правила не применились: nft их не принял (клиенты VPN заблокированы, режим `block` или `minimal`) или у выбранного SSID нет имени интерфейса (`access points not found` — клиенты заблокированы, а при запрошенном `passthrough` идут напрямую) |

Если демон не отвечает (`ubus call xvpn status` выдаёт ошибку) — сервис выключен или procd его
перезапускает.

```bash
logread -e 'xvpn|xray'
```

Журнал демона и скриптов (тег `xvpn`) и вывод xray (procd пишет его под именем бинаря).

Ещё полезно:

```bash
ubus call xvpn test          # протестировать все серверы сейчас
ubus call xvpn check         # проверить активный сервер сейчас
nft list table inet xvpn     # правила для сетей и SSID
nft list table bridge xvpn   # метки для портов и SSID в мосту
```

Файлы состояния правил: `/var/run/xvpn/fw_mode` (применённый режим: `full`, `passthrough`, `block`,
`minimal`), `/var/run/xvpn/fw_error` (текст ошибки, есть только пока запрошенный режим не
применился). Сгенерированный конфиг xray — `/var/etc/xvpn/config.json`.

## Удаление

```bash
opkg remove luci-app-xvpn
```

- Сервис останавливается и выключается, правила nftables снимаются — клиенты бывших VPN-точек
  ходят в интернет напрямую. Include `firewall.xvpn` удаляется из `/etc/config/firewall`.
- Фиксированные имена `xvpn-apN` снимаются с SSID (только помеченные `xvpn_ifname`), но
  `wifi reload` не делается — пакет могут удалять через этот же Wi-Fi. Прежние имена вернутся при
  следующей перезагрузке сети или радио. Если в `wireless` есть чужие незакоммиченные изменения,
  имена не трогаются.
- `xray-core` и другие зависимости остаются, их можно удалить отдельно. Настройки и кэш при
  необходимости удалите вручную: `/etc/config/xvpn`, `/etc/xvpn/`.

## Разработка

Структура пакета и описание всех файлов — [DESIGN.md §3.1](DESIGN.md#31-файлы-пакета), сборка и
тесты — [§9](DESIGN.md#9-сборка-и-тесты). Тесты и стенды работают в docker на образе
`openwrt/rootfs:x86-64-24.10.4`.

```bash
DOCKER_CONTEXT=default sh scripts/test.sh
```

Модульные тесты: парсер ссылок и подписок, генерация конфига с `xray run -test`, рендер правил с
`nft -c`, имена SSID.

```bash
DOCKER_CONTEXT=default sh scripts/itest.sh
```

Интеграционный тест: сервис под procd в `--privileged`-контейнере, локальные VLESS-серверы,
клиент в network namespace; выбор сервера, failover, подписка, kill switch при загрузке, рестарте и
ошибке nft, `xray_down`. `NAME=` — имя контейнера для параллельных запусков.

```bash
sh scripts/luci.sh
```

LuCI с пакетом из рабочей копии и тестовыми серверами для ручной проверки интерфейса:
http://127.0.0.1:8019, логин `root`, пароль — переменная `PASS` в скрипте. `sh scripts/luci.sh sync`
копирует файлы пакета заново (настройки сохраняются), `sh scripts/luci.sh stop` удаляет контейнер.

`DOCKER_CONTEXT=default` нужен, если docker по умолчанию смотрит в другой контекст (например,
незапущенный Docker Desktop). `scripts/build.sh` и `scripts/luci.sh` сами вызывают
`docker --context default`; все скрипты принимают переменную `DOCKER`.

CI выполняется локально, GitHub Actions не используется. Перед каждым push и PR:

```bash
sh scripts/ci.sh
```

Скрипт проверяет закоммиченный HEAD (незакоммиченные изменения не проверяются): `test.sh` с
xray из фида и с последним релизом xray с GitHub (пока только предупреждение, [#14](https://github.com/Arseso/openwrt-xray-vless-client/issues/14)), `itest.sh`
(не дольше 12 мин) и `build.sh`; ipk — в `dist/`, логи шагов — в `.ci/`. Занимает около
15 минут.

Релиз — из запушенного `main` с чистым деревом:

```bash
sh scripts/ci.sh release
```

После тех же проверок ставит тег `v<PKG_VERSION>` (или `v<PKG_VERSION>-r<PKG_RELEASE>` при
`PKG_RELEASE` ≠ 1), пушит его и публикует GitHub Release с ipk (нужен `gh` с доступом к
репозиторию). Для нового релиза поднимите `PKG_VERSION` или `PKG_RELEASE` в
`luci-app-xvpn/Makefile`.

## Лицензия

MIT (`PKG_LICENSE` в `luci-app-xvpn/Makefile`).
