#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
SCRIPT=$ROOT/install.sh
fail() { echo "FAIL: $*" >&2; exit 1; }

WORK=$(mktemp -d)
mkdir -p "$WORK/sbin" "$WORK/bin"
target=$WORK/mihomo-speedtest.sh
touch "$target"

# --- создание с нуля (только первый каталог доступен) ---
(
  INSTALL_LIB_ONLY=1 SELFDIR="$ROOT/installer" . "$SCRIPT"
  ensure_mihomo_speedtest_symlink "$target" "$WORK/sbin" "$WORK/bin"
)
[ -L "$WORK/sbin/mihomo-speedtest" ] || fail "симлинк не создан в первом каталоге"
[ "$(readlink "$WORK/sbin/mihomo-speedtest")" = "$target" ] || fail "симлинк указывает не туда"

# --- идемпотентность: повторный вызов не трогает верную ссылку ---
before=$(stat -c %Y "$WORK/sbin/mihomo-speedtest" 2>/dev/null || stat -f %m "$WORK/sbin/mihomo-speedtest")
sleep 1
(
  INSTALL_LIB_ONLY=1 SELFDIR="$ROOT/installer" . "$SCRIPT"
  ensure_mihomo_speedtest_symlink "$target" "$WORK/sbin" "$WORK/bin"
)
after=$(stat -c %Y "$WORK/sbin/mihomo-speedtest" 2>/dev/null || stat -f %m "$WORK/sbin/mihomo-speedtest")
[ "$before" = "$after" ] || fail "идемпотентный вызов пересоздал уже верную ссылку"

# --- обновление неверной ссылки ---
ln -sf "$WORK/somewhere-else" "$WORK/sbin/mihomo-speedtest"
(
  INSTALL_LIB_ONLY=1 SELFDIR="$ROOT/installer" . "$SCRIPT"
  ensure_mihomo_speedtest_symlink "$target" "$WORK/sbin" "$WORK/bin"
)
[ "$(readlink "$WORK/sbin/mihomo-speedtest")" = "$target" ] || fail "неверная ссылка не обновлена"

# --- первый каталог недоступен (не директория) -> fallback на второй ---
(
  INSTALL_LIB_ONLY=1 SELFDIR="$ROOT/installer" . "$SCRIPT"
  ensure_mihomo_speedtest_symlink "$target" "$WORK/no-such-dir" "$WORK/bin"
)
[ -L "$WORK/bin/mihomo-speedtest" ] || fail "не сработал fallback на второй каталог"

# --- оба каталога недоступны -> WARN, без падения ---
(
  INSTALL_LIB_ONLY=1 SELFDIR="$ROOT/installer" . "$SCRIPT"
  ensure_mihomo_speedtest_symlink "$target" "$WORK/no-such-1" "$WORK/no-such-2" \
    || fail "функция не должна возвращать ошибку даже без доступных каталогов"
)

# --- Review Focus: посторонний ОБЫЧНЫЙ файл (не симлинк) по тому же пути -
# не должен быть затёрт молча.
rm -f "$WORK/bin/mihomo-speedtest"
mkdir -p "$WORK/sbin3"
printf 'посторонний файл, не наш\n' > "$WORK/sbin3/mihomo-speedtest"
(
  INSTALL_LIB_ONLY=1 SELFDIR="$ROOT/installer" . "$SCRIPT"
  ensure_mihomo_speedtest_symlink "$target" "$WORK/sbin3" "$WORK/bin"
)
[ ! -L "$WORK/sbin3/mihomo-speedtest" ] || fail "посторонний обычный файл был заменён на символическую ссылку без предупреждения"
grep -qF "посторонний файл, не наш" "$WORK/sbin3/mihomo-speedtest" || fail "содержимое постороннего файла изменилось"
[ -L "$WORK/bin/mihomo-speedtest" ] || fail "не сработал fallback на второй каталог при занятом первом"

rm -rf "$WORK"
echo "test_ensure_mihomo_speedtest_symlink.sh: OK"
