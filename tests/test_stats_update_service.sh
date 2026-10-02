#!/bin/sh
set -eu
# Тесты write_stats_update() (speedtest2.sh, сиблинг write_stats_run()) -
# копирует CGI-обёртку раздела "Обновления" (stats_update.sh) в раздаваемый
# каталог как cgi-bin/update и делает её исполняемой. По образцу проверки
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

# --- исходник stats_update.sh есть: ensure_stats_httpd() должен записать
#     cgi-bin/update и сделать его исполняемым, даже если сам HTTP-сервер
#     не поднялся (STATS_HTTPD_PY указывает на несуществующий путь - тот
#     же приём, что "бинарник httpd отсутствует" в test_stats_httpd.sh, не
#     запускает настоящий python3-процесс). Все производные пути (в т.ч.
#     STATS_UPDATE_SCRIPT) заданы явно - как и остальные STATS_*_SCRIPT в
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
  STATS_UPDATE_SOURCE=$ROOT/web/stats_update.sh
  STATS_UPDATE_SCRIPT=$W1/www/cgi-bin/update
  RUN_LOG=$W1/run.log
  ensure_stats_httpd
  [ -f "$STATS_UPDATE_SCRIPT" ] || exit 71
  [ -x "$STATS_UPDATE_SCRIPT" ] || exit 72
  exit 0
)
rc=$?
case $rc in
  0) ;;
  71) fail "write_stats_update: cgi-bin/update не создан после ensure_stats_httpd()" ;;
  72) fail "write_stats_update: cgi-bin/update создан, но не исполняем" ;;
  *) fail "write_stats_update (исходник есть) subshell завершился неожиданно (rc=$rc)" ;;
esac

# --- исходника stats_update.sh нет (STATS_UPDATE_SOURCE указывает на
#     несуществующий файл) - write_stats_update() должна тихо
#     предупредить в RUN_LOG и вернуть 0, не создавая cgi-bin/update и не
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
  STATS_UPDATE_SOURCE=$W2/stats_update.sh
  STATS_UPDATE_SCRIPT=$W2/www/cgi-bin/update
  RUN_LOG=$W2/run.log
  ensure_stats_httpd
  [ ! -f "$STATS_UPDATE_SCRIPT" ] || exit 73
  grep -q "раздел обновлений недоступен" "$RUN_LOG" || exit 74
  exit 0
)
rc=$?
case $rc in
  0) ;;
  73) fail "write_stats_update: cgi-bin/update создан без исходника stats_update.sh" ;;
  74) fail "write_stats_update: WARN об отсутствующем stats_update.sh не залогирован" ;;
  *) fail "write_stats_update (исходника нет) subshell завершился неожиданно (rc=$rc)" ;;
esac

# --- STATS_UPDATE_SOURCE/STATS_UPDATE_SCRIPT по умолчанию: без явного
#     переопределения переменные должны сами лечь на $DIR/stats_update.sh и
#     $STATS_HTTP_DIR/cgi-bin/update (та же схема, что STATS_RUN_SOURCE/
#     STATS_RUN_SCRIPT) - DIR/STATS_HTTP_DIR экспортируются ДО "sourcing"
#     speedtest2.sh, иначе ${VAR:-...} вычислит дефолт от старого DIR ---
W3=$TEST_ROOT/w3
mkdir -p "$W3"
cp "$ROOT/web/stats_update.sh" "$W3/stats_update.sh"
chmod +x "$W3/stats_update.sh"
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
  [ -f "$W3/www/cgi-bin/update" ] || exit 75
  [ -x "$W3/www/cgi-bin/update" ] || exit 76
  exit 0
)
rc=$?
case $rc in
  0) ;;
  75) fail "write_stats_update: дефолтный STATS_UPDATE_SOURCE (\$DIR/stats_update.sh) не подхвачен" ;;
  76) fail "write_stats_update: дефолтный STATS_UPDATE_SCRIPT не исполняем" ;;
  *) fail "write_stats_update (дефолты) subshell завершился неожиданно (rc=$rc)" ;;
esac

echo "test_stats_update_service.sh: OK"
