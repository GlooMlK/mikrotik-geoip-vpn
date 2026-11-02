# Откат GeoIP VPN на стандартную маршрутизацию
# Выполнять если что-то не работает.
# Отключает ВСЁ, что создал setup-mikrotik.rsc, по comment (не по номерам!):
#   mangle ALL LAN + RU GeoIP bypass, DNS-редирект, watchdog.
# LAN сразу возвращается к прямой маршрутизации через провайдера.

# 1. Стоп watchdog (чтобы не рестартнул контейнер посреди отката)
:do { /system scheduler remove [find name="mihomo-watchdog"] } on-error={}

# 2. Отключаем маркировку (Lan → провайдер напрямую)
:do { /ip firewall mangle disable [find comment="ALL LAN via mihomo"] } on-error={}
:do { /ip firewall mangle disable [find comment="RU GeoIP bypass container"] } on-error={}

# 3. Отключаем DNS-редирект на контейнер (иначе DNS умрёт вместе с ним!)
:do { /ip firewall nat disable [find comment="DNS -> mihomo udp"] } on-error={}
:do { /ip firewall nat disable [find comment="DNS -> mihomo tcp"] } on-error={}
# Клиенты вернутся к DNS роутера. Если DHCP раздавал только внешний DNS —
# выдайте /ip dns set allow-remote-requests=yes и dns-server=<IP роутера> в DHCP.

# 4. Останавливаем контейнер (он больше не нужен для базового интернета)
:do { /container stop [find comment="GeoIP VPN"] } on-error={}

# 5. Если у вас БЫЛИ собственные mangle-правила до установки — включите их
#    вручную по комментарию (не по номерам!):
#    /ip firewall mangle enable [find comment="ВАШ_КОММЕНТАРИЙ"]

:log info "GeoIP VPN откачен: LAN идёт напрямую через провайдера, DNS — роутер"
