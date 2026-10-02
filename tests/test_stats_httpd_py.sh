#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
SCRIPT=$ROOT/web/stats_httpd.py
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/stats-httpd-py-test.XXXXXX")

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

command -v python3 >/dev/null 2>&1 || {
  echo "test_stats_httpd_py.sh: python3 недоступен, пропущено" >&2
  echo "test_stats_httpd_py.sh: OK (пропущено)"
  exit 0
}
[ -f "$SCRIPT" ] || fail "не найден $SCRIPT"

BASE_PORT=$((28000 + ($$ % 3000)))

# Все старые проверки транспорта выполняются внутри одной тестовой сессии.
# Запросы без сессии ниже явно используют `command curl`.
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
  # $1=порт. Ждёт, пока сервер не начнёт отвечать хоть чем-то (не 000).
  port=$1
  i=0
  while [ $i -lt 40 ]; do
    code=$(curl -s -m 1 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$port/" 2>/dev/null)
    [ "$code" != "000" ] && return 0
    sleep 0.2; i=$((i + 1))
  done
  return 1
}

start_server() {
  # $1=docroot $2=port $3=conf-файл-или-пусто. Печатает pid в stdout.
  dir=$1; port=$2; conf=$3
  if [ -n "$conf" ]; then
    python3 "$SCRIPT" -f -p "127.0.0.1:$port" -h "$dir" -c "$conf" >"$dir/../server.log" 2>&1 &
  else
    python3 "$SCRIPT" -f -p "127.0.0.1:$port" -h "$dir" >"$dir/../server.log" 2>&1 &
  fi
  echo $!
}

# =========================================================================
# Часть 1: статика
# =========================================================================
W1=$TEST_ROOT/w1/www
mkdir -p "$W1"
printf '<html>привет мир</html>' > "$W1/stats.html"
PORT1=$BASE_PORT
PID1=$(start_server "$W1" "$PORT1" "")
CLEANUP_PIDS="$CLEANUP_PIDS $PID1"
wait_up "$PORT1" || fail "сервер (часть 1) не поднялся"

curl -s -m 2 "http://127.0.0.1:$PORT1/stats.html" | grep -q "привет мир" \
  || fail "статика: /stats.html не отдан"
# С 2026-09-28 корень - только SPA-shell (index.html); stats.html здесь
# просто произвольный статический файл, на "/" он не подставляется.
code=$(curl -s -m 2 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT1/")
[ "$code" = "404" ] || fail "статика: / без index.html должен давать 404 (не stats.html), получено $code"
printf '<html>spa-shell</html>' > "$W1/index.html"
curl -s -m 2 "http://127.0.0.1:$PORT1/" | grep -q "spa-shell" \
  || fail "статика: / не мапится на index.html"
rm -f "$W1/index.html"
code=$(curl -s -m 2 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT1/nope.html")
[ "$code" = "404" ] || fail "статика: отсутствующий файл должен давать 404, получено $code"
code=$(curl -s -m 2 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT1/../../etc/passwd")
[ "$code" != "200" ] || fail "статика: обход каталога (..) не должен отдавать файл (200)"

echo "test_stats_httpd_py.sh: часть 1 (статика) OK" >&2

# =========================================================================
# Часть 2: CGI (GET/POST, переменные окружения, тело запроса)
# =========================================================================
W2=$TEST_ROOT/w2/www
mkdir -p "$W2/cgi-bin"
printf '<html>index</html>' > "$W2/stats.html"
cat > "$W2/cgi-bin/echo" <<'CGI'
#!/bin/sh
echo "Content-Type: text/plain; charset=utf-8"
echo
echo "method=$REQUEST_METHOD"
echo "query=$QUERY_STRING"
echo "len=$CONTENT_LENGTH"
if [ "$REQUEST_METHOD" = "POST" ]; then
  body=$(dd bs=1 count="$CONTENT_LENGTH" 2>/dev/null)
  echo "body=$body"
fi
CGI
chmod +x "$W2/cgi-bin/echo"

PORT2=$((BASE_PORT + 1))
PID2=$(start_server "$W2" "$PORT2" "")
CLEANUP_PIDS="$CLEANUP_PIDS $PID2"
wait_up "$PORT2" || fail "сервер (часть 2) не поднялся"

OUT_GET=$(curl -s -m 2 "http://127.0.0.1:$PORT2/cgi-bin/echo?a=1")
echo "$OUT_GET" | grep -q "method=GET" || fail "CGI GET: неверный REQUEST_METHOD ($OUT_GET)"
echo "$OUT_GET" | grep -q "query=a=1" || fail "CGI GET: QUERY_STRING не передан ($OUT_GET)"

OUT_POST=$(curl -s -m 2 -X POST --data "node_cap=5" "http://127.0.0.1:$PORT2/cgi-bin/echo")
echo "$OUT_POST" | grep -q "method=POST" || fail "CGI POST: неверный REQUEST_METHOD ($OUT_POST)"
echo "$OUT_POST" | grep -q "body=node_cap=5" || fail "CGI POST: тело запроса не дошло до скрипта ($OUT_POST)"

# статика в том же каталоге, что и cgi-bin, всё ещё раздаётся как файл, не исполняется
curl -s -m 2 "http://127.0.0.1:$PORT2/stats.html" | grep -q "index" \
  || fail "CGI: обычная статика рядом с cgi-bin сломалась"

echo "test_stats_httpd_py.sh: часть 2 (CGI) OK" >&2

# =========================================================================
# Часть 3: сессионная защита заменяет устаревший Basic Auth
# =========================================================================
W3=$TEST_ROOT/w3/www
mkdir -p "$W3/cgi-bin"
printf '<html>открыто всем</html>' > "$W3/stats.html"
cp "$W2/cgi-bin/echo" "$W3/cgi-bin/echo"
chmod +x "$W3/cgi-bin/echo"
CONF3=$TEST_ROOT/w3/httpd.conf
printf '/cgi-bin:admin:hunter2\n' > "$CONF3"

PORT3=$((BASE_PORT + 2))
PID3=$(start_server "$W3" "$PORT3" "$CONF3")
CLEANUP_PIDS="$CLEANUP_PIDS $PID3"
wait_up "$PORT3" || fail "сервер (часть 3) не поднялся"

curl -s -m 2 "http://127.0.0.1:$PORT3/stats.html" | grep -q "открыто всем" \
  || fail "сессия должна открывать stats.html"

code=$(command curl -s -m 2 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT3/stats.html")
[ "$code" = "302" ] || fail "stats.html без сессии должен перенаправляться на вход, получено $code"

code=$(command curl -s -m 2 -u admin:hunter2 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT3/cgi-bin/echo")
[ "$code" = "302" ] || fail "Basic Auth не должен обходить вход по сессии, получено $code"

code=$(curl -s -m 2 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT3/cgi-bin/echo")
[ "$code" = "200" ] || fail "сессия должна открывать CGI, получено $code"

echo "test_stats_httpd_py.sh: часть 3 (сессионная защита) OK" >&2

# =========================================================================
# Часть 4: убийство процесса-слушателя не обрывает уже начатый ответ
#          (свойство, на которое полагается self-restart в ensure_stats_httpd())
# =========================================================================
W4=$TEST_ROOT/w4/www
mkdir -p "$W4/cgi-bin"
printf '<html>x</html>' > "$W4/stats.html"
cat > "$W4/cgi-bin/slow" <<'CGI'
#!/bin/sh
sleep 1
echo "Content-Type: text/plain; charset=utf-8"
echo
echo "готово-после-паузы"
CGI
chmod +x "$W4/cgi-bin/slow"

PORT4=$((BASE_PORT + 3))
PID4=$(start_server "$W4" "$PORT4" "")
wait_up "$PORT4" || fail "сервер (часть 4) не поднялся"

curl -s -m 5 "http://127.0.0.1:$PORT4/cgi-bin/slow" > "$TEST_ROOT/resp4.txt" &
CURL_PID=$!
sleep 0.3
kill "$PID4" 2>/dev/null || fail "не удалось послать kill слушателю во время запроса"
wait "$CURL_PID" 2>/dev/null || true

grep -q "готово-после-паузы" "$TEST_ROOT/resp4.txt" \
  || fail "self-restart: убийство слушателя оборвало уже начатый ответ (модель должна быть fork-per-connection)"

echo "test_stats_httpd_py.sh: часть 4 (fork-per-connection переживает kill слушателя) OK" >&2

# =========================================================================
# Часть 5: SPA-фоллбек "чистых" URL (index.html есть в docroot) - см.
# docs/plans/2026-09-12-web-spa-migration-design.md, шаг 1
# =========================================================================
W5=$TEST_ROOT/w5/www
mkdir -p "$W5/cgi-bin"
printf '<html>spa-shell-marker</html>' > "$W5/index.html"
cat > "$W5/cgi-bin/dummy" <<'CGI'
#!/bin/sh
echo "Content-Type: text/plain; charset=utf-8"
echo
echo ok
CGI
chmod +x "$W5/cgi-bin/dummy"

PORT5=$((BASE_PORT + 4))
PID5=$(start_server "$W5" "$PORT5" "")
CLEANUP_PIDS="$CLEANUP_PIDS $PID5"
wait_up "$PORT5" || fail "сервер (часть 5) не поднялся"

for p in / /stats /settings /any/nested/path; do
  curl -s -m 2 "http://127.0.0.1:$PORT5$p" | grep -q "spa-shell-marker" \
    || fail "SPA-фоллбек: GET $p должен отдавать index.html"
done

code=$(curl -s -m 2 -X POST -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT5/unknown")
[ "$code" = "404" ] || fail "SPA-фоллбек: POST на несуществующий путь должен остаться 404, получено $code"

code=$(curl -s -m 2 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT5/cgi-bin/missing")
[ "$code" = "404" ] || fail "SPA-фоллбек: отсутствующий скрипт под cgi-bin должен остаться 404, получено $code"

echo "test_stats_httpd_py.sh: часть 5 (SPA-фоллбек) OK" >&2

# =========================================================================
# Часть 6: "/api/run" - алиас на "cgi-bin/run" (та же защита, тот же
# вывод); "/api/stats" и "/api/progress" - алиасы на статические
# stats.json/progress.json (не CGI); "/api/settings" - алиас на
# "cgi-bin/config" с доп. переменной окружения API_JSON=1; остальные
# "/api/*" - заглушка JSON 501, а не 404 (шаги 1 и 4 design-дока)
# =========================================================================
W6=$TEST_ROOT/w6/www
mkdir -p "$W6/cgi-bin"
printf '<html>spa-shell-marker</html>' > "$W6/index.html"
cat > "$W6/cgi-bin/run" <<'CGI'
#!/bin/sh
echo "Content-Type: application/json; charset=utf-8"
echo
echo '{"running":false,"started":false}'
CGI
chmod +x "$W6/cgi-bin/run"
cat > "$W6/cgi-bin/config" <<'CGI'
#!/bin/sh
echo "Content-Type: text/plain; charset=utf-8"
echo
echo "method=$REQUEST_METHOD"
echo "api_json=${API_JSON:-}"
CGI
chmod +x "$W6/cgi-bin/config"
printf '{"ok":true,"marker":"stats-json-marker"}' > "$W6/stats.json"
printf '{"running":true,"marker":"progress-json-marker"}' > "$W6/progress.json"
CONF6=$TEST_ROOT/w6/httpd.conf
printf '/cgi-bin:admin:hunter2\n' > "$CONF6"

PORT6=$((BASE_PORT + 5))
PID6=$(start_server "$W6" "$PORT6" "$CONF6")
CLEANUP_PIDS="$CLEANUP_PIDS $PID6"
wait_up "$PORT6" || fail "сервер (часть 6) не поднялся"

code=$(command curl -s -m 2 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT6/api/run")
[ "$code" = "401" ] || fail "/api/run: без сессии должен вернуть 401, получено $code"

OUT_ALIAS=$(curl -s -m 2 -u admin:hunter2 "http://127.0.0.1:$PORT6/api/run")
OUT_LEGACY=$(curl -s -m 2 -u admin:hunter2 "http://127.0.0.1:$PORT6/cgi-bin/run")
[ "$OUT_ALIAS" = "$OUT_LEGACY" ] || fail "/api/run: ответ должен совпадать с /cgi-bin/run (алиас), получено [$OUT_ALIAS] vs [$OUT_LEGACY]"
echo "$OUT_ALIAS" | grep -q '"running":false' || fail "/api/run: не похоже на JSON от stats_run.sh ($OUT_ALIAS)"

# /api/stats - обычный статический файл (не CGI, без Basic Auth - он
# настроен только на /cgi-bin в CONF6), содержимое и Content-Type как у
# .json.
code=$(curl -s -m 2 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT6/api/stats")
[ "$code" = "200" ] || fail "/api/stats: должен отдавать stats.json (200), получено $code"
curl -s -m 2 "http://127.0.0.1:$PORT6/api/stats" | grep -q "stats-json-marker" \
  || fail "/api/stats: не похоже на содержимое stats.json"
CT6=$(curl -s -m 2 -D - -o /dev/null "http://127.0.0.1:$PORT6/api/stats" | tr -d '\r' | grep -i '^Content-Type:')
echo "$CT6" | grep -qi "application/json" || fail "/api/stats: Content-Type должен быть application/json, получено [$CT6]"

# /api/progress - тот же приём, что и /api/stats: обычный статический
# файл, без Basic Auth, Content-Type/Content-Length как у обычного .json.
code=$(curl -s -m 2 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT6/api/progress")
[ "$code" = "200" ] || fail "/api/progress: должен отдавать progress.json (200), получено $code"
curl -s -m 2 "http://127.0.0.1:$PORT6/api/progress" | grep -q "progress-json-marker" \
  || fail "/api/progress: не похоже на содержимое progress.json"
CT6B=$(curl -s -m 2 -D - -o /dev/null "http://127.0.0.1:$PORT6/api/progress" | tr -d '\r' | grep -i '^Content-Type:')
echo "$CT6B" | grep -qi "application/json" || fail "/api/progress: Content-Type должен быть application/json, получено [$CT6B]"

# /api/progress без progress.json на диске (ещё не было прогона с этой
# версией speedtest2.sh) - задокументированная в stats_httpd.py
# особенность SPA-фоллбека: 200 с телом index.html, НЕ 404 (тот же код,
# что обслуживает /api/stats - алиас подставляется до проверки на "api/",
# различить их там уже нельзя). Фиксируем именно это поведение, а не
# желаемое - чтобы правка _spa_fallback() не прошла тут незамеченной.
rm -f "$W6/progress.json"
code=$(curl -s -m 2 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT6/api/progress")
[ "$code" = "200" ] || fail "/api/progress без файла: ожидался 200 (SPA-фоллбек, см. комментарий в stats_httpd.py), получено $code"
curl -s -m 2 "http://127.0.0.1:$PORT6/api/progress" | grep -q "spa-shell-marker" \
  || fail "/api/progress без файла: ожидался index.html (SPA-фоллбек)"
printf '{"running":true,"marker":"progress-json-marker"}' > "$W6/progress.json"

# /api/settings - тот же Basic Auth, что и у /cgi-bin/config, но с
# дополнительной переменной окружения API_JSON=1 (сам JSON-ответ
# print_settings_json() проверяется в tests/test_stats_cgi.sh - здесь
# только сама проводка алиаса в stats_httpd.py).
code=$(command curl -s -m 2 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT6/api/settings")
[ "$code" = "401" ] || fail "/api/settings: без сессии должен вернуть 401, получено $code"

OUT_SETTINGS=$(curl -s -m 2 -u admin:hunter2 "http://127.0.0.1:$PORT6/api/settings")
echo "$OUT_SETTINGS" | grep -q "api_json=1" || fail "/api/settings: алиас должен добавлять API_JSON=1 в окружение CGI ($OUT_SETTINGS)"

code=$(curl -s -m 2 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT6/cgi-bin/config")
[ "$code" = "302" ] || fail "/cgi-bin/config: устаревшая HTML-форма должна перенаправлять на /settings, получено $code"
location=$(curl -s -m 2 -D - -o /dev/null "http://127.0.0.1:$PORT6/cgi-bin/config" | tr -d '\r' | awk 'tolower($1)=="location:" {print $2}')
[ "$location" = "/settings" ] || fail "/cgi-bin/config: ожидался Location /settings, получено $location"

# остальные "/api/*" без алиаса - как и раньше, заглушка 501
code=$(curl -s -m 2 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT6/api/whatever")
[ "$code" = "501" ] || fail "/api/whatever (нет алиаса): должен отвечать 501, получено $code"
curl -s -m 2 "http://127.0.0.1:$PORT6/api/whatever" | grep -q '"not_implemented"' \
  || fail "/api/whatever: заглушка должна быть JSON с error=not_implemented"

echo "test_stats_httpd_py.sh: часть 6 (/api/run, /api/stats, /api/progress, /api/settings - алиасы; остальные /api/* - заглушка) OK" >&2

# --- /api/updates/check|status|prepare|apply|discard (задача 6 порции
#     "managed-updates") - все пять алиасов на общий "cgi-bin/update" с
#     разной MST_UPDATE_ACTION, та же защита сессией/CSRF, что и у
#     /api/run и /api/settings выше. Поведение самого stats_update.sh
#     (что он делает с MST_UPDATE_ACTION/update.sh) не проверяется здесь
#     - см. tests/test_stats_update.sh - здесь фейковый CGI-скрипт вместо
#     настоящего, проверяется только сама проводка алиасов в
#     stats_httpd.py. ---
cat > "$W6/cgi-bin/update" <<'CGI'
#!/bin/sh
echo "Content-Type: text/plain; charset=utf-8"
echo
echo "action=${MST_UPDATE_ACTION:-}"
echo "method=$REQUEST_METHOD"
CGI
chmod +x "$W6/cgi-bin/update"

code=$(command curl -s -m 2 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT6/api/updates/status")
[ "$code" = "401" ] || fail "/api/updates/status: без сессии должен вернуть 401, получено $code"

OUT_CHECK=$(curl -s -m 2 -X POST "http://127.0.0.1:$PORT6/api/updates/check")
echo "$OUT_CHECK" | grep -q "action=check" || fail "/api/updates/check: MST_UPDATE_ACTION не проброшен ($OUT_CHECK)"
echo "$OUT_CHECK" | grep -q "method=POST" || fail "/api/updates/check: метод не POST ($OUT_CHECK)"

for a in status prepare apply discard; do
  OUT=$(curl -s -m 2 "http://127.0.0.1:$PORT6/api/updates/$a")
  echo "$OUT" | grep -q "action=$a" || fail "/api/updates/$a: MST_UPDATE_ACTION не проброшен ($OUT)"
done

echo "test_stats_httpd_py.sh: часть 6b (/api/updates/*) OK" >&2

# --- /api/system (пункт 5 фидбека по макету "Панель управления": футер с
#     версией/аптаймом/CPU/MEM/статусом mihomo) - тот же алиас-приём, что
#     и у "/api/run"/"/api/settings" выше: cgi-bin/system подставной
#     (само содержимое stats_system.sh проверяется отдельно, в
#     tests/test_stats_system.sh) - здесь только сама проводка алиаса в
#     API_ALIASES stats_httpd.py, включая защиту сессией. ---
cat > "$W6/cgi-bin/system" <<'CGI'
#!/bin/sh
echo "Content-Type: application/json; charset=utf-8"
echo
echo '{"release_version":"9","marker":"system-json-marker"}'
CGI
chmod +x "$W6/cgi-bin/system"

code=$(command curl -s -m 2 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT6/api/system")
[ "$code" = "401" ] || fail "/api/system: без сессии должен вернуть 401, получено $code"

OUT_SYSTEM=$(curl -s -m 2 -u admin:hunter2 "http://127.0.0.1:$PORT6/api/system")
echo "$OUT_SYSTEM" | grep -q "system-json-marker" || fail "/api/system: алиас не дошёл до cgi-bin/system ($OUT_SYSTEM)"

echo "test_stats_httpd_py.sh: часть 6c (/api/system) OK" >&2


# =========================================================================
# Часть 7: чтение тела POST-запроса не должно висеть бесконечно, если
# клиент заявил Content-Length больше реально присланного и держит
# соединение открытым (например HTTP/1.1 keep-alive от браузера, ничего
# больше не отправляющий) - на реальном роутере это повесило ВЕСЬ процесс
# целиком: новые подключения (даже с localhost) переставали приниматься,
# хотя порт оставался LISTEN (см. CHANGELOG). Handler.timeout/
# STATS_HTTPD_READ_TIMEOUT - защита от этого; здесь подставляем маленький
# таймаут вместо реальных 30с по умолчанию, чтобы тест не ждал долго.
# =========================================================================
W7=$TEST_ROOT/w7/www
mkdir -p "$W7/cgi-bin"
cat > "$W7/cgi-bin/slow" <<'CGI'
#!/bin/sh
echo "Content-Type: text/plain; charset=utf-8"
echo
echo "method=$REQUEST_METHOD"
CGI
chmod +x "$W7/cgi-bin/slow"

PORT7=$((BASE_PORT + 6))
STATS_HTTPD_READ_TIMEOUT=1
export STATS_HTTPD_READ_TIMEOUT
PID7=$(start_server "$W7" "$PORT7" "")
unset STATS_HTTPD_READ_TIMEOUT
CLEANUP_PIDS="$CLEANUP_PIDS $PID7"
wait_up "$PORT7" || fail "сервер (часть 7) не поднялся"

# Открываем сырое TCP-соединение в фоне: объявляем Content-Length больше
# реально отправленного, держим сокет открытым несколько секунд (дольше
# таймаута) и НЕ закрываем его - именно так вешался процесс на роутере.
python3 - "$PORT7" "$AUTH_COOKIE" "$AUTH_CSRF" <<'RAWSOCK' &
import socket, sys, time
port = int(sys.argv[1])
cookie, csrf = sys.argv[2], sys.argv[3]
s = socket.create_connection(("127.0.0.1", port), timeout=5)
req = (
    "POST /cgi-bin/slow HTTP/1.1\r\n"
    "Host: 127.0.0.1\r\n"
    f"Cookie: {cookie}\r\n"
    f"X-CSRF-Token: {csrf}\r\n"
    "Content-Length: 1000000\r\n"
    "Content-Type: text/plain\r\n"
    "Connection: keep-alive\r\n"
    "\r\n"
    "not-enough-bytes"
)
s.sendall(req.encode())
time.sleep(4)
s.close()
RAWSOCK
SLOWCLIENT_PID=$!
CLEANUP_PIDS="$CLEANUP_PIDS $SLOWCLIENT_PID"

# Даём фоновому клиенту время подключиться и отправить неполное тело.
sleep 1

# Ключевая проверка: ПОКА "медленный" клиент всё ещё висит на
# соединении, обычный независимый запрос должен пройти сразу, а не
# ждать, пока освободится сервер, - раньше (без timeout) он бы завис
# так же, как и всё остальное.
code=$(curl -s -m 3 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT7/cgi-bin/slow" -X GET)
[ "$code" != "000" ] || fail "часть 7: сервер завис из-за одного клиента с незавершённым телом запроса (регрессия бага с реального роутера)"

wait "$SLOWCLIENT_PID" 2>/dev/null || true

echo "test_stats_httpd_py.sh: часть 7 (таймаут на чтение тела запроса) OK" >&2

# =========================================================================
# Часть 8: дочерний процесс (fork на каждое соединение, см. ForkingHTTPServer
# в шапке файла) должен закрывать СВОЙ унаследованный слушающий сокет -
# иначе, пока ребёнок жив (например завис на чтении тела запроса - часть 7
# выше), порт остаётся занятым даже после того, как speedtest2.sh убил
# родительский процесс из pidfile (stop_stats_httpd() перед перезапуском на
# новый адрес/пароль или после setup.sh). Именно так на реальном роутере
# новый процесс (что python3, что резервный busybox httpd) не мог
# забиндиться: "OSError: [Errno 125] Address already in use" в
# stats_httpd.log (125 - это EADDRINUSE на MIPS), хотя "живых" процессов по
# имени в ps оставался только один - зависший ребёнок, а не родитель.
#
# Настоящий os.fork() здесь не годится - для честной проверки нужно убить
# родителя и дождаться падения одной ОС на реальном железе, что нестабильно
# и медленно в тестовом окружении; вместо этого подменяем os.fork()/os._exit()
# и напрямую проверяем, что ForkingHTTPServer.process_request() в ветке
# "ребёнок" закрывает self.socket (слушающий) ДО обработки запроса - именно
# это и есть исправление (см. класс ForkingHTTPServer в stats_httpd.py).
# =========================================================================
python3 - "$SCRIPT" <<'MOCKFORK' || fail "часть 8: дочерний процесс не закрывает унаследованный слушающий сокет (регрессия EADDRINUSE после перезапуска - см. CHANGELOG)"
import importlib.util
import os
import socket
import sys

script = sys.argv[1]
# stats_httpd.py делает "import stats_auth" без манипуляций sys.path -
# в проде это всегда работает (оба файла всегда рядом, плоско, в $DIR).
# До переноса stats_auth.py в web/ это же неявно работало и здесь через
# sys.path[0]="" (CWD) под "python3 -", т.к. CWD теста - корень репозитория,
# где раньше лежал stats_auth.py. Теперь оба файла лежат в одной папке
# web/, но уже не в CWD - добавляем её явно.
sys.path.insert(0, os.path.dirname(script))
spec = importlib.util.spec_from_file_location("stats_httpd_under_test", script)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

server = mod.ForkingHTTPServer.__new__(mod.ForkingHTTPServer)
listen_sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
listen_sock.bind(("127.0.0.1", 0))
listen_sock.listen(1)
server.socket = listen_sock
server.active_children = set()

orig_fork, orig_exit = os.fork, os._exit
os.fork = lambda: 0  # притворяемся ребёнком
os._exit = lambda status: (_ for _ in ()).throw(SystemExit(status))
server.finish_request = lambda request, addr: None
server.shutdown_request = lambda request: None

try:
    try:
        server.process_request("dummy-request", ("127.0.0.1", 1))
    except SystemExit:
        pass
finally:
    os.fork, os._exit = orig_fork, orig_exit

if listen_sock.fileno() != -1:
    print("часть 8: дочерний процесс не закрыл слушающий сокет", file=sys.stderr)
    sys.exit(1)
print("часть 8: OK", file=sys.stderr)
MOCKFORK

echo "test_stats_httpd_py.sh: часть 8 (дочерний процесс закрывает слушающий сокет) OK" >&2

# =========================================================================
# Часть 9: остановка слушателя (TERM - так его гасит supervisor при
# "S80speedtest-stats stop", в т.ч. из uninstall.sh) должна закрывать и
# ПРОСТАИВАЮЩИЕ keep-alive-соединения. Раньше ребёнок (fork на соединение)
# переживал родителя и продолжал отвечать по уже открытому соединению:
# открытая вкладка панели опрашивает /api/progress каждые 2 с, таймаут
# простоя (30 с) не наступал никогда - после удаления проекта веб-сервис
# для браузера продолжал "работать".
# =========================================================================
W9=$TEST_ROOT/w9/www
mkdir -p "$W9"
printf '<html>x</html>' > "$W9/stats.html"
PORT9=$((BASE_PORT + 8))
PID9=$(start_server "$W9" "$PORT9" "")
CLEANUP_PIDS="$CLEANUP_PIDS $PID9"
wait_up "$PORT9" || fail "сервер (часть 9) не поднялся"

python3 - "$PORT9" "$PID9" "$AUTH_COOKIE" <<'KEEPALIVE' || fail "часть 9: keep-alive-соединение пережило остановку веб-сервиса"
import http.client, os, signal, sys, time
port, pid, cookie = int(sys.argv[1]), int(sys.argv[2]), sys.argv[3]
c = http.client.HTTPConnection("127.0.0.1", port, timeout=3)
hdr = {"Cookie": cookie}
c.request("GET", "/stats.html", headers=hdr)
r = c.getresponse(); r.read()
assert r.status == 200, r.status
os.kill(pid, signal.SIGTERM)
time.sleep(1)
try:
    c.request("GET", "/stats.html", headers=hdr)
    r = c.getresponse(); r.read()
except (OSError, http.client.HTTPException):
    sys.exit(0)
print("ответ %s по старому соединению после остановки" % r.status, file=sys.stderr)
sys.exit(1)
KEEPALIVE

echo "test_stats_httpd_py.sh: часть 9 (остановка закрывает keep-alive-соединения) OK" >&2

echo "test_stats_httpd_py.sh: OK (все части)"
