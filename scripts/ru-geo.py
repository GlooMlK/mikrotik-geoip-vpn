#!/usr/bin/env python3
"""Генерирует ru_geo.rsc — список RU CIDR для MikroTik address-list.

Источник: RIPE delegated stats (авторитетные данные о всех выделенных
адресах). ~11.5 тысяч записей.

Использование:
    python3 ru-geo.py                # → ru_geo.rsc рядом со скриптом
    scp ru_geo.rsc admin@РОУТЕР:ru_geo.rsc
    # на роутере:
    # /import file=ru_geo.rsc
    # /ip firewall mangle add chain=prerouting action=accept \
    #     dst-address-list=RU_GEO in-interface=bridge \
    #     comment="RU GeoIP bypass container" place-before=4
    # (place-before = номер правила "ALL LAN via mihomo" минус 1)

Зачем: без этого списка весь трафик (включая RU) идёт через контейнер
mihomo в userspace — на 2-ядерных ARM это потолок ~100-150 Мбит/с и
CPU 99%. Со списком RU-трафик форвардится ядром на линейной скорости.

Обновление: список адресов RIPE меняется медленно, обновляйте раз в 1-3
месяца (повторный /import сам очистит и пересоздаст список).
"""

import math
import sys
import urllib.request

URL = "https://ftp.ripe.net/pub/stats/ripencc/delegated-ripencc-latest"
LIST = "RU_GEO"


def main() -> None:
    print(f"Загружаю {URL} ...", file=sys.stderr)
    with urllib.request.urlopen(URL, timeout=60) as r:
        text = r.read().decode()

    rows = []
    for line in text.splitlines():
        p = line.split("|")
        if len(p) >= 7 and p[1] == "RU" and p[2] == "ipv4":
            ip, cnt = p[3], int(p[4])
            rows.append(f"add list={LIST} address={ip}/{32 - int(math.log2(cnt))}")

    out = (
        f"/ip firewall address-list remove [find list={LIST}]\n"
        f"/ip firewall address-list\n" + "\n".join(rows) + "\n"
    )
    with open("ru_geo.rsc", "w") as f:
        f.write(out)
    print(f"Готово: {len(rows)} записей → ru_geo.rsc", file=sys.stderr)


if __name__ == "__main__":
    main()
