#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
SCRIPT=$ROOT/mihomo-speedtest.sh
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/mihomo-speedtest-dispatch-test.XXXXXX")
trap 'rm -rf "$TEST_ROOT"' EXIT INT TERM

fail() { echo "FAIL: $*" >&2; exit 1; }

sh -n "$SCRIPT" || fail "mihomo-speedtest.sh не проходит sh -n"

mkfake() {
  cat > "$TEST_ROOT/$1" <<EOF
#!/bin/sh
printf '%s\n' "\$0 \$*" >> "$TEST_ROOT/calls.log"
EOF
  chmod +x "$TEST_ROOT/$1"
}
mkfake install.sh
mkfake uninstall.sh
mkfake update.sh
mkfake setup.sh
mkfake speedtest2.sh
mkfake stats_auth.sh
mkfake stats_service.sh
mkfake S80speedtest-stats

assert_called() {
  grep -qF "$1" "$TEST_ROOT/calls.log" || fail "не вызвано: $1 (лог: $(cat "$TEST_ROOT/calls.log" 2>/dev/null))"
}

: > "$TEST_ROOT/calls.log"
DIR=$TEST_ROOT sh "$SCRIPT" install --foo bar
assert_called "$TEST_ROOT/install.sh --foo bar"

: > "$TEST_ROOT/calls.log"
DIR=$TEST_ROOT sh "$SCRIPT" uninstall --purge
assert_called "$TEST_ROOT/uninstall.sh --purge"

: > "$TEST_ROOT/calls.log"
DIR=$TEST_ROOT sh "$SCRIPT" update check
assert_called "$TEST_ROOT/update.sh check"

: > "$TEST_ROOT/calls.log"
DIR=$TEST_ROOT sh "$SCRIPT" setup
assert_called "$TEST_ROOT/setup.sh"

for pair in "recalibrate:--recalibrate" "stop-web:--stop-web" "start-web:--start-web" "show-url:--show-url" "version:--version"; do
  cmd=${pair%%:*}; flag=${pair##*:}
  : > "$TEST_ROOT/calls.log"
  DIR=$TEST_ROOT sh "$SCRIPT" "$cmd"
  assert_called "$TEST_ROOT/install.sh $flag"
done

: > "$TEST_ROOT/calls.log"
DIR=$TEST_ROOT sh "$SCRIPT" run --extra
assert_called "$TEST_ROOT/speedtest2.sh --force --extra"

: > "$TEST_ROOT/calls.log"
DIR=$TEST_ROOT sh "$SCRIPT" reset-password
assert_called "$TEST_ROOT/stats_auth.sh reset"

: > "$TEST_ROOT/calls.log"
DIR=$TEST_ROOT sh "$SCRIPT" status
assert_called "$TEST_ROOT/stats_service.sh status"

: > "$TEST_ROOT/calls.log"
DIR=$TEST_ROOT INITD_SCRIPT=$TEST_ROOT/S80speedtest-stats sh "$SCRIPT" restart-web
assert_called "$TEST_ROOT/S80speedtest-stats restart"

out=$(DIR=$TEST_ROOT sh "$SCRIPT" 2>&1); rc=$?
[ "$rc" = 0 ] || fail "пустая команда должна давать exit 0, получено $rc"
case "$out" in *"Использование"*) ;; *) fail "пустая команда должна печатать usage: $out" ;; esac

out=$(DIR=$TEST_ROOT sh "$SCRIPT" help 2>&1); rc=$?
[ "$rc" = 0 ] || fail "help должен давать exit 0, получено $rc"

# Review Focus: похоже на существующий флаг install.sh, но НЕ команда диспетчера.
out=$(DIR=$TEST_ROOT sh "$SCRIPT" --recalibrate 2>&1) && rc=0 || rc=$?
[ "$rc" = 2 ] || fail "'--recalibrate' (с дефисами, не как команда) должен быть неизвестной командой, получено rc=$rc, out=$out"
case "$out" in *"Неизвестная команда"*) ;; *) fail "нет сообщения о неизвестной команде: $out" ;; esac

out=$(DIR=$TEST_ROOT sh "$SCRIPT" bogus-command 2>&1) && rc=0 || rc=$?
[ "$rc" = 2 ] || fail "неизвестная команда должна давать exit 2, получено $rc"
case "$out" in *"Неизвестная команда"*) ;; *) fail "нет сообщения о неизвестной команде: $out" ;; esac

echo "test_mihomo_speedtest_dispatch.sh: OK"
