#!/bin/sh
# Проверяет, может ли запись ip host использоваться клиентами сети Home.
# При успехе печатает IPv4-адрес Home; при отказе объясняет причину в stderr.
# Настройки Keenetic и файлы не меняет.
set -eu

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

command -v ndmc >/dev/null 2>&1 || fail 'Команда ndmc недоступна'
config=$(ndmc -c 'show running-config' 2>/dev/null) || fail 'Не удалось прочитать конфигурацию Keenetic'
interface=$(ndmc -c 'show interface Home' 2>/dev/null) || fail 'Не удалось прочитать интерфейс Home'

lan_ip=$(printf '%s\n' "$interface" | awk '
  $1 == "interface-name:" && $2 == "Home" { home = 1 }
  $1 == "address:" && $2 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ {
    count++
    ip = $2
    split(ip, part, ".")
    if (part[1] != 192 || part[2] != 168 || part[3] !~ /^[0-9]+$/ || part[3] > 255 || part[4] != 1) bad = 1
  }
  END { if (home && count == 1 && !bad) print ip }
')
[ -n "$lan_ip" ] || fail 'Не удалось однозначно определить адрес Home вида 192.168.x.1'

decision=$(printf '%s\n' "$config" | awk -v wanted="$lan_ip" '
  function finish_pool() {
    if (in_pool && binding == "Home" && enabled) {
      home_pools++
      if (dns_count == 0) good = 1
      else if (dns_count == 1 && dns_value == wanted) good = 1
      else foreign_dns = 1
    }
    in_pool = 0
    binding = ""
    enabled = 0
    dns_count = 0
    dns_value = ""
  }
  $1 == "ip" && $2 == "dhcp" && $3 == "pool" { finish_pool(); in_pool = 1; next }
  $0 == "!" { finish_pool(); next }
  $0 == "service dns-proxy" { dns_proxy = 1 }
  in_pool && $1 == "bind" { if (NF == 2) binding = $2; next }
  in_pool && $0 ~ /^[[:space:]]*enable[[:space:]]*$/ { enabled = 1; next }
  in_pool && $1 == "dns-server" {
    if (NF < 2) foreign_dns = 1
    for (i = 2; i <= NF; i++) { dns_count++; dns_value = $i }
  }
  END {
    finish_pool()
    if (!dns_proxy) print "DNS-прокси Keenetic не включён"
    else if (home_pools == 0) print "Нет активного DHCP-пула Home"
    else if (home_pools > 1) print "Найдено несколько активных DHCP-пулов Home"
    else if (foreign_dns || !good) print "DHCP Home выдаёт другой или дополнительный DNS-сервер"
    else print "ok"
  }
')
[ "$decision" = ok ] || fail "$decision"
printf '%s\n' "$lan_ip"
