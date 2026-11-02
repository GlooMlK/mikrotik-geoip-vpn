# Архитектура GeoIP VPN на MikroTik

## Обзор

Двухуровневое GeoIP-разделение трафика на роутере MikroTik:
- **Российские ресурсы** → напрямую **ядром роутера** (kernel fast-path, линейная скорость)
- **Иностранные** → через VPN (VLESS + Reality в контейнере mihomo)
- **Локальная сеть** → без изменений

Зачем два уровня: userspace-прокси в контейнере на 2-ядерных ARM упирается в
~100-150 Мбит/с и 99% CPU. Грубое разделение (RU_GEO, 11.5K CIDR из RIPE
delegated) делается в mangle ДО контейнера — RU-трафик его вообще не достигает.
Точное (GeoIP/GeoSite, блок-листы РКН) — внутри mihomo.

## Компоненты

### MikroTik (роутер)
- **address-list RU_GEO**: 11 460 RU CIDR (генератор `scripts/ru-geo.py`, RIPE delegated; обновление раз в 1-3 месяца)
- **mangle (порядок важен!)**:
  1. `accept dst-address-list=RU_GEO in-interface=bridge` — RU мимо контейнера
  2. `mark-routing=to-vless dst-address=!ЛОКАЛКА in-interface=bridge` — остальное в контейнер
- **veth MIHOMO**: L3-модель — контейнер `12.0.0.5/24`, шлюз (router side) `12.0.0.2/24` на интерфейсе veth; veth НЕ является bridge-портом
- **routing table**: to-vless → default via 12.0.0.5
- **NAT (полный конфиг)**: DNS-редирект LAN → 12.0.0.5:53 (mihomo строит карту домен↔IP для доменных правил); masquerade на WAN
- **IPv6**: отключён (`disable-ipv6=yes`) — иначе v6 обходит всю систему

### Mihomo (контейнер)
- **TUN** (`stack: mixed`, `mtu: 1500`): пакеты приходят маршрутизацией с veth;
  `auto-redirect` в RouterOS-контейнере фактически неактивен (nftables в netns недоступен) —
  datapath чисто L3: routed → eth0 контейнера → TUN
- **GeoIP/GeoSite**: точная классификация того, что долетело (страховка RU_GEO + blocked-листы)
- **VLESS+Reality** (`xtls-rprx-vision`, **без mux/smux**): туннель к VPS
- **QUIC REJECT** (UDP 443) после GEOIP,RU: иностранный HTTP/3 режется —
  QUIC-в-TCP-туннеле даёт шторм ретрансмиссий (замер: один iPhone с iCloud = 98% CPU роутера)
- **Защита**: restart-policy=on-failure, memory-max, GOGC=40, GOMEMLIMIT + watchdog-scheduler на роутере

### Варианты конфигурации
| | geoip-config.yaml (полный) | geoip-lite.yaml |
|---|---|---|
| Роутеры | 512 МБ | 256 МБ |
| GeoIP-база (8 МБ RAM) | да | нет — RU уже отсечён списком RU_GEO |
| GeoSite | да (если geosite.dat скачался) | нет |
| DNS-сервер mihomo | да (+ NAT-редирект) | нет — клиенты на DNS роутера |
| Доменные правила | работают (через DNS-карту) | нет (только IP) |
| RAM контейнера | 50-90 МБ | 14-50 МБ |

### VPN-сервер (VPS)
- **Xray**: VLESS + Reality инбаунд; version pinned (26.6.27 — новые ломают REALITY-auth старых клиентов)
- Routing на VPS: `geosite:telegram` и Telegram DC → **direct** (не warp — сервис звонков игнорирует WARP-IP); `geosite:google-gemini` → direct; `geosite:category-ru` → direct
- **Панель 3x-ui закрыть** (firewall / 127.0.0.1 + SSH-tunnel)

## Поток трафика

```
[Устройство в LAN]
       |
       v mangle prerouting, in-interface=bridge:
[1] dst ∈ RU_GEO? ──── да ──→ ACCEPT → main table → ISP → RU-сайт
       | нет                        (ядро роутера, линейная скорость)
[2] dst не локалка? ──→ mark to-vless
       |
       v routing table to-vless → 12.0.0.5 (veth)
[Контейнер mihomo: TUN]
       |
   IP-правила: Telegram DC → VPN; ru-blocked → VPN; GEOIP RU/GEOSITE-ru → DIRECT;
   QUIC (udp 443) → REJECT; MATCH → VPN
       |
       ├── DIRECT → eth0 контейнера → 12.0.0.2 → роутер → ISP
       └── VPN → VLESS+Reality (TCP, без mux) → VPS → интернет
```

DNS: (полный конфиг) клиенты → NAT-редирект → mihomo DNS (77.88.8.8 напрямую
из контейнера) → карта домен↔IP для доменных правил. (lite) клиенты → DNS
роутера напрямую — контейнер в пути DNS не участвует.

## Модель отказов (fail-closed)

| Сценарий | Поведение |
|---|---|
| VPN-сервер недоступен | Иностранное — чёрная дыра (не утечёт в DIRECT); RU и локалка работают ядром |
| Контейнер упал/завис | Иностранное — чёрная дыра до авторестарта (~10 с, restart-policy/watchdog); RU работает ядром |
| Контейнер упал (полный конфиг, DNS-редирект) | DNS LAN умирает вместе с контейнером — сайты не открываются по имени, включая RU. Watchdog поднимает за ~минуту |
| RU_GEO устарел | Конкретный RU-IP уходит в контейнер: GEOIP,RU → DIRECT (медленнее, но работает) |
| Гео-база не скачалась | Кэшированная версия (бандл в репо) |
| Новый иностранный IP | Автоматически VPN (MATCH) |
| ISP включил IPv6 | Ничего не меняется — IPv6 отключён на роутере |

## Почему GeoIP, а не домены (fake-ip)?

| Подход | GeoIP | Домены (fake-ip) |
|---|---|---|
| Ручные списки | НЕ нужны | нужны |
| Приложение без DNS | ловится по IP | пролетает |
| DNS-петли | нет | возможны |
| Обслуживание | нулевое | постоянное |
| Новый иностранный | автоматически VPN | вручную вписать |

## Метрики (реальные замеры, MikroTik E50UG / hAP, 2026-11)

| Метрика | Значение |
|---|---|
| RU-трафик (kernel bypass) | 378+ Мбит/с (замер 800-Мбит канала) |
| CPU роутера под нагрузкой | 13% (было 98% до байпаса) |
| RAM контейнера: lite / полный | 14-50 МБ / 50-90 МБ |
| RU-сайты | 45-60 мс |
| VPN: RTT до VPS (EU) | 67 мс физика + 10-30 мс стек |
| Блок-листы IP | 75 000+ записей (.mrs) |
| RU_GEO | 11 460 CIDR (RIPE) |

## Совместимость

Проверено на:
- MikroTik E50UG (ARM, 512 МБ) — полный конфиг
- 256-МБ ARM-роутеры (hAP и др.) — lite-конфиг + RU_GEO
- RouterOS 7.13+
- mihomo v1.19.30 (pinned), Xray-core v26.6.27 (pinned)
