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
    #     comment="RU GeoIP bypass container"
    # /ip firewall mangle move [find comment="RU GeoIP bypass container"] \
    #     [find comment="ALL LAN via mihomo"]

Зачем: без этого списка весь трафик (включая RU) идёт через контейнер
mihomo в userspace — на 2-ядерных ARM это потолок ~100-150 Мбит/с и
CPU 99%. Со списком RU-трафик форвардится ядром на линейной скорости.

Обновление: список адресов RIPE меняется медленно, обновляйте раз в 1-3
месяца. Повторный /import сам очистит и пересоздаст список (первая
строка файла — remove). Импорт занимает 1-3 минуты, на это время список
неполон — делайте в спокойное окно.
"""

import ipaddress
import sys
import time
import urllib.request
from pathlib import Path

URL = "https://ftp.ripe.net/pub/stats/ripencc/delegated-ripencc-latest"
LIST = "RU_GEO"
MIN_EXPECTED = 5000  # защита от усечённой выгрузки/смены формата


def fetch(url: str, attempts: int = 3) -> str:
    for i in range(attempts):
        try:
            with urllib.request.urlopen(url, timeout=60) as r:
                return r.read().decode()
        except Exception as e:  # noqa: BLE001
            print(f"попытка {i + 1}/{attempts} не удалась: {e}", file=sys.stderr)
            if i + 1 == attempts:
                raise
            time.sleep(3)
    raise RuntimeError("unreachable")


def main() -> None:
    print(f"Загружаю {URL} ...", file=sys.stderr)
    text = fetch(URL)

    seen = set()
    rows = []
    for line in text.splitlines():
        p = line.split("|")
        # country=RU, ipv4, только реальные выделения (не reserved)
        if len(p) >= 7 and p[1] == "RU" and p[2] == "ipv4" and p[6] in ("allocated", "assigned"):
            first = ipaddress.ip_address(p[3])
            last = ipaddress.ip_address(int(first) + int(p[4]) - 1)
            # summarize_address_range корректно режет ЛЮБОЙ count (не только степени двойки)
            for net in ipaddress.summarize_address_range(first, last):
                if net not in seen:
                    seen.add(net)
                    rows.append(f"add list={LIST} address={net}")

    if len(rows) < MIN_EXPECTED:
        sys.exit(
            f"Подозрительно мало записей ({len(rows)} < {MIN_EXPECTED}): "
            "формат файла изменился или выгрузка оборвалась. Выход БЕЗ записи — "
            "рабочий список на роутере не тронут."
        )

    out = (
        f"# generated: {time.strftime('%Y-%m-%d')} | {len(rows)} CIDR | RIPE delegated\n"
        f"/ip firewall address-list remove [find list={LIST}]\n"
        f"/ip firewall address-list\n" + "\n".join(rows) + "\n"
    )
    out_path = Path(__file__).with_name("ru_geo.rsc")
    tmp = out_path.with_suffix(".tmp")
    tmp.write_text(out)
    tmp.replace(out_path)  # атомарная замена
    print(f"Готово: {len(rows)} записей → {out_path}", file=sys.stderr)


if __name__ == "__main__":
    main()
