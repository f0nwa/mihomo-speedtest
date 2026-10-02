#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
SCRIPT=$ROOT/speedtest-runtime/speedtest2.sh
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/speedtest2-test.XXXXXX")
trap 'rm -rf "$TEST_ROOT"' EXIT INT TERM

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_eq() {
  [ "$1" = "$2" ] || fail "expected [$1] = [$2]"
}

LOADED_MARK=$TEST_ROOT/library-loaded
MST_LIB_ONLY=1 TEST_SCRIPT=$SCRIPT LOADED_MARK=$LOADED_MARK /bin/sh -c '
  . "$TEST_SCRIPT"
  command -V main >/dev/null 2>&1 || exit 91
  command -V cleanup >/dev/null 2>&1 || exit 92
  : > "$LOADED_MARK"
' >/dev/null 2>&1 || true

[ -f "$LOADED_MARK" ] || fail "library mode did not return control after sourcing"

MST_LIB_ONLY=1 . "$SCRIPT"

# Единицы журнала: десятичные Мбит/с, включая ноль и скорости свыше 32 бит.
assert_eq "$(format_mbit 0)" 0.0
assert_eq "$(format_mbit 1000000)" 8.0
assert_eq "$(format_mbit 1048576)" 8.4
assert_eq "$(format_mbit 12500)" 0.1
assert_eq "$(format_mbit 5000000000)" 40000.0

LOCK=$TEST_ROOT/mst.lock
WORK=$TEST_ROOT/work.$$
RUN_LOG=$WORK/run.log
mkdir -p "$WORK"
acquire_lock || fail "first process could not acquire lock"
[ "$LOCK_HELD" = 1 ] || fail "lock owner flag was not set"

if MST_LIB_ONLY=1 LOCK=$LOCK TEST_SCRIPT=$SCRIPT /bin/sh -c '
  . "$TEST_SCRIPT"
  acquire_lock
' >/dev/null 2>&1; then
  fail "second process acquired the same lock"
fi

cleanup
[ ! -e "$LOCK" ] || fail "owned lock was not removed"

# --- force: parse_args, живой вывод say(), захват зависшей блокировки, ожидание живой ---

(
  MST_LIB_ONLY=1 . "$SCRIPT"
  FORCE=0
  parse_args --force
  [ "$FORCE" = 1 ] || exit 1
)
[ $? -eq 0 ] || fail "parse_args did not set FORCE=1 for --force"

(
  MST_LIB_ONLY=1 . "$SCRIPT"
  FORCE=0
  parse_args --recalibrate --force --something-else
  [ "$FORCE" = 1 ] || exit 1
)
[ $? -eq 0 ] || fail "parse_args did not recognise --force among other arguments"

(
  MST_LIB_ONLY=1 . "$SCRIPT"
  parse_args --recalibrate
  [ "$FORCE" = 0 ] || exit 1
)
[ $? -eq 0 ] || fail "parse_args must not enable FORCE without --force"

SAYWORK=$TEST_ROOT/say-force-work
mkdir -p "$SAYWORK"
(
  WORK=$SAYWORK
  RUN_LOG=$SAYWORK/run.log
  LOG=$TEST_ROOT/say-force.log
  FORCE=0
  OUT=$(say "тихий прогон" 2>&1)
  [ -z "$OUT" ] || exit 1
)
[ $? -eq 0 ] || fail "say() printed to stdout even though FORCE=0"

(
  WORK=$SAYWORK
  RUN_LOG=$SAYWORK/run.log
  LOG=$TEST_ROOT/say-force.log
  FORCE=1
  OUT=$(say "живой прогон" 2>&1)
  case $OUT in
    *"живой прогон"*) ;;
    *) exit 1 ;;
  esac
)
[ $? -eq 0 ] || fail "say() did not echo live when FORCE=1"
grep -q "живой прогон" "$SAYWORK/run.log" || fail "say() with FORCE=1 stopped writing to RUN_LOG"

# force: чужая блокировка занята мёртвым pid -> force её забирает и продолжает работу
STALEWORK=$TEST_ROOT/force-stale-work
mkdir -p "$STALEWORK"
STALELOCK=$STALEWORK/mst.lock
mkdir "$STALELOCK"
echo 999999 > "$STALELOCK/pid"   # заведомо несуществующий pid в тестовом окружении
(
  MST_LIB_ONLY=1 . "$SCRIPT"
  FORCE=1
  FORCE_WAIT=5
  LOCK=$STALELOCK
  WORK=$STALEWORK/work
  RUN_LOG=$WORK/run.log
  mkdir -p "$WORK"
  acquire_lock
) || fail "force did not take over a stale lock"
[ -f "$STALELOCK/pid" ] || fail "force did not leave its own pid after taking over a stale lock"

# force: чужая блокировка занята живым процессом -> ждёт FORCE_WAIT секунд и сдаётся с ошибкой
BUSYWORK=$TEST_ROOT/force-busy-work
mkdir -p "$BUSYWORK"
BUSYLOCK=$BUSYWORK/mst.lock
mkdir "$BUSYLOCK"
echo $$ > "$BUSYLOCK/pid"   # pid текущего тестового процесса — заведомо жив
if (
  MST_LIB_ONLY=1 . "$SCRIPT"
  FORCE=1
  FORCE_WAIT=4
  LOCK=$BUSYLOCK
  WORK=$BUSYWORK/work
  RUN_LOG=$WORK/run.log
  mkdir -p "$WORK"
  sleep() { :; }   # не ждать реальные секунды в тесте
  acquire_lock
); then
  fail "force acquired a lock held by a live process"
fi
[ -d "$BUSYLOCK" ] || fail "force must not remove a lock held by a live process"


TERM_MARK=$TEST_ROOT/continued-after-term
set +e
MST_LIB_ONLY=1 TEST_SCRIPT=$SCRIPT TERM_MARK=$TERM_MARK /bin/sh -c '
  . "$TEST_SCRIPT"
  WORK=$(mktemp -d "${TMPDIR:-/tmp}/mst-signal.XXXXXX")
  RUN_LOG=$WORK/run.log
  LOCK=$WORK.lock
  acquire_lock || exit 90
  install_traps
  kill -TERM $$
  : > "$TERM_MARK"
'
term_rc=$?
set -e
assert_eq "$term_rc" 143
[ ! -e "$TERM_MARK" ] || fail "script continued after TERM"

PUBDIR=$TEST_ROOT/publish
mkdir -p "$PUBDIR"
printf '%s\n' 'proxies:' '  - name: one' > "$PUBDIR/current.yaml"
cp "$PUBDIR/current.yaml" "$PUBDIR/new.yaml"
FAST_CHANGED=9
publish_fast "$PUBDIR/new.yaml" "$PUBDIR/current.yaml" || fail "equal publish failed"
assert_eq "$FAST_CHANGED" 0
[ ! -e "$PUBDIR/.current.yaml.$$" ] || fail "equal publish wrote a temporary file"

printf '%s\n' 'proxies:' '  - name: two' > "$PUBDIR/new.yaml"
publish_fast "$PUBDIR/new.yaml" "$PUBDIR/current.yaml" || fail "changed publish failed"
assert_eq "$FAST_CHANGED" 1
cmp -s "$PUBDIR/new.yaml" "$PUBDIR/current.yaml" || fail "published content differs"

printf '%s\n' 'proxies:' '  - name: preserved' > "$PUBDIR/current.yaml"
if (
  cp() { return 1; }
  publish_fast "$PUBDIR/new.yaml" "$PUBDIR/current.yaml"
); then
  fail "publish succeeded after simulated copy failure"
fi
grep -q 'name: preserved' "$PUBDIR/current.yaml" || fail "old output was damaged"

if (
  mv() { return 1; }
  publish_fast "$PUBDIR/new.yaml" "$PUBDIR/current.yaml"
); then
  fail "publish succeeded after simulated move failure"
fi
grep -q 'name: preserved' "$PUBDIR/current.yaml" || fail "move failure damaged old output"

WORK=$TEST_ROOT/log-work
mkdir -p "$WORK"
RUN_LOG=$WORK/run.log
LOG=$TEST_ROOT/persistent.log
LOG_LIMIT=102400
LOG_FLUSHED=0
say "первая строка"
say "вторая строка"
[ ! -e "$LOG" ] || fail "say wrote directly to persistent storage"
flush_log || fail "flush_log failed"
assert_eq "$(grep -c 'строка' "$LOG")" 2
flush_log || fail "second flush_log failed"
assert_eq "$(grep -c 'строка' "$LOG")" 2

printf '%s\n' \
  '300 n0001' \
  '290 n0002' \
  '280 n0003' \
  '270 n0004' > "$TEST_ROOT/results.txt"
printf 'n0001\tA\nn0002\tA\nn0003\tB\nn0004\tC\n' > "$TEST_ROOT/map.txt"
select_winners "$TEST_ROOT/results.txt" "$TEST_ROOT/map.txt" "$TEST_ROOT/win.txt" 100 3 3
assert_eq "$(wc -l < "$TEST_ROOT/win.txt" | tr -d ' ')" 3
grep -q 'n0001' "$TEST_ROOT/win.txt" || fail "fastest duplicate was lost"
grep -q 'n0003' "$TEST_ROOT/win.txt" || fail "unique node B was lost"
grep -q 'n0004' "$TEST_ROOT/win.txt" || fail "unique node C was lost"

# --- MIN_WINNERS: если порог прошло меньше минимума, добираем из
#     остальных РАБОЧИХ (SP>0) нод по убыванию скорости - см.
#     "важное дополнение" от 2026-09-08: пустая/недобранная "самая
#     быстрая" группа хуже, чем нода медленнее порога, но живая.
printf '%s\n' \
  '100 n0001' \
  '90 n0002' \
  '80 n0003' \
  '70 n0004' \
  '0 n0005' > "$TEST_ROOT/results-mw.txt"
printf 'n0001\tA\nn0002\tB\nn0003\tC\nn0004\tD\nn0005\tE\n' > "$TEST_ROOT/map-mw.txt"
# порог 1000 - никто не проходит, но 4 ноды рабочие (SP>0) - добор до 3-х
select_winners "$TEST_ROOT/results-mw.txt" "$TEST_ROOT/map-mw.txt" "$TEST_ROOT/win-mw1.txt" 1000 20 3
assert_eq "$(wc -l < "$TEST_ROOT/win-mw1.txt" | tr -d ' ')" 3
grep -q 'n0001' "$TEST_ROOT/win-mw1.txt" || fail "MIN_WINNERS: самая быстрая рабочая нода потеряна при доборе"
grep -q 'n0002' "$TEST_ROOT/win-mw1.txt" || fail "MIN_WINNERS: вторая по скорости рабочая нода потеряна при доборе"
grep -q 'n0003' "$TEST_ROOT/win-mw1.txt" || fail "MIN_WINNERS: третья по скорости рабочая нода потеряна при доборе"
grep -q 'n0004' "$TEST_ROOT/win-mw1.txt" && fail "MIN_WINNERS: добрано больше, чем требовал минимум"
grep -q 'n0005' "$TEST_ROOT/win-mw1.txt" && fail "MIN_WINNERS: полностью нерабочая (SP=0) нода не должна попадать в добор"

# частично прошли порог (только n0001, т.к. 290 < 295) + добор с дедупом
# имён между прошедшими порог и добором (n0002 - дубль имени A, должен
# быть пропущен в пользу n0003/n0004)
printf '%s\n' \
  '300 n0001' \
  '290 n0002' \
  '280 n0003' \
  '270 n0004' > "$TEST_ROOT/results-mw2.txt"
printf 'n0001\tA\nn0002\tA\nn0003\tB\nn0004\tC\n' > "$TEST_ROOT/map-mw2.txt"
select_winners "$TEST_ROOT/results-mw2.txt" "$TEST_ROOT/map-mw2.txt" "$TEST_ROOT/win-mw2.txt" 295 3 3
assert_eq "$(wc -l < "$TEST_ROOT/win-mw2.txt" | tr -d ' ')" 3
grep -q 'n0001' "$TEST_ROOT/win-mw2.txt" || fail "MIN_WINNERS+дедуп: прошедшая порог нода потеряна"
grep -q 'n0002' "$TEST_ROOT/win-mw2.txt" && fail "MIN_WINNERS+дедуп: добрана нода с именем, уже занятым прошедшей порог"
grep -q 'n0003' "$TEST_ROOT/win-mw2.txt" || fail "MIN_WINNERS+дедуп: нода B не добрана"
grep -q 'n0004' "$TEST_ROOT/win-mw2.txt" || fail "MIN_WINNERS+дедуп: нода C не добрана"

# рабочих нод в принципе меньше минимума - берём сколько есть, без падения
printf '%s\n' \
  '50 n0001' \
  '0 n0002' \
  '0 n0003' > "$TEST_ROOT/results-mw3.txt"
printf 'n0001\tA\nn0002\tB\nn0003\tC\n' > "$TEST_ROOT/map-mw3.txt"
select_winners "$TEST_ROOT/results-mw3.txt" "$TEST_ROOT/map-mw3.txt" "$TEST_ROOT/win-mw3.txt" 1000 20 3
assert_eq "$(wc -l < "$TEST_ROOT/win-mw3.txt" | tr -d ' ')" 1
grep -q 'n0001' "$TEST_ROOT/win-mw3.txt" || fail "MIN_WINNERS: единственная рабочая нода должна была попасть в выдачу"

# TOPN всё равно ограничивает добор сверху, даже если MIN_WINNERS просит больше
printf '%s\n' \
  '50 n0001' \
  '40 n0002' \
  '30 n0003' \
  '20 n0004' > "$TEST_ROOT/results-mw4.txt"
printf 'n0001\tA\nn0002\tB\nn0003\tC\nn0004\tD\n' > "$TEST_ROOT/map-mw4.txt"
select_winners "$TEST_ROOT/results-mw4.txt" "$TEST_ROOT/map-mw4.txt" "$TEST_ROOT/win-mw4.txt" 1000 2 5
assert_eq "$(wc -l < "$TEST_ROOT/win-mw4.txt" | tr -d ' ')" 2
grep -q 'n0001' "$TEST_ROOT/win-mw4.txt" || fail "MIN_WINNERS+TOPN: самая быстрая нода потеряна"
grep -q 'n0002' "$TEST_ROOT/win-mw4.txt" || fail "MIN_WINNERS+TOPN: вторая по скорости нода потеряна"
grep -q 'n0003' "$TEST_ROOT/win-mw4.txt" && fail "MIN_WINNERS+TOPN: добор превысил TOPN"

SEEN=$TEST_ROOT/seen-names.txt
: > "$SEEN"
remember_name A "$SEEN" || fail "first name was treated as duplicate"
if remember_name A "$SEEN"; then
  fail "duplicate name was counted twice"
fi
remember_name B "$SEEN" || fail "second unique name was rejected"
assert_eq "$(wc -l < "$SEEN" | tr -d ' ')" 2

WORK=$TEST_ROOT/prepare-work
mkdir -p "$WORK/nodes"
PREP=$ROOT/speedtest-runtime/prep.awk
SOURCES=$TEST_ROOT/inline-source.yaml
BLOCK='Russia|RU'
EXTYPE='trojan|ss'
printf '%s\n' \
  'proxies:' \
  '  - {name: inline, type: vless, server: 1.2.3.4, port: 443}' > "$SOURCES"
if prepare_nodes; then
  fail "prepare_nodes hid prep.awk parse failure"
fi
grep -q 'inline proxy maps are not supported' "$WORK/prep.err" || fail "prepare_nodes lost parser diagnostic"

API_MAIN=127.0.0.1:9090
API=127.0.0.1:9099
DELAY_URL='https%3A%2F%2Fwww.gstatic.com%2Fgenerate_204'
WORK=$TEST_ROOT/network-work
mkdir -p "$WORK"
printf '%s\n' D0001 > "$WORK/delay_groups.txt"
if (
  curl() { return 7; }
  reload_provider
); then
  fail "reload_provider hid curl failure"
fi
if (
  curl() { return 7; }
  fetch_delays
); then
  fail "fetch_delays hid curl failure"
fi

if (
  curl() {
    for arg do
      [ "$arg" = -f ] && return 22
    done
    return 0
  }
  reload_provider
); then
  fail "reload_provider treats HTTP 500 as success"
fi
if (
  curl() {
    for arg do
      [ "$arg" = -f ] && return 22
    done
    return 0
  }
  fetch_delays
); then
  fail "fetch_delays treats HTTP 500 as success"
fi
if (
  curl() {
    for arg do
      [ "$arg" = -f ] && return 22
    done
    return 0
  }
  select_proxy n0001
); then
  fail "select_proxy treats HTTP 500 as success"
fi

assert_eq "$(normalize_speed '12345.67')" 12345
assert_eq "$(normalize_speed 'unexpected')" 0
assert_eq "$(normalize_speed '')" 0
assert_eq "$(accepted_speed 200 '12345.67')" 12345
assert_eq "$(accepted_speed 206 '9876.54')" 9876
assert_eq "$(accepted_speed 403 '999999.00')" 0
assert_eq "$(accepted_speed 000 '999999.00')" 0

ENVDIR=$TEST_ROOT/env-work
mkdir -p "$ENVDIR"
printf '%s\n' "SOURCES='/tmp/custom-a.yaml /tmp/custom-b.yaml'" "MIN_SPEED='999'" "SIZE='2097152'" \
  > "$ENVDIR/speedtest2.env"
(
  unset ENV
  DIR=$ENVDIR
  MST_LIB_ONLY=1 . "$SCRIPT"
  assert_eq "$SOURCES" '/tmp/custom-a.yaml /tmp/custom-b.yaml'
  assert_eq "$MIN_SPEED" 999
  # SPEED_URL должен строиться ПОСЛЕ чтения speedtest2.env - иначе SIZE из
  # env (или из веб-формы, которая пишет тем же способом) молча не
  # действовал бы: URL остался бы со значением SIZE по умолчанию (10 МБ).
  assert_eq "$SPEED_URL" 'https://speed.cloudflare.com/__down?bytes=2097152'
)

NOENVDIR=$TEST_ROOT/noenv-work
mkdir -p "$NOENVDIR"
(
  unset ENV SOURCES BLOCK
  DIR=$NOENVDIR
  MIHOMO_DIR=$NOENVDIR
  MST_LIB_ONLY=1 . "$SCRIPT"
  assert_eq "$SOURCES" "$NOENVDIR/config.yaml"
  assert_eq "$BLOCK" ''
  assert_eq "$MIN_SPEED" 1048576
)

if (
  BLOCK=
  SOURCES=$TEST_ROOT/missing.yaml
  LOG=/dev/null
  main
); then
  fail "main should reject an empty BLOCK filter"
fi

MIN_RATIO=0.25
MIN_FLOOR=524288
assert_eq "$(compute_threshold 4194304)" 1048576
assert_eq "$(compute_threshold 1048576)" 524288
assert_eq "$(compute_threshold 0)" 524288

if (
  curl() { return 7; }
  result=$(measure_direct)
  [ "$result" = 0 ]
); then
  :
else
  fail "measure_direct did not fall back to 0 on curl failure"
fi

# --- история замеров: trim_runs / trim_nodes_since / record_history ---

HISTDIR=$TEST_ROOT/history-work
mkdir -p "$HISTDIR"

printf '100\ta\t1\t1\t1\t1\t1\t1\t1\n200\tb\t1\t1\t1\t1\t1\t1\t1\n300\tc\t1\t1\t1\t1\t1\t1\t1\n' \
  > "$HISTDIR/runs_in.tsv"
trim_runs "$HISTDIR/runs_in.tsv" "$HISTDIR/runs_out.tsv" 2 0 300
assert_eq "$(wc -l < "$HISTDIR/runs_out.tsv" | tr -d ' ')" 2
grep -q '^100' "$HISTDIR/runs_out.tsv" && fail "trim_runs: oldest run was not dropped by count"
grep -q '^300' "$HISTDIR/runs_out.tsv" || fail "trim_runs: newest run was lost"

printf '100\ta\t1\t1\t1\t1\t1\t1\t1\n999900\tb\t1\t1\t1\t1\t1\t1\t1\n999990\tc\t1\t1\t1\t1\t1\t1\t1\n' \
  > "$HISTDIR/runs_in2.tsv"
trim_runs "$HISTDIR/runs_in2.tsv" "$HISTDIR/runs_out2.tsv" 0 1 1000000
grep -q '^100' "$HISTDIR/runs_out2.tsv" && fail "trim_runs: old run not dropped by days"
assert_eq "$(wc -l < "$HISTDIR/runs_out2.tsv" | tr -d ' ')" 2

trim_runs "$HISTDIR/runs_in.tsv" "$HISTDIR/runs_out3.tsv" 0 0 300
assert_eq "$(wc -l < "$HISTDIR/runs_out3.tsv" | tr -d ' ')" 3

printf '100\t5000\tnodeA\n200\t6000\tnodeB\n300\t7000\tnodeC\n' > "$HISTDIR/nodes_in.tsv"
trim_nodes_since "$HISTDIR/nodes_in.tsv" "$HISTDIR/nodes_out.tsv" 200
assert_eq "$(wc -l < "$HISTDIR/nodes_out.tsv" | tr -d ' ')" 2
grep -q nodeA "$HISTDIR/nodes_out.tsv" && fail "trim_nodes_since: row below cutoff was kept"

trim_nodes_since "$HISTDIR/nodes_in.tsv" "$HISTDIR/nodes_out_empty.tsv" ""
[ -s "$HISTDIR/nodes_out_empty.tsv" ] && fail "trim_nodes_since: empty cutoff must produce empty output"

# record_history: полный цикл на реалистичных, разнесённых по времени прогонах
# (интервалы как у реального cron speedtest2 - раз в 3 часа), проверяет и
# ротацию runs.tsv, и синхронную обрезку history.tsv по новому cutoff.
RHDIR=$TEST_ROOT/record-history-work
mkdir -p "$RHDIR/opt/zash"
(
  DIR=$RHDIR/opt
  LAST=$DIR/speedtest_last.txt
  STATS_HTML=$DIR/zash/stats.html
  STATS_JSON=$DIR/zash/stats.json
  printf '<!doctype html>old' > "$STATS_HTML"   # остаток старой версии - должен исчезнуть
  STATS_HTTP_ENABLE=0
  RENDER_STATS=$ROOT/web/render_stats.awk
  HISTORY_RUNS=$DIR/speedtest_runs.tsv
  HISTORY_NODES=$DIR/speedtest_history.tsv
  HISTORY_KEEP_RUNS=3
  HISTORY_KEEP_DAYS=0
  WORK=$RHDIR/work
  mkdir -p "$WORK"
  RUN_LOG=$WORK/run.log
  LOCK_HELD=0

  NOW=$(date +%s)
  E1=$((NOW - 3 * 10800)); E2=$((NOW - 2 * 10800)); E3=$((NOW - 10800))
  printf '%s\tt1\t1000\t500\t10\t8\t8\t5\t2\n' "$E1" > "$HISTORY_RUNS"
  printf '%s\tt2\t1000\t500\t10\t8\t8\t5\t2\n' "$E2" >> "$HISTORY_RUNS"
  printf '%s\tt3\t1000\t500\t10\t8\t8\t5\t2\n' "$E3" >> "$HISTORY_RUNS"
  printf '%s\t900\toldnode1\n' "$E1" > "$HISTORY_NODES"
  printf '%s\t900\toldnode3\n' "$E2" >> "$HISTORY_NODES"
  printf '%s\t900\toldnode4\n' "$E3" >> "$HISTORY_NODES"

  printf '2000000 n0001\n' > "$WORK/win.txt"
  printf 'n0001\tFastNode\n' > "$WORK/map.txt"
  printf '%s\n' 'proxies:' '  - name: one' > "$LAST"

  record_history 6000000 1500000 30 20 15 10 1

  [ "$(wc -l < "$HISTORY_RUNS" | tr -d ' ')" = 3 ] || exit 81
  grep -q "^$E1" "$HISTORY_RUNS" && exit 82
  grep -q oldnode1 "$HISTORY_NODES" && exit 83
  grep -q FastNode "$HISTORY_NODES" || exit 84
  [ -f "$STATS_JSON" ] || exit 85
  grep -q '"node_history"' "$STATS_JSON" || exit 86
  if [ -e "$STATS_HTML" ]; then exit 87; fi
)
rh_rc=$?
case $rh_rc in
  0) ;;
  81) fail "record_history: rotation did not keep exactly 3 runs" ;;
  82) fail "record_history: oldest run was not dropped" ;;
  83) fail "record_history: node history was not trimmed to the new cutoff" ;;
  84) fail "record_history: new winner was not appended to node history" ;;
  85) fail "record_history: stats.json was not generated" ;;
  86) fail "record_history: stats.json has no node_history" ;;
  87) fail "render_stats: устаревший stats.html не удалён" ;;
  *) fail "record_history subshell failed unexpectedly (rc=$rh_rc)" ;;
esac

# запись без каталога zash/ (external-ui ещё не установлен) не должна падать,
# и оба нулевых порога ротации должны принудительно включить дефолт
NOZASHDIR=$TEST_ROOT/no-zash-work
mkdir -p "$NOZASHDIR/opt"
(
  DIR=$NOZASHDIR/opt
  LAST=$DIR/speedtest_last.txt
  STATS_HTML=$DIR/zash/stats.html
  STATS_JSON=$DIR/zash/stats.json
  STATS_HTTP_ENABLE=0
  RENDER_STATS=$ROOT/web/render_stats.awk
  HISTORY_RUNS=$DIR/speedtest_runs.tsv
  HISTORY_NODES=$DIR/speedtest_history.tsv
  HISTORY_KEEP_RUNS=0
  HISTORY_KEEP_DAYS=0
  WORK=$NOZASHDIR/work
  mkdir -p "$WORK"
  RUN_LOG=$WORK/run.log
  LOCK_HELD=0
  : > "$WORK/win.txt"
  : > "$WORK/map.txt"
  record_history 1000000 500000 5 4 3 2 0
  [ -f "$STATS_JSON" ] && exit 91
  [ -f "$HISTORY_RUNS" ] || exit 92
  grep -q "оба 0" "$WORK/run.log" || exit 93
)
nz_rc=$?
case $nz_rc in
  0) ;;
  91) fail "render_stats: wrote stats.json despite missing zash/ directory" ;;
  92) fail "record_history: runs.tsv must still be written even if stats.json cannot be" ;;
  93) fail "record_history: missing both-zero-limits warning was not logged" ;;
  *) fail "no-zash subshell failed unexpectedly (rc=$nz_rc)" ;;
esac

# --- порция 2 "независимая служба веб-интерфейса статистики" (см.
#     docs/superpowers/specs/2026-09-15-independent-stats-service-design.md):
#     обычный прогон (record_history() -> render_stats()) больше не должен
#     ни поднимать, ни готовить, ни проверять HTTP-бэкенд статистики - это
#     теперь отдельная забота stats_service.sh. STATS_HTTP_ENABLE=1 задан
#     нарочно (раньше это включало ensure_stats_httpd() на каждом прогоне) -
#     проверяем именно то, что render_stats() её больше не вызывает.
NOHTTPDIR=$TEST_ROOT/no-http-work
mkdir -p "$NOHTTPDIR/opt/stats_www"
(
  DIR=$NOHTTPDIR/opt
  LAST=$DIR/speedtest_last.txt
  STATS_HTML=$DIR/stats_www/stats.html
  STATS_JSON=$DIR/stats_www/stats.json
  STATS_HTTP_ENABLE=1
  STATS_HTTP_DIR=$DIR/stats_www
  STATS_HTTP_PIDFILE=$DIR/stats_httpd.pid
  STATS_HTTP_CONF=$DIR/stats_httpd.conf
  RENDER_STATS=$ROOT/web/render_stats.awk
  HISTORY_RUNS=$DIR/speedtest_runs.tsv
  HISTORY_NODES=$DIR/speedtest_history.tsv
  HISTORY_KEEP_RUNS=3
  HISTORY_KEEP_DAYS=0
  WORK=$NOHTTPDIR/work
  mkdir -p "$WORK"
  RUN_LOG=$WORK/run.log
  LOCK_HELD=0
  printf '2000000 n0001\n' > "$WORK/win.txt"
  printf 'n0001\tFastNode\n' > "$WORK/map.txt"
  printf '%s\n' 'proxies:' '  - name: one' > "$LAST"
  record_history 6000000 1500000 30 20 15 10 1
  [ -f "$STATS_JSON" ] || exit 94
  [ -f "$STATS_HTTP_PIDFILE" ] && exit 95
  [ -d "$STATS_HTTP_DIR/cgi-bin" ] && exit 96
  if grep -q "Веб-сервис статистики" "$WORK/run.log" 2>/dev/null; then
    exit 97
  fi
)
nh_rc=$?
case $nh_rc in
  0) ;;
  94) fail "порция 2: stats.json не сформирован обычным прогоном" ;;
  95) fail "порция 2: обычный прогон создал pid-файл HTTP-бэкенда - render_stats() всё ещё управляет процессом" ;;
  96) fail "порция 2: обычный прогон создал cgi-bin/ раздаваемого каталога - render_stats() всё ещё готовит docroot" ;;
  97) fail "порция 2: в логе обычного прогона есть сообщения ensure_stats_httpd() про веб-сервис статистики" ;;
  *) fail "no-http subshell failed unexpectedly (rc=$nh_rc)" ;;
esac

# --- update_node_stability: агрегат стабильности всех нод пула ---
NSDIR=$TEST_ROOT/node-stability-work
mkdir -p "$NSDIR/opt"
(
  DIR=$NSDIR/opt
  WORK=$NSDIR/work
  mkdir -p "$WORK"
  RUN_LOG=$WORK/run.log
  LOCK_HELD=0
  NODE_STATS_UPDATE=$ROOT/speedtest-runtime/node_stats_update.awk
  HISTORY_STABILITY=$DIR/node_stability.tsv
  STABILITY_WINDOW=200
  STABILITY_DROP_AFTER=2

  printf 'n0001\tFastNode\nn0002\tDeadNode\n' > "$WORK/map.txt"
  printf '120 n0001\n' > "$WORK/alive.txt"
  printf '5242880 n0001\n' > "$WORK/res.txt"   # FastNode прошла и speed-тест этого прогона

  update_node_stability
  [ -f "$HISTORY_STABILITY" ] || exit 71
  awk -F'\t' '$1=="FastNode"' "$HISTORY_STABILITY" | grep -q . || exit 72
  [ "$(awk -F'\t' '$1=="FastNode"{print $6}' "$HISTORY_STABILITY")" = "1" ] || exit 73
  [ "$(awk -F'\t' '$1=="DeadNode"{print $10}' "$HISTORY_STABILITY")" = "D" ] || exit 74
  [ "$(awk -F'\t' '$1=="FastNode"{print $11}' "$HISTORY_STABILITY")" = "5242880" ] || exit 78
  [ "$(awk -F'\t' '$1=="FastNode"{print $13}' "$HISTORY_STABILITY")" = "1" ] || exit 79

  # второй прогон: DeadNode пропала из пула целиком; FastNode снова жива по
  # delay-check, но до speed-теста в этом прогоне не дошли (res.txt пуст) -
  # копим скорость только когда есть реальный замер, счётчики не должны сдвинуться
  printf 'n0001\tFastNode\n' > "$WORK/map.txt"
  printf '110 n0001\n' > "$WORK/alive.txt"
  : > "$WORK/res.txt"
  update_node_stability
  [ "$(awk -F'\t' '$1=="DeadNode"{print $9}' "$HISTORY_STABILITY")" = "1" ] || exit 75
  [ "$(awk -F'\t' '$1=="FastNode"{print $11}' "$HISTORY_STABILITY")" = "5242880" ] || exit 80
  [ "$(awk -F'\t' '$1=="FastNode"{print $13}' "$HISTORY_STABILITY")" = "1" ] || exit 81

  # третий прогон: DeadNode всё ещё вне пула - при STABILITY_DROP_AFTER=2 удаляется
  update_node_stability
  awk -F'\t' '$1=="DeadNode"' "$HISTORY_STABILITY" | grep -q . && exit 76
  [ "$(awk -F'\t' '$1=="FastNode"{print $5}' "$HISTORY_STABILITY")" = "3" ] || exit 77
)
ns_rc=$?
case $ns_rc in
  0) ;;
  71) fail "update_node_stability: node_stability.tsv не записан" ;;
  72) fail "update_node_stability: строка FastNode отсутствует" ;;
  73) fail "update_node_stability: runs_alive у FastNode не увеличился" ;;
  74) fail "update_node_stability: окно DeadNode должно начинаться с D" ;;
  75) fail "update_node_stability: consec_absent у DeadNode не вырос после исчезновения из пула" ;;
  76) fail "update_node_stability: строка DeadNode должна быть удалена после STABILITY_DROP_AFTER прогонов отсутствия" ;;
  77) fail "update_node_stability: runs_seen у FastNode должен быть 3 после трёх прогонов" ;;
  78) fail "update_node_stability: last_speed у FastNode не записан из res.txt" ;;
  79) fail "update_node_stability: speed_samples у FastNode должен быть 1 после первого замера" ;;
  80) fail "update_node_stability: last_speed у FastNode не должен теряться без свежего замера" ;;
  81) fail "update_node_stability: speed_samples у FastNode не должен расти без свежего замера" ;;
  *) fail "update_node_stability subshell failed unexpectedly (rc=$ns_rc)" ;;
esac


# --- convert_source(): уже-YAML источник проходит без изменений, $BIN не вызывается ---
WORK=$TEST_ROOT/conv-passthrough
mkdir -p "$WORK"
RUN_LOG=$WORK/run.log
: > "$RUN_LOG"
SUB_CONVERT=$ROOT/speedtest-runtime/sub_convert.awk
BIN=/nonexistent-must-not-be-called
YAML_SRC=$TEST_ROOT/already.yaml
printf '%s\n' 'proxies:' '  - name: already' '    type: vless' > "$YAML_SRC"
out=$(convert_source "$YAML_SRC") || fail "convert_source: уже-YAML источник не должен отклоняться"
assert_eq "$out" "$YAML_SRC"

# --- convert_source(): база64 vless-подписка конвертируется и проходит валидацию ---
WORK=$TEST_ROOT/conv-vless-ok
mkdir -p "$WORK"
RUN_LOG=$WORK/run.log
: > "$RUN_LOG"
FAKE_BIN_OK=$TEST_ROOT/fake-bin-ok.sh
printf '%s\n' '#!/bin/sh' 'exit 0' > "$FAKE_BIN_OK"
chmod +x "$FAKE_BIN_OK"
BIN=$FAKE_BIN_OK
MIXED_PORT=7899
API=127.0.0.1:9099
SUB_SRC=$TEST_ROOT/durev-like.yaml
printf 'vless://aaaaaaaa-1111-4222-8333-bbbbbbbbbbbb@node1.example.com:8443?type=xhttp&security=reality&sni=sni1.example.net&pbk=TestPublicKey1AAAAAAAAAAAAAAAAAAAAAAAAAAAAA&sid=0123abcd&fp=chrome#Auto\n' | base64 > "$SUB_SRC"
out=$(convert_source "$SUB_SRC") || fail "convert_source: валидная vless-подписка должна пройти"
grep -q '^  - name: "Auto"' "$out" || fail "convert_source: сконвертированный файл не содержит ожидаемую ноду"

# --- convert_source(): база64 vless-подписка, не прошедшая $BIN -t, отклоняется целиком ---
WORK=$TEST_ROOT/conv-vless-fail
mkdir -p "$WORK"
RUN_LOG=$WORK/run.log
: > "$RUN_LOG"
FAKE_BIN_FAIL=$TEST_ROOT/fake-bin-fail.sh
printf '%s\n' '#!/bin/sh' 'echo "fatal: bad proxy config" >&2' 'exit 1' > "$FAKE_BIN_FAIL"
chmod +x "$FAKE_BIN_FAIL"
BIN=$FAKE_BIN_FAIL
if convert_source "$SUB_SRC"; then
  fail "convert_source: источник, не прошедший \$BIN -t, не должен быть принят"
fi
grep -q 'не прошёл проверку' "$RUN_LOG" || fail "convert_source: причина отказа не попала в RUN_LOG"

# --- convert_source(): мусор (не yaml и не base64-подписка) отклоняется ---
WORK=$TEST_ROOT/conv-junk
mkdir -p "$WORK"
RUN_LOG=$WORK/run.log
: > "$RUN_LOG"
BIN=/nonexistent-must-not-be-called
JUNK_SRC=$TEST_ROOT/junk.yaml
printf 'not really anything useful\n' > "$JUNK_SRC"
if convert_source "$JUNK_SRC"; then
  fail "convert_source: мусорный источник не должен быть принят"
fi

# --- prepare_nodes(): полный путь с одним clash-yaml и одним base64-vless источником ---
WORK=$TEST_ROOT/prepare-mixed
mkdir -p "$WORK/nodes"
RUN_LOG=$WORK/run.log
: > "$RUN_LOG"
PREP=$ROOT/speedtest-runtime/prep.awk
BLOCK=''
EXTYPE='trojan|ss'
SOURCES="$YAML_SRC $SUB_SRC"
BIN=$FAKE_BIN_OK
prepare_nodes || fail "prepare_nodes: не должен падать на смеси yaml+base64-источников"
assert_eq "$(cat "$WORK/cnt.txt")" 2
grep -q 'already' "$WORK/map.txt" || fail "prepare_nodes: нода из yaml-источника потерялась"
grep -q 'Auto' "$WORK/map.txt" || fail "prepare_nodes: нода из base64-источника не попала в пул"

# --- prepare_nodes(): все источники отклонены -> 0 нод, без зависания на чтении stdin ---
WORK=$TEST_ROOT/prepare-allrejected
mkdir -p "$WORK/nodes"
RUN_LOG=$WORK/run.log
: > "$RUN_LOG"
BIN=/nonexistent-must-not-be-called
SOURCES="$JUNK_SRC"
prepare_nodes || fail "prepare_nodes: не должен возвращать ошибку, если источники просто пусты"
assert_eq "$(cat "$WORK/cnt.txt")" 0

# --- write_progress(): прогресс скоростного теста по нодам текущего
#     прогона (шаг 1 задачи "видно по нодам при прогоне") - render_progress.awk
#     сам проверен отдельно в test_render_progress.sh, здесь - только
#     обвязка в speedtest2.sh (сборка awk-вызова из глобалей + publish_file,
#     создание каталога, WARN-путь при отсутствующем RENDER_PROGRESS).
WORK=$TEST_ROOT/progress-work
mkdir -p "$WORK"
RUN_LOG=$WORK/run.log
: > "$RUN_LOG"
RENDER_PROGRESS=$ROOT/web/render_progress.awk
STATS_PROGRESS=$WORK/out/stats_www/progress.json
PROGRESS_TOTAL=3
PROGRESS_STARTED_ISO="2026-09-14 09:00:00"

: > "$WORK/progress.tsv"
write_progress 1
[ -f "$STATS_PROGRESS" ] || fail "write_progress: progress.json не создан (в т.ч. каталог не создался)"
grep -q '"running":true' "$STATS_PROGRESS" || fail "write_progress: running:true не записан для ещё идущего цикла"
grep -q '"total":3' "$STATS_PROGRESS" || fail "write_progress: total не подхвачен из PROGRESS_TOTAL"
grep -q '"tested":0' "$STATS_PROGRESS" || fail "write_progress: tested должен быть 0 - ни одна нода ещё не дописана"

printf 'nodeA\t1048576\tok\n' >> "$WORK/progress.tsv"
write_progress 1
grep -q '"tested":1' "$STATS_PROGRESS" || fail "write_progress: tested не обновился после новой строки в progress.tsv"
grep -q 'nodeA' "$STATS_PROGRESS" || fail "write_progress: имя ноды потерялось"

write_progress 0
grep -q '"running":false' "$STATS_PROGRESS" || fail "write_progress: финальный вызов не выставил running:false"
grep -q 'nodeA' "$STATS_PROGRESS" || fail "write_progress: финальный вызов потерял уже накопленные результаты"

# --- write_progress(): отсутствующий RENDER_PROGRESS - WARN в лог, без
#     падения (set -eu в этом тестовом файле - если бы write_progress
#     возвращала ненулевой код, тест сам упал бы здесь) и без создания
#     STATS_PROGRESS ---
WORK=$TEST_ROOT/progress-missing-render
mkdir -p "$WORK"
RUN_LOG=$WORK/run.log
: > "$RUN_LOG"
RENDER_PROGRESS=$WORK/does-not-exist.awk
STATS_PROGRESS=$WORK/out/stats_www/progress.json
PROGRESS_TOTAL=1
PROGRESS_STARTED_ISO="2026-09-14 09:00:00"
: > "$WORK/progress.tsv"
write_progress 1
[ -f "$STATS_PROGRESS" ] && fail "write_progress: не должен был создать progress.json без render_progress.awk"
grep -q 'WARN' "$RUN_LOG" || fail "write_progress: отсутствие RENDER_PROGRESS должно было залогировать WARN"

# --- zash_ui_dir()/cleanup_old_zash_stats(): уборка старого stats.html из
#     каталога external-ui, оставшегося от прежней схемы (см. TODO.md -
#     "убрать старую страницу статистики из встроенного веб-UI mihomo") ---

ZASHDIR=$TEST_ROOT/zash-cleanup-work
mkdir -p "$ZASHDIR/opt"
(
  DIR=$ZASHDIR/opt
  WORK=$ZASHDIR/work
  mkdir -p "$WORK"
  RUN_LOG=$WORK/run.log
  : > "$RUN_LOG"
  FORCE=0

  # относительный путь без кавычек - как в config.example.yaml
  SOURCES=$DIR/config.yaml
  printf 'external-controller: 0.0.0.0:9090\nexternal-ui: ./zash\n' > "$SOURCES"
  got=$(zash_ui_dir)
  [ "$got" = "$DIR/zash" ] || exit 71

  # значение в кавычках
  printf 'external-ui: "./zash2"\n' > "$SOURCES"
  got=$(zash_ui_dir)
  [ "$got" = "$DIR/zash2" ] || exit 72

  # абсолютный путь остаётся как есть
  printf 'external-ui: /opt/etc/mihomo/zash3\n' > "$SOURCES"
  got=$(zash_ui_dir)
  [ "$got" = "/opt/etc/mihomo/zash3" ] || exit 73

  # config.yaml отсутствует - пусто, без падения (set -eu в этом файле -
  # если бы функция вернула ненулевой код без вывода не через return 0,
  # тест упал бы здесь сам)
  rm -f "$SOURCES"
  got=$(zash_ui_dir)
  [ -z "$got" ] || exit 74

  exit 0
)
zud_rc=$?
case $zud_rc in
  0) ;;
  71) fail "zash_ui_dir: не разобран относительный путь ./zash" ;;
  72) fail "zash_ui_dir: не срезаны кавычки вокруг пути" ;;
  73) fail "zash_ui_dir: испорчен абсолютный путь" ;;
  74) fail "zash_ui_dir: должен быть пустым без config.yaml" ;;
  *) fail "zash_ui_dir subshell failed unexpectedly (rc=$zud_rc)" ;;
esac

(
  DIR=$ZASHDIR/opt2
  WORK=$ZASHDIR/work2
  mkdir -p "$WORK" "$DIR/zash"
  RUN_LOG=$WORK/run.log
  : > "$RUN_LOG"
  FORCE=0
  SOURCES=$DIR/config.yaml
  printf 'external-ui: ./zash\n' > "$SOURCES"

  # свой файл (с подписью render_stats.awk) - удаляется, в лог пишется OK
  printf '<!doctype html><title>speedtest2 - статистика</title>' > "$DIR/zash/stats.html"
  cleanup_old_zash_stats
  [ -f "$DIR/zash/stats.html" ] && exit 81
  grep -q 'OK:.*stats.html' "$RUN_LOG" || exit 82

  # чужой файл с тем же именем, но без нашей подписи - не трогаем
  printf '<!doctype html><title>zashboard</title>' > "$DIR/zash/stats.html"
  cleanup_old_zash_stats
  [ -f "$DIR/zash/stats.html" ] || exit 83

  # каталога external-ui вообще нет - не падаем (set -eu)
  rm -rf "$DIR/zash"
  cleanup_old_zash_stats

  exit 0
)
cz_rc=$?
case $cz_rc in
  0) ;;
  81) fail "cleanup_old_zash_stats: не убрал старый stats.html со своей подписью" ;;
  82) fail "cleanup_old_zash_stats: не залогировал OK об удалении" ;;
  83) fail "cleanup_old_zash_stats: удалил чужой файл без нашей подписи" ;;
  *) fail "cleanup_old_zash_stats subshell failed unexpectedly (rc=$cz_rc)" ;;
esac

echo "test_speedtest2: OK"
