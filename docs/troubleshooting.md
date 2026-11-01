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

## Известные грабли

1. **TUN stack: mips** — контейнер крашится. Используйте `mixed`
2. **Mount dst не /etc/mihomo** — mihomo не найдёт конфиг
3. **Нет искл. локалки в mangle** — потеряете SSH к роутеру
4. **Контейнер :latest** — автообновление может сломать. Пиньте тег
5. **Xray-core обновлён** — Reality-auth ломается. Пиньте версию
