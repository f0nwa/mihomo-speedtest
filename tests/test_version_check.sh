#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SCRIPT="$ROOT/installer/version_check.sh"
FAILED=0

assert_eq() {
  if [ "$1" != "$2" ]; then
    echo "FAIL: '$1' != '$2' ($3)" >&2
    FAILED=1
  fi
}

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

assert_ok  version_ge "2.0" "2.0"
assert_ok  version_ge "2.1" "2.0"
assert_ok  version_ge "1.19.29" "1.19.29"
assert_ok  version_ge "1.19.30" "1.19.29"
assert_ok  version_ge "5.1.4" "5.1.4"
assert_ok  version_ge "5.2" "5.1.4"
assert_fail version_ge "1.19.28" "1.19.29"
assert_fail version_ge "1.9.0" "1.19.29"
assert_ok  version_ge "2.0 Stable" "2.0"

FAKEBIN=$(mktemp -d)
cat > "$FAKEBIN/pidof" <<'EOF2'
#!/bin/sh
[ "$1" = "mihomo" ] && exit 0
exit 1
EOF2
chmod +x "$FAKEBIN/pidof"
PATH="$FAKEBIN:$PATH" assert_ok check_mihomo_process

cat > "$FAKEBIN/pidof" <<'EOF2'
#!/bin/sh
exit 1
EOF2
chmod +x "$FAKEBIN/pidof"
if PATH="$FAKEBIN:$PATH" check_mihomo_process 2>/tmp/vc_err.$$; then
  echo "FAIL: check_mihomo_process should fail when pidof finds nothing" >&2
  FAILED=1
fi
grep -q "Процесс mihomo не найден" /tmp/vc_err.$$ || { echo "FAIL: missing diagnostic message" >&2; FAILED=1; }
rm -f /tmp/vc_err.$$

rm -f "$FAKEBIN/pidof"
env -i PATH="$FAKEBIN:$PATH" sh -c '. "'"$SCRIPT"'"; check_mihomo_process' 2>/dev/null || true

rm -rf "$FAKEBIN"

FAKEBIN=$(mktemp -d)
cat > "$FAKEBIN/xkeen" <<'EOF2'
#!/bin/sh
if [ "$1" = "-v" ]; then
  printf 'Версия XKeen 2.0 Stable (время сборки: 2026-06-06 08:53:30 MSK)\n'
  printf '  Ядро проксирования Mihomo версии 1.19.29\n'
fi
EOF2
chmod +x "$FAKEBIN/xkeen"
cat > "$FAKEBIN/ndmc" <<'EOF2'
#!/bin/sh
printf '  version: (unassigned)\n'
printf '  ndm.core.version: "5.1.4 (KeeneticOS)"\n'
EOF2
chmod +x "$FAKEBIN/ndmc"
cat > "$FAKEBIN/pidof" <<'EOF2'
#!/bin/sh
[ "$1" = "mihomo" ] && exit 0
exit 1
EOF2
chmod +x "$FAKEBIN/pidof"

assert_eq "$(PATH="$FAKEBIN:$PATH" xkeen_version)" "2.0" "xkeen_version"
assert_eq "$(PATH="$FAKEBIN:$PATH" mihomo_version)" "1.19.29" "mihomo_version"
assert_eq "$(PATH="$FAKEBIN:$PATH" keeneticos_version)" "5.1.4" "keeneticos_version (пропускает пустое поле version)"

MIN_XKEEN_VERSION=2.0 MIN_MIHOMO_VERSION=1.19.29 MIN_KEENETICOS_VERSION=5.1.4 \
  PATH="$FAKEBIN:$PATH" assert_ok check_versions

MIN_XKEEN_VERSION=2.1 MIN_MIHOMO_VERSION=1.19.29 MIN_KEENETICOS_VERSION=5.1.4 \
  PATH="$FAKEBIN:$PATH" check_versions 2>/tmp/vc_err2.$$ && { echo "FAIL: should reject XKeen 2.0 < 2.1" >&2; FAILED=1; }
grep -q "Версия XKeen ниже минимума" /tmp/vc_err2.$$ || { echo "FAIL: missing XKeen diagnostic" >&2; FAILED=1; }
rm -f /tmp/vc_err2.$$

cat > "$FAKEBIN/xkeen" <<'EOF2'
#!/bin/sh
if [ "$1" = "-v" ]; then
  printf '  Версия \033[93mXKeen 2.0 Stable\033[0m (время сборки: \033[96m2026-06-06 08:53:30 MSK\033[0m)\n'
  printf '  Ядро проксирования Mihomo версии \033[93m1.19.29\033[0m\n'
fi
EOF2
chmod +x "$FAKEBIN/xkeen"
assert_eq "$(PATH="$FAKEBIN:$PATH" xkeen_version)" "2.0" "xkeen_version (ANSI-коды подсветки, как в реальном выводе xkeen -v)"
assert_eq "$(PATH="$FAKEBIN:$PATH" mihomo_version)" "1.19.29" "mihomo_version (ANSI-коды подсветки, как в реальном выводе xkeen -v)"

cat > "$FAKEBIN/xkeen" <<'EOF2'
#!/bin/sh
exit 127
EOF2
chmod +x "$FAKEBIN/xkeen"
MIN_XKEEN_VERSION=2.0 PATH="$FAKEBIN:$PATH" check_versions 2>/dev/null && { echo "FAIL: should reject when xkeen missing" >&2; FAILED=1; }

rm -rf "$FAKEBIN"

# Реальный формат XKeen 2.1: без слова "Версия", плюс строка Yq.
FAKEBIN21=$(mktemp -d)
cat > "$FAKEBIN21/xkeen" <<'EOF2'
#!/bin/sh
printf '  \033[92mXKeen 2.1 Stable\033[0m (время сборки: 2026-10-06 10:58:45 MSK)\n'
printf '  Ядро проксирования Mihomo версии \033[93m1.19.32\033[0m\n'
printf '  Парсер конфигурационных файлов Yq версии 4.50.1\n'
EOF2
chmod +x "$FAKEBIN21/xkeen"
got=$(env -i PATH="$FAKEBIN21:$PATH" sh -c '. "'"$SCRIPT"'"; echo "$(xkeen_version) $(mihomo_version)"')
[ "$got" = "2.1 1.19.32" ] || { echo "FAIL: XKeen 2.1 parse: '$got'" >&2; FAILED=1; }
rm -rf "$FAKEBIN21"

if [ "$FAILED" = 1 ]; then
  echo "test_version_check.sh: FAILED" >&2
  exit 1
fi
echo "test_version_check.sh: OK"
