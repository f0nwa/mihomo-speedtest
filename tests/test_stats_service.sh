#!/bin/sh
set -eu
# Тесты stats_service.sh (порция 1 задачи "независимая служба
# веб-интерфейса статистики", см.
# docs/superpowers/specs/2026-09-15-independent-stats-service-design.md).
#
# Настоящий python3 не нужен: вместо него подставляется fake_httpd.sh
# (обычный sh-скрипт с тем же CLI: -f -p BIND:PORT -h DIR)
# через STATS_HTTPD_PY_CMD=sh -
# py_available-проверка в stats_service.sh смотрит только на "команда
# найдена и файл существует", не на то, что это настоящий python.
# Поведение фейкового бэкенда задаётся переменными окружения
# FAKE_EXIT_AFTER (сколько секунд прожить) и FAKE_EXIT_CODE (код выхода);
# без FAKE_EXIT_AFTER бэкенд живёт, пока его не убьют.

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
SERVICE=$ROOT/web/stats_service.sh
SPEEDTEST=$ROOT/speedtest-runtime/speedtest2.sh
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/stats-service-test.XXXXXX")

CLEANUP_PIDS=""
cleanup_test() {
  for p in $CLEANUP_PIDS; do
    kill "$p" 2>/dev/null || true
  done
  rm -rf "$TEST_ROOT"
}
trap cleanup_test EXIT INT TERM

fail() {
  echo "FAIL: $*" >&2
  [ -n "${LOGFILE:-}" ] && [ -f "$LOGFILE" ] && { echo "--- $LOGFILE ---" >&2; cat "$LOGFILE" >&2; }
  exit 1
}

wait_for() {
  # $1 = сколько секунд ждать, $2.. = команда/условие ("test", "grep -q", ...)
  timeout=$1
  shift
  n=0
  while [ "$n" -lt "$timeout" ]; do
    if "$@" >/dev/null 2>&1; then
      return 0
    fi
    n=$((n + 1))
    sleep 1
  done
  "$@" >/dev/null 2>&1
}

FAKE_HTTPD=$TEST_ROOT/fake_httpd.sh
cat > "$FAKE_HTTPD" <<'EOF'
#!/bin/sh
# фейковый HTTP-бэкенд для тестов stats_service.sh - см. шапку test_stats_service.sh
after=${FAKE_EXIT_AFTER:-}
code=${FAKE_EXIT_CODE:-1}
if [ -z "$after" ]; then
  while :; do sleep 1; done
fi
i=0
while [ "$i" -lt "$after" ]; do
  sleep 1
  i=$((i + 1))
done
exit "$code"
EOF
chmod +x "$FAKE_HTTPD"

new_case() {
  # $1 = имя подкаталога фикстуры внутри $TEST_ROOT
  W=$TEST_ROOT/$1
  mkdir -p "$W"
  cp "$SPEEDTEST" "$W/speedtest2.sh"
  : > "$W/speedtest2.env"
  RUNTIME=$W/runtime
  LOGFILE=$RUNTIME/service.log
  export DIR=$W
  export STATS_SERVICE_RUNTIME_DIR=$RUNTIME
  export SUPERVISOR_PIDFILE=$RUNTIME/supervisor.pid
  export STATS_HTTP_PIDFILE=$RUNTIME/httpd.pid
  export STATS_HTTP_LOG=$RUNTIME/httpd.log
  export RUN_LOG=$RUNTIME/service.log
  export STATS_HTTP_DIR=$W/stats_www
  export STATS_HTTPD_PY_CMD=sh
  export STATS_HTTPD_PY=$FAKE_HTTPD
  export STATS_HTTP_ENABLE=1
  export STATS_SERVICE_BACKOFF="1 2 3 4"
  export STATS_SERVICE_STABLE_SECONDS=100
  unset FAKE_EXIT_AFTER FAKE_EXIT_CODE 2>/dev/null || true
}

run_supervise_bg() {
  sh "$SERVICE" supervise >"$W/supervise.out" 2>&1 &
  SUP_PID=$!
  CLEANUP_PIDS="$CLEANUP_PIDS $SUP_PID"
}

stop_supervise() {
  kill "$SUP_PID" 2>/dev/null || true
  wait "$SUP_PID" 2>/dev/null || true
}

# --- 1: supervise() поднимает supervisor и бэкенд без истории прогонов ---
new_case c1
run_supervise_bg
wait_for 5 [ -f "$STATS_HTTP_PIDFILE" ] || fail "1: httpd.pid не появился"
httpd_pid=$(cat "$STATS_HTTP_PIDFILE")
kill -0 "$httpd_pid" 2>/dev/null || fail "1: бэкенд не запущен"
kill -0 "$SUP_PID" 2>/dev/null || fail "1: supervisor не запущен"
sh "$SERVICE" status | grep -q "httpd: работает" || fail "1: status не подтверждает работающий httpd"
stop_supervise

# --- 6: TERM останавливает supervisor и бэкенд без повторного запуска ---
new_case c6
run_supervise_bg
wait_for 5 [ -f "$STATS_HTTP_PIDFILE" ] || fail "6: httpd.pid не появился"
httpd_pid=$(cat "$STATS_HTTP_PIDFILE")
kill "$SUP_PID"
wait_for 5 sh -c "! kill -0 $SUP_PID 2>/dev/null" || fail "6: supervisor не завершился по TERM"
[ ! -f "$SUPERVISOR_PIDFILE" ] || fail "6: supervisor.pid не убран после остановки"
[ ! -f "$STATS_HTTP_PIDFILE" ] || fail "6: httpd.pid не убран после остановки"
kill -0 "$httpd_pid" 2>/dev/null && fail "6: бэкенд остался жив после остановки supervisor'а"
sleep 2
kill -0 "$httpd_pid" 2>/dev/null && fail "6: бэкенд респавнулся после штатной остановки"
true

# --- 3 и 4: падение бэкенда -> респавн, серия падений -> растущий backoff ---
new_case c34
export FAKE_EXIT_AFTER=1
export FAKE_EXIT_CODE=7
run_supervise_bg
wait_for 8 grep -q "попытка 3" "$LOGFILE" || fail "3/4: не дождались третьей попытки респавна"
grep -q "попытка 1" "$LOGFILE" || fail "4: нет лога попытки 1"
grep -q "через 1s (попытка 1)" "$LOGFILE" || fail "4: задержка попытки 1 не равна первому значению backoff"
grep -q "через 2s (попытка 2)" "$LOGFILE" || fail "4: задержка попытки 2 не увеличилась до второго значения backoff"
grep -q "через 3s (попытка 3)" "$LOGFILE" || fail "4: задержка попытки 3 не увеличилась до третьего значения backoff"
stop_supervise

# --- 5: после стабильной работы (>= STATS_SERVICE_STABLE_SECONDS) backoff сбрасывается ---
# STATS_SERVICE_STABLE_SECONDS читается supervise() один раз в начале цикла ожидания
# каждого запуска бэкенда, поэтому проверяем через два последовательных прогона
# supervise() в одном и том же runtime-каталоге: первый (быстрое падение) поднимает
# счётчик попыток, второй (бэкенд живёт дольше порога) должен его сбросить.
new_case c5
export STATS_SERVICE_STABLE_SECONDS=2
export FAKE_EXIT_AFTER=1
run_supervise_bg
wait_for 5 grep -q "попытка 1" "$LOGFILE" || fail "5: нет первого падения"
stop_supervise
export FAKE_EXIT_AFTER=3
run_supervise_bg
wait_for 6 grep -q "прожил 3s" "$LOGFILE" || fail "5: не дождались падения после стабильного прогона (3s)"
tail -n 5 "$LOGFILE" | grep -q "попытка 1" || fail "5: после стабильного прогона счётчик попыток не сброшен на 1"
stop_supervise

# --- 7: нечисловой/устаревший pid-файл не приводит к ошибке и не мешает старту ---
new_case c7
mkdir -p "$RUNTIME"
echo "not-a-pid" > "$STATS_HTTP_PIDFILE"
( : ) & deadpid=$!
wait "$deadpid" 2>/dev/null || true
echo "$deadpid" > "$SUPERVISOR_PIDFILE"
sh "$SERVICE" status >/dev/null 2>&1 && fail "7: status доложил о работе при мёртвом/чужом pid"
run_supervise_bg
wait_for 5 grep -qE "^[0-9]+$" "$STATS_HTTP_PIDFILE" || fail "7: supervise() не стартовал из-за устаревших pid-файлов (httpd.pid=$(cat "$STATS_HTTP_PIDFILE" 2>/dev/null))"
new_httpd_pid=$(cat "$STATS_HTTP_PIDFILE")
kill -0 "$new_httpd_pid" 2>/dev/null || fail "7: новый бэкенд не поднят после устаревших pid-файлов"
stop_supervise

# --- 8: python-бэкенд недоступен -> служба не запускается ---
new_case c8
export STATS_HTTPD_PY=/nonexistent/nope.py
if sh "$SERVICE" supervise >"$W/supervise.out" 2>&1; then
  fail "8: supervisor запустился без Python-бэкенда"
fi
grep -q "веб-интерфейс не запущен" "$LOGFILE" || fail "8: нет понятного сообщения об обязательном Python"
[ ! -f "$SUPERVISOR_PIDFILE" ] || fail "8: supervisor.pid создан без Python-бэкенда"
[ ! -f "$STATS_HTTP_PIDFILE" ] || fail "8: httpd.pid создан без Python-бэкенда"

# --- 10: STATS_HTTP_ENABLE=0 не запускает никаких процессов ---
new_case c10
export STATS_HTTP_ENABLE=0
sh "$SERVICE" supervise
[ ! -f "$SUPERVISOR_PIDFILE" ] || fail "10: supervisor.pid создан при STATS_HTTP_ENABLE=0"
[ ! -f "$STATS_HTTP_PIDFILE" ] || fail "10: httpd.pid создан при STATS_HTTP_ENABLE=0"

# --- 11: prepare() не копирует скрипты и статику в stats_www и убирает
#     копии, оставшиеся от старых версий (их теперь берёт stats_httpd.py
#     прямо из $DIR) ---
new_case c11
mkdir -p "$STATS_HTTP_DIR/cgi-bin"
: > "$STATS_HTTP_DIR/cgi-bin/update"
: > "$STATS_HTTP_DIR/app.js"
: > "$STATS_HTTP_DIR/index.html"
: > "$STATS_HTTP_DIR/stats.json"
sh "$SERVICE" prepare
[ ! -e "$STATS_HTTP_DIR/cgi-bin" ] || fail "11: prepare() не удалил старый cgi-bin/"
[ ! -e "$STATS_HTTP_DIR/app.js" ] || fail "11: prepare() не удалил старую копию app.js"
[ ! -e "$STATS_HTTP_DIR/index.html" ] || fail "11: prepare() не удалил старую копию index.html"
[ -f "$STATS_HTTP_DIR/stats.json" ] || fail "11: prepare() удалил данные stats.json"

# --- исполняемый бит новых файлов ---
[ -x "$SERVICE" ] || fail "stats_service.sh не исполняемый"

echo "OK: test_stats_service.sh"
