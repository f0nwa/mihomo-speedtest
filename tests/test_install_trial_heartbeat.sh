#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
SCRIPT=$ROOT/install.sh
fail() { echo "FAIL: $*" >&2; exit 1; }

sh -n "$SCRIPT" || fail "install.sh не проходит sh -n"

TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/install-trial-heartbeat-test.XXXXXX")
trap 'rm -rf "$TEST_ROOT"' EXIT INT TERM
export UI_LOG="$TEST_ROOT/ui.log" UI=plain

# Фиктивный speedtest2.sh, который "выполняется" дольше одного тика
# heartbeat - интервал через TRIAL_HEARTBEAT_INTERVAL укорочен, чтобы
# тест не ждал реальные 8 секунд.
mkdir -p "$TEST_ROOT/dir"
cat > "$TEST_ROOT/dir/speedtest2.sh" <<'INNER'
#!/bin/sh
sleep 2
: > "${0%/*}/trial.done"
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

# Спиннер синхронный: run_trial_with_heartbeat возвращается только после
# завершения speedtest2.sh (маркер уже есть), последней строкой идёт итог
# [OK], а не тик - фонового heartbeat, который мог бы пережить прогон, нет.
[ -f "$TEST_ROOT/dir/trial.done" ] || fail "run_trial_with_heartbeat вернулся раньше, чем завершился speedtest2.sh"
tail -1 "$TEST_ROOT/err.log" | grep -q '^ *\[OK\] Пробный прогон' \
  || fail "после прогона последней должна быть строка [OK] Пробный прогон: $(tail -1 "$TEST_ROOT/err.log")"

# Сбой пробного прогона: установка продолжается (код 0), но на экране -
# последние строки speedtest.log и путь к нему, а не одна строка [!!].
cat > "$TEST_ROOT/dir/speedtest2.sh" <<'INNER'
#!/bin/sh
echo "ОШИБКА_ПРОГОНА: нет нод" >> "${0%/*}/speedtest.log"
exit 1
INNER
rc=0
(
  DIR=$TEST_ROOT/dir
  run_trial_with_heartbeat
) 2>"$TEST_ROOT/fail.err" || rc=$?
[ "$rc" = 0 ] || fail "сбой пробного прогона не должен прерывать установку (код $rc)"
grep -q '^ *\[!!\] Пробный прогон' "$TEST_ROOT/fail.err" || fail "при сбое нет строки [!!] Пробный прогон"
grep -q 'ОШИБКА_ПРОГОНА: нет нод' "$TEST_ROOT/fail.err" || fail "при сбое хвост speedtest.log должен быть на экране: $(cat "$TEST_ROOT/fail.err")"
grep -q "Подробности: $TEST_ROOT/dir/speedtest.log" "$TEST_ROOT/fail.err" || fail "при сбое нет строки Подробности: .../speedtest.log"

# Хвост журнала после пробного прогона должен попадать в stderr, а не
# пропадать (раньше "2>/dev/null >&2" уводил его в /dev/null).
printf 'строка1\nстрока2\nПОСЛЕДНЯЯ_СТРОКА\n' > "$TEST_ROOT/dir/speedtest.log"
(
  DIR=$TEST_ROOT/dir
  print_trial_log_tail
) >"$TEST_ROOT/tail.out" 2>"$TEST_ROOT/tail.err"
# Хвост теперь уходит в журнал UI_LOG, а на экране - только итоговая строка.
grep -q "ПОСЛЕДНЯЯ_СТРОКА" "$UI_LOG" || fail "хвост speedtest.log должен попадать в UI_LOG"
grep -q "ПОСЛЕДНЯЯ_СТРОКА" "$TEST_ROOT/tail.err" && fail "хвост speedtest.log не должен печататься на экран"
[ ! -s "$TEST_ROOT/tail.out" ] || fail "хвост speedtest.log не должен идти в stdout"

# trial_status: прогресс по нодам из progress.json
cat > "$TEST_ROOT/dir/speedtest2.sh" <<'INNER'
#!/bin/sh
printf '{"running":true,"phase":"x","total":52,"tested":14,"ok":3}\n' > "$STATS_PROGRESS"
exit 0
INNER
(
  STATS_PROGRESS=$TEST_ROOT/progress.json
  export STATS_PROGRESS
  [ "$(trial_status)" = "подготовка" ] || exit 1
  "$TEST_ROOT/dir/speedtest2.sh"
  [ "$(trial_status)" = "Проверка нод 14/52" ] || { echo "got: $(trial_status)" >&2; exit 2; }
  printf '{"running":true,"total":0,"tested":0}\n' > "$STATS_PROGRESS"
  [ "$(trial_status)" = "подготовка" ] || exit 3
) || fail "trial_status: неверный вывод (код $?)"

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
