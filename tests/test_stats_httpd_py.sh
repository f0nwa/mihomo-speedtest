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
  # $1=docroot (данные) $2=порт $3=каталог приложения (скрипты и статика).
  # Печатает pid в stdout.
  dir=$1; port=$2; app=$3
  STATS_APP_DIR=$app python3 "$SCRIPT" -f -p "127.0.0.1:$port" -h "$dir" >"$dir/../server.log" 2>&1 &
  echo $!
}

mk_script() {
  # $1=путь; тело скрипта - со stdin. Делает исполняемым.
  cat > "$1"
  chmod +x "$1"
}

# =========================================================================
# Часть 1: статика интерфейса - из каталога приложения по таблице
# STATIC_FILES; произвольные файлы docroot не раздаются
# =========================================================================
W1=$TEST_ROOT/w1/www; A1=$TEST_ROOT/w1/app
mkdir -p "$W1" "$A1"
printf '<html>spa-shell-marker</html>' > "$A1/stats_index.html"
printf 'body{color:red}' > "$A1/stats_style.css"
printf 'console.log("app-marker")' > "$A1/stats_app.js"
printf 'секрет' > "$W1/secret.txt"
printf 'секрет' > "$A1/stats_cgi.sh"
PORT1=$BASE_PORT
PID1=$(start_server "$W1" "$PORT1" "$A1")
CLEANUP_PIDS="$CLEANUP_PIDS $PID1"
wait_up "$PORT1" || fail "сервер (часть 1) не поднялся"

curl -s -m 2 "http://127.0.0.1:$PORT1/" | grep -q "spa-shell-marker" || fail "статика: / не отдаёт stats_index.html"
curl -s -m 2 "http://127.0.0.1:$PORT1/style.css" | grep -q "color:red" || fail "статика: /style.css не отдаёт stats_style.css"
CT1=$(curl -s -m 2 -D - -o /dev/null "http://127.0.0.1:$PORT1/style.css" | tr -d '\r' | grep -i '^Content-Type:')
echo "$CT1" | grep -qi "text/css" || fail "статика: Content-Type style.css [$CT1]"
curl -s -m 2 "http://127.0.0.1:$PORT1/app.js" | grep -q "app-marker" || fail "статика: /app.js не отдаёт stats_app.js"
for p in /secret.txt /stats_cgi.sh /../../etc/passwd; do
  curl -s -m 2 "http://127.0.0.1:$PORT1$p" | grep -q "секрет\|root:" && fail "статика: $p не должен отдавать файл"
done
for p in /stats /settings /any/nested/path; do
  curl -s -m 2 "http://127.0.0.1:$PORT1$p" | grep -q "spa-shell-marker" \
    || fail "SPA-фоллбек: GET $p должен отдавать index.html"
done
code=$(curl -s -m 2 -X POST -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT1/unknown")
[ "$code" = "404" ] || fail "SPA-фоллбек: POST на неизвестный путь должен быть 404, получено $code"
code=$(curl -s -m 2 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT1/cgi-bin/config")
[ "$code" = "404" ] || fail "/cgi-bin/* больше не поддерживается: ожидался 404, получено $code"
rm -f "$A1/stats_index.html"
code=$(curl -s -m 2 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT1/")
[ "$code" = "404" ] || fail "статика: / без stats_index.html должен давать 404, получено $code"

echo "test_stats_httpd_py.sh: часть 1 (статика и SPA-фоллбек) OK" >&2

# =========================================================================
# Часть 2: API на скриптах - протокол CGI (метод, query, тело, доп.
# переменные из API_ROUTES), сессия и CSRF
# =========================================================================
W2=$TEST_ROOT/w2/www; A2=$TEST_ROOT/w2/app
mkdir -p "$W2" "$A2"
printf '<html>spa-shell-marker</html>' > "$A2/stats_index.html"
mk_script "$A2/stats_cgi.sh" <<'CGI'
#!/bin/sh
echo "Content-Type: text/plain; charset=utf-8"
echo
echo "method=$REQUEST_METHOD"
echo "query=$QUERY_STRING"
echo "api_json=${API_JSON:-}"
echo "cwd=$(pwd)"
if [ "$REQUEST_METHOD" = "POST" ]; then
  body=$(dd bs=1 count="$CONTENT_LENGTH" 2>/dev/null)
  echo "body=$body"
fi
CGI
mk_script "$A2/stats_update.sh" <<'CGI'
#!/bin/sh
echo "Status: 202 Accepted"
echo "Content-Type: text/plain; charset=utf-8"
echo
echo "action=${MST_UPDATE_ACTION:-}"
echo "method=$REQUEST_METHOD"
CGI
mk_script "$A2/stats_config.sh" <<'CGI'
#!/bin/sh
echo "Content-Type: text/plain; charset=utf-8"
echo
echo "config_action=${MST_CONFIG_ACTION:-}"
CGI
PORT2=$((BASE_PORT + 1))
PID2=$(start_server "$W2" "$PORT2" "$A2")
CLEANUP_PIDS="$CLEANUP_PIDS $PID2"
wait_up "$PORT2" || fail "сервер (часть 2) не поднялся"

OUT=$(curl -s -m 2 "http://127.0.0.1:$PORT2/api/settings?a=1")
echo "$OUT" | grep -q "method=GET" || fail "API GET: неверный REQUEST_METHOD ($OUT)"
echo "$OUT" | grep -q "query=a=1" || fail "API GET: QUERY_STRING не передан ($OUT)"
echo "$OUT" | grep -q "api_json=1" || fail "/api/settings: нет API_JSON=1 ($OUT)"
echo "$OUT" | grep -qF "cwd=$A2" || fail "API: скрипт должен запускаться из каталога приложения ($OUT)"
OUT=$(curl -s -m 2 -X POST --data "node_cap=5" "http://127.0.0.1:$PORT2/api/settings")
echo "$OUT" | grep -q "body=node_cap=5" || fail "API POST: тело запроса не дошло до скрипта ($OUT)"

code=$(command curl -s -m 2 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT2/api/settings")
[ "$code" = "401" ] || fail "API без сессии должен вернуть 401, получено $code"
code=$(command curl -s -m 2 -o /dev/null -w '%{http_code}' -u admin:hunter2 "http://127.0.0.1:$PORT2/api/settings")
[ "$code" = "401" ] || fail "Basic Auth не должен обходить вход по сессии, получено $code"
code=$(command curl -s -m 2 -o /dev/null -w '%{http_code}' -H "Cookie: $AUTH_COOKIE" -X POST "http://127.0.0.1:$PORT2/api/settings")
[ "$code" = "403" ] || fail "POST без CSRF должен вернуть 403, получено $code"
code=$(command curl -s -m 2 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT2/")
[ "$code" = "302" ] || fail "страница без сессии должна перенаправляться на вход, получено $code"

code=$(curl -s -m 2 -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:$PORT2/api/updates/check")
[ "$code" = "202" ] || fail "заголовок Status из скрипта не стал кодом ответа, получено $code"
for a in check status prepare apply discard; do
  OUT=$(curl -s -m 2 "http://127.0.0.1:$PORT2/api/updates/$a")
  echo "$OUT" | grep -q "action=$a" || fail "/api/updates/$a: MST_UPDATE_ACTION не проброшен ($OUT)"
done
OUT=$(curl -s -m 2 "http://127.0.0.1:$PORT2/api/config/backups")
echo "$OUT" | grep -q "config_action=backups" || fail "/api/config/backups: MST_CONFIG_ACTION не проброшен ($OUT)"

# скрипта нет - понятная ошибка, а не SPA-страница
code=$(curl -s -m 2 -o "$TEST_ROOT/body2" -w '%{http_code}' "http://127.0.0.1:$PORT2/api/run")
[ "$code" = "503" ] || fail "/api/run без stats_run.sh: ожидался 503, получено $code"
grep -q '"script_missing"' "$TEST_ROOT/body2" || fail "/api/run без stats_run.sh: нет error=script_missing"

code=$(curl -s -m 2 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT2/api/whatever")
[ "$code" = "501" ] || fail "/api/whatever: должен отвечать 501, получено $code"

echo "test_stats_httpd_py.sh: часть 2 (API на скриптах) OK" >&2

# =========================================================================
# Часть 3: данные /api/stats и /api/progress - из docroot; файла нет -
# "{}" (фронтенд трактует как "данных ещё нет")
# =========================================================================
printf '{"marker":"stats-json-marker"}' > "$W2/stats.json"
curl -s -m 2 "http://127.0.0.1:$PORT2/api/stats" | grep -q "stats-json-marker" || fail "/api/stats не отдаёт stats.json"
CT3=$(curl -s -m 2 -D - -o /dev/null "http://127.0.0.1:$PORT2/api/stats" | tr -d '\r' | grep -i '^Content-Type:')
echo "$CT3" | grep -qi "application/json" || fail "/api/stats: Content-Type [$CT3]"
OUT=$(curl -s -m 2 -w ' %{http_code}' "http://127.0.0.1:$PORT2/api/progress")
[ "$OUT" = "{} 200" ] || fail "/api/progress без файла: ожидалось '{} 200', получено [$OUT]"
code=$(curl -s -m 2 -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:$PORT2/api/stats")
[ "$code" = "405" ] || fail "POST /api/stats: ожидался 405, получено $code"
code=$(command curl -s -m 2 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT2/api/stats")
[ "$code" = "401" ] || fail "/api/stats без сессии: ожидался 401, получено $code"

echo "test_stats_httpd_py.sh: часть 3 (данные) OK" >&2

# =========================================================================
# Часть 4: убийство процесса-слушателя не обрывает уже начатый ответ
#          (supervisor перезапускает сервер из-под принятого запроса)
# =========================================================================
W4=$TEST_ROOT/w4/www; A4=$TEST_ROOT/w4/app
mkdir -p "$W4" "$A4"
mk_script "$A4/stats_run.sh" <<'CGI'
#!/bin/sh
sleep 1
echo "Content-Type: text/plain; charset=utf-8"
echo
echo "готово-после-паузы"
CGI
PORT4=$((BASE_PORT + 3))
PID4=$(start_server "$W4" "$PORT4" "$A4")
wait_up "$PORT4" || fail "сервер (часть 4) не поднялся"

curl -s -m 5 "http://127.0.0.1:$PORT4/api/run" > "$TEST_ROOT/resp4.txt" &
CURL_PID=$!
sleep 0.3
kill "$PID4" 2>/dev/null || fail "не удалось послать kill слушателю во время запроса"
wait "$CURL_PID" 2>/dev/null || true

grep -q "готово-после-паузы" "$TEST_ROOT/resp4.txt" \
  || fail "self-restart: убийство слушателя оборвало уже начатый ответ (модель должна быть fork-per-connection)"

echo "test_stats_httpd_py.sh: часть 4 (fork-per-connection переживает kill слушателя) OK" >&2

# =========================================================================
# Часть 5: чтение тела POST-запроса не должно висеть бесконечно, если
# клиент заявил Content-Length больше реально присланного и держит
# соединение открытым - на реальном роутере это вешало весь процесс.
# Подставляем маленький STATS_HTTPD_READ_TIMEOUT вместо 30 с.
# =========================================================================
W7=$TEST_ROOT/w7/www; A7=$TEST_ROOT/w7/app
mkdir -p "$W7" "$A7"
mk_script "$A7/stats_run.sh" <<'CGI'
#!/bin/sh
echo "Content-Type: text/plain; charset=utf-8"
echo
echo "method=$REQUEST_METHOD"
CGI

PORT7=$((BASE_PORT + 6))
STATS_HTTPD_READ_TIMEOUT=1
export STATS_HTTPD_READ_TIMEOUT
PID7=$(start_server "$W7" "$PORT7" "$A7")
unset STATS_HTTPD_READ_TIMEOUT
CLEANUP_PIDS="$CLEANUP_PIDS $PID7"
wait_up "$PORT7" || fail "сервер (часть 5) не поднялся"

python3 - "$PORT7" "$AUTH_COOKIE" "$AUTH_CSRF" <<'RAWSOCK' &
import socket, sys, time
port = int(sys.argv[1])
cookie, csrf = sys.argv[2], sys.argv[3]
s = socket.create_connection(("127.0.0.1", port), timeout=5)
req = (
    "POST /api/run HTTP/1.1\r\n"
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
sleep 1

# Пока "медленный" клиент висит на соединении, независимый запрос должен
# пройти сразу.
code=$(curl -s -m 3 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT7/api/run")
[ "$code" != "000" ] || fail "часть 5: сервер завис из-за одного клиента с незавершённым телом запроса (регрессия бага с реального роутера)"

wait "$SLOWCLIENT_PID" 2>/dev/null || true

echo "test_stats_httpd_py.sh: часть 5 (таймаут на чтение тела запроса) OK" >&2

# =========================================================================
# Часть 6: дочерний процесс (fork на каждое соединение, см. ForkingHTTPServer
# в шапке файла) должен закрывать СВОЙ унаследованный слушающий сокет -
# иначе, пока ребёнок жив (например завис на чтении тела запроса - часть 5
# выше), порт остаётся занятым даже после того, как supervisor убил
# родительский процесс (перезапуск на новый адрес или после setup.sh). Именно так на реальном роутере
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
python3 - "$SCRIPT" <<'MOCKFORK' || fail "часть 6: дочерний процесс не закрывает унаследованный слушающий сокет (регрессия EADDRINUSE после перезапуска - см. CHANGELOG)"
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
    print("часть 6: дочерний процесс не закрыл слушающий сокет", file=sys.stderr)
    sys.exit(1)
print("часть 6: OK", file=sys.stderr)
MOCKFORK

echo "test_stats_httpd_py.sh: часть 6 (дочерний процесс закрывает слушающий сокет) OK" >&2

# =========================================================================
# Часть 7: остановка слушателя (TERM - так его гасит supervisor при
# "S80speedtest-stats stop", в т.ч. из uninstall.sh) должна закрывать и
# ПРОСТАИВАЮЩИЕ keep-alive-соединения: открытая вкладка опрашивает
# /api/progress каждые 2 с, и без этого веб-сервис "работал" бы для
# браузера и после удаления проекта.
# =========================================================================
W9=$TEST_ROOT/w9/www; A9=$TEST_ROOT/w9/app
mkdir -p "$W9" "$A9"
printf 'body{}' > "$A9/stats_style.css"
PORT9=$((BASE_PORT + 8))
PID9=$(start_server "$W9" "$PORT9" "$A9")
CLEANUP_PIDS="$CLEANUP_PIDS $PID9"
wait_up "$PORT9" || fail "сервер (часть 7) не поднялся"

python3 - "$PORT9" "$PID9" "$AUTH_COOKIE" <<'KEEPALIVE' || fail "часть 7: keep-alive-соединение пережило остановку веб-сервиса"
import http.client, os, signal, sys, time
port, pid, cookie = int(sys.argv[1]), int(sys.argv[2]), sys.argv[3]
c = http.client.HTTPConnection("127.0.0.1", port, timeout=3)
hdr = {"Cookie": cookie}
c.request("GET", "/style.css", headers=hdr)
r = c.getresponse(); r.read()
assert r.status == 200, r.status
os.kill(pid, signal.SIGTERM)
time.sleep(1)
try:
    c.request("GET", "/style.css", headers=hdr)
    r = c.getresponse(); r.read()
except (OSError, http.client.HTTPException):
    sys.exit(0)
print("ответ %s по старому соединению после остановки" % r.status, file=sys.stderr)
sys.exit(1)
KEEPALIVE

echo "test_stats_httpd_py.sh: часть 7 (остановка закрывает keep-alive-соединения) OK" >&2

echo "test_stats_httpd_py.sh: OK (все части)"
