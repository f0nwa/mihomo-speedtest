#!/bin/sh
# HTTP-маршруты /api/fm/* файлового менеджера (stats_httpd.py + stats_files.py).
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
SCRIPT=$ROOT/web/stats_httpd.py
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/stats-files-http.XXXXXX")
CLEANUP_PIDS=""
cleanup_test() {
  for p in $CLEANUP_PIDS; do kill "$p" 2>/dev/null || true; done
  rm -rf "$TEST_ROOT"
}
trap cleanup_test EXIT INT TERM
fail() { echo "FAIL: $*" >&2; exit 1; }

command -v python3 >/dev/null 2>&1 || {
  echo "test_stats_files_http.sh: python3 недоступен, пропущено" >&2
  echo "test_stats_files_http.sh: OK (пропущено)"
  exit 0
}

PORT=$((31000 + ($$ % 3000)))
STATS_AUTH_STATE_DIR=$TEST_ROOT/auth-state
STATS_AUTH_RUNTIME_DIR=$TEST_ROOT/auth-runtime
LOG=$TEST_ROOT/speedtest.log
export STATS_AUTH_STATE_DIR STATS_AUTH_RUNTIME_DIR LOG
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
COOKIE="mst_session=$(printf '%s\n' "$AUTH_VALUES" | sed -n '1p')"
CSRF=$(printf '%s\n' "$AUTH_VALUES" | sed -n '2p')

# c - с сессией и CSRF, nocsrf - только с сессией, anon - без ничего
c() { command curl -s -m 20 -H "Cookie: $COOKIE" -H "X-CSRF-Token: $CSRF" "$@"; }
nocsrf() { command curl -s -m 20 -H "Cookie: $COOKIE" "$@"; }
anon() { command curl -s -m 20 "$@"; }
B=http://127.0.0.1:$PORT/api/fm

WWW=$TEST_ROOT/www; APP=$TEST_ROOT/app; DATA=$TEST_ROOT/data
mkdir -p "$WWW" "$APP" "$DATA"
printf '<html>shell</html>' > "$APP/stats_index.html"
STATS_APP_DIR=$APP python3 "$SCRIPT" -f -p "127.0.0.1:$PORT" -h "$WWW" >"$TEST_ROOT/server.log" 2>&1 &
CLEANUP_PIDS="$!"
i=0
while [ $i -lt 40 ]; do
  [ "$(c -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/")" != "000" ] && break
  sleep 0.2; i=$((i + 1))
done

code() { c -o /dev/null -w '%{http_code}' "$@"; }

[ "$(anon -o /dev/null -w '%{http_code}' "$B/list?path=/")" = "401" ] || fail "1: без сессии ожидался 401"
printf 'hello' > "$DATA/one.txt"
c "$B/list?path=$DATA" | grep -q '"name": "one.txt"' || fail "2: list не показал файл"
c "$B/tree?path=$TEST_ROOT" | grep -q '"data"' || fail "3: tree не показал подкаталог"
[ "$(nocsrf -X POST -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' -d "{\"path\":\"$DATA/d\"}" "$B/mkdir")" = "403" ] || fail "4: mkdir без CSRF ожидался 403"
[ "$(code -X POST -H 'Content-Type: application/json' -d "{\"path\":\"$DATA/d\"}" "$B/mkdir")" = "200" ] || fail "5: mkdir"
[ -d "$DATA/d" ] || fail "5: каталог не создан"

# загрузка 5 МиБ (больше лимита тела обычных скриптов API) и скачивание
head -c 5242880 /dev/urandom > "$TEST_ROOT/big.bin"
[ "$(code -X POST --data-binary @"$TEST_ROOT/big.bin" -H 'Content-Type: application/octet-stream' "$B/upload?path=$DATA/d&name=big.bin")" = "200" ] || fail "6: upload"
cmp "$TEST_ROOT/big.bin" "$DATA/d/big.bin" || fail "6: загруженный файл отличается"
c -D "$TEST_ROOT/h.txt" -o "$TEST_ROOT/back.bin" "$B/download?path=$DATA/d/big.bin"
cmp "$TEST_ROOT/big.bin" "$TEST_ROOT/back.bin" || fail "7: скачанный файл отличается"
grep -qi '^Content-Disposition: attachment' "$TEST_ROOT/h.txt" || fail "7: нет Content-Disposition"
[ "$(code -X POST --data-binary 'x' "$B/upload?path=$DATA/d&name=../evil")" = "400" ] || fail "8: имя ../evil ожидался 400"
[ ! -e "$DATA/evil" ] || fail "8: файл вне каталога создан"

# чтение и сохранение текста
c "$B/read?path=$DATA/one.txt" | grep -q '"content": "hello"' || fail "9: read"
MT=$(c "$B/read?path=$DATA/one.txt" | python3 -c 'import json,sys; print(json.load(sys.stdin)["mtime"])')
[ "$(code -X PUT -H 'Content-Type: application/json' -d "{\"path\":\"$DATA/one.txt\",\"content\":\"changed\",\"mtime\":$MT}" "$B/write")" = "200" ] || fail "10: write"
[ "$(cat "$DATA/one.txt")" = "changed" ] || fail "10: содержимое не сохранено"
[ "$(cat "$DATA/one.txt.bak")" = "hello" ] || fail "10: нет .bak"
[ "$(code -X PUT -H 'Content-Type: application/json' -d "{\"path\":\"$DATA/one.txt\",\"content\":\"again\",\"mtime\":1}" "$B/write")" = "409" ] || fail "11: устаревший mtime ожидался 409"

# переименование и удаление
[ "$(code -X POST -H 'Content-Type: application/json' -d "{\"src\":\"$DATA/one.txt\",\"dst\":\"$DATA/two.txt\"}" "$B/rename")" = "200" ] || fail "12: rename"
[ -f "$DATA/two.txt" ] || fail "12: файл не переименован"
c -X POST -H 'Content-Type: application/json' -d '{"path":"/etc"}' "$B/delete" | grep -q '"error": "protected"' || fail "13: удаление /etc не отклонено"
[ "$(code -X POST -H 'Content-Type: application/json' -d "{\"path\":\"$DATA/d\"}" "$B/delete")" = "409" ] || fail "14: непустой каталог ожидался 409"
[ "$(code -X POST -H 'Content-Type: application/json' -d "{\"path\":\"$DATA/d\",\"recursive\":true,\"confirm\":\"$DATA/d\"}" "$B/delete")" = "200" ] || fail "15: recursive delete с confirm"
[ ! -e "$DATA/d" ] || fail "15: каталог остался"
[ "$(code "$B/download?path=/dev/null")" = "415" ] || fail "16: /dev/null ожидался 415"
[ "$(code "$B/nothing")" = "501" ] || fail "17: неизвестный маршрут ожидался 501"
grep -q '\[files\]' "$LOG" || fail "18: нет записи в журнале"

echo "test_stats_files_http.sh: OK"
