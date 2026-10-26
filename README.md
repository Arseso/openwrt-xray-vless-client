# luci-app-xvpn

VPN-клиент для OpenWrt 24.10 на [xray-core](https://github.com/XTLS/Xray-core) с LuCI-интерфейсом.
Сам обновляет подписки, подключается к лучшему серверу по HTTP-пингу и переключается на другой,
если текущий перестал отвечать. В VPN идёт весь трафик выбранных точек доступа — сетей OpenWrt,
отдельных LAN-портов или отдельных SSID; остальные клиенты роутера ходят напрямую.

- Протоколы — всё, что умеет xray 25.1.30: `vless://` (Reality, XTLS-Vision, XHTTP, WS, gRPC,
  HTTPUpgrade, mKCP), `vmess://`, `trojan://`, `ss://`.
- Подписки: base64 или plain-список ссылок, xray-JSON; заголовки `subscription-userinfo`,
  `profile-update-interval`, `profile-title`. Плюс ручные ссылки.
- Kill switch: при падении xray, рестарте, загрузке роутера и ошибке nftables клиенты VPN остаются
  без интернета, а не уходят мимо туннеля.
- Защита DNS: DNS-запросы клиентов VPN перехватываются и идут через туннель; IPv6 блокируется.

Устройство, под которое делается проект, — Xiaomi AX3000T (`mediatek/filogic`, 256 МБ ОЗУ).
Пакет архитектуры `all` и должен работать на любом роутере с OpenWrt 24.10, где хватает памяти.

Статус: версия 0.1.0, **до релиза**. Проверено в контейнере OpenWrt (тесты и интеграционный тест),
на реальном роутере — ещё нет ([#25](https://github.com/Arseso/openwrt-xray-vless-client/issues/25)). Из интерфейса готова только вкладка «Статус», остальное
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

ipk будут выкладываться в [GitHub Releases](https://github.com/Arseso/openwrt-xray-vless-client/releases).
Скопируйте его на роутер и установите:

```bash
scp luci-app-xvpn_*.ipk root@192.168.1.1:/tmp/
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

owut / Attended Sysupgrade (ASU) собирают образ только из официальных фидов, `luci-app-xvpn` туда
не попадёт. Можно добавить в список пакетов образа зависимости (`xray-core`, `kmod-nft-tproxy`,
`kmod-nft-socket`, `kmod-nft-bridge`, `curl`, `ucode-mod-uloop`), тогда после обновления останется
поставить только сам ipk.

## Настройка

Раздел в LuCI: **Сервисы → XVPN**. Сейчас там работает вкладка «Статус»: состояние, активный
сервер, подписки, таблица серверов с пингом и кнопкой «Использовать», кнопки «Проверить все»,
«Обновить подписки», «Перезапустить» и «Включить»/«Отключить». Вкладки «Подписки» ([#20](https://github.com/Arseso/openwrt-xray-vless-client/issues/20)), «Точки
доступа», «Настройки» и «Журнал» ([#21](https://github.com/Arseso/openwrt-xray-vless-client/issues/21)) в работе — пока подписки, ручные ссылки и точки доступа
задаются через `uci` по SSH. Полная схема конфига — в [DESIGN.md §4](DESIGN.md#4-uci-схема-etcconfigxvpn).

### 1. Подписка или ссылки

```bash
uci add xvpn subscription
uci set xvpn.@subscription[-1].name='Мой VPN'
uci set xvpn.@subscription[-1].enabled='1'
uci set xvpn.@subscription[-1].url='https://example.com/sub/xxxx'
uci commit xvpn
```

Необязательные параметры подписки: `user_agent` (по нему панели Marzban/Remnawave/3x-ui выбирают
формат ответа), `update_interval` (часы; `0` — из заголовка `profile-update-interval` или 12),
`include`/`exclude` (регулярки по имени сервера), `via_tunnel` (`1` — качать через активный
сервер, при неудаче напрямую).

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
Wi-Fi. Своё `ifname`, заданное вами, не меняется. Подробности — [DESIGN.md §7.2](DESIGN.md#72-фиксированные-имена-ssid-в-etcconfigwireless).

### 3. Kill switch, DNS, IPv6

По умолчанию всё включено:

| Опция | По умолчанию | Значение |
|-------|--------------|----------|
| `xvpn.access.killswitch` | `1` | `0` — когда живых серверов нет, клиенты VPN идут напрямую |
| `xvpn.access.dns_hijack` | `1` | DNS клиентов VPN перехватывается и уходит через туннель |
| `xvpn.access.dns_server` | `1.1.1.1` | DNS-сервер, на который идут запросы клиентов |
| `xvpn.access.ipv6` | `block` | IPv6 клиентов VPN блокируется |

### 4. Включить

В LuCI — кнопка «Включить» на вкладке «Статус». Или:

```bash
uci set xvpn.main.enabled='1'
uci commit xvpn
/etc/init.d/xvpn enable
/etc/init.d/xvpn restart
ubus call xvpn update
```

Сервис работает, только если включены оба: `main.enabled=1` и автозапуск
(`/etc/init.d/xvpn enable`). `ubus call xvpn update` сразу скачивает подписки (иначе демон
сделает это сам по расписанию). После изменения `xvpn`, `wireless` или `network` через `uci commit`
сервис перезагружается сам.

## Как это работает

- **Полный туннель через TPROXY.** Трафик клиентов выбранных точек доступа метится в своих
  таблицах nftables (`bridge xvpn` — порты и SSID, `inet xvpn` — сети) и отправляется TPROXY в
  xray (TCP и UDP). Приватные адреса (LAN) идут как обычно. fw4 эти таблицы не трогает, после
  `fw4 flush` их возвращает include.
- **Failover в демоне.** Каждый сервер — отдельный outbound xray со своим тестовым SOCKS-портом.
  Демон `xvpnd` каждые 30 с проверяет активный сервер HTTP-пингом
  (`https://www.gstatic.com/generate_204`); после 3 неудач подряд проверяет прямой интернет и, если
  он есть, отправляет сервер в карантин и переходит на сервер с минимальным пингом. Переключение —
  перегенерация конфига и перезапуск xray (около секунды, соединения клиентов рвутся).
- **Kill switch.** Правила не снимаются при падении xray, рестарте и upgrade; при загрузке
  клиентов блокирует `xvpn-guard` ещё до fw4 и сети; если nft не принял правила — клиенты VPN
  блокируются, а статус показывает `error`.
- **Подписки** кэшируются в `/etc/xvpn/subs/`, поэтому VPN поднимается после перезагрузки без
  доступа к серверу подписки.

Подробно — [DESIGN.md](DESIGN.md): архитектура (§3), логика демона (§6), правила nftables и
жизненный цикл (§7).

## Ограничения и известные проблемы

- **Только полный туннель.** Раздельной маршрутизации (домены, «Россия напрямую») нет ([#30](https://github.com/Arseso/openwrt-xray-vless-client/issues/30)).
- **Трафик самого роутера идёт напрямую**, в том числе NTP, загрузка подписок с `via_tunnel=0` и
  при неудаче через туннель, `opkg` ([#35](https://github.com/Arseso/openwrt-xray-vless-client/issues/35)).
- **До синхронизации времени ряд протоколов не работает** ([#5](https://github.com/Arseso/openwrt-xray-vless-client/issues/5)). У AX3000T нет RTC; VMess (AEAD),
  Shadowsocks 2022, Reality и TLS чувствительны к расхождению часов. Сразу после загрузки демон
  может посчитать все серверы мёртвыми и уйти в `no_servers` до конца карантина (300 с).
- **Память** ([#7](https://github.com/Arseso/openwrt-xray-vless-client/issues/7)). На 256 МБ при генерации конфига дополнительно запускается `xray run -test`,
  вкладка «Статус» раз в 30 с запускает `xray api`, тест серверов — до 8 `curl` одновременно.
  OOM-killer может выбрать xray — обрыв у всех клиентов.
- **Не проверено на железе.** Тесты и интеграционный тест идут в контейнере OpenWrt x86-64;
  проверка на AX3000T по чек-листу ([#25](https://github.com/Arseso/openwrt-xray-vless-client/issues/25)) ещё не пройдена, в том числе с аппаратным offload (PPE).
- **ICMP не проксируется:** при включённом kill switch `ping` из VPN-сети в интернет не проходит —
  это ожидаемо.
- **Локальные имена.** DNS клиентов VPN уходит на один `dns_server` через туннель — имена `*.lan`
  у них не резолвятся.
- **Смена сервера рвёт все соединения** клиентов ([#13](https://github.com/Arseso/openwrt-xray-vless-client/issues/13)).
- **xray 25.1.30 из фида:** нет VLESS `encryption` (ML-KEM), hysteria2, tuic; транспорты `h2` и
  `quic` пропускаются. Путь к другому бинарю — `xvpn.main.xray_bin` (совместимость — [#14](https://github.com/Arseso/openwrt-xray-vless-client/issues/14)).
- Подписки в форматах Clash YAML и sing-box JSON не поддерживаются — смените `user_agent` ([#36](https://github.com/Arseso/openwrt-xray-vless-client/issues/36)).
- Прочие известные проблемы — в [issues](https://github.com/Arseso/openwrt-xray-vless-client/issues):
  например, xray не стартует при выключенном IPv6 или занятом порту ([#9](https://github.com/Arseso/openwrt-xray-vless-client/issues/9)), DNS клиентов зависит от
  UDP через сервер, а health-check этого не видит ([#10](https://github.com/Arseso/openwrt-xray-vless-client/issues/10)), большие подписки замедляют старт ([#8](https://github.com/Arseso/openwrt-xray-vless-client/issues/8)).

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
| `no_servers` | серверов нет или ни один не отвечает (xray при этом работает) |
| `xray_down` | не работает сам xray (упал, завис, битый конфиг или бинарь); причина и последние строки его лога — в `last_error`, демон сам перезапускает xray (`xray_restarts`) |
| `error` | nft не принял правила — клиенты VPN заблокированы (или, при выключенном kill switch, идут напрямую) |

Если демон не отвечает (`ubus call xvpn status` выдаёт ошибку) — сервис выключен или procd его
перезапускает.

```bash
logread -e xvpn
```

Журнал демона и скриптов (тег `xvpn`). Вывод xray procd пишет в журнал под именем бинаря:

```bash
logread -e xray
```

Ещё полезно:

```bash
ubus call xvpn test        # протестировать все серверы сейчас
ubus call xvpn check       # проверить активный сервер сейчас
nft list table inet xvpn   # применённые правила
```

Файлы состояния правил: `/var/run/xvpn/fw_mode` (применённый режим: `full`, `passthrough`, `block`,
`minimal`), `/var/run/xvpn/fw_error` (ошибка nft, есть только пока правила не применились).
Сгенерированный конфиг xray — `/var/etc/xvpn/config.json`.

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

Структура пакета и описание всех файлов — [DESIGN.md §3.1](DESIGN.md#31-файлы-пакета). Тесты и
стенды работают в docker на образе `openwrt/rootfs:x86-64-24.10.4`.

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

## Лицензия

MIT (`PKG_LICENSE` в `luci-app-xvpn/Makefile`).
