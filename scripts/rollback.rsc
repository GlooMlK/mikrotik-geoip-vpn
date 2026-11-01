# Откат GeoIP VPN на стандартную маршрутизацию
# Выполнять если что-то не работает

# Возвращаем старые mangle правила
/ip firewall mangle enable 0,1,2

# Отключаем ALL-LAN правило
/ip firewall mangle disable [find comment="ALL LAN via mihomo"]

# Возвращаем дефолтный конфиг контейнера
/container envs set [find key="CONFIG"] value=default_config.yaml

# Перезапуск
/container stop 0
/delay 15s
/container start 0

:log info "Rolled back to default config"
