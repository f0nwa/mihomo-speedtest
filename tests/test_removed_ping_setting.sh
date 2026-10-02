#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/removed-ping-setting-test.XXXXXX")
trap 'rm -rf "$TEST_ROOT"' EXIT INT TERM

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

api=$(DIR="$ROOT" ENV=/dev/null API_JSON=1 REQUEST_METHOD=GET "$ROOT/web/stats_cgi.sh")
case $api in
  *max_ping_ms*) fail "API всё ещё публикует непоказательный предел задержки" ;;
esac

html=$(DIR="$ROOT" ENV=/dev/null REQUEST_METHOD=GET "$ROOT/web/stats_cgi.sh")
case $html in
  *'name="max_ping_ms"'*) fail "HTML-форма всё ещё показывает предел задержки" ;;
esac

old_env=$TEST_ROOT/speedtest2.env
printf '%s\n' \
  "SOURCES='/old/config.yaml'" \
  "BLOCK='test'" \
  "MIN_SPEED='123'" \
  "MAX_PING_MS='300'" \
  "MAX_TESTED='10'" > "$old_env"

INSTALL_LIB_ONLY=1 SELFDIR="$ROOT/installer" . "$ROOT/install.sh"
SOURCES=/new/config.yaml
BLOCK=test
BLOCK_SOURCE=test
MIN_SPEED=123
write_env "$old_env"

grep -q '^MAX_PING_MS=' "$old_env" \
  && fail "повторная установка сохранила удалённую настройку MAX_PING_MS"
grep -q "^MAX_TESTED='10'" "$old_env" \
  || fail "повторная установка потеряла действующий лимит MAX_TESTED"

echo "test_removed_ping_setting.sh: OK"
