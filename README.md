# MikroTik + Mihomo + VLESS Reality + GeoIP Router

Автоматическая GeoIP-маршрутизация на роутере MikroTik: российские ресурсы — напрямую, иностранные — через VPN-туннель. Без ручных списков, с автообновлением гео-баз каждые 6 часов.

> **Note:** Проект — сетевая конфигурация маршрутизации. Применяется для: доступа к рабочим ресурсам при командировках, защиты трафика в публичных сетях, разделения внутреннего и внешнего трафика в корпоративных сетях. Пользователь самостоятельно обеспечивает соответствие законодательству своей юрисдикции.

## Архитектура

```
[LAN устройства]
       |
       v (mangle: весь трафик → mihomo)
[MikroTik] --veth--> [mihomo container]
                          |
                    GeoIP правила:
                    ├── RULE-SET ru-blocked ──────────→ VPN
                    ├── RULE-SET ru-blocked-community ─→ VPN
                    ├── GEOIP private (RFC6890) ──────→ DIRECT
                    ├── GEOSITE category-ru ──────────→ DIRECT
                    ├── GEOIP RU ─────────────────────→ DIRECT
                    └── MATCH (всё остальное) ────────→ VPN
                          |
                    VPN: VLESS + Reality → ваш сервер
                          |
                    [VPS] → интернет
```

## Что это даёт

| Преимущество | Как работает |
|---|---|
| **Ноль ручных списков** | GeoIP-базы решают автоматически |
| **Иностранный сервис?** | Автоматически VPN (не RU IP) |
| **Новый банк/гос-сайт?** | Автоматически DIRECT (RU IP) |
| **Приложение без DNS (голый IP)** | GeoIP проверяет по IP |
| **Автообновление** | Гео-базы обновляются каждые 6 часов |
| **Fail-closed** | VPN недоступен → иностранные ресурсы недоступны (не уйдут в DIRECT) |
| **RU-ресурсы на полной скорости** | 45-60 мс напрямую |

## Требования

- MikroTik RouterOS 7.x с поддержкой containers (ARM/ARM64)
- USB-накопитель для контейнеров
- VPS с VLESS + Reality (Xray)
- 256+ МБ RAM на роутере (проверено на 256 МБ — работает, 128 МБ — не рекомендуется)

## Быстрый старт

### 1. Подготовка VPS

Установите [3x-ui](https://github.com/MHSanaei/3x-ui) или Xray вручную. Создайте VLESS + Reality инбаунд.

### 2. Установка контейнера на MikroTik

```routeros
# Включаем containers
/device-mode update container=yes

# Создаём veth
/interface veth add name=MIHOMO address=12.0.0.2/24 gateway=12.0.0.1

# Добавляем bridge-порт
/interface bridge port add bridge=bridge interface=MIHOMO

# IP на bridge для veth
/ip address add address=12.0.0.1/24 interface=bridge

# Контейнер
/container add remote-image=wiktorbgu/mihomo-mikrotik:1.19.30 interface=MIHOMO envlist=MIHOMO start-on-boot=yes
```

### 3. Конфигурация

Скопируйте файлы из `configs/` на USB:

```
/usb1-part1/containers/etc/mihomo/
├── geoip-config.yaml    ← основной конфиг
├── my-srv.yaml          ← ссылка VLESS (замените на свою!)
└── rules/               ← создастся автоматически
```

Замените в `my-srv.yaml` ссылку на свою:
```
vless://ВАШ_UUID@ВАШ_СЕРВЕР:ВАШ_ПОРТ?...&sni=ВАШ_SNI&...#имя
```

### 4. Маунт и запуск

```routeros
/container mounts add list=mihomo-cfg src=/usb1-part1/containers/etc/mihomo dst=/etc/mihomo
/container set 0 mountlist=mihomo-cfg
/container envs add list=MIHOMO key=CONFIG value=geoip-config.yaml
/container restart 0
```

### 5. Маршрутизация (mangle)

```routeros
# Отключаем старые правила (если были)
/ip firewall mangle disable 0,1,2

# Единственное правило: весь LAN-трафик через mihomo
/ip firewall mangle add \
  chain=prerouting \
  action=mark-routing \
  new-routing-mark=to-vless \
  passthrough=no \
  in-interface=bridge \
  dst-address=!192.168.Х.0/24 \
  comment="ALL LAN via mihomo"

# Таблица маршрутизации
/ip route add dst-address=0.0.0.0/0 gateway=12.0.0.5 routing-table=to-vless
```

**Замените `192.168.Х.0/24` на вашу локальную подсеть!**

### 6. Проверка

С устройства в LAN:
```bash
# RU-ресурс (должен быть быстрый, ~50мс)
curl -o /dev/null -w "%{time_total}s" https://ya.ru/

# Иностранный ресурс (должен работать через VPN)
curl -o /dev/null -w "%{time_total}s" https://api.telegram.org/
```

## Файлы

| Файл | Назначение |
|---|---|
| `configs/geoip-config.yaml` | Основной конфиг mihomo с GeoIP-маршрутизацией |
| `configs/my-srv.yaml.example` | Шаблон VLESS-ссылки (заменить на свою) |
| `scripts/setup-mikrotik.rsc` | Полный скрипт настройки MikroTik |
| `scripts/rollback.rsc` | Откат на стандартную маршрутизацию |
| `docs/architecture.md` | Подробное описание архитектуры |
| `docs/troubleshooting.md` | Решение проблем |

## Структура правил (приоритет)

```
1. RULE-SET ru-blocked           → VPN
2. RULE-SET ru-blocked-community → VPN
3. GEOIP private                 → DIRECT (локалка RFC6890)
4. GEOSITE category-ru           → DIRECT (RU-домены)
5. GEOIP RU                      → DIRECT (RU IP-адреса)
6. MATCH                         → VPN (всё остальное)
```

## Откат

```routeros
/ip firewall mangle enable 0,1,2
/ip firewall mangle disable [find comment="ALL LAN via mihomo"]
/container envs set [find key="CONFIG"] value=default_config.yaml
/container restart 0
```

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
