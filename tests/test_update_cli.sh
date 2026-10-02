#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
SCRIPT=$ROOT/updater/update.sh
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/update-cli-test.XXXXXX")

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
  case "$2" in
    *"$1"*) ;;
    *) fail "expected to find: $1 (context: $3)" ;;
  esac
}

sh -n "$SCRIPT" || fail "update.sh не проходит sh -n"

# Ошибка транспорта должна сохранять подробности и давать следующий шаг.
mkdir -p "$TEST_ROOT/bin" "$TEST_ROOT/tmp-error"
cat > "$TEST_ROOT/bin/curl" <<'EOF'
#!/bin/sh
printf 'curl: (28) test download timeout\n' >&2
exit 28
EOF
chmod +x "$TEST_ROOT/bin/curl"
if PATH="$TEST_ROOT/bin:$PATH" TMPROOT="$TEST_ROOT/tmp-error" \
  UPDATE_RELEASE_BASE=https://example.invalid/releases/latest/download \
  sh "$SCRIPT" --check >"$TEST_ROOT/out.log" 2>"$TEST_ROOT/err.log"; then
  fail "--check должен остановиться при ошибке загрузки"
fi
for expected in 'curl: (28) test download timeout' 'код загрузчика: 28' \
  'https://example.invalid/releases/latest/download/manifest.txt' \
  'Повторите обновление через несколько минут' 'пришлите этот вывод'; do
  grep -Fq "$expected" "$TEST_ROOT/err.log" || fail "нет диагностики: $expected"
done
if grep -q 'проверьте сеть и сертификаты' "$TEST_ROOT/err.log"; then
  fail "ошибка не должна предлагать пользователю проверять сертификаты"
fi
[ ! -s "$TEST_ROOT/out.log" ] || fail "диагностика попала в stdout"
[ -z "$(ls -A "$TEST_ROOT/tmp-error")" ] || fail "временные файлы не очищены"
echo "test_update_cli.sh: диагностика загрузки OK" >&2

have_busybox_httpd=1
command -v busybox >/dev/null 2>&1 || have_busybox_httpd=0
if [ "$have_busybox_httpd" = 1 ]; then
  busybox httpd 2>&1 | grep -qi applet && have_busybox_httpd=0
fi
command -v curl >/dev/null 2>&1 || have_busybox_httpd=0

[ "$have_busybox_httpd" = 1 ] || {
  echo "test_update_cli.sh: busybox httpd/curl недоступны, сетевые проверки пропущены" >&2
  echo "test_update_cli.sh: OK (частично)"
  exit 0
}

BASE_PORT=$((23000 + ($$ % 3000)))

start_httpd() {
  dir=$1; port=$2
  busybox httpd -f -p "127.0.0.1:$port" -h "$dir" >/dev/null 2>&1 &
  echo $!
}

wait_httpd() {
  port=$1; path=$2
  i=0
  while [ $i -lt 30 ]; do
    code=$(curl -s -m 1 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$port$path" 2>/dev/null)
    [ "$code" != "000" ] && return 0
    sleep 0.2; i=$((i + 1))
  done
  return 1
}

SHA_X=1111111111111111111111111111111111111111111111111111111111111111
SHA_X=$(printf '%s' "$SHA_X" | cut -c1-64)

SRV=$TEST_ROOT/srv
mkdir -p "$SRV"
cat > "$SRV/manifest.txt" << EOF
FORMAT_VERSION=2
RELEASE_VERSION=9
RELEASE_TAG=v9
MIN_UPDATER_VERSION=1
CONFIG_SCHEMA_VERSION=1
COMPONENT|updater|Обновлятор
NOTE|updater|Заметка updater
FILE|updater|update.sh|/opt/etc/mihomo-speedtest/update.sh|10|$SHA_X|0755|sh
ACTION|updater|restart-mihomo
EOF
PORT=$BASE_PORT
PID=$(start_httpd "$SRV" "$PORT")
CLEANUP_PIDS="$CLEANUP_PIDS $PID"
wait_httpd "$PORT" /manifest.txt || fail "тестовый httpd не поднялся"

# --- 1: --check без установленного манифеста ---
OUT=$(UPDATE_RELEASE_BASE="http://127.0.0.1:$PORT" UPDATE_STATE_DIR="$TEST_ROOT/state-empty" sh "$SCRIPT" --check)
assert_contains "не отслеживается update.sh" "$OUT" "--check без installed-manifest.txt"
assert_contains "Доступна версия релиза: v9 (номер 9" "$OUT" "--check показывает версию из манифеста"

echo "test_update_cli.sh: часть 1 (--check без installed) OK" >&2

# --- 2: --check с установленным манифестом ---
INSTALLED_DIR=$TEST_ROOT/state-installed
mkdir -p "$INSTALLED_DIR"
printf 'FORMAT_VERSION=2\nRELEASE_VERSION=7\nRELEASE_TAG=v7\nMIN_UPDATER_VERSION=1\nCONFIG_SCHEMA_VERSION=1\n' > "$INSTALLED_DIR/installed-manifest.txt"
OUT=$(UPDATE_RELEASE_BASE="http://127.0.0.1:$PORT" UPDATE_STATE_DIR="$INSTALLED_DIR" sh "$SCRIPT" --check)
assert_contains "Установлена версия релиза: v7 (номер 7)" "$OUT" "--check читает installed-manifest.txt, если он есть"
assert_contains "Доступна версия релиза: v9 (номер 9" "$OUT" "--check показывает версию из манифеста рядом с установленной"

echo "test_update_cli.sh: часть 2 (--check с installed) OK" >&2

# --- 3: --plan, файл отсутствует ---
OUT=$(UPDATE_RELEASE_BASE="http://127.0.0.1:$PORT" UPDATE_STATE_DIR="$TEST_ROOT/state-empty" sh "$SCRIPT" --plan)
assert_contains "/opt/etc/mihomo-speedtest/update.sh [updater]: отсутствует" "$OUT" "--plan: файла нет на диске"
assert_contains "restart-mihomo" "$OUT" "--plan: действие компонента попало в план"

echo "test_update_cli.sh: часть 3 (--plan, файл отсутствует) OK" >&2

# --- 4: --plan --format=json валиден ---
OUT_JSON=$(UPDATE_RELEASE_BASE="http://127.0.0.1:$PORT" UPDATE_STATE_DIR="$TEST_ROOT/state-empty" sh "$SCRIPT" --plan --format=json)
command -v python3 >/dev/null 2>&1 && python3 - "$OUT_JSON" << 'PYEOF'
import json, sys
d = json.loads(sys.argv[1])
assert d["release_version"] == "9"
assert d["components"][0]["id"] == "updater"
print("json ok", file=sys.stderr)
PYEOF

echo "test_update_cli.sh: часть 4 (--plan --format=json) OK" >&2

# --- 5: --components сужает выбор ---
OUT=$(UPDATE_RELEASE_BASE="http://127.0.0.1:$PORT" UPDATE_STATE_DIR="$TEST_ROOT/state-empty" sh "$SCRIPT" --plan --components=updater)
assert_contains "updater (Обновлятор)" "$OUT" "--components=updater выбирает компонент явно"

echo "test_update_cli.sh: часть 5 (--components) OK" >&2

# --- 6: сеть недоступна - понятная ошибка, ненулевой код ---
if UPDATE_RELEASE_BASE="http://127.0.0.1:1" UPDATE_HTTP_TIMEOUT=1 sh "$SCRIPT" --check >/dev/null 2>"$TEST_ROOT/err.log"; then
  fail "--check должен вернуть ошибку при недоступной сети"
fi
grep -q "Не удалось скачать файл обновления" "$TEST_ROOT/err.log" || fail "--check не сообщил о недоступности сети"

echo "test_update_cli.sh: часть 6 (сеть недоступна) OK" >&2

# --- 7: --plan ничего не пишет в /opt (только в TMPROOT) ---
WATCH_DIR=$TEST_ROOT/opt-watch
mkdir -p "$WATCH_DIR"
BEFORE=$(find "$WATCH_DIR" | wc -l)
UPDATE_RELEASE_BASE="http://127.0.0.1:$PORT" UPDATE_STATE_DIR="$TEST_ROOT/state-empty" TMPROOT="$TEST_ROOT/tmp-plan" \
  sh -c "mkdir -p \"$TEST_ROOT/tmp-plan\"; INSTALLED_MANIFEST_PATH=\"$WATCH_DIR/installed-manifest.txt\" sh \"$SCRIPT\" --plan" >/dev/null
AFTER=$(find "$WATCH_DIR" | wc -l)
[ "$BEFORE" = "$AFTER" ] || fail "--plan не должен создавать/менять файлы вне TMPROOT"

echo "test_update_cli.sh: часть 7 (--plan не пишет в постоянное хранилище) OK" >&2

echo "test_update_cli.sh: OK"
