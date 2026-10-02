#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/stats-run-test.XXXXXX")
trap 'rm -rf "$TEST_ROOT"' EXIT INT TERM

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_contains() {
  case "$2" in
    *"$1"*) ;;
    *) fail "expected to find: $1 (context: $3)" ;;
  esac
}

assert_not_contains() {
  case "$2" in
    *"$1"*) fail "expected NOT to find: $1 (context: $3)" ;;
  esac
}

# --- фикстура: DIR со своей копией speedtest2.sh/stats_run.sh, без BLOCK -
#     как у настоящей установки, но реальный "прогон" (при POST) должен
#     сразу же остановиться на самой первой проверке main() ("BLOCK не
#     задан") и выйти, не трогая mihomo/сеть - этого достаточно, чтобы
#     проверить, что stats_run.sh действительно порождает отвязанный
#     фоновый процесс speedtest2.sh, а не просто отвечает JSON-ом ---
W=$TEST_ROOT/w
mkdir -p "$W"
cp "$ROOT/speedtest-runtime/speedtest2.sh" "$W/speedtest2.sh"
cp "$ROOT/web/stats_run.sh" "$W/stats_run.sh"
chmod +x "$W/speedtest2.sh" "$W/stats_run.sh"
: > "$W/speedtest2.env"
LOCK=$W/mst.lock

run_cgi() {
  # $1=METHOD. Печатает вывод CGI в stdout. LOCK - тестовый, отдельный от
  # /tmp/mst.lock, чтобы не мешать реальному прогону на этой же машине и
  # другим тестам (см. test_speedtest2.sh - тот же приём).
  method=$1
  DIR="$W" ENV="$W/speedtest2.env" LOCK="$LOCK" TMPROOT="$W" \
    REQUEST_METHOD="$method" "$W/stats_run.sh"
}

wait_for_log() {
  # $1=needle, $2=файл, $3=таймаут в десятых секунды (по умолчанию 30 = 3с).
  needle=$1; f=$2; n=${3:-30}
  i=0
  while [ "$i" -lt "$n" ]; do
    [ -f "$f" ] && grep -qF "$needle" "$f" 2>/dev/null && return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

# --- GET без DIR: скрипт не должен падать, а вернуть понятную JSON-ошибку ---
OUT_NODIR=$(REQUEST_METHOD=GET "$W/stats_run.sh")
assert_contains "Content-Type: application/json" "$OUT_NODIR" "no-DIR content-type"
assert_contains '"error"' "$OUT_NODIR" "no-DIR error field"

# --- GET: блокировка свободна -> running:false ---
OUT_IDLE=$(run_cgi GET)
assert_contains "Content-Type: application/json" "$OUT_IDLE" "idle content-type"
assert_contains '"running":false' "$OUT_IDLE" "idle GET reports not running"

# --- POST: блокировка свободна -> запускает speedtest2.sh --force в фоне,
#     started:true; процесс должен пережить завершение самого CGI-скрипта
#     (run_cgi уже вернул управление) и дописать в speedtest.log признак
#     того, что main() реально стартовал (BLOCK не задан -> ранний return) ---
OUT_START=$(run_cgi POST)
assert_contains '"started":true' "$OUT_START" "POST starts a run when idle"
assert_contains '"running":true' "$OUT_START" "POST reports running after start"
wait_for_log "BLOCK не задан" "$W/speedtest.log" \
  || fail "background speedtest2.sh --force did not run (detached process was not spawned/survived)"

# --- POST повторно, пока блокировка искусственно занята "живым" pid (наш
#     собственный $$) -> НЕ должен порождать вторую копию (started:false) ---
W2=$TEST_ROOT/w2
mkdir -p "$W2"
cp "$ROOT/speedtest-runtime/speedtest2.sh" "$W2/speedtest2.sh"
cp "$ROOT/web/stats_run.sh" "$W2/stats_run.sh"
chmod +x "$W2/speedtest2.sh" "$W2/stats_run.sh"
: > "$W2/speedtest2.env"
LOCK2=$W2/mst.lock
mkdir -p "$LOCK2"
echo $$ > "$LOCK2/pid"

OUT_BUSY_GET=$(DIR="$W2" ENV="$W2/speedtest2.env" LOCK="$LOCK2" TMPROOT="$W2" REQUEST_METHOD=GET "$W2/stats_run.sh")
assert_contains '"running":true' "$OUT_BUSY_GET" "GET reports running while lock held by live pid"

OUT_BUSY_POST=$(DIR="$W2" ENV="$W2/speedtest2.env" LOCK="$LOCK2" TMPROOT="$W2" REQUEST_METHOD=POST "$W2/stats_run.sh")
assert_contains '"started":false' "$OUT_BUSY_POST" "POST does not spawn a second run while one is in progress"
assert_contains '"running":true' "$OUT_BUSY_POST" "POST still reports running while lock held"
sleep 0.3
[ -f "$W2/speedtest2.log" ] && fail "POST spawned a second speedtest2.sh despite lock being held"

echo "test_stats_run.sh: OK"
