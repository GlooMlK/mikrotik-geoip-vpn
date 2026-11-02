# Полный скрипт настройки MikroTik для GeoIP VPN
# ВЫПОЛНЯТЬ В Winbox Terminal ИЛИ ЧЕРЕЗ SSH (RouterOS 7.13+)
# Перед выполнением замените:
#   - 192.168.1.0/24 на вашу локальную подсеть (строки с dst-address и src-address)
#   - ВАШ_СЕКРЕТ на случайную строку: openssl rand -hex 16
#
# Скрипт идемпотентен: повторный запуск не падает на существующих объектах.

# ═══════════════════════════════════════════════
# 0. Отключаем IPv6 (иначе v6-трафик ходит мимо всей системы!)
# ═══════════════════════════════════════════════
/ipv6 settings set disable-ipv6=yes

# ═══════════════════════════════════════════════
# 1. Включение containers (если ещё не включены)
# ═══════════════════════════════════════════════
/device-mode update container=yes

# ═══════════════════════════════════════════════
# 2. Сетевые интерфейсы (L3-модель, без bridge-порта)
#    veth: address = IP КОНТЕЙНЕРА, gateway = IP роутера на этом veth
# ═══════════════════════════════════════════════
:if ([:len [/interface veth find name="MIHOMO"]] = 0) do={
  /interface veth add name=MIHOMO address=12.0.0.5/24 gateway=12.0.0.2
}
:if ([:len [/ip address find address="12.0.0.2/24"]] = 0) do={
  /ip address add address=12.0.0.2/24 interface=MIHOMO comment="mihomo gateway (router side)"
}

# ═══════════════════════════════════════════════
# 3. Таблица маршрутизации
# ═══════════════════════════════════════════════
:if ([:len [/routing table find name="to-vless"]] = 0) do={
  /routing table add name=to-vless fib
}
:if ([:len [/ip route find comment="via mihomo"]] = 0) do={
  /ip route add dst-address=0.0.0.0/0 gateway=12.0.0.5 routing-table=to-vless comment="via mihomo"
}

# ═══════════════════════════════════════════════
# 4. Структура на USB (на части прошивок/ФС каталоги создаются через Files)
# ═══════════════════════════════════════════════
:do { /file add name=usb1-part1/containers/etc type=directory } on-error={}
:do { /file add name=usb1-part1/containers/etc/mihomo type=directory } on-error={}
:do { /file add name=usb1-part1/containers/etc/mihomo/rules type=directory } on-error={}

# ═══════════════════════════════════════════════
# 5. Контейнер mihomo
#    Сначала загрузите configs/ на USB (Winbox Files или scp):
#    geoip-config.yaml + rules/*.mrs → /usb1-part1/containers/etc/mihomo/
#    my-srv.yaml (со своей VLESS-ссылкой!)      → туда же
# ═══════════════════════════════════════════════
:if ([:len [/container mounts find list="mihomo-cfg"]] = 0) do={
  /container mounts add list=mihomo-cfg src=/usb1-part1/containers/etc/mihomo dst=/etc/mihomo
}

:if ([:len [/container envs find list="MIHOMO" key="CONFIG"]] = 0) do={
  /container envs add list=MIHOMO key=CONFIG value=geoip-config.yaml
  /container envs add list=MIHOMO key=GOGC value=40
  /container envs add list=MIHOMO key=GOMEMLIMIT value=120MiB
}

:if ([:len [/container find comment="GeoIP VPN"]] = 0) do={
  /container add \
    remote-image=wiktorbgu/mihomo-mikrotik:1.19.30 \
    interface=MIHOMO \
    envlist=MIHOMO \
    mounts=mihomo-cfg \
    start-on-boot=yes \
    restart-policy=on-failure restart-max-count=10 restart-interval=10s \
    memory-max=150MiB \
    logging=yes \
    comment="GeoIP VPN"
}

# ═══════════════════════════════════════════════
# 6. DNS: запросы LAN клиентов → mihomo (иначе доменные
#    правила в полном конфиге не работают — mihomo строит
#    карту домен↔IP только по своим DNS-ответам)
# ═══════════════════════════════════════════════
:if ([:len [/ip firewall nat find comment="DNS -> mihomo udp"]] = 0) do={
  /ip firewall nat add chain=dstnat action=dst-nat to-addresses=12.0.0.5 to-ports=53 \
      protocol=udp dst-port=53,1253,5353 in-interface=bridge dst-address-list=!local \
      comment="DNS -> mihomo udp"
}
:if ([:len [/ip firewall nat find comment="DNS -> mihomo tcp"]] = 0) do={
  /ip firewall nat add chain=dstnat action=dst-nat to-addresses=12.0.0.5 to-ports=53 \
      protocol=tcp dst-port=53,1253,5353 in-interface=bridge dst-address-list=!local \
      comment="DNS -> mihomo tcp"
}

# ═══════════════════════════════════════════════
# 7. Маршрутизация (mangle)
# ═══════════════════════════════════════════════
# 7а. RU-байпас: российский трафик мимо контейнера, ядром, на линейной
#     скорости. ОБЯЗАТЕЛЕН для geoip-lite.yaml, крайне рекомендуется для
#     полного (снимает CPU-потолок userspace-прокси).
#     Сначала: python3 scripts/ru-geo.py && scp ru_geo.rsc на роутер
:if ([:len [/ip firewall mangle find comment="RU GeoIP bypass container"]] = 0) do={
  :if ([:len [/ip firewall address-list find list="RU_GEO"]] > 0) do={
    /ip firewall mangle add chain=prerouting action=accept \
        dst-address-list=RU_GEO in-interface=bridge \
        comment="RU GeoIP bypass container"
    /ip firewall mangle move [find comment="RU GeoIP bypass container"] \
        [find comment="ALL LAN via mihomo"]
  } else={
    :log warning "setup: RU_GEO пуст — выполните /import file=ru_geo.rsc и повторите шаг 7а"
  }
}

# 7б. ВЕСЬ остальной трафик с LAN → через mihomo (исключая локальные подсети)
#     Для нескольких локальных подсетей/VLAN замените на dst-address-list=LOCAL_NETS
:if ([:len [/ip firewall mangle find comment="ALL LAN via mihomo"]] = 0) do={
  /ip firewall mangle add \
    chain=prerouting \
    action=mark-routing \
    new-routing-mark=to-vless \
    passthrough=no \
    in-interface=bridge \
    dst-address=!192.168.1.0/24 \
    comment="ALL LAN via mihomo"
}

# ═══════════════════════════════════════════════
# 8. Запуск
# ═══════════════════════════════════════════════
/container start [find comment="GeoIP VPN"]

:log info "GeoIP VPN deployed. Проверка с LAN-устройства: curl ifconfig.me должен показать IP VPS"
