#!/bin/sh
set -eu
# Тесты write_stats_system() (speedtest2.sh, сиблинг write_stats_run()) -
# копирует CGI-обёртку футера веб-интерфейса (stats_system.sh) в раздаваемый
# каталог как cgi-bin/system и делает её исполняемой. По образцу проверки
# write_stats_run внутри ensure_stats_httpd() из test_stats_httpd.sh (случай
# "бинарник httpd отсутствует") - короче, только "файл скопирован и
# исполняем после ensure_stats_httpd()" / "WARN без исходника, без падения".

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
SCRIPT=$ROOT/speedtest-runtime/speedtest2.sh
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/stats-update-service-test.XXXXXX")
trap 'rm -rf "$TEST_ROOT"' EXIT INT TERM

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

# --- исходник stats_system.sh есть: ensure_stats_httpd() должен записать
#     cgi-bin/system и сделать его исполняемым, даже если сам HTTP-сервер
#     не поднялся (STATS_HTTPD_PY указывает на несуществующий путь - тот
#     же приём, что "бинарник httpd отсутствует" в test_stats_httpd.sh, не
#     запускает настоящий python3-процесс). Все производные пути (в т.ч.
#     STATS_SYSTEM_SCRIPT) заданы явно - как и остальные STATS_*_SCRIPT в
#     этом сценарии, чтобы не зависеть от значения по умолчанию, которое
#     ${VAR:-...} вычисляет в момент "sourcing" speedtest2.sh, раньше, чем
#     этот подшелл переопределяет DIR/STATS_HTTP_DIR ---
W1=$TEST_ROOT/w1
mkdir -p "$W1"
(
  MST_LIB_ONLY=1 . "$SCRIPT"
  STATS_HTTPD_PY=/nonexistent/nope-httpd.py
  DIR=$W1
  ENV=$W1/speedtest2.env
  STATS_HTTP_ENABLE=1
  STATS_HTTP_DIR=$W1/www
  STATS_HTTP_PIDFILE=$W1/httpd.pid
  STATS_HTTP_LOG=$W1/httpd.log
  STATS_HTTP_CONF=$W1/httpd.conf
  STATS_CGI_SOURCE=$ROOT/web/stats_cgi.sh
  STATS_CGI_SCRIPT=$W1/www/cgi-bin/config
  STATS_SYSTEM_SOURCE=$ROOT/web/stats_system.sh
  STATS_SYSTEM_SCRIPT=$W1/www/cgi-bin/system
  RUN_LOG=$W1/run.log
  ensure_stats_httpd
  [ -f "$STATS_SYSTEM_SCRIPT" ] || exit 81
  [ -x "$STATS_SYSTEM_SCRIPT" ] || exit 82
  exit 0
)
rc=$?
case $rc in
  0) ;;
  81) fail "write_stats_system: cgi-bin/system не создан после ensure_stats_httpd()" ;;
  82) fail "write_stats_system: cgi-bin/system создан, но не исполняем" ;;
  *) fail "write_stats_system (исходник есть) subshell завершился неожиданно (rc=$rc)" ;;
esac

# --- исходника stats_system.sh нет (STATS_SYSTEM_SOURCE указывает на
#     несуществующий файл) - write_stats_system() должна тихо
#     предупредить в RUN_LOG и вернуть 0, не создавая cgi-bin/system и не
#     роняя ensure_stats_httpd() целиком ---
W2=$TEST_ROOT/w2
mkdir -p "$W2"
(
  MST_LIB_ONLY=1 . "$SCRIPT"
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
  STATS_SYSTEM_SOURCE=$W2/stats_system.sh
  STATS_SYSTEM_SCRIPT=$W2/www/cgi-bin/system
  RUN_LOG=$W2/run.log
  ensure_stats_httpd
  [ ! -f "$STATS_SYSTEM_SCRIPT" ] || exit 83
  grep -q "футер веб-интерфейса недоступен" "$RUN_LOG" || exit 84
  exit 0
)
rc=$?
case $rc in
  0) ;;
  83) fail "write_stats_system: cgi-bin/system создан без исходника stats_system.sh" ;;
  84) fail "write_stats_system: WARN об отсутствующем stats_system.sh не залогирован" ;;
  *) fail "write_stats_system (исходника нет) subshell завершился неожиданно (rc=$rc)" ;;
esac

# --- STATS_SYSTEM_SOURCE/STATS_SYSTEM_SCRIPT по умолчанию: без явного
#     переопределения переменные должны сами лечь на $DIR/stats_system.sh и
#     $STATS_HTTP_DIR/cgi-bin/system (та же схема, что STATS_RUN_SOURCE/
#     STATS_RUN_SCRIPT) - DIR/STATS_HTTP_DIR экспортируются ДО "sourcing"
#     speedtest2.sh, иначе ${VAR:-...} вычислит дефолт от старого DIR ---
W3=$TEST_ROOT/w3
mkdir -p "$W3"
cp "$ROOT/web/stats_system.sh" "$W3/stats_system.sh"
chmod +x "$W3/stats_system.sh"
(
  DIR=$W3
  STATS_HTTP_DIR=$W3/www
  export DIR STATS_HTTP_DIR
  MST_LIB_ONLY=1 . "$SCRIPT"
  STATS_HTTPD_PY=/nonexistent/nope-httpd.py
  ENV=$W3/speedtest2.env
  STATS_HTTP_ENABLE=1
  STATS_HTTP_PIDFILE=$W3/httpd.pid
  STATS_HTTP_LOG=$W3/httpd.log
  STATS_HTTP_CONF=$W3/httpd.conf
  STATS_CGI_SOURCE=$ROOT/web/stats_cgi.sh
  STATS_CGI_SCRIPT=$W3/www/cgi-bin/config
  RUN_LOG=$W3/run.log
  ensure_stats_httpd
  [ -f "$W3/www/cgi-bin/system" ] || exit 85
  [ -x "$W3/www/cgi-bin/system" ] || exit 86
  exit 0
)
rc=$?
case $rc in
  0) ;;
  85) fail "write_stats_system: дефолтный STATS_SYSTEM_SOURCE (\$DIR/stats_system.sh) не подхвачен" ;;
  86) fail "write_stats_system: дефолтный STATS_SYSTEM_SCRIPT не исполняем" ;;
  *) fail "write_stats_system (дефолты) subshell завершился неожиданно (rc=$rc)" ;;
esac

echo "test_stats_system_service.sh: OK"
