#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
SCRIPT=$ROOT/speedtest-runtime/speedtest2.sh
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/stats-httpd-test.XXXXXX")

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

# порт берём из pid текущего процесса - разные прогоны теста меньше мешают друг другу
BASE_PORT=$((20000 + ($$ % 5000)))

# Python-сервер всегда требует сессию. Создаём одну общую тестовую сессию.
STATS_AUTH_STATE_DIR=$TEST_ROOT/auth-state
STATS_AUTH_RUNTIME_DIR=$TEST_ROOT/auth-runtime
export STATS_AUTH_STATE_DIR STATS_AUTH_RUNTIME_DIR
if command -v python3 >/dev/null 2>&1; then
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
else
  AUTH_COOKIE=
  AUTH_CSRF=
fi

curl() {
  command curl -H "Cookie: $AUTH_COOKIE" -H "X-CSRF-Token: $AUTH_CSRF" "$@"
}

# --- STATS_HTTP_ENABLE=0: ensure_stats_httpd() ничего не поднимает и не падает ---
W1=$TEST_ROOT/w1
mkdir -p "$W1"
(
  MST_LIB_ONLY=1 . "$SCRIPT"
  DIR=$W1
  ENV=$W1/speedtest2.env
  STATS_HTTP_ENABLE=0
  STATS_HTTP_DIR=$W1/www
  STATS_HTTP_PIDFILE=$W1/httpd.pid
  STATS_HTTP_LOG=$W1/httpd.log
  STATS_HTTP_CONF=$W1/httpd.conf
  STATS_CGI_SOURCE=$ROOT/web/stats_cgi.sh
  STATS_CGI_SCRIPT=$W1/www/cgi-bin/config
  RUN_LOG=$W1/run.log
  ensure_stats_httpd
  # [ ... ] && exit N как последняя команда подшелла вернул бы код самого
  # [ ], а не N, когда условие ложно (нужный/проходящий случай) - под set -eu
  # это тихо убило бы подшелл ДО exit N. Поэтому - негация + || и явный exit 0.
  [ ! -f "$STATS_HTTP_PIDFILE" ] || exit 71
  [ ! -d "$STATS_HTTP_DIR" ] || exit 72
  exit 0
)
rc=$?
case $rc in
  0) ;;
  71) fail "ensure_stats_httpd: wrote a pidfile while disabled" ;;
  72) fail "ensure_stats_httpd: created the serve directory while disabled" ;;
  *) fail "disabled-case subshell failed unexpectedly (rc=$rc)" ;;
esac

# --- бинарник httpd отсутствует: WARN в лог, без падения ---
W2=$TEST_ROOT/w2
mkdir -p "$W2"
(
  MST_LIB_ONLY=1 . "$SCRIPT"
  # STATS_HTTPD_PY на несуществующий путь вместо подмены PATH целиком -
  # пустой PATH ломает mkdir/date и прочие внешние команды, которыми
  # пользуются say() и другие функции скрипта, и даёт не ту ошибку.
  STATS_HTTPD_PY=/nonexistent/nope-httpd.py
  DIR=$W2
  ENV=$W2/speedtest2.env
  STATS_HTTP_ENABLE=1
  STATS_HTTP_DIR=$W2/www
  STATS_HTTP_PIDFILE=$W2/httpd.pid
  STATS_HTTP_LOG=$W2/httpd.log
  STATS_HTTP_CONF=$W2/httpd.conf
  STATS_CGI_SOURCE=$ROOT/web/stats_cgi.sh
  STATS_CGI_SCRIPT=$W2/www/cgi-bin/config
  RUN_LOG=$W2/run.log
  ensure_stats_httpd
  [ ! -f "$STATS_HTTP_PIDFILE" ] || exit 73
  grep -q "не найден" "$RUN_LOG" || exit 74
  exit 0
)
rc=$?
case $rc in
  0) ;;
  73) fail "ensure_stats_httpd: wrote a pidfile despite missing httpd binary" ;;
  74) fail "ensure_stats_httpd: missing-binary warning was not logged" ;;
  *) fail "missing-binary subshell failed unexpectedly (rc=$rc)" ;;
esac

# --- stats_httpd_advertise_host(): какой адрес показывать оператору в
#     консоли рядом с "OK: веб-сервис статистики ..." - "0.0.0.0" самому
#     не откроешь в браузере, нужен реальный IP роутера ---
(
  MST_LIB_ONLY=1 . "$SCRIPT"
  result=$(stats_httpd_advertise_host "192.168.10.1")
  [ "$result" = "192.168.10.1" ] || exit 75
  exit 0
)
rc=$?
case $rc in
  0) ;;
  75) fail "stats_httpd_advertise_host: конкретный bind должен возвращаться как есть" ;;
  *) fail "stats_httpd_advertise_host (bind конкретный) subshell failed unexpectedly (rc=$rc)" ;;
esac

FAKEIP=$TEST_ROOT/fake-ip.sh
cat > "$FAKEIP" <<'EOF'
#!/bin/sh
echo "2: br0    inet 192.168.10.1/24 brd 192.168.10.255 scope global br0"
EOF
chmod +x "$FAKEIP"
(
  MST_LIB_ONLY=1 . "$SCRIPT"
  STATS_HTTPD_IP_CMD=$FAKEIP
  result=$(stats_httpd_advertise_host "0.0.0.0")
  [ "$result" = "192.168.10.1" ] || exit 76
  exit 0
)
rc=$?
case $rc in
  0) ;;
  76) fail "stats_httpd_advertise_host: 0.0.0.0 с доступным ip-детектором должен вернуть найденный LAN-адрес" ;;
  *) fail "stats_httpd_advertise_host (fake ip) subshell failed unexpectedly (rc=$rc)" ;;
esac

(
  MST_LIB_ONLY=1 . "$SCRIPT"
  STATS_HTTPD_IP_CMD=/nonexistent/nope-ip
  result=$(stats_httpd_advertise_host "0.0.0.0")
  [ -z "$result" ] || exit 77
  exit 0
)
rc=$?
case $rc in
  0) ;;
  77) fail "stats_httpd_advertise_host: 0.0.0.0 без ip-детектора должен вернуть пусто" ;;
  *) fail "stats_httpd_advertise_host (нет ip) subshell failed unexpectedly (rc=$rc)" ;;
esac

# Несколько "scope global" адресов сразу (LAN-мост + WAN/VPN-туннель
# xkeen/mihomo) - реальный случай, из-за которого раньше в лог попадал
# произвольный адрес вместо LAN (см. CHANGELOG). Частный диапазон должен
# выигрывать независимо от того, в каком порядке "ip" их напечатал.
FAKEIP_MULTI=$TEST_ROOT/fake-ip-multi.sh
cat > "$FAKEIP_MULTI" <<'EOF'
#!/bin/sh
echo "3: tun0    inet 198.51.100.11/32 scope global tun0"
echo "2: br0    inet 192.168.10.1/24 brd 192.168.10.255 scope global br0"
EOF
chmod +x "$FAKEIP_MULTI"
(
  MST_LIB_ONLY=1 . "$SCRIPT"
  STATS_HTTPD_IP_CMD=$FAKEIP_MULTI
  result=$(stats_httpd_advertise_host "0.0.0.0")
  [ "$result" = "192.168.10.1" ] || exit 78
  exit 0
)
rc=$?
case $rc in
  0) ;;
  78) fail "stats_httpd_advertise_host: LAN-адрес (192.168.10.1) должен выигрывать у не-частного (198.51.100.11), даже если идёт вторым в выводе ip" ;;
  *) fail "stats_httpd_advertise_host (multi, LAN вторым) subshell failed unexpectedly (rc=$rc)" ;;
esac

FAKEIP_MULTI2=$TEST_ROOT/fake-ip-multi2.sh
cat > "$FAKEIP_MULTI2" <<'EOF'
#!/bin/sh
echo "2: br0    inet 10.0.0.1/24 brd 10.0.0.255 scope global br0"
echo "3: tun0    inet 198.51.100.11/32 scope global tun0"
EOF
chmod +x "$FAKEIP_MULTI2"
(
  MST_LIB_ONLY=1 . "$SCRIPT"
  STATS_HTTPD_IP_CMD=$FAKEIP_MULTI2
  result=$(stats_httpd_advertise_host "0.0.0.0")
  [ "$result" = "10.0.0.1" ] || exit 79
  exit 0
)
rc=$?
case $rc in
  0) ;;
  79) fail "stats_httpd_advertise_host: LAN-адрес (10.0.0.1) должен выигрывать, даже если идёт первым (проверка, что фильтр не ломает обычный порядок)" ;;
  *) fail "stats_httpd_advertise_host (multi, LAN первым) subshell failed unexpectedly (rc=$rc)" ;;
esac

# Ни одного частного адреса нет вовсе (нетипичная сеть) - как и раньше,
# берём первый попавшийся, лишь бы не остаться совсем без адреса.
FAKEIP_NOPRIV=$TEST_ROOT/fake-ip-nopriv.sh
cat > "$FAKEIP_NOPRIV" <<'EOF'
#!/bin/sh
echo "3: tun0    inet 198.51.100.11/32 scope global tun0"
echo "4: tun1    inet 203.0.113.5/32 scope global tun1"
EOF
chmod +x "$FAKEIP_NOPRIV"
(
  MST_LIB_ONLY=1 . "$SCRIPT"
  STATS_HTTPD_IP_CMD=$FAKEIP_NOPRIV
  result=$(stats_httpd_advertise_host "0.0.0.0")
  [ "$result" = "198.51.100.11" ] || exit 80
  exit 0
)
rc=$?
case $rc in
  0) ;;
  80) fail "stats_httpd_advertise_host: без частных адресов должен вернуться первый попавшийся (198.51.100.11), не пусто" ;;
  *) fail "stats_httpd_advertise_host (без частных) subshell failed unexpectedly (rc=$rc)" ;;
esac

echo "test_stats_httpd.sh: stats_httpd_advertise_host() OK" >&2

# --- обязательный Python-сервер умеет чистые URL, API и общую авторизацию ---
have_python3=1
command -v python3 >/dev/null 2>&1 || have_python3=0
if [ "$have_python3" = 1 ]; then
  W2B=$TEST_ROOT/w2b
  mkdir -p "$W2B"
  PORT_FB=$((BASE_PORT + 10))
  PIDFILE_FB=$W2B/httpd.pid
  (
    MST_LIB_ONLY=1 . "$SCRIPT"
    STATS_HTTPD_PY=$ROOT/web/stats_httpd.py
    DIR=$W2B
    ENV=$W2B/speedtest2.env
    STATS_HTTP_ENABLE=1
    STATS_HTTP_BIND=127.0.0.1
    STATS_HTTP_PORT=$PORT_FB
    STATS_HTTP_DIR=$W2B/www
    STATS_HTTP_PIDFILE=$PIDFILE_FB
    STATS_HTTP_LOG=$W2B/httpd.log
    STATS_HTTP_CONF=$W2B/httpd.conf
    STATS_CGI_SOURCE=$ROOT/web/stats_cgi.sh
    STATS_CGI_SCRIPT=$W2B/www/cgi-bin/config
    RUN_LOG=$W2B/run.log
    ensure_stats_httpd
  )
  PID_FB=$(cat "$PIDFILE_FB" 2>/dev/null || true)
  [ -n "$PID_FB" ] || fail "python3-приоритет: pidfile not written when python3 backend is available"
  CLEANUP_PIDS="$CLEANUP_PIDS $PID_FB"
  kill -0 "$PID_FB" 2>/dev/null || fail "python3-приоритет: процесс из pidfile не жив"
  grep -qF "http://127.0.0.1:$PORT_FB/stats" "$W2B/run.log" \
    || fail "python3-приоритет: в OK-сообщении нет адреса для оператора"

  echo "python3-основной" > "$W2B/www/stats.html"
  i=0
  while [ $i -lt 20 ]; do
    curl -s -m 1 "http://127.0.0.1:$PORT_FB/stats.html" 2>/dev/null | grep -q python3-основной && break
    sleep 0.2; i=$((i + 1))
  done
  curl -s -m 1 "http://127.0.0.1:$PORT_FB/stats.html" 2>/dev/null | grep -q python3-основной \
    || fail "python3-приоритет: основной сервер (python3) не отдаёт файл на настроенном порту"
  # чистый URL/SPA-фоллбек, API-алиасы и т.п. - уже исчерпывающе проверены
  # в tests/test_stats_httpd_py.sh (части 5-6), здесь проверяем только сам
  # выбор backend'а.

  # STATS_HTTP_ENABLE=0 должен останавливать и этот сервер тоже
  (
    MST_LIB_ONLY=1 . "$SCRIPT"
    STATS_HTTPD_PY=$ROOT/web/stats_httpd.py
    DIR=$W2B
    ENV=$W2B/speedtest2.env
    STATS_HTTP_ENABLE=0
    STATS_HTTP_DIR=$W2B/www
    STATS_HTTP_PIDFILE=$PIDFILE_FB
    STATS_HTTP_LOG=$W2B/httpd.log
    STATS_HTTP_CONF=$W2B/httpd.conf
    STATS_CGI_SOURCE=$ROOT/web/stats_cgi.sh
    STATS_CGI_SCRIPT=$W2B/www/cgi-bin/config
    RUN_LOG=$W2B/run.log
    ensure_stats_httpd
  )
  kill -0 "$PID_FB" 2>/dev/null && fail "python3-приоритет: STATS_HTTP_ENABLE=0 не остановил процесс"
  [ -f "$PIDFILE_FB" ] && fail "python3-приоритет: STATS_HTTP_ENABLE=0 не удалил pid-файл"

  echo "test_stats_httpd.sh: обязательный Python-сервер OK" >&2
else
  echo "test_stats_httpd.sh: python3 недоступен, проверка обязательного Python-сервера пропущена" >&2
fi

echo "test_stats_httpd.sh: OK"
