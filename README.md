# MikroTik + Mihomo + VLESS Reality + GeoIP Router

GeoIP-разделение трафика на роутере MikroTik в два уровня: **российский — напрямую ядром роутера на линейной скорости**, иностранное — через VLESS+Reality в контейнере mihomo. Без ручных списков доменов, с автообновлением блок-листов каждые 6 часов.

> **Note:** Проект — сетевая конфигурация маршрутизации. Применяется для: доступа к рабочим ресурсам при командировках, защиты трафика в публичных сетях, разделения внутреннего и внешнего трафика в корпоративных сетях. Пользователь самостоятельно обеспечивает соответствие законодательству своей юрисдикции.

## Архитектура

Ключевая идея: **RU-трафик не должен проходить через userspace-прокси** — это и скорость (ядро vs контейнер), и CPU (2-ядерные ARM). Поэтому разделение делается дважды: грубо на роутере (address-list из RIPE), точно в mihomo (GeoIP).

```
[LAN устройства]
       |
       v  mangle prerouting:
       ├── 1. dst ∈ RU_GEO (11.5K CIDR от RIPE) ──→ ACCEPT, ядро → провайдер
       │      (RU на линейной скорости, контейнер не задействован)
       └── 2. всё остальное → routing-mark to-vless → veth → контейнер
                |
           [mihomo container]  (только иностранное + заблокированное)
                ├── IP-CIDR Telegram DC (звонки) ──→ VPN
                ├── RULE-SET ru-blocked ─────────→ VPN
                ├── GEOIP private ───────────────→ DIRECT
                ├── GEOSITE category-ru ─────────→ DIRECT  (страховка RU_GEO)
                ├── GEOIP RU ────────────────────→ DIRECT  (страховка RU_GEO)
                ├── UDP 443 (QUIC) ──────────────→ REJECT  (только иностранное)
                └── MATCH ───────────────────────→ VPN
                |
           VLESS + Reality (xtls-rprx-vision, БЕЗ mux) → [VPS] → интернет
```

Fail-closed: VPN/контейнер мёртв → иностранный трафик черную дыру (не утечёт в DIRECT), RU и локалка продолжают работать ядром.

## Что это даёт

| Преимущество | Как работает |
|---|---|
| **Ноль ручных списков** | RIPE-delegated (RU_GEO) + GeoIP-базы решают автоматически |
| **Иностранный сервис?** | Автоматически VPN (не RU IP) |
| **Новый банк/гос-сайт?** | Автоматически DIRECT (RU IP) |
| **RU на линейной скорости** | Ядро роутера, без VPN-детура (замер: 378+ Мбит/с) |
| **Низкий CPU** | Контейнер видит только иностранное (замер: 13% вместо 98%) |
| **Автообновление** | Блок-листы каждые 6 часов; RU_GEO — пересборка раз в 1-3 мес |
| **Fail-closed** | VPN недоступен → иностранное недоступно (не уйдёт в DIRECT) |
| **Самовосстановление** | restart-policy + memory-max + watchdog (см. ниже) |

## Требования

- MikroTik RouterOS **7.13+** с поддержкой containers (ARM/ARM64)
- USB-накопитель для контейнеров
- VPS с VLESS + Reality (Xray)
- 256+ МБ RAM на роутере (с lite-конфигом контейнер занимает 14-50 МБ)

## Быстрый старт

### 1. Подготовка VPS

Установите [3x-ui](https://github.com/MHSanaei/3x-ui) или Xray вручную. Создайте VLESS + Reality инбаунд. **Панель обязательно закройте** (firewall по своим IP / 127.0.0.1 + SSH-tunnel) — открытая панель = украденные креды всех клиентов.

### 2. Установка на MikroTik

Полный идемпотентный скрипт: **`scripts/setup-mikrotik.rsc`** (замените в нём подсеть и секрет). Ключевые шаги вручную:

```routeros
# IPv6 отключаем ОБЯЗАТЕЛЬНО (иначе v6-трафик ходит мимо всей системы!)
/ipv6 settings set disable-ipv6=yes

# veth: address = IP контейнера, gateway = IP роутера на veth
/interface veth add name=MIHOMO address=12.0.0.5/24 gateway=12.0.0.2
/ip address add address=12.0.0.2/24 interface=MIHOMO

# Таблица маршрутизации
/routing table add name=to-vless fib
/ip route add dst-address=0.0.0.0/0 gateway=12.0.0.5 routing-table=to-vless comment="via mihomo"

# Контейнер (envs и mounts — ДО container add!)
/container mounts add list=mihomo-cfg src=/usb1-part1/containers/etc/mihomo dst=/etc/mihomo
/container envs add list=MIHOMO key=CONFIG value=geoip-config.yaml
/container add remote-image=wiktorbgu/mihomo-mikrotik:1.19.30 \
  interface=MIHOMO envlist=MIHOMO mounts=mihomo-cfg start-on-boot=yes \
  restart-policy=on-failure restart-max-count=10 restart-interval=10s \
  memory-max=150MiB logging=yes comment="GeoIP VPN"
```

### 3. Конфигурация

Скопируйте файлы из `configs/` на USB:

```
/usb1-part1/containers/etc/mihomo/
├── geoip-config.yaml    ← полный конфиг (512 МБ роутеры)
├── geoip-lite.yaml      ← lite для 256 МБ (см. раздел ниже)
├── my-srv.yaml          ← ссылка VLESS (замените на свою!)
└── rules/*.mrs          ← блок-листы (в репо, для офлайн-старта)
```

Ссылка (`my-srv.yaml`) — из своего инбаунда:
```
vless://ВАШ_UUID@ВАШ_СЕРВЕР:ВАШ_ПОРТ?...&flow=xtls-rprx-vision&type=tcp#имя
```
⚠️ **НЕ добавляйте `smux=true`** — с `xtls-rprx-vision` это ломает UDP (звонки Telegram висят), замедляет всё и портит TLS-профиль Vision (см. troubleshooting, грабля 6).

### 4. DNS (для полного конфига)

Доменные правила (гос-сайты, category-ru) работают только если mihomo строит карту «домен↔IP» по своим DNS-ответам. Перехватываем DNS LAN → контейнер:

```routeros
/ip firewall nat add chain=dstnat action=dst-nat to-addresses=12.0.0.5 to-ports=53 \
    protocol=udp dst-port=53,1253,5353 in-interface=bridge dst-address-list=!local \
    comment="DNS -> mihomo udp"
# и то же для protocol=tcp
```
Для lite-конфига не нужно — клиенты остаются на DNS роутера.

### 5. Маршрутизация (mangle)

```routeros
# Сначала RU-байпас (см. следующий раздел — ОБЯЗАТЕЛЕН для lite, рекомендован всем)
# затем: весь остальной LAN-трафик через mihomo
/ip firewall mangle add \
  chain=prerouting action=mark-routing new-routing-mark=to-vless \
  passthrough=no in-interface=bridge \
  dst-address=!192.168.Х.0/24 \
  comment="ALL LAN via mihomo"
```
**Замените `192.168.Х.0/24` на вашу локальную подсеть!** Несколько подсетей/VLAN — используйте `dst-address-list=LOCAL_NETS`.

### 6. Watchdog (рекомендуется)

Контейнер может зависнуть «работает, но не отвечает» (наблюдалось на 256 МБ). Watchdog проверяет API раз в минуту и сам перезапускает:

```routeros
/system scheduler add name=mihomo-watchdog interval=1m \
  policy=ftp,read,write,policy,test on-event={
    :do { /tool fetch url="http://12.0.0.5:9090/version" \
        http-header-field="Authorization: Bearer ВАШ_СЕКРЕТ" output=user
    } on-error={
        :if ([/container get [find] running]) do={ /container restart [find] } \
        else={ /container start [find] }
    }
  }
```
⚠️ `policy=ftp` обязательна — без неё `/tool fetch` в шедулере молча падает (ловили на проде).

### 7. Проверка

С устройства в LAN:
```bash
# RU-ресурс — быстрый, ядром роутера
curl -o /dev/null -w "%{time_total}s\n" https://ya.ru/

# Иностранное — через VPN
curl -o /dev/null -w "%{time_total}s\n" https://api.telegram.org/

# Анти-утечка: должен показать IP вашего VPS
curl ifconfig.me
```

## Файлы

| Файл | Назначение |
|---|---|
| `configs/geoip-config.yaml` | Основной конфиг mihomo с GeoIP-маршрутизацией |
| `configs/geoip-lite.yaml` | **LITE для роутеров 256 МБ RAM** (−25-40 МБ памяти) |
| `configs/my-srv.yaml.example` | Шаблон VLESS-ссылки (заменить на свою) |
| `scripts/setup-mikrotik.rsc` | Полный скрипт настройки MikroTik |
| `scripts/ru-geo.py` | Генератор RU_GEO address-list (RIPE, 11.5K CIDR) |
| `scripts/rollback.rsc` | Откат на стандартную маршрутизацию |
| `docs/architecture.md` | Подробное описание архитектуры |
| `docs/troubleshooting.md` | Решение проблем |

## Роутеры с 256 МБ RAM (Pro-M, hAP и т.п.)

На 256-мегабайтных роутерах полный конфиг (GeoIP-база 8 МБ + GeoSite + DNS)
доводит контейнер до 85-116 МБ, роутер время от времени убивает его по OOM.
Рецепт для 256 МБ — **RU-байпас + lite-конфиг**:

```bash
# 1. RU-список на роутере (RU-трафик пойдёт мимо контейнера, ядром, линейно)
python3 scripts/ru-geo.py          # → ru_geo.rsc (11.5K записей)
scp ru_geo.rsc admin@РОУТЕР:ru_geo.rsc
```
```routeros
# 2. На роутере:
/import file=ru_geo.rsc
/ip firewall mangle add chain=prerouting action=accept \
    dst-address-list=RU_GEO in-interface=bridge \
    comment="RU GeoIP bypass container"
# затем поднимите ПЕРЕД правилом "ALL LAN" (не по номерам — они плывут):
/ip firewall mangle move [find comment="RU GeoIP bypass container"] [find comment="ALL LAN via mihomo"]

# 3. Lite-конфиг вместо основного:
#    залить configs/geoip-lite.yaml в /etc/mihomo контейнера и
/container envs set [find list="MIHOMO" && key="CONFIG"] value=geoip-lite.yaml

# 4. Защита от OOM (контейнер сам перезапустится за 10 сек):
/container set 0 restart-policy=on-failure restart-max-count=10 \
    restart-interval=10s memory-max=150MiB
/container envs add list=MIHOMO key=GOGC value=40
```

Замеры на реальном стенде (256 МБ): контейнер **14-51 МБ** вместо 85-116,
RU-трафик 378+ Мбит/с (ядром роутера), CPU 13% вместо 98%.

## Структура правил (приоритет)

```
Полный конфиг (geoip-config.yaml):
1. IP-CIDR Telegram DC        → VPN   (звонки: STUN/релеи до QUIC REJECT)
2. DOMAIN-SUFFIX гос/банки RF → DIRECT
3. RULE-SET ru-blocked        → VPN   (заблокированные РКН)
4. RULE-SET ru-blocked-community → VPN
5. GEOIP private              → DIRECT
6. GEOSITE category-ru        → DIRECT
7. GEOIP RU                   → DIRECT
8. UDP 443 (QUIC)             → REJECT (только иностранный долетает)
9. MATCH                      → VPN

Lite (geoip-lite.yaml): Telegram → QUIC REJECT → RULE-SET → приватные
CIDR → MATCH→VPN (RU отсекается раньше — списком RU_GEO на роутере)
```


## Откат

Выполните `scripts/rollback.rsc` — он отключает ВСЁ внедрённое (mangle-правила,
DNS-редирект, watchdog) по комментариям и возвращает LAN на прямую маршрутизацию
через провайдера. Не включайте правила по номерам (`enable 0,1,2`) — на чужом
роутере это случайные правила.

## Лицензия

GPL-3.0

## Благодарности и источники

Этот проект построен на труде следующих авторов и сообществ:

### Ключевые компоненты

- **[wiktorbgu/mihomo-mikrotik](https://hub.docker.com/r/wiktorbgu/mihomo-mikrotik)** — Docker-контейнер mihomo для MikroTik RouterOS. Упрощает развёртывание прокси-клиента на роутере.

- **[runetfreedom](https://github.com/runetfreedom)** — поддерживает актуальные GeoIP/GeoSite базы для маршрутизации. Репозитории:
  - [russia-blocked-geoip](https://github.com/runetfreedom/russia-blocked-geoip) — IP-базы
  - [russia-blocked-geosite](https://github.com/runetfreedom/russia-blocked-geosite) — доменные базы
  - Автообновление через GitHub Actions каждые 6 часов
  - Лицензия: GPL-3.0

- **[XTLS/Xray-core](https://github.com/XTLS/Xray-core)** — протокол VLESS и технология Reality для защищённых туннелей. Открытый исходный код.

### Источники данных

- [antifilter.download](https://antifilter.download) — агрегатор данных о сетевой доступности

### Статьи и вдохновение

- [v2rayN для России (Habr)](https://habr.com/ru/articles/853796/) — статья о региональных пресетах для v2rayN, вдохновившая на GeoIP-подход вместо ручных списков

### Фреймворки и утилиты

- [Mihomo (Clash Meta)](https://github.com/MetaCubeX/mihomo) — ядро прокси-клиента
- [MikroTik RouterOS](https://mikrotik.com) — сетевая операционная система
- [3x-ui](https://github.com/MHSanaei/3x-ui) — панель управления Xray

Всем авторам — благодарность за открытый код и свободный доступ к своим наработкам.

## Офлайн-установка (без доступа к GitHub)

Файлы rule-providers включены в репо: `configs/rules/*.mrs`. Загрузите их на MikroTik вместе с остальными конфигами — GitHub при первом запуске не нужен.

```bash
scp configs/rules/*.mrs admin@МИКРОТИК:/usb1-part1/containers/etc/mihomo/rules/
```

## Ложные срабатывания на RU-сайты

Некоторые российские IP случайно попадают в antifilter данные. В конфиге добавлены DIRECT-правила для 40+ гос-сервисов и банков. Если RU-сайт не открывается — добавьте перед `RULE-SET`:
```yaml
  - DOMAIN-SUFFIX,проблемный-сайт.ru,DIRECT
```

## Известные проблемы и решения

### Google Gemini / "Antigravity" — блокировка через WARP
**Симптом:** При авторизации "в вашем регионе недоступно".
**Причина:** Google блокирует Cloudflare WARP IP как VPN, даже из поддерживаемых стран.
**Решение:** Маршрутизировать gemini через direct (VPS IP) вместо warp на VPN-сервере:
```json
// Xray routing на VPS:
{"domain": ["geosite:google-gemini"], "outboundTag": "direct"}  // НЕ warp!
```
Если VPS в поддерживаемой стране (France поддерживает Gemini) — работает.

### Telegram звонки — висят на «Установка защищенного соединения»
**Симптом:** Сообщения работают, звонок после принятия вечно «устанавливает соединение».
**Причина (найдена на проде, три слоя):**
1. Сигналинг звонков шёл через WARP (Cloudflare) на VPS — сервис звонков Telegram
   игнорирует WARP-IP, E2E-хендшейк не начинался
2. `smux=true` в VLESS-ссылке ломал XUDP-сессии (`closed pipe` в логах Xray)
3. Релейный трафик (порты 4000/19302) не должен попадать под QUIC REJECT (UDP 443)

**Решение:**
- На VPS: `geosite:telegram` + `149.154.160.0/20`, `91.108.0.0/16` → outbound **direct**
  (НЕ warp; проверка: в access.log Xray `tcp:149.154.* [.. -> direct]`)
- В ссылке: **без smux** (грабля 6)
- В конфиге: Telegram IP-CIDR → VPN в начале правил (уже есть в обоих конфигах)

Диагностика тракта: перехватите реальный init-пакет релея (`tcpdump -X udp port 4000`),
отправьте те же байты с LAN-устройства через туннель — если ack возвращается,
тракт исправен и проблема в сигналинге.

### Госсайты (nalog.ru и др.) — ложные срабатывания блок-листов
**Симптом:** lkfl2.nalog.ru не открывается.
**Причина:** IP гос-сайтов попадают в antifilter блок-листы.
**Решение:** DOMAIN-SUFFIX правила для гос-доменов ПЕРЕД блок-листами:
```yaml
- DOMAIN-SUFFIX,nalog.ru,DIRECT  # до RULE-SET,ru-blocked
```
