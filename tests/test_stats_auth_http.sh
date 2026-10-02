#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
TMP=${TMPDIR:-/tmp}/mihomo-auth-http.$$
WWW=$TMP/www
STATE=$TMP/state
RUNTIME=$TMP/runtime
PORT=$((38000 + ($$ % 2000)))
PID=

cleanup() {
    [ -z "$PID" ] || kill "$PID" 2>/dev/null || true
    [ -z "$PID" ] || wait "$PID" 2>/dev/null || true
    rm -rf "$TMP"
}
trap cleanup EXIT INT TERM
fail() { echo "FAIL: $*" >&2; exit 1; }

mkdir -p "$WWW/cgi-bin"
printf '<!doctype html><div>auth-spa-shell</div>\n' > "$WWW/index.html"
printf 'body{}\n' > "$WWW/style.css"
printf 'console.log("app")\n' > "$WWW/app.js"
cat > "$WWW/cgi-bin/config" <<'CGI'
#!/bin/sh
printf 'Content-Type: application/json; charset=utf-8\n\n'
printf '{"method":"%s"}\n' "$REQUEST_METHOD"
CGI
cat > "$WWW/cgi-bin/run" <<'CGI'
#!/bin/sh
printf 'Content-Type: application/json; charset=utf-8\n\n'
printf '{"started":true}\n'
CGI
chmod +x "$WWW/cgi-bin/config" "$WWW/cgi-bin/run"
printf '{"ok":true}\n' > "$WWW/stats.json"

start_server() {
    STATS_AUTH_STATE_DIR=$STATE STATS_AUTH_RUNTIME_DIR=$RUNTIME \
        python3 "$ROOT/web/stats_httpd.py" -p "127.0.0.1:$PORT" -h "$WWW" -f \
        >"$TMP/server.log" 2>&1 &
    PID=$!
    n=0
    while [ "$n" -lt 50 ]; do
        command curl -s -o /dev/null "http://127.0.0.1:$PORT/style.css" && return 0
        sleep 0.05
        n=$((n + 1))
    done
    cat "$TMP/server.log" >&2
    fail "сервер не поднялся"
}

json_field() {
    python3 -c 'import json,sys; print(json.load(sys.stdin)[sys.argv[1]])' "$1"
}

start_server
BASE=http://127.0.0.1:$PORT

# Без credentials и setup-code сервер закрыт и объясняет состояние только API статуса.
code=$(command curl -s -o "$TMP/body" -w '%{http_code}' "$BASE/api/auth/status")
[ "$code" = 503 ] || fail "неинициализированный status должен вернуть 503, получено $code"
grep -q 'uninitialized' "$TMP/body" || fail "нет режима uninitialized"
code=$(command curl -s -o /dev/null -w '%{http_code}' "$BASE/api/stats")
[ "$code" = 503 ] || fail "данные открыты до инициализации: $code"
code=$(command curl -s -o /dev/null -w '%{http_code}' "$BASE/stats")
[ "$code" = 503 ] || fail "страница открыта до инициализации: $code"
code=$(command curl -s -o /dev/null -w '%{http_code}' "$BASE/app.js")
[ "$code" = 200 ] || fail "app.js нужен экрану настройки: $code"
code=$(command curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/app.js")
[ "$code" = 401 ] || fail "POST к публичному ресурсу без сессии должен вернуть 401: $code"

SETUP_CODE=$(python3 - "$ROOT/web/stats_auth.py" "$STATE" "$RUNTIME" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("stats_auth", sys.argv[1])
mod = importlib.util.module_from_spec(spec); spec.loader.exec_module(mod)
print(mod.reset_auth(sys.argv[2], sys.argv[3]))
PY
)

STATUS=$(command curl -s "$BASE/api/auth/status")
[ "$(printf '%s' "$STATUS" | json_field mode)" = setup ] || fail "после reset должен быть setup"
code=$(command curl -s -o /dev/null -w '%{http_code}' "$BASE/stats")
[ "$code" = 302 ] || fail "в setup-режиме /stats должен перенаправляться: $code"
loc=$(command curl -s -D - -o /dev/null "$BASE/stats" | tr -d '\r' | awk 'tolower($1)=="location:" {print $2}')
[ "$loc" = /setup ] || fail "ожидался Location /setup, получено $loc"

code=$(command curl -s -o "$TMP/bad" -w '%{http_code}' -H 'Content-Type: application/json' \
    --data '{"code":"wrong","username":"admin","password":"secret","password_confirm":"secret"}' \
    "$BASE/api/auth/setup")
[ "$code" = 401 ] || fail "неверный setup-код должен дать 401, получено $code"

auth_json=$(printf '{"code":"%s","username":"admin","password":"secret","password_confirm":"secret"}' "$SETUP_CODE")
code=$(command curl -s -D "$TMP/setup.headers" -o "$TMP/setup.body" -w '%{http_code}' \
    -H 'Content-Type: application/json' --data "$auth_json" "$BASE/api/auth/setup")
[ "$code" = 200 ] || { cat "$TMP/setup.body" >&2; fail "setup не завершился: $code"; }
COOKIE=$(tr -d '\r' < "$TMP/setup.headers" | awk -F': ' 'tolower($1)=="set-cookie" {sub(/;.*/, "", $2); print $2}')
[ -n "$COOKIE" ] || fail "setup не выдал cookie"
grep -qi '^Set-Cookie: mst_session=.*HttpOnly.*SameSite=Strict' "$TMP/setup.headers" || fail "нет безопасных флагов cookie"
CSRF=$(json_field csrf < "$TMP/setup.body")
[ -n "$CSRF" ] || fail "setup не вернул CSRF"
[ ! -e "$STATE/setup-code.sha256" ] || fail "setup-code не удалён"
! grep -R -q 'secret' "$STATE" || fail "пароль записан открытым текстом"

code=$(command curl -s -o /dev/null -w '%{http_code}' "$BASE/api/stats")
[ "$code" = 401 ] || fail "API без сессии должен вернуть 401: $code"
code=$(command curl -s -o /dev/null -w '%{http_code}' "$BASE/stats")
[ "$code" = 302 ] || fail "страница без сессии должна перенаправляться: $code"
loc=$(command curl -s -D - -o /dev/null "$BASE/stats" | tr -d '\r' | awk 'tolower($1)=="location:" {print $2}')
[ "$loc" = /login ] || fail "ожидался Location /login, получено $loc"
code=$(command curl -s -o /dev/null -w '%{http_code}' -H "Cookie: $COOKIE" "$BASE/api/stats")
[ "$code" = 200 ] || fail "сессия не открывает API: $code"

code=$(command curl -s -o /dev/null -w '%{http_code}' -H "Cookie: $COOKIE" -X POST "$BASE/api/run")
[ "$code" = 403 ] || fail "POST без CSRF должен вернуть 403: $code"
code=$(command curl -s -o /dev/null -w '%{http_code}' -H "Cookie: $COOKIE" -H "X-CSRF-Token: $CSRF" -X POST "$BASE/api/run")
[ "$code" = 200 ] || fail "POST с CSRF должен пройти: $code"
code=$(command curl -s -o /dev/null -w '%{http_code}' -H "Cookie: $COOKIE" -X POST "$BASE/app.js")
[ "$code" = 403 ] || fail "POST к публичному ресурсу без CSRF должен вернуть 403: $code"
code=$(command curl -s -o /dev/null -w '%{http_code}' -H "Cookie: $COOKIE" -H "X-CSRF-Token: $CSRF" -X POST "$BASE/app.js")
[ "$code" = 405 ] || fail "POST к публичному ресурсу с CSRF должен вернуть 405: $code"

code=$(command curl -s -D "$TMP/logout.headers" -o /dev/null -w '%{http_code}' \
    -H "Cookie: $COOKIE" -H "X-CSRF-Token: $CSRF" -X POST "$BASE/api/auth/logout")
[ "$code" = 200 ] || fail "logout не сработал: $code"
grep -qi '^Set-Cookie: mst_session=.*Max-Age=0' "$TMP/logout.headers" || fail "logout не очищает cookie"
code=$(command curl -s -o /dev/null -w '%{http_code}' -H "Cookie: $COOKIE" "$BASE/api/stats")
[ "$code" = 401 ] || fail "старая сессия действует после logout: $code"

code=$(command curl -s -o "$TMP/login.bad" -w '%{http_code}' -H 'Content-Type: application/json' \
    --data '{"username":"admin","password":"wrong"}' "$BASE/api/auth/login")
[ "$code" = 401 ] || fail "неверный пароль должен дать 401: $code"
code=$(command curl -s -D "$TMP/login.headers" -o "$TMP/login.body" -w '%{http_code}' \
    -H 'Content-Type: application/json' --data '{"username":"admin","password":"secret"}' "$BASE/api/auth/login")
[ "$code" = 200 ] || fail "вход не сработал: $code"
grep -q 'csrf' "$TMP/login.body" || fail "вход не вернул CSRF"

code=$(python3 - "$BASE/api/auth/login" <<'PY'
import urllib.request, urllib.error, sys
req = urllib.request.Request(sys.argv[1], data=b"x" * 17000, headers={"Content-Type":"application/json"}, method="POST")
try:
    urllib.request.urlopen(req, timeout=3)
    print(200)
except urllib.error.HTTPError as e:
    print(e.code)
PY
)
[ "$code" = 413 ] || fail "слишком большое JSON-тело должно дать 413: $code"

# Unicode-логин разрешён ядром и должен работать через HTTP без TypeError.
UNICODE_CODE=$(python3 - "$ROOT/web/stats_auth.py" "$STATE" "$RUNTIME" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("stats_auth", sys.argv[1])
mod = importlib.util.module_from_spec(spec); spec.loader.exec_module(mod)
print(mod.reset_auth(sys.argv[2], sys.argv[3]))
PY
)
unicode_json=$(printf '{"code":"%s","username":"админ","password":"секрет","password_confirm":"секрет"}' "$UNICODE_CODE")
code=$(command curl -s -D "$TMP/unicode.headers" -o "$TMP/unicode.body" -w '%{http_code}' \
    -H 'Content-Type: application/json' --data "$unicode_json" "$BASE/api/auth/setup")
[ "$code" = 200 ] || fail "setup с Unicode-логином не сработал: $code"
UNICODE_COOKIE=$(tr -d '\r' < "$TMP/unicode.headers" | awk -F': ' 'tolower($1)=="set-cookie" {sub(/;.*/, "", $2); print $2}')
UNICODE_CSRF=$(json_field csrf < "$TMP/unicode.body")
command curl -s -o /dev/null -H "Cookie: $UNICODE_COOKIE" -H "X-CSRF-Token: $UNICODE_CSRF" -X POST "$BASE/api/auth/logout"
code=$(command curl -s -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' \
    --data '{"username":"админ","password":"секрет"}' "$BASE/api/auth/login")
[ "$code" = 200 ] || fail "вход с Unicode-логином не сработал: $code"

# Login/setup создают сессию под auth.lock: параллельный reset обязан
# выполниться после них и очистить даже только что созданную сессию.
python3 - "$ROOT/web/stats_auth.py" "$TMP/race" <<'PY'
import importlib.util, os, sys, threading, time
spec = importlib.util.spec_from_file_location("stats_auth", sys.argv[1])
mod = importlib.util.module_from_spec(spec); spec.loader.exec_module(mod)
base = sys.argv[2]

def dirs(name):
    root = os.path.join(base, name)
    os.makedirs(root, exist_ok=True)
    return os.path.join(root, "state"), os.path.join(root, "runtime")

state, runtime = dirs("login")
mod.write_credentials(state, "админ", "секрет", iterations=mod.PBKDF2_MIN_ITERATIONS)
entered, release, result = threading.Event(), threading.Event(), {}
original_verify = mod.verify_password
def slow_verify(password, record):
    entered.set(); release.wait(3)
    return original_verify(password, record)
mod.verify_password = slow_verify
login = threading.Thread(target=lambda: result.setdefault("session", mod.authenticate_and_create_session(state, runtime, "админ", "секрет")))
login.start(); assert entered.wait(2)
reset = threading.Thread(target=lambda: mod.reset_auth(state, runtime))
reset.start(); time.sleep(0.05); assert reset.is_alive(), "reset не дождался login auth.lock"
release.set(); login.join(3); reset.join(3)
assert not login.is_alive() and not reset.is_alive()
assert mod.load_session(runtime, result["session"]["id"], touch=False) is None
mod.verify_password = original_verify

state, runtime = dirs("setup")
code = mod.reset_auth(state, runtime)
entered, release, result = threading.Event(), threading.Event(), {}
original_create = mod.create_session
def slow_create(runtime_dir, username, now=None):
    entered.set(); release.wait(3)
    return original_create(runtime_dir, username, now=now)
mod.create_session = slow_create
setup = threading.Thread(target=lambda: result.setdefault("session", mod.complete_setup_and_create_session(state, runtime, code, "admin", "secret", iterations=mod.PBKDF2_MIN_ITERATIONS)))
setup.start(); assert entered.wait(2)
reset = threading.Thread(target=lambda: mod.reset_auth(state, runtime))
reset.start(); time.sleep(0.05); assert reset.is_alive(), "reset не дождался setup auth.lock"
release.set(); setup.join(3); reset.join(3)
assert not setup.is_alive() and not reset.is_alive()
assert mod.load_session(runtime, result["session"]["id"], touch=False) is None
PY

echo "test_stats_auth_http.sh: OK"
