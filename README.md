# MikroTik + Mihomo + VLESS Reality + GeoIP VPN

Доменная GeoIP-маршрутизация на роутере MikroTik: российские сайты — напрямую, всё остальное — через VPN. Без ручных списков, с автообновлением блок-листов РКН каждые 6 часов.

## Архитектура

```
[LAN устройства]
       |
       v (mangle: весь трафик → mihomo)
[MikroTik] --veth--> [mihomo container]
                          |
                    GeoIP правила:
                    ├── RULE-SET ru-blocked (75K IP) ──────→ VPN
                    ├── RULE-SET ru-blocked-community (ТСПУ) → VPN
                    ├── GEOIP private (RFC6890) ────────────→ DIRECT
                    ├── GEOSITE category-ru (1162 домена) ──→ DIRECT
                    ├── GEOIP RU ────────────────────────────→ DIRECT
                    └── MATCH (всё остальное) ───────────────→ VPN
                          |
                    VPN: VLESS + Reality → ваш сервер
                          |
                    [VPS за рубежом] → интернет
```

## Что это даёт

| Преимущество | Как работает |
|---|---|
| **Ноль ручных списков** | GeoIP + антифильтр решают автоматически |
| **Заблокированный появился?** | Автоматически VPN (не RU IP) |
| **Новый банк/гос-сайт?** | Автоматически DIRECT (RU IP) |
| **Приложение без DNS (голый IP)** | GeoIP проверяет по IP |
| **Автообновление** | Блок-листы РКН обновляются каждые 6 часов |
| **Fail-closed** | VPN упал → заблокированные недоступны (не утекут в DIRECT) |
| **RU-сайты на полной скорости** | 45-60 мс напрямую |

## Требования

- MikroTik RouterOS 7.x с поддержкой containers (ARM/ARM64)
- USB-накопитель для контейнеров
- VPS за рубежом с VLESS + Reality (Xray)
- 512+ МБ RAM на роутере

## Быстрый старт

### 1. Подготовка VPS (за рубежом)

Установите 3x-ui или Xray вручную. Создайте VLESS + Reality инбаунд.

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
# RU-сайт (должен быть быстрый, ~50мс)
curl -o /dev/null -w "%{time_total}s" https://ya.ru/

# Заблокированный (должен работать через VPN)
curl -o /dev/null -w "%{time_total}s" https://api.telegram.org/
```

## Файлы

| Файл | Назначение |
|---|---|
| `configs/geoip-config.yaml` | Основной конфиг mihomo с GeoIP + антифильтр |
| `configs/my-srv.yaml.example` | Шаблон VLESS-ссылки (заменить на свою) |
| `scripts/setup-mikrotik.rsc` | Полный скрипт настройки MikroTik |
| `scripts/rollback.rsc` | Откат на стандартную маршрутизацию |
| `docs/architecture.md` | Подробное описание архитектуры |
| `docs/troubleshooting.md` | Решение проблем |

## Структура правил (приоритет)

```
1. RULE-SET ru-blocked         → VPN  (75K IP из реестра РКН)
2. RULE-SET ru-blocked-community → VPN  (ТСПУ-блоки, 833 IP)
3. GEOIP private               → DIRECT (локалка RFC6890)
4. GEOSITE category-ru         → DIRECT (1162 RU-домена)
5. GEOIP RU                    → DIRECT (все RU IP)
6. MATCH                       → VPN   (всё остальное)
```

## Источники блок-листов

- [runetfreedom/russia-blocked-geoip](https://github.com/runetfreedom/russia-blocked-geoip) — IP из реестра РКН
- [antifilter.download](https://antifilter.download) — исходные данные
- Обновление: автоматическое, каждые 6 часов

## Откат

```routeros
/ip firewall mangle enable 0,1,2
/ip firewall mangle disable [find comment="ALL LAN via mihomo"]
/container envs set [find key="CONFIG"] value=default_config.yaml
/container restart 0
```

## Лицензия

GPL-3.0 (наследие runetfreedom)

## Благодарности

- [wiktorbgu/mihomo-mikrotik](https://hub.docker.com/r/wiktorbgu/mihomo-mikrotik) — контейнер mihomo для MikroTik
- [runetfreedom](https://github.com/runetfreedom) — российские GeoIP/GeoSite базы
- [XTLS/Xray-core](https://github.com/XTLS/Xray-core) — VLESS + Reality протокол
- Статья [Habr: v2rayN для России](https://habr.com/ru/articles/853796/)
