#!/bin/sh
# /api/system - состояние системы для футера веб-интерфейса (версия релиза,
# аптайм, CPU, память, работает ли mihomo). Считается в stats_httpd.py
# (system_status()) по подставному каталогу /proc и манифесту.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
command -v python3 >/dev/null 2>&1 || { echo "test_stats_system.sh: OK (python3 нет, пропущено)"; exit 0; }

python3 - "$ROOT/web" <<'PY'
import importlib.util, os, sys, tempfile

web = sys.argv[1]
sys.path.insert(0, web)
spec = importlib.util.spec_from_file_location("stats_httpd", os.path.join(web, "stats_httpd.py"))
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

def fail(msg):
    print("FAIL: " + msg, file=sys.stderr)
    sys.exit(1)

def write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(text)

tmp = tempfile.mkdtemp()
proc = os.path.join(tmp, "proc")
manifest = os.path.join(tmp, "installed-manifest.txt")
write(manifest, "FORMAT_VERSION=2\nRELEASE_VERSION=9\n")
write(os.path.join(proc, "uptime"), "1234.5 111.1\n")
write(os.path.join(proc, "meminfo"),
      "MemTotal:        100000 kB\nMemFree:           50000 kB\nMemAvailable:      62000 kB\n")
write(os.path.join(proc, "stat"), "cpu  100 0 0 800 0 0 0 0 0 0\ncpu0 1 2 3 4\n")
write(os.path.join(proc, "1", "comm"), "init\n")
write(os.path.join(proc, "42", "comm"), "mihomo\n")

def second_sample(_delay):
    write(os.path.join(proc, "stat"), "cpu  112 0 0 888 0 0 0 0 0 0\n")

st = mod.system_status(proc=proc, manifest=manifest, cpu_delay=0, sleep=second_sample)
expected = {"release_version": "9", "uptime_seconds": 1234, "cpu_percent": 12,
            "mem_percent": 38, "mihomo_active": True}
if st != expected:
    fail("system_status: %r != %r" % (st, expected))

# RELEASE_TAG важнее RELEASE_VERSION, ведущая "v" срезается
write(manifest, "RELEASE_VERSION=9\nRELEASE_TAG=v26.10.2\n")
if mod.system_status(proc=proc, manifest=manifest, cpu_delay=0, sleep=lambda d: None)["release_version"] != "26.10.2":
    fail("версия релиза из RELEASE_TAG")

# mihomo не запущен; нет манифеста; без MemAvailable берётся MemFree
os.remove(os.path.join(proc, "42", "comm"))
write(os.path.join(proc, "meminfo"), "MemTotal: 100000 kB\nMemFree: 50000 kB\n")
st = mod.system_status(proc=proc, manifest=os.path.join(tmp, "nope"), cpu_delay=0, sleep=lambda d: None)
if st["mihomo_active"] is not False: fail("mihomo не работает: %r" % st)
if st["release_version"] is not None: fail("без манифеста версия должна быть null: %r" % st)
if st["mem_percent"] != 50: fail("память по MemFree: %r" % st)
if st["cpu_percent"] != 0: fail("CPU без изменения счётчиков должен быть 0: %r" % st)

# /proc недоступен - всё неизвестно, без исключений
st = mod.system_status(proc=os.path.join(tmp, "no-proc"), manifest=manifest, cpu_delay=0, sleep=lambda d: None)
for k in ("uptime_seconds", "cpu_percent", "mem_percent", "mihomo_active"):
    if st[k] is not None:
        fail("без /proc %s должен быть null: %r" % (k, st))
PY

# --- HTTP: маршрут, метод, защита сессией ---
TMP=$(mktemp -d)
PID=
trap '[ -z "$PID" ] || kill "$PID" 2>/dev/null; rm -rf "$TMP"' EXIT INT TERM
fail() { echo "FAIL: $*" >&2; exit 1; }
mkdir -p "$TMP/www" "$TMP/proc"
printf '1.0 1.0\n' > "$TMP/proc/uptime"
export STATS_AUTH_STATE_DIR=$TMP/as STATS_AUTH_RUNTIME_DIR=$TMP/ar
SID=$(python3 - "$ROOT/web" <<'PY'
import os, sys
sys.path.insert(0, sys.argv[1]); import stats_auth as m
m.write_credentials(os.environ["STATS_AUTH_STATE_DIR"], "u", "p", iterations=m.PBKDF2_MIN_ITERATIONS)
print(m.create_session(os.environ["STATS_AUTH_RUNTIME_DIR"], "u")["id"])
PY
)
PORT=$((31000 + ($$ % 3000)))
STATS_PROC_DIR=$TMP/proc CPU_SAMPLE_DELAY=0 INSTALLED_MANIFEST_PATH=$TMP/none \
  python3 "$ROOT/web/stats_httpd.py" -f -p "127.0.0.1:$PORT" -h "$TMP/www" >"$TMP/log" 2>&1 &
PID=$!
i=0
until curl -s -o /dev/null "http://127.0.0.1:$PORT/" 2>/dev/null; do
  i=$((i + 1)); [ $i -lt 50 ] || fail "сервер не поднялся"; sleep 0.1
done
OUT=$(curl -s -H "Cookie: mst_session=$SID" "http://127.0.0.1:$PORT/api/system")
case $OUT in *'"uptime_seconds": 1'*) ;; *) fail "/api/system: $OUT" ;; esac
code=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/api/system")
[ "$code" = 401 ] || fail "/api/system без сессии: $code"
code=$(curl -s -o /dev/null -w '%{http_code}' -H "Cookie: mst_session=$SID" -X POST "http://127.0.0.1:$PORT/api/system")
[ "$code" = 403 ] || [ "$code" = 405 ] || fail "POST /api/system: $code"

echo "test_stats_system.sh: OK"
