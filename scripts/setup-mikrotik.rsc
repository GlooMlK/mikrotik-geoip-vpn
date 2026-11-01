# Полный скрипт настройки MikroTik для GeoIP VPN
# ВЫПОЛНЯТЬ В Winbox Terminal ИЛИ ЧЕРЕЗ SSH
# Перед выполнением замените:
#   - 192.168.1.0/24 на вашу локальную подсеть
#   - Секрет API на свой

# ═══════════════════════════════════════════════
# 1. Включение containers (если ещё не включены)
# ═══════════════════════════════════════════════
/device-mode update container=yes

# ═══════════════════════════════════════════════
# 2. Сетевые интерфейсы
# ═══════════════════════════════════════════════
/interface veth add name=MIHOMO address=12.0.0.2/24 gateway=12.0.0.1
/interface bridge port add bridge=bridge interface=MIHOMO
/ip address add address=12.0.0.1/24 interface=bridge comment="mihomo gateway"

# ═══════════════════════════════════════════════
# 3. Таблица маршрутизации
# ═══════════════════════════════════════════════
/routing table add name=to-vless fib
/ip route add dst-address=0.0.0.0/0 gateway=12.0.0.5 routing-table=to-vless comment="via mihomo"

# ═══════════════════════════════════════════════
# 4. Структура на USB
# ═══════════════════════════════════════════════
/file add name=usb1-part1/containers/etc type=directory
/file add name=usb1-part1/containers/etc/mihomo type=directory
/file add name=usb1-part1/containers/etc/mihomo/rules type=directory

# ═══════════════════════════════════════════════
# 5. Контейнер mihomo
# ═══════════════════════════════════════════════
# Сначала загрузите configs/ на USB (через Winbox Files или scp)
# geoip-config.yaml → /usb1-part1/containers/etc/mihomo/
# my-srv.yaml       → /usb1-part1/containers/etc/mihomo/ (со своей ссылкой!)

/container mounts add list=mihomo-cfg src=/usb1-part1/containers/etc/mihomo dst=/etc/mihomo

/container envs add list=MIHOMO key=CONFIG value=geoip-config.yaml
/container envs add list=MIHOMO key=LOG_LEVEL value=info
/container envs add list=MIHOMO key=MIXED_PORT value=1080
/container envs add list=MIHOMO key=UI_PORT value=9090
/container envs add list=MIHOMO key=UI_SECRET value=ВАШ_СЕКРЕТ
/container envs add list=MIHOMO key=IPV6 value=false
/container envs add list=MIHOMO key=KEEP_ALIVE_IDLE value=600

/container add \
  remote-image=wiktorbgu/mihomo-mikrotik:1.19.30 \
  interface=MIHOMO \
  envlist=MIHOMO \
  mounts=mihomo-cfg \
  start-on-boot=yes \
  logging=yes \
  comment="GeoIP VPN"

# ═══════════════════════════════════════════════
# 6. Маршрутизация (mangle)
# ═══════════════════════════════════════════════
# ВЕСЬ трафик с LAN → через mihomo
# ИСКЛЮЧЕНИЕ: локальная подсеть
/ip firewall mangle add \
  chain=prerouting \
  action=mark-routing \
  new-routing-mark=to-vless \
  passthrough=no \
  in-interface=bridge \
  dst-address=!192.168.1.0/24 \
  comment="ALL LAN via mihomo"

# ═══════════════════════════════════════════════
# 7. Запуск
# ═══════════════════════════════════════════════
/container start 0

:log info "GeoIP VPN deployed. Test from a LAN device!"
