#!/bin/sh
# Сквозной интеграционный тест раздела "Обновления" (порция 5, задача 8):
# реальный stats_httpd.py (как tests/test_stats_httpd_py.sh) поверх
# временной установки со всем движком обновлений (update.sh +
# update_plan.awk + update_prepare.sh + update_transaction.sh +
# stats_update.sh) и фейковым релизным httpd (та же раскладка, что блок
# SRV2/W2 в tests/test_stats_update.sh) - полный цикл через HTTP: сессия
# -> GET /api/updates/status (пусто) -> POST /api/updates/check ->
# POST /api/updates/prepare -> дождаться job.state=done ->
# POST /api/updates/apply -> дождаться job.state=done ->
# GET /api/updates/status показывает result.status=applied.
#
# Часть 2 - отдельно: cron-строка ежедневной проверки после install.sh
# (crontab -l фикстура, как в tests/test_install.sh) в этой же временной
# установке.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/managed-updates-integration-test.XXXXXX")

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
  exit 1
}
assert_contains() {
  case "$2" in *"$1"*) ;; *) fail "expected: $1 (context: $3)";; esac
}

command -v python3 >/dev/null 2>&1 || {
  echo "test_managed_updates_integration.sh: python3 недоступен, пропущено" >&2
  echo "test_managed_updates_integration.sh: OK (пропущено)"
  exit 0
}
command -v busybox >/dev/null 2>&1 || {
  echo "test_managed_updates_integration.sh: busybox недоступен, пропущено" >&2
  echo "test_managed_updates_integration.sh: OK (пропущено)"
  exit 0
}

BASE_PORT=$((29500 + ($$ % 1500)))

# =========================================================================
# Часть 1: полный веб-цикл check -> prepare -> apply через реальный HTTP
# =========================================================================

# --- фейковый релизный httpd (та же раскладка, что SRV2 в
#     tests/test_stats_update.sh - pinned_base() в update.sh требует,
#     чтобы UPDATE_RELEASE_BASE буквально оканчивался на
#     ".../releases/latest/download") ---
SRV=$TEST_ROOT/srv
RELDIR=$SRV/releases/download/v9
mkdir -p "$SRV/releases/latest/download" "$RELDIR"
for eng in update.sh update_plan.awk update_prepare.sh update_transaction.sh; do
  cp "$ROOT/updater/$eng" "$RELDIR/$eng"
done
printf '#!/bin/sh\necho ok\n' > "$RELDIR/marker.rel"

gen_manifest_row() {
  # $1 component-id, $2 имя файла (относительно RELDIR), $3 dest, $4 mode, $5 check
  f=$RELDIR/$2
  sz=$(wc -c < "$f" | tr -d ' ')
  sum=$(sha256sum "$f" | cut -d' ' -f1)
  printf 'FILE|%s|%s|%s|%s|%s|%s|%s\n' "$1" "$2" "$3" "$sz" "$sum" "$4" "$5"
}
{
  printf 'FORMAT_VERSION=2\nRELEASE_VERSION=9\nMIN_UPDATER_VERSION=1\nCONFIG_SCHEMA_VERSION=1\nRELEASE_TAG=v9\n'
  printf 'COMPONENT|updater|Обновлятор\nCOMPONENT|speedtest-runtime|Ядро\n'
  printf 'NOTE|updater|заметка\nNOTE|speedtest-runtime|заметка\n'
  gen_manifest_row updater update.sh /opt/etc/mihomo-speedtest/update.sh 0755 sh
  gen_manifest_row updater update_plan.awk /opt/etc/mihomo-speedtest/update_plan.awk 0644 awk
  gen_manifest_row updater update_prepare.sh /opt/etc/mihomo-speedtest/update_prepare.sh 0755 sh
  gen_manifest_row updater update_transaction.sh /opt/etc/mihomo-speedtest/update_transaction.sh 0755 sh
  gen_manifest_row speedtest-runtime marker.rel /opt/etc/mihomo-speedtest/marker.rel 0644 none
} > "$SRV/releases/latest/download/manifest.txt"

PORT_REL=$BASE_PORT
busybox httpd -f -p "127.0.0.1:$PORT_REL" -h "$SRV" >/dev/null 2>&1 &
REL_PID=$!
CLEANUP_PIDS="$CLEANUP_PIDS $REL_PID"
i=0
while [ $i -lt 30 ]; do
  curl -s -m 1 -o /dev/null "http://127.0.0.1:$PORT_REL/releases/latest/download/manifest.txt" && break
  sleep 0.2; i=$((i + 1))
done

# --- "установленная" копия движка обновлений (DIR для stats_update.sh,
#     она же источник cgi-bin/update) ---
W=$TEST_ROOT/install
mkdir -p "$W"
cp "$ROOT"/install.sh "$ROOT"/uninstall.sh "$ROOT"/*/*.sh "$ROOT"/*/*.awk "$W/" 2>/dev/null || true
chmod +x "$W"/*.sh

WWW=$TEST_ROOT/www
mkdir -p "$WWW/cgi-bin"
printf '<html>spa-shell</html>' > "$WWW/index.html"
cp "$W/stats_update.sh" "$WWW/cgi-bin/update"
chmod +x "$WWW/cgi-bin/update"

STATE=$TEST_ROOT/state
TARGET=$TEST_ROOT/target
RUNDIR=$TEST_ROOT/runtime
TMPR=$TEST_ROOT/tmp
mkdir -p "$STATE" "$TARGET" "$RUNDIR" "$TMPR"

# --- сессия (та же схема, что tests/test_stats_httpd_py.sh - stats_auth.py
#     напрямую создаёт учётку и сессию, минуя саму форму /login) ---
STATS_AUTH_STATE_DIR=$TEST_ROOT/auth-state
STATS_AUTH_RUNTIME_DIR=$TEST_ROOT/auth-runtime
export STATS_AUTH_STATE_DIR STATS_AUTH_RUNTIME_DIR
AUTH_VALUES=$(python3 - "$ROOT/web/stats_auth.py" "$STATS_AUTH_STATE_DIR" "$STATS_AUTH_RUNTIME_DIR" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("stats_auth", sys.argv[1])
mod = importlib.util.module_from_spec(spec); spec.loader.exec_module(mod)
mod.write_credentials(sys.argv[2], "tester", "secret", iterations=mod.PBKDF2_MIN_ITERATIONS)
session = mod.create_session(sys.argv[3], "tester")
print(session["id"])
print(session["csrf"])
PY
)
AUTH_COOKIE="mst_session=$(printf '%s\n' "$AUTH_VALUES" | sed -n '1p')"
AUTH_CSRF=$(printf '%s\n' "$AUTH_VALUES" | sed -n '2p')

curl() {
  command curl -H "Cookie: $AUTH_COOKIE" -H "X-CSRF-Token: $AUTH_CSRF" "$@"
}

wait_up() {
  port=$1
  i=0
  while [ $i -lt 40 ]; do
    code=$(curl -s -m 1 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$port/" 2>/dev/null)
    [ "$code" != "000" ] && return 0
    sleep 0.2; i=$((i + 1))
  done
  return 1
}

PORT_WEB=$((PORT_REL + 1))
DIR=$W \
TMPROOT=$TMPR \
UPDATE_SCRIPT=$W/update.sh \
UPDATE_RELEASE_BASE="http://127.0.0.1:$PORT_REL/releases/latest/download" \
UPDATE_STATE_DIR=$STATE \
UPDATE_TARGET_ROOT=$TARGET \
STATS_UPDATE_RUNTIME_DIR=$RUNDIR \
python3 "$ROOT/web/stats_httpd.py" -f -p "127.0.0.1:$PORT_WEB" -h "$WWW" >"$TEST_ROOT/httpd.log" 2>&1 &
WEB_PID=$!
CLEANUP_PIDS="$CLEANUP_PIDS $WEB_PID"
wait_up "$PORT_WEB" || fail "stats_httpd.py не поднялся"

# --- GET /api/updates/status: ничего ещё не запускалось (свежий /tmp) ---
OUT_STATUS0=$(curl -s -m 2 "http://127.0.0.1:$PORT_WEB/api/updates/status")
assert_contains '"last_check":null' "$OUT_STATUS0" "status до check: last_check"
assert_contains '"job":null' "$OUT_STATUS0" "status до check: job"

# --- POST /api/updates/check (синхронно внутри CGI-запроса, ruling п.1) ---
OUT_CHECK=$(curl -s -m 10 -X POST "http://127.0.0.1:$PORT_WEB/api/updates/check")
assert_contains '"ok":true' "$OUT_CHECK" "check: ok=true"
assert_contains '"release_version":"9"' "$OUT_CHECK" "check: план содержит релиз"

# --- POST /api/updates/prepare (фоновый воркер, ruling п.3) ---
OUT_PREPARE=$(curl -s -m 5 -X POST "http://127.0.0.1:$PORT_WEB/api/updates/prepare")
assert_contains '"started":true' "$OUT_PREPARE" "prepare: фон запущен"

OUT_STATUS_P=""
i=0
while [ $i -lt 150 ]; do
  OUT_STATUS_P=$(curl -s -m 2 "http://127.0.0.1:$PORT_WEB/api/updates/status")
  if printf '%s' "$OUT_STATUS_P" | grep -q '"action":"prepare"' \
    && printf '%s' "$OUT_STATUS_P" | grep -q '"state":"error"'; then
    fail "prepare завершился ошибкой: $OUT_STATUS_P"
  fi
  if printf '%s' "$OUT_STATUS_P" | grep -q '"action":"prepare"' \
    && printf '%s' "$OUT_STATUS_P" | grep -q '"state":"done"'; then
    break
  fi
  sleep 0.1; i=$((i + 1))
done
[ $i -lt 150 ] || fail "prepare не завершился за 15с (последний status: $OUT_STATUS_P)"
assert_contains '"prepared":true' "$OUT_STATUS_P" "prepare: план подготовлен"
PLAN_ID=$(printf '%s' "$OUT_STATUS_P" | sed -n 's/.*"plan_id":"\([0-9a-f]\{64\}\)".*/\1/p' | head -1)
[ -n "$PLAN_ID" ] || fail "prepare: plan_id не найден в status ($OUT_STATUS_P)"

# --- POST /api/updates/apply (фоновый воркер, ruling п.4) ---
OUT_APPLY=$(curl -s -m 5 -X POST --data "plan_id=$PLAN_ID" "http://127.0.0.1:$PORT_WEB/api/updates/apply")
assert_contains '"started":true' "$OUT_APPLY" "apply: фон запущен"

OUT_STATUS_A=""
i=0
while [ $i -lt 150 ]; do
  OUT_STATUS_A=$(curl -s -m 2 "http://127.0.0.1:$PORT_WEB/api/updates/status")
  if printf '%s' "$OUT_STATUS_A" | grep -q '"action":"apply"' \
    && printf '%s' "$OUT_STATUS_A" | grep -q '"state":"error"'; then
    fail "apply завершился ошибкой: $OUT_STATUS_A"
  fi
  if printf '%s' "$OUT_STATUS_A" | grep -q '"action":"apply"' \
    && printf '%s' "$OUT_STATUS_A" | grep -q '"state":"done"'; then
    break
  fi
  sleep 0.1; i=$((i + 1))
done
[ $i -lt 150 ] || fail "apply не завершился за 15с (последний status: $OUT_STATUS_A)"

# --- GET /api/updates/status: применённый план виден как result.status ---
assert_contains '"status":"applied"' "$OUT_STATUS_A" "status после apply: result.status=applied"
[ -f "$TARGET/opt/etc/mihomo-speedtest/marker.rel" ] || fail "apply не опубликовал файл релиза в целевой каталог"

# --- Review Focus: успешный apply не должен трогать last-check.json,
#     бейдж/список обновляются только следующим check ---
[ -f "$RUNDIR/last-check.json" ] || fail "last-check.json пропал после apply (должен остаться от предыдущего check)"
grep -q '"source":"button"' "$RUNDIR/last-check.json" || fail "apply подменил last-check.json"

echo "test_managed_updates_integration.sh: часть 1 (веб-цикл check->prepare->apply по HTTP) OK" >&2

kill "$REL_PID" 2>/dev/null || true
kill "$WEB_PID" 2>/dev/null || true

# =========================================================================
# Часть 2: cron-строка ежедневной проверки после install.sh (crontab -l
# фикстура, как в tests/test_install.sh) в этой же временной установке ($W)
# =========================================================================
CRON_STORE=$TEST_ROOT/crontab.txt
: > "$CRON_STORE"
CRONBIN=$TEST_ROOT/cronbin
mkdir -p "$CRONBIN"
cat > "$CRONBIN/crontab" <<EOF
#!/bin/sh
if [ "\$1" = "-l" ]; then cat "$CRON_STORE" 2>/dev/null; exit 0; fi
if [ "\$1" = "-" ]; then cat > "$CRON_STORE"; exit 0; fi
exit 1
EOF
chmod +x "$CRONBIN/crontab"

(
  PATH="$CRONBIN:$PATH"
  export PATH
  SELFDIR=$ROOT/installer
  DIR=$W
  TMPROOT=$TEST_ROOT
  INSTALLED_SCRIPT=$W/speedtest2.sh
  UPDATE_CHECK_SCRIPT=$W/stats_update.sh
  INSTALL_LIB_ONLY=1 . "$ROOT/install.sh"
  install_cron
  install_update_check_cron
)

grep -qF "$W/speedtest2.sh" "$CRON_STORE" || fail "cron: основная строка speedtest2.sh отсутствует"
grep -qF "$W/stats_update.sh check" "$CRON_STORE" || fail "cron: строка ежедневной проверки обновлений отсутствует"

echo "test_managed_updates_integration.sh: часть 2 (cron-строка после install.sh) OK" >&2

echo "test_managed_updates_integration.sh: OK (все части)"
