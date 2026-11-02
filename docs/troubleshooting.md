# Решение проблем

## Контейнер не стартует

```routeros
/container print
/log print where topics~"container"
```

Если `exited with status 1`:
- Проверьте что `geoip-config.yaml` на месте: `/file print where name~"geoip"`
- Проверьте что `my-srv.yaml` содержит валидную ссылку
- Попробуйте дефолт: `/container envs set [find key="CONFIG"] value=default_config.yaml`

## Туннель не подключается

1. Проверьте доступность VPN-сервера:
```routeros
/tool fetch url="https://ВАШ_СЕРВЕР:ПОРТ/" output=user
```

2. Проверьте на VPN-сервере:
```bash
tail -20 /var/log/x-ui/error.log
```

3. Частые причины:
   - SNI не совпадает (сервер и клиент должны использовать одинаковый SNI)
   - UUID не совпадает
   - Порт закрыт файрволом

## RU-сайты идут через VPN (медленно)

Проверьте что GeoIP базы загрузились:
```bash
curl http://12.0.0.5:9090/providers/rules -H "Authorization: Bearer ВАШ_СЕКРЕТ"
```

Если ruleCount = 0:
- Подождите 1-2 минуты (первая загрузка)
- Проверьте доступность GitHub из контейнера

## Иностранные ресурсы не работают

1. Убедитесь что туннель работает (см. выше)
2. Проверьте не попал ли сайт в RU-GeoIP:
```bash
dig +short иностранный-ресурс.com
# если IP начинается с известных RU-диапазонов — GeoIP ошибся
```

## Интернет совсем не работает

**Откатитесь:**
```routeros
/ip firewall mangle enable 0,1,2
/ip firewall mangle disable [find comment="ALL LAN via mihomo"]
/container envs set [find key="CONFIG"] value=default_config.yaml
/container stop 0; delay 15s; /container start 0
```

## Гео-базаы не обновляются

Проверьте что контейнер может достучаться до GitHub:
```routeros
/tool fetch url="https://raw.githubusercontent.com/" output=user
```

Если GitHub недоступен — гео-базаы будут использовать кэш.

## Высокое потребление RAM

Контейнер mihomo + GeoIP базы ~50-80 МБ. На роутерах с 256 МБ может не хватить.
Решение: используйте облегчённые базы:
```yaml
url: "https://raw.githubusercontent.com/runetfreedom/russia-blocked-geoip/release/geoip-ru-only.dat"
```

## Контейнер падает / зависает (OOM), интернет пропадает

Симптом: контейнер `exited with signal 9` в логах, LAN без DNS/VPN,
помогает ручной перезапуск. Причина: на роутерах с 256 МБ RAM контейнер
mihomo растёт (GeoIP-базы + соединения) до предела и убивается ядром,
а с `restart-policy=no` сам не поднимается.

```routeros
/container set 0 restart-policy=on-failure restart-max-count=10 \
    restart-interval=10s memory-max=150MiB
/container env add list=МИХОМО_ЛИСТ key=GOGC value=40   # агрессивный GC Go → меньше RSS
/container stop 0; delay 5s; /container start 0
```

`memory-max` защищает роутер (контейнер умрёт раньше, чем RouterOS),
`on-failure` поднимет его через 10 секунд автоматически.
Для 512 МБ роутеров ставьте `memory-max=200MiB`.

Лог рестартов: `/log print where topics~"container"`.

## Известные грабли

1. **TUN stack: mips** — контейнер крашится. Используйте `mixed`
2. **Mount dst не /etc/mihomo** — mihomo не найдёт конфиг
3. **Нет искл. локалки в mangle** — потеряете SSH к роутеру
4. **Контейнер :latest** — автообновление может сломать. Пиньте тег
5. **Xray-core обновлён** — Reality-auth ломается. Пиньте версию
6. **`smux=true` в VLESS-ссылке** — НЕ используйте с `flow=xtls-rprx-vision`:
   head-of-line blocking («все сайты медленно»), ломает UDP (звонки Telegram
   висят на «установка защищенного соединения»), портит TLS-профиль Vision.
7. **QUIC REJECT без RU-байпаса** — заблокирует и российский HTTP/3:
   браузер ждёт таймаута и откатывается на TCP → «всё медленно».
   REJECT допустим только вместе с `RU_GEO`-списком на роутере (см. ниже).

## Медленный интернет / CPU 100%

Симптом: speedtest даёт 50-100 Мбит из гигабита, на роутере CPU 99%.

Причина: весь трафик идёт через контейнер (userspace: TUN + шифрование).
Потолок 2-ядерных ARM ≈ 100-150 Мбит. Плюс QUIC-в-TCP вызывает шторм
ретрансмиссий: один iPhone с iCloud-синхронностью сжигал оба ядра (98%/85%)
на 5 Мбит трафика.

**Решение: российский трафик мимо контейнера (RU-байпас).**
RU-запросы форвардятся ядром роутера на линейной скорости, контейнер
остаётся только для иностранного:

```routeros
# 1. Сгенерируйте список RU CIDR из RIPE delegated (см. scripts/ru-geo.py)
#    → ru_geo.rsc с 11460 записями list=RU_GEO
# 2. Импортируйте: /import file=ru_geo.rsc
# 3. Правило ПЕРЕД "ALL LAN via mihomo":
/ip firewall mangle add chain=prerouting action=accept \
    dst-address-list=RU_GEO in-interface=bridge \
    comment="RU GeoIP bypass container" place-before=4
```

Результат на MikroTik E50UG: RU-трафик 378+ Мбит/с (было 60),
CPU 13%/9% (было 98%/85%), иностранное по-прежнему через VPN
(проверка анти-утечки: `curl ifconfig.me` должен показать IP VPN-сервера).

⚠️ После RU-байпаса правило QUIC REJECT в конфиге mihomo становится
безопасным (см. граблю 7) — и обязательным: иначе фоновый QUIC (iCloud,
Google Drive) в туннеле снова сожжёт CPU.

⚠️ Небольшой процент RU-хостов из блок-листов (заблокированные ресурсы
с RU-хостингом) после байпаса пойдут напрямую. Если заблокированный
RU-сайт перестал открываться — проверьте, не его ли это.

## Диагностика «всё медленно»

```bash
# 1. Физический RTT до VPN-сервера (с роутера, минуя туннель) — норма 50-100ms для EU
/ping IP_ВАШЕГО_VPS count=6

# 2. Задержка по мнению mihomo (весь прокси-трейл)
curl http://12.0.0.5:9090/group/SELECTOR/delay?url=https%3A%2F%2Fwww.gstatic.com%2Fgenerate_204&timeout=5000 -H "Authorization: Bearer СЕКРЕТ"
# норма: физический RTT + 10-30ms

# 3. Путь до контейнера (должно быть < 5ms)
curl http://12.0.0.5:9090/version -H "Authorization: Bearer СЕКРЕТ" -w "%{time_total}\n" -o /dev/null
```

Если (1) и (2) в норме, а сайты медленно — проверьте пункты 6 и 7 выше.
