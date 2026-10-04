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

# Хвост журнала после пробного прогона должен попадать в stderr, а не
# пропадать (раньше "2>/dev/null >&2" уводил его в /dev/null).
printf 'строка1\nстрока2\nПОСЛЕДНЯЯ_СТРОКА\n' > "$TEST_ROOT/dir/speedtest.log"
(
  DIR=$TEST_ROOT/dir
  print_trial_log_tail
) >"$TEST_ROOT/tail.out" 2>"$TEST_ROOT/tail.err"
grep -q "ПОСЛЕДНЯЯ_СТРОКА" "$TEST_ROOT/tail.err" || fail "хвост speedtest.log должен печататься в stderr"
[ ! -s "$TEST_ROOT/tail.out" ] || fail "хвост speedtest.log не должен идти в stdout"

# Нет журнала - без ошибки и без шума от tail
(
  DIR=$TEST_ROOT/nonexistent
  print_trial_log_tail
) 2>"$TEST_ROOT/tail_missing.err" || fail "print_trial_log_tail не должен падать без журнала"
grep -q "tail:" "$TEST_ROOT/tail_missing.err" && fail "ошибка tail об отсутствующем журнале не должна попадать в вывод"

# Под "curl ... | sh" stdin переоткрывается на терминал (reopen_tty), и
# без явного exit оболочка после main продолжила бы читать команды со
# stdin. Эмулируем: всё, что идёт в потоке после install.sh, не должно
# выполняться.
mkdir -p "$TEST_ROOT/piped"
for f in $ALL_PROJECT_FILES; do : > "$TEST_ROOT/piped/$f"; done
cp "$ROOT/installer/version_check.sh" "$TEST_ROOT/piped/version_check.sh"
{ cat "$SCRIPT"; echo 'echo ПОСЛЕ_КОНЦА_СКРИПТА'; } \
  | DIR="$TEST_ROOT/piped" SELFDIR="$TEST_ROOT/piped" sh -s -- --version \
    >"$TEST_ROOT/piped.out" 2>"$TEST_ROOT/piped.err" || true
grep -q "ПОСЛЕ_КОНЦА_СКРИПТА" "$TEST_ROOT/piped.out" && fail "после main install.sh должен завершаться, а не читать команды дальше со stdin"
grep -q "Установленный релиз не отслеживается" "$TEST_ROOT/piped.err" || fail "--version под sh -s должен отработать (stderr: $(cat "$TEST_ROOT/piped.err"))"

echo "test_install_trial_heartbeat.sh: OK"
