#!/bin/sh
# test_dns_guard.sh - тесты для xkeen_ui_dns_protection_active() (version_check.sh,
# ещё не реализована - см. CHANGELOG/AGENTS.md, порция 1 из плана "DNS-guard
# перед перезаписью config.yaml в setup.sh").
#
# Панель Xkeen UI (сторонний проект) при включении "Защищённого DNS Mihomo"
# всегда одновременно включает переключатель Keenetic "opkg dns-override" и
# отключает провайдерский DNS на WAN-интерфейсах ("ip no name-servers" /
# "ipv6 no name-servers") - это видно в её исходниках
# (services/mihomo_dns.py:_configure_keenetic_dns_for_mihomo). Оба признака
# читаются одной командой "ndmc -c show running-config" (тем же способом,
# каким version_check.sh уже читает версию KeeneticOS в keeneticos_version()).
#
# Контракт xkeen_ui_dns_protection_active():
#   - без аргументов, ничего не печатает в stdout
#   - код возврата 0 ("активна") - когда оба признака найдены одновременно,
#     ИЛИ когда ndmc недоступен/упал и однозначно проверить нельзя (при
#     сомнении лучше лишний раз спросить пользователя, чем молча
#     перезаписать чужой DNS-конфиг - на практике этот путь не должен
#     встречаться в setup.sh/install.sh: оба уже требуют рабочий ndmc для
#     check_versions() раньше по цепочке вызовов)
#   - код возврата 1 ("не активна") - override явно выключен, либо оба
#     признака отсутствуют, либо есть только один из двух (панель Xkeen UI
#     всегда включает оба вместе - раздельно это не её схема)
#
# Проверка на WAN-интерфейс намеренно упрощена до поиска подстроки по всему
# выводу "show running-config", без разбора конкретных блоков interface -
# ложное срабатывание (лишний раз спросить) не страшно, а пропуск - да.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SCRIPT="$ROOT/installer/version_check.sh"
FAILED=0
FAKEBIN=$(mktemp -d)
trap 'rm -rf "$FAKEBIN"' EXIT

assert_ok() {
  if ! "$@"; then
    echo "FAIL: expected success: $*" >&2
    FAILED=1
  fi
}

assert_fail() {
  if "$@"; then
    echo "FAIL: expected failure: $*" >&2
    FAILED=1
  fi
}

. "$SCRIPT"

if ! command -v xkeen_ui_dns_protection_active >/dev/null 2>&1; then
  echo "test_dns_guard.sh: FAILED - xkeen_ui_dns_protection_active() ещё не реализована в version_check.sh (портция 1 плана)" >&2
  exit 1
fi

# Сценарий 1: оба признака есть - opkg dns-override включён и провайдерский
# DNS явно отключен на WAN (ровно то, что делает мастер Xkeen UI при
# включении).
cat > "$FAKEBIN/ndmc" <<'EOF'
#!/bin/sh
cat <<'OUT'
interface ISP
	security-level public
	ip address dhcp
	ip dhcp client no name-servers
	ipv6 dhcp client no name-servers
!
opkg dns-override
!
OUT
EOF
chmod +x "$FAKEBIN/ndmc"
PATH="$FAKEBIN:$PATH" assert_ok xkeen_ui_dns_protection_active

# Сценарий 2: dns-override явно выключен - панель точно ни при чём,
# независимо от прочих настроек WAN.
cat > "$FAKEBIN/ndmc" <<'EOF'
#!/bin/sh
cat <<'OUT'
interface ISP
	ip dhcp client no name-servers
!
no opkg dns-override
!
OUT
EOF
chmod +x "$FAKEBIN/ndmc"
PATH="$FAKEBIN:$PATH" assert_fail xkeen_ui_dns_protection_active

# Сценарий 3: ни строки dns-override, ни признаков отключения
# провайдерского DNS вообще нет в выводе - обычный роутер без DNS-защиты
# Xkeen UI.
cat > "$FAKEBIN/ndmc" <<'EOF'
#!/bin/sh
cat <<'OUT'
interface ISP
	ip address dhcp
!
OUT
EOF
chmod +x "$FAKEBIN/ndmc"
PATH="$FAKEBIN:$PATH" assert_fail xkeen_ui_dns_protection_active

# Сценарий 4: dns-override включён, но провайдерский DNS не трогали - это
# НЕ схема Xkeen UI (она всегда выключает оба вместе), похоже на что-то
# постороннее с тем же общим рубильником Keenetic - не наш случай.
cat > "$FAKEBIN/ndmc" <<'EOF'
#!/bin/sh
cat <<'OUT'
interface ISP
	ip address dhcp
!
opkg dns-override
!
OUT
EOF
chmod +x "$FAKEBIN/ndmc"
PATH="$FAKEBIN:$PATH" assert_fail xkeen_ui_dns_protection_active

# Сценарий 5: провайдерский DNS отключен, но dns-override не упомянут (уже
# точно не активная передача DNS Mihomo на порт 53) - тоже не наш случай.
cat > "$FAKEBIN/ndmc" <<'EOF'
#!/bin/sh
cat <<'OUT'
interface ISP
	ip dhcp client no name-servers
	ipv6 dhcp client no name-servers
!
OUT
EOF
chmod +x "$FAKEBIN/ndmc"
PATH="$FAKEBIN:$PATH" assert_fail xkeen_ui_dns_protection_active

# Сценарий 6: ndmc падает - однозначно проверить нельзя, считаем активной
# (перебдеть безопаснее, чем промолчать). На практике недостижимо из
# setup.sh/install.sh - туда раньше по цепочке не пропустит check_versions().
cat > "$FAKEBIN/ndmc" <<'EOF'
#!/bin/sh
exit 1
EOF
chmod +x "$FAKEBIN/ndmc"
PATH="$FAKEBIN:$PATH" assert_ok xkeen_ui_dns_protection_active

# Сценарий 7: ndmc не установлен вовсе - тот же осторожный дефолт.
rm -f "$FAKEBIN/ndmc"
PATH="$FAKEBIN:$PATH" assert_ok xkeen_ui_dns_protection_active

if [ "$FAILED" = 1 ]; then
  echo "test_dns_guard.sh: FAILED" >&2
  exit 1
fi
echo "test_dns_guard.sh: OK"
