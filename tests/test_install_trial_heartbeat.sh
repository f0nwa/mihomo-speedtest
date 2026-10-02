#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
SCRIPT=$ROOT/install.sh
fail() { echo "FAIL: $*" >&2; exit 1; }

sh -n "$SCRIPT" || fail "install.sh не проходит sh -n"

TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/install-trial-heartbeat-test.XXXXXX")
trap 'rm -rf "$TEST_ROOT"' EXIT INT TERM

# Фиктивный speedtest2.sh, который "выполняется" дольше одного тика
# heartbeat - интервал через TRIAL_HEARTBEAT_INTERVAL укорочен, чтобы
# тест не ждал реальные 8 секунд.
mkdir -p "$TEST_ROOT/dir"
cat > "$TEST_ROOT/dir/speedtest2.sh" <<'INNER'
#!/bin/sh
sleep 2
exit 0
INNER
chmod +x "$TEST_ROOT/dir/speedtest2.sh"

INSTALL_LIB_ONLY=1 SELFDIR="$ROOT/installer" . "$SCRIPT"
unset INSTALL_LIB_ONLY

(
  DIR=$TEST_ROOT/dir
  TRIAL_HEARTBEAT_INTERVAL=1
  run_trial_with_heartbeat
) 2>"$TEST_ROOT/err.log"

lines=$(grep -c "Пробный прогон ещё выполняется" "$TEST_ROOT/err.log" || true)
[ "$lines" -ge 1 ] || fail "heartbeat должен был напечатать хотя бы одну строку за время выполнения speedtest2.sh"

# после завершения speedtest2.sh фоновый heartbeat не должен продолжать
# печатать - ждём дольше интервала и проверяем, что строк не прибавилось
before=$lines
sleep 2
after=$(grep -c "Пробный прогон ещё выполняется" "$TEST_ROOT/err.log" || true)
[ "$after" = "$before" ] || fail "heartbeat должен останавливаться сразу после завершения speedtest2.sh (было $before, стало $after)"

echo "test_install_trial_heartbeat.sh: OK"
