#!/bin/sh
# Шаблон Entware init-скрипта для независимой службы веб-интерфейса
# статистики. install.sh ставит этот файл как исполняемый
# /opt/etc/init.d/S80speedtest-stats (сама установка - порция 3, см.
# docs/superpowers/specs/2026-09-15-independent-stats-service-design.md).
# rc.unslung запускает такие скрипты по порядку при монтировании /opt и
# останавливает при его размонтировании - см. design, "Основания для
# Entware-интеграции".
#
# Управление только по собственным pid-файлам службы (supervisor.pid,
# httpd.pid в $STATS_SERVICE_RUNTIME_DIR) - не ищет процессы по общему
# имени "python3": на роутере могут работать другие python3-процессы.
#
# start       - запускает один supervisor (stats_service.sh supervise) в
#               фоне и проверяет, что он не завершился сразу.
# stop        - посылает supervisor'у TERM, ждёт STOP_WAIT секунд и при
#               необходимости завершает его и оставшийся HTTP-бэкенд
#               напрямую по pid-файлам.
# restart     - stop, затем start.
# reconfigure - то же самое, что restart: адрес привязки, порт и Basic
#               Auth читаются заново при каждом старте supervisor'а.
# check       - печатает состояние supervisor'а и HTTP-бэкенда
#               (делегирует "$SERVICE" status) и возвращает код 0/1.

DIR=${DIR:-/opt/etc/mihomo-speedtest}
SERVICE=${SERVICE:-$DIR/stats_service.sh}
ENV=${ENV:-$DIR/speedtest2.env}
STATS_SERVICE_RUNTIME_DIR=${STATS_SERVICE_RUNTIME_DIR:-/tmp/mihomo-speedtest-stats}
SUPERVISOR_PIDFILE=${SUPERVISOR_PIDFILE:-$STATS_SERVICE_RUNTIME_DIR/supervisor.pid}
STATS_HTTP_PIDFILE=${STATS_HTTP_PIDFILE:-$STATS_SERVICE_RUNTIME_DIR/httpd.pid}
STOP_WAIT=${STOP_WAIT:-10}   # секунд ожидания штатного завершения supervisor'а перед kill -9; тесты переопределяют в меньшую сторону

export DIR SERVICE ENV STATS_SERVICE_RUNTIME_DIR SUPERVISOR_PIDFILE STATS_HTTP_PIDFILE

pid_alive() {
  p=$(cat "$1" 2>/dev/null) || return 1
  case "$p" in
    ''|*[!0-9]*) return 1 ;;
  esac
  kill -0 "$p" 2>/dev/null
}

stats_enabled() {
  # Печатает STATS_HTTP_ENABLE из $ENV (по умолчанию 1) без побочных
  # эффектов - минимальный разбор одной переменной, чтобы не подключать
  # весь speedtest2.sh только для этой проверки. Если переменная задана
  # в файле несколько раз - как и обычный ". "$ENV"", побеждает последняя
  # строка.
  val=1
  if [ -f "$ENV" ]; then
    line=$(sed -n 's/^STATS_HTTP_ENABLE=//p' "$ENV" | tail -n 1)
    [ -n "$line" ] && val=$line
  fi
  printf '%s' "$val"
}

do_start() {
  if [ ! -f "$SERVICE" ]; then
    echo "$SERVICE не найден - переустановите проект" >&2
    return 1
  fi
  if [ "$(stats_enabled)" != 1 ]; then
    echo "STATS_HTTP_ENABLE=0 - веб-сервис статистики отключён, служба не запускается"
    return 0
  fi
  if pid_alive "$SUPERVISOR_PIDFILE"; then
    echo "служба уже запущена (supervisor pid $(cat "$SUPERVISOR_PIDFILE"))"
    return 0
  fi
  mkdir -p "$STATS_SERVICE_RUNTIME_DIR" 2>/dev/null
  sh "$SERVICE" supervise >/dev/null 2>&1 &
  child=$!
  sleep 1
  if kill -0 "$child" 2>/dev/null; then
    echo "OK: служба статистики запущена (pid $child)"
    return 0
  fi
  echo "служба статистики завершилась сразу после запуска - подробности в $STATS_SERVICE_RUNTIME_DIR/service.log"
  return 1
}

do_stop() {
  if ! pid_alive "$SUPERVISOR_PIDFILE"; then
    rm -f "$SUPERVISOR_PIDFILE"
    return 0
  fi
  pid=$(cat "$SUPERVISOR_PIDFILE")
  kill "$pid" 2>/dev/null
  i=0
  while [ "$i" -lt "$STOP_WAIT" ] && kill -0 "$pid" 2>/dev/null; do
    sleep 1
    i=$((i + 1))
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill -9 "$pid" 2>/dev/null
  fi
  # Штатно supervisor сам останавливает бэкенд и убирает pid-файлы (см.
  # on_term() в stats_service.sh); kill -9 выше на этот путь не попадает -
  # только запасной вариант, если supervisor не успел отреагировать на TERM.
  if pid_alive "$STATS_HTTP_PIDFILE"; then
    kill "$(cat "$STATS_HTTP_PIDFILE")" 2>/dev/null
  fi
  rm -f "$SUPERVISOR_PIDFILE" "$STATS_HTTP_PIDFILE" "$STATS_HTTP_PIDFILE.addr"
  return 0
}

do_check() {
  if [ ! -f "$SERVICE" ]; then
    echo "$SERVICE не найден" >&2
    return 1
  fi
  sh "$SERVICE" status
}

case "${1:-}" in
  start) do_start ;;
  stop) do_stop ;;
  restart|reconfigure) do_stop; do_start ;;
  check) do_check ;;
  *)
    echo "usage: $0 {start|stop|restart|reconfigure|check}" >&2
    exit 2
    ;;
esac
