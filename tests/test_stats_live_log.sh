#!/bin/sh
# Живой журнал вкладки «Журнал»: say() в speedtest2.sh пишет копию строк
# только при наличии маркера зрителя, stats_httpd.py (/api/log) отдаёт их
# по смещению, обрезает по размеру и подчищает всё после ухода зрителя.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
SPEEDTEST=$ROOT/speedtest-runtime/speedtest2.sh
HTTPD=$ROOT/web/stats_httpd.py
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/stats-live-log-test.XXXXXX")
SERVER_PID=""
cleanup_test() {
  [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null || true
  rm -rf "$TEST_ROOT"
}
trap cleanup_test EXIT INT TERM

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

command -v python3 >/dev/null 2>&1 || {
  echo "test_stats_live_log.sh: OK (python3 недоступен, пропущено)"
  exit 0
}

LIVE=$TEST_ROOT/live
TMPROOT=$TEST_ROOT/tmp
mkdir -p "$TMPROOT"
export TMPROOT

# --- Часть 1: say() и маркер зрителя ---
(
  LIVE_LOG_DIR=$LIVE
  MST_LIB_ONLY=1 . "$SPEEDTEST"
  WORK=$TEST_ROOT/work
  RUN_LOG=$WORK/run.log
  LOG=$TEST_ROOT/history.log
  mkdir -p "$WORK"
  FORCE=0
  say "без зрителя"
  [ ! -e "$LIVE" ] || exit 11          # без маркера say() каталог не создаёт
  mkdir -p "$LIVE"
  : > "$LIVE/viewer"
  say "со зрителем"
  LOG_TAG=service
  say "от службы"
  grep -q "\[speedtest\] со зрителем" "$LIVE/live.log" || exit 12
  grep -q "\[service\] от службы" "$LIVE/live.log" || exit 13
  grep -q "без зрителя" "$LIVE/live.log" && exit 14
  grep -q "со зрителем" "$RUN_LOG" || exit 15   # обычный журнал прогона не пострадал
  rm -rf "$LIVE"
) || fail "часть 1: say() и живой журнал (код $?)"
echo "test_stats_live_log.sh: часть 1 (say) OK" >&2

# --- Часть 2: live_log_poll()/live_log_cleanup() напрямую ---
mkdir -p "$TMPROOT/mst.4242"
printf '10:00:00 идёт прогон\n' > "$TMPROOT/mst.4242/speedtest.log"
printf '09:00:00 старый прогон\n' > "$TEST_ROOT/history.log"

LIVE_LOG_DIR=$LIVE LOG=$TEST_ROOT/history.log python3 - "$HTTPD" <<'PY' || fail "часть 2: live_log_poll/cleanup"
import importlib.util, os, sys, time
script = sys.argv[1]
sys.path.insert(0, os.path.dirname(script))
spec = importlib.util.spec_from_file_location("stats_httpd_under_test", script)
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
d = os.environ["LIVE_LOG_DIR"]

def check(cond, msg):
    if not cond:
        print("часть 2:", msg, file=sys.stderr); sys.exit(1)

r = m.live_log_poll("", 0)
check(r["reset"], "первый опрос должен быть reset")
check("старый прогон" in r["seed"] and "идёт прогон" in r["seed"], "затравка без истории/идущего прогона: %r" % r["seed"])
check(os.path.exists(os.path.join(d, "viewer")), "нет маркера зрителя")
gen, off = r["gen"], r["offset"]

log = os.path.join(d, "live.log")
with open(log, "ab") as f:
    f.write("12:00:00 [speedtest] строка <b>1</b>\n12:00:01 [speedtest] недопис".encode())
r = m.live_log_poll(gen, off)
check(not r["reset"] and r["gen"] == gen, "без изменений поколение сохраняется")
check(r["text"] == "12:00:00 [speedtest] строка <b>1</b>\n", "отдаются только целые строки: %r" % r["text"])
off = r["offset"]
with open(log, "ab") as f:
    f.write(b"\n")
r = m.live_log_poll(gen, off)
check(r["text"].endswith("недопис\n"), "дописанная строка не пришла")
off = r["offset"]

r2 = m.live_log_poll("чужое", 5)
check(r2["reset"] and "seed" in r2 and "строка" in r2["text"], "переподключение должно вернуть затравку и весь журнал")
r3 = m.live_log_poll(gen, 10 ** 9)
check(r3["reset"], "смещение за концом файла - reset")

# обрезка по размеру: ничего не теряется, поколение меняется
with open(log, "ab") as f:
    for i in range(200):
        f.write(("12:01:%02d [speedtest] длинная строка номер %d\n" % (i % 60, i)).encode())
r = m.live_log_poll(gen, off, limit=2048)
check(r["reset"] and r["gen"] != gen, "после обрезки должно смениться поколение")
check("обрезаны" in r["seed"] and "номер 199" in r["seed"], "хвост обрезанного журнала должен стать затравкой")
check(os.path.getsize(os.path.join(d, "seed")) <= 2048, "затравка после обрезки больше лимита")
check(not os.path.exists(log) or os.path.getsize(log) == 0, "после обрезки live.log должен начаться заново")

# чтение большими порциями: more
with open(log, "ab") as f:
    f.write(b"x" * 100 + b"\n" + b"y" * 100 + b"\n")
r4 = m.live_log_poll(r["gen"], 0, read_max=150)
check(r4["more"] and r4["text"] == "x" * 100 + "\n", "порционное чтение: %r" % r4)

# уборка: свежий маркер не трогаем, протухший - удаляем всё
check(m.live_log_cleanup(idle=30) is False, "свежий зритель не должен удаляться")
check(os.path.exists(log), "live.log удалён при живом зрителе")
old = time.time() - 100
os.utime(os.path.join(d, "viewer"), (old, old))
check(m.live_log_cleanup(idle=30) is True, "протухший зритель должен удаляться")
left = sorted(f for f in os.listdir(d) if f != "lock")
check(left == [], "после уборки остались файлы: %r" % left)
# шальной live.log без маркера тоже подчищается
open(log, "w").write("x\n")
m.live_log_cleanup(idle=30)
check(not os.path.exists(log), "live.log без маркера не удалён")
PY
echo "test_stats_live_log.sh: часть 2 (poll/cleanup) OK" >&2

# --- Часть 3: HTTP /api/log за авторизацией ---
command -v curl >/dev/null 2>&1 || { echo "test_stats_live_log.sh: OK (без curl часть 3 пропущена)"; exit 0; }
STATS_AUTH_STATE_DIR=$TEST_ROOT/auth-state
STATS_AUTH_RUNTIME_DIR=$TEST_ROOT/auth-runtime
export STATS_AUTH_STATE_DIR STATS_AUTH_RUNTIME_DIR
AUTH_VALUES=$(python3 - "$ROOT/web/stats_auth.py" "$STATS_AUTH_STATE_DIR" "$STATS_AUTH_RUNTIME_DIR" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("stats_auth", sys.argv[1])
mod = importlib.util.module_from_spec(spec); spec.loader.exec_module(mod)
mod.write_credentials(sys.argv[2], "tester", "secret", iterations=mod.PBKDF2_MIN_ITERATIONS)
print(mod.create_session(sys.argv[3], "tester")["id"])
PY
)
COOKIE="mst_session=$AUTH_VALUES"
WWW=$TEST_ROOT/www
mkdir -p "$WWW"
PORT=$((31000 + ($$ % 3000)))
LIVE_LOG_DIR=$LIVE LIVE_LOG_IDLE=1 python3 "$HTTPD" -f -p "127.0.0.1:$PORT" -h "$WWW" >"$TEST_ROOT/server.log" 2>&1 &
SERVER_PID=$!
i=0
until curl -s -m 1 -o /dev/null "http://127.0.0.1:$PORT/" 2>/dev/null; do
  i=$((i + 1)); [ $i -lt 40 ] || fail "часть 3: сервер не поднялся"; sleep 0.2
done

code=$(curl -s -m 3 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/api/log")
[ "$code" = 401 ] || fail "часть 3: /api/log без сессии должен отвечать 401, получено $code"
[ ! -e "$LIVE/viewer" ] || fail "часть 3: неавторизованный запрос создал маркер зрителя"

body=$(curl -s -m 3 -H "Cookie: $COOKIE" "http://127.0.0.1:$PORT/api/log?gen=&offset=0")
case $body in *'"reset": true'*'"gen"'*|*'"gen"'*'"reset": true'*) ;; *) fail "часть 3: неожиданный ответ $body" ;; esac
[ -f "$LIVE/viewer" ] || fail "часть 3: опрос не создал маркер зрителя"

code=$(curl -s -m 3 -o /dev/null -w '%{http_code}' -X POST -H "Cookie: $COOKIE" "http://127.0.0.1:$PORT/api/log")
[ "$code" != 200 ] || fail "часть 3: POST /api/log не должен приниматься"

# Страницу «закрыли»: родитель сервера сам прекращает сбор (проверка раз в 5 с)
i=0
while [ -e "$LIVE/viewer" ]; do
  i=$((i + 1)); [ $i -lt 40 ] || fail "часть 3: после ухода зрителя маркер не удалён"; sleep 0.25
done
[ ! -e "$LIVE/live.log" ] && [ ! -e "$LIVE/seed" ] || fail "часть 3: после ухода зрителя остались файлы журнала"

echo "test_stats_live_log.sh: OK"
