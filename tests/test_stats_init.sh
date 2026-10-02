#!/bin/sh
set -eu
# Тесты шаблона stats_init.sh (start/stop/restart/check) - обёртки над
# stats_service.sh, которую install.sh ставит как исполняемый
# /opt/etc/init.d/S80speedtest-stats (сама установка - порция 3, см.
# docs/superpowers/specs/2026-09-15-independent-stats-service-design.md).
# stats_service.sh здесь настоящий (не подменяется), подменяется только
# HTTP-бэкенд - см. шапку test_stats_service.sh про fake_httpd.sh.

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
INIT=$ROOT/web/stats_init.sh
SERVICE=$ROOT/web/stats_service.sh
SPEEDTEST=$ROOT/speedtest-runtime/speedtest2.sh
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/stats-init-test.XXXXXX")
trap 'rm -rf "$TEST_ROOT"' EXIT INT TERM

fail() {
  echo "FAIL: $*" >&2
  [ -f "$LOGFILE" ] && { echo "--- $LOGFILE ---" >&2; cat "$LOGFILE" >&2; }
  exit 1
}

wait_for() {
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

W=$TEST_ROOT/w
mkdir -p "$W"
cp "$SPEEDTEST" "$W/speedtest2.sh"
: > "$W/speedtest2.env"

FAKE_HTTPD=$TEST_ROOT/fake_httpd.sh
cat > "$FAKE_HTTPD" <<'EOF'
#!/bin/sh
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

RUNTIME=$W/runtime
LOGFILE=$RUNTIME/service.log
export DIR=$W
export SERVICE=$SERVICE
export ENV=$W/speedtest2.env
export STATS_SERVICE_RUNTIME_DIR=$RUNTIME
export SUPERVISOR_PIDFILE=$RUNTIME/supervisor.pid
export STATS_HTTP_PIDFILE=$RUNTIME/httpd.pid
export STATS_HTTP_LOG=$RUNTIME/httpd.log
export STATS_HTTP_CONF=$RUNTIME/httpd.conf
export RUN_LOG=$RUNTIME/service.log
export STATS_HTTP_DIR=$W/stats_www
export STATS_HTTPD_PY_CMD=sh
export STATS_HTTPD_PY=$FAKE_HTTPD
export STATS_HTTPD_CMD="sh $TEST_ROOT/fake_busybox.sh"
cp "$FAKE_HTTPD" "$TEST_ROOT/fake_busybox.sh"
export STATS_HTTP_ENABLE=1
export STATS_SERVICE_BACKOFF="1 1 1 1"
export STOP_WAIT=5

# --- start: поднимает supervisor и бэкенд ---
sh "$INIT" start >"$W/start1.out" 2>&1 || fail "start: завершился с ошибкой ($(cat "$W/start1.out"))"
wait_for 5 [ -f "$STATS_HTTP_PIDFILE" ] || fail "start: httpd.pid не появился"
sup1=$(cat "$SUPERVISOR_PIDFILE")
kill -0 "$sup1" 2>/dev/null || fail "start: supervisor не запущен"

# --- check: докладывает "работает" и возвращает 0 ---
sh "$INIT" check | grep -q "работает" || fail "check: не подтвердил работу службы"

# --- повторный start: не создаёт второй supervisor ---
sh "$INIT" start >"$W/start2.out" 2>&1 || fail "повторный start завершился с ошибкой"
sup2=$(cat "$SUPERVISOR_PIDFILE")
[ "$sup1" = "$sup2" ] || fail "повторный start создал новый supervisor (было $sup1, стало $sup2)"
grep -q "уже запущена" "$W/start2.out" || fail "повторный start не сообщил, что служба уже запущена"

# --- stop: останавливает supervisor и бэкенд, без последующего респавна ---
httpd_pid=$(cat "$STATS_HTTP_PIDFILE")
sh "$INIT" stop >"$W/stop1.out" 2>&1 || fail "stop завершился с ошибкой"
[ ! -f "$SUPERVISOR_PIDFILE" ] || fail "stop: supervisor.pid не убран"
[ ! -f "$STATS_HTTP_PIDFILE" ] || fail "stop: httpd.pid не убран"
kill -0 "$sup1" 2>/dev/null && fail "stop: supervisor всё ещё жив"
kill -0 "$httpd_pid" 2>/dev/null && fail "stop: бэкенд всё ещё жив"
sleep 2
kill -0 "$httpd_pid" 2>/dev/null && fail "stop: бэкенд респавнулся после остановки"

# --- check после stop: сообщает "не работает" и возвращает не 0 ---
sh "$INIT" check >/dev/null 2>&1 && fail "check после stop вернул успех"

# --- повторный stop на уже остановленной службе: не ошибка ---
sh "$INIT" stop >"$W/stop2.out" 2>&1 || fail "повторный stop завершился с ошибкой"

# --- restart: поднимает новый supervisor и бэкенд ---
sh "$INIT" restart >"$W/restart1.out" 2>&1 || fail "restart завершился с ошибкой"
wait_for 5 [ -f "$STATS_HTTP_PIDFILE" ] || fail "restart: httpd.pid не появился"
sup3=$(cat "$SUPERVISOR_PIDFILE")
kill -0 "$sup3" 2>/dev/null || fail "restart: supervisor не запущен"
sh "$INIT" stop >/dev/null 2>&1 || true

# --- STATS_HTTP_ENABLE=0: start не запускает никаких процессов ---
echo "STATS_HTTP_ENABLE=0" > "$ENV"
sh "$INIT" start >"$W/start3.out" 2>&1 || fail "start с STATS_HTTP_ENABLE=0 завершился с ошибкой"
[ ! -f "$SUPERVISOR_PIDFILE" ] || fail "STATS_HTTP_ENABLE=0: supervisor всё равно запущен"
grep -q "отключён" "$W/start3.out" || fail "STATS_HTTP_ENABLE=0: не сообщено об отключении"

# --- исполняемые биты новых файлов ---
[ -x "$INIT" ] || fail "stats_init.sh не исполняемый"
[ -x "$SERVICE" ] || fail "stats_service.sh не исполняемый"

echo "OK: test_stats_init.sh"
