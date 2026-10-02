#!/bin/sh
# Старое самообновление speedtest2.sh (--check-update/--update-core/
# --update-stats: файлы с ветки main и VERSIONS, без SHA256) удалено -
# обновления ставит только update.sh. Флаги должны завершаться понятной
# ошибкой и НЕ запускать вместо себя полный прогон спидтеста.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
SCRIPT=$ROOT/speedtest-runtime/speedtest2.sh
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/removed-update-flags-test.XXXXXX")
trap 'rm -rf "$TEST_ROOT"' EXIT INT TERM

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

for flag in --check-update --update-core --update-stats; do
  W=$TEST_ROOT/w${flag#--}
  mkdir -p "$W"
  # Маркер: при запуске main() скрипт взял бы блокировку $LOCK.
  rc=0
  out=$(cd "$W" && DIR="$W" ENV="$W/speedtest2.env" LOG="$W/speedtest.log" \
    TMPROOT="$W" LOCK="$W/mst.lock" WORK="$W/work" \
    sh "$SCRIPT" "$flag" 2>&1) || rc=$?
  [ "$rc" = 2 ] || fail "$flag: ожидался код 2, получен $rc ($out)"
  case $out in
    *"$flag больше не поддерживается"*"mihomo-speedtest update --check"*) ;;
    *) fail "$flag: нет подсказки про update.sh: $out" ;;
  esac
  [ ! -e "$W/mst.lock" ] && [ ! -e "$W/work" ] || fail "$flag: запущен прогон спидтеста"
done

# Функции старого механизма не должны остаться в библиотечном режиме.
MST_LIB_ONLY=1 . "$SCRIPT"
for fn in check_update update_core update_stats apply_stats_update update_component_files fetch_from_source_or_mirror; do
  if command -V "$fn" >/dev/null 2>&1; then
    fail "функция $fn старого самообновления всё ещё определена"
  fi
done

echo "test_removed_update_flags.sh: OK"
