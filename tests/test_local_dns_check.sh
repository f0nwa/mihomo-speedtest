#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/local-dns-check.XXXXXX")
trap 'rm -rf "$WORK"' EXIT INT TERM
mkdir -p "$WORK/bin"

cat > "$WORK/bin/ndmc" <<'EOF'
#!/bin/sh
[ "$1" = -c ] || exit 2
case $2 in
  'show running-config') [ "${NDMC_FAIL:-}" != config ] || exit 1; cat "$FAKE_CONFIG" ;;
  'show interface Home') [ "${NDMC_FAIL:-}" != interface ] || exit 1; cat "$FAKE_INTERFACE" ;;
  *) exit 2 ;;
esac
EOF
chmod +x "$WORK/bin/ndmc"
PATH="$WORK/bin:$PATH"; export PATH
FAKE_CONFIG=$WORK/config
FAKE_INTERFACE=$WORK/interface
export FAKE_CONFIG FAKE_INTERFACE

cat > "$FAKE_INTERFACE" <<'EOF'
   interface-name: Home
          address: 192.168.10.1
             mask: 255.255.255.0
            addresses:
                  address: fe80::1234
EOF

make_config() {
  cat > "$FAKE_CONFIG" <<EOF
ip dhcp pool _WEBADMIN
    range 192.168.10.33 192.168.10.152
$1
    bind Home
    enable
!
service dns-proxy
EOF
}

expect_ok() {
  label=$1
  if ! sh "$ROOT/installer/local_dns_check.sh" > "$WORK/out" 2> "$WORK/err"; then
    echo "FAIL: $label отклонён: $(cat "$WORK/err")" >&2
    exit 1
  fi
  [ "$(cat "$WORK/out")" = 192.168.10.1 ] || { echo "FAIL: $label вернул не адрес Home" >&2; exit 1; }
}

expect_skip() {
  label=$1
  if sh "$ROOT/installer/local_dns_check.sh" > "$WORK/out" 2> "$WORK/err"; then
    echo "FAIL: $label ошибочно разрешён" >&2
    exit 1
  fi
  [ ! -s "$WORK/out" ] || { echo "FAIL: $label выдал адрес при отказе" >&2; exit 1; }
  [ -s "$WORK/err" ] || { echo "FAIL: $label не объяснил отказ" >&2; exit 1; }
}

# Единственный DNS Home совпадает с адресом роутера.
make_config '    dns-server 192.168.10.1'
expect_ok 'один DNS роутера'

# Без dns-server Keenetic выдаёт адрес интерфейса по умолчанию.
make_config ''
expect_ok 'DNS по умолчанию'

# Нынешний роутер: дополнительный DNS делает локальное имя ненадёжным.
make_config '    dns-server 192.168.10.11 192.168.10.1'
expect_skip 'два DNS Home'

make_config '    dns-server 192.168.10.11'
expect_skip 'только сторонний DNS'

make_config '    dns-server 192.168.10.1'
sed '/^service dns-proxy$/d' "$FAKE_CONFIG" > "$WORK/no-proxy"
mv "$WORK/no-proxy" "$FAKE_CONFIG"
expect_skip 'отключённый DNS proxy'

make_config '    dns-server 192.168.10.1'
cat >> "$FAKE_CONFIG" <<'EOF'
ip dhcp pool SECOND
    dns-server 192.168.10.1
    bind Home
    enable
!
EOF
expect_skip 'два активных пула Home'

make_config '    dns-server 192.168.10.1'
sed 's/192\.168\.10\.1/10.0.0.1/' "$FAKE_INTERFACE" > "$WORK/other-interface"
mv "$WORK/other-interface" "$FAKE_INTERFACE"
expect_skip 'адрес Home вне 192.168.x.1'

NDMC_FAIL=config; export NDMC_FAIL
expect_skip 'сбой чтения конфигурации'
NDMC_FAIL=interface
expect_skip 'сбой чтения интерфейса'

echo 'OK: test_local_dns_check.sh'
