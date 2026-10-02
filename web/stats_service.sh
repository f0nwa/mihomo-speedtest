#!/bin/sh
# Независимая служба веб-интерфейса статистики (supervisor). Дизайн:
# docs/superpowers/specs/2026-09-15-independent-stats-service-design.md.
#
# Держит цикл supervisor: запускает HTTP-бэкенд в foreground, ждёт его
# завершения и при неожиданном выходе перезапускает с нарастающей задержкой
# (backoff). Не запускает speedtest, не меняет историю замеров и не
# генерирует stats.json - этим занимается speedtest2.sh (render_stats()).
#
# Переиспользует функции speedtest2.sh (say(), cleanup_old_zash_stats())
# тем же приёмом, что и stats_cgi.sh/stats_run.sh:
# подключение с MST_LIB_ONLY=1, без запуска main(). Поэтому DIR должен
# указывать на каталог, где рядом лежит сам speedtest2.sh (обычная
# установка - /opt/etc/mihomo, ставится install.sh).
#
# Важно про порядок переменных ниже: STATS_HTTP_PIDFILE/STATS_HTTP_LOG
# получают новые значения по умолчанию (внутри
# $STATS_SERVICE_RUNTIME_DIR, обычно /tmp/mihomo-speedtest-stats) ДО
# подключения speedtest2.sh. Внутри speedtest2.sh эти же переменные
# определяются как "${VAR:-старое_значение_в_DIR}" - раз переменная уже
# не пуста, старое значение не подставляется. speedtest2.sh следом сам
# читает speedtest2.env (". "$ENV""), и если там эти переменные заданы
# явно - они, как и раньше, побеждают. Так соблюдается требование
# дизайна: пользовательские переопределения в speedtest2.env сохраняют
# приоритет над новыми путями по умолчанию.

DIR=${DIR:-/opt/etc/mihomo-speedtest}
MIHOMO_DIR=${MIHOMO_DIR:-/opt/etc/mihomo}
SPEEDTEST_SCRIPT=${SPEEDTEST_SCRIPT:-$DIR/speedtest2.sh}

STATS_SERVICE_RUNTIME_DIR=${STATS_SERVICE_RUNTIME_DIR:-/tmp/mihomo-speedtest-stats}
SUPERVISOR_PIDFILE=${SUPERVISOR_PIDFILE:-$STATS_SERVICE_RUNTIME_DIR/supervisor.pid}
STATS_HTTP_PIDFILE=${STATS_HTTP_PIDFILE:-$STATS_SERVICE_RUNTIME_DIR/httpd.pid}
STATS_HTTP_LOG=${STATS_HTTP_LOG:-$STATS_SERVICE_RUNTIME_DIR/httpd.log}
RUN_LOG=${RUN_LOG:-$STATS_SERVICE_RUNTIME_DIR/service.log}   # свой журнал supervisor'а - см. say() в speedtest2.sh

# Последовательность задержек перед повторным запуском упавшего бэкенда
# (секунды, через пробел; последнее значение - потолок для всех попыток
# сверх длины списка). Задержка сбрасывается на первое значение, если
# предыдущий запуск бэкенда прожил не меньше STATS_SERVICE_STABLE_SECONDS.
# Оба переопределяются окружением - тестам не нужны настоящие ожидания.
STATS_SERVICE_BACKOFF=${STATS_SERVICE_BACKOFF:-"2 5 15 60"}
STATS_SERVICE_STABLE_SECONDS=${STATS_SERVICE_STABLE_SECONDS:-60}

export DIR MIHOMO_DIR STATS_HTTP_PIDFILE STATS_HTTP_LOG RUN_LOG

if [ ! -f "$SPEEDTEST_SCRIPT" ]; then
  echo "$SPEEDTEST_SCRIPT не найден - переустановите проект" >&2
  exit 1
fi

export MST_LIB_ONLY=1
. "$SPEEDTEST_SCRIPT"
export DIR MIHOMO_DIR ENV   # дочерний httpd и его
                  # CGI (stats_cgi.sh/stats_run.sh) должны видеть тот же speedtest2.env
export LIVE_LOG_DIR   # живой журнал: stats_httpd.py должен смотреть в тот же каталог, что и say()
LOG_TAG=service     # метка строк службы в живом журнале (не экспортируется - дочерним прогонам своя)

BACKEND_PID=
STOPPING=0

pid_from_file() {
  # Печатает pid из файла $1, только если он выглядит как число - см.
  # design "нечисловые PID-файлы не приводят к убийству чужого процесса".
  p=$(cat "$1" 2>/dev/null) || return 0
  case "$p" in
    ''|*[!0-9]*) return 0 ;;
  esac
  printf '%s' "$p"
}

prepare() {
  # Готовит каталог данных (stats.json, progress.json). Скрипты и файлы
  # интерфейса stats_httpd.py берёт прямо из $DIR. Копии в stats_www от
  # старых версий удаляются (одна запись в /opt и только если они есть).
  export DIR MIHOMO_DIR ENV
  cleanup_old_zash_stats
  if [ ! -d "$STATS_HTTP_DIR" ] && ! mkdir -p "$STATS_HTTP_DIR"; then
    say "WARN: Не удалось создать $STATS_HTTP_DIR, веб-сервис статистики не поднят"
    return 1
  fi
  [ -d "$STATS_HTTP_DIR/cgi-bin" ] && rm -rf "$STATS_HTTP_DIR/cgi-bin"
  for old in index.html style.css app.js chart.js codemirror.js codemirror.css; do
    [ -f "$STATS_HTTP_DIR/$old" ] && rm -f "$STATS_HTTP_DIR/$old"
  done
  return 0
}

try_backend() {
  # $1 = команда сервера ("$STATS_HTTPD_PY_CMD $STATS_HTTPD_PY").
  # Запуск "&" идёт прямо в текущем шелле, без "$(...)": supervise() ждёт
  # бэкенд через "wait", а wait видит только прямых потомков. pid
  # кладётся в глобальную $BACKEND_PID.
  cmd=$1
  bin=${cmd%% *}
  if ! command -v "$bin" >/dev/null 2>&1; then
    say "WARN: $bin не найден"
    return 1
  fi
  $cmd -f -p "$STATS_HTTP_BIND:$STATS_HTTP_PORT" -h "$STATS_HTTP_DIR" \
    > "$STATS_HTTP_LOG" 2>&1 < /dev/null &
  BACKEND_PID=$!
  sleep 1
  if ! kill -0 "$BACKEND_PID" 2>/dev/null; then
    say "WARN: $cmd запустился и сразу завершился (порт занят? см. $STATS_HTTP_LOG)"
    BACKEND_PID=
    return 1
  fi
  return 0
}

start_backend() {
  # Запускает единственный поддерживаемый бэкенд stats_httpd.py. Только он
  # реализует общую авторизацию для UI и API.
  # без управления pid-файлом (это решает supervise()) и без подшелла
  # (см. try_backend() выше). При успехе кладёт pid в $BACKEND_PID и
  # возвращает 0; при неудаче обоих вариантов - $BACKEND_PID пуст,
  # возврат 1 (WARN уже написан через say()).
  BACKEND_PID=
  if [ ! -f "$STATS_HTTPD_PY" ] || ! command -v "$STATS_HTTPD_PY_CMD" >/dev/null 2>&1; then
    say "WARN: Python 3 или $STATS_HTTPD_PY не найден - веб-интерфейс не запущен"
    return 1
  fi
  try_backend "$STATS_HTTPD_PY_CMD $STATS_HTTPD_PY" && return 0
  say "WARN: Веб-сервис статистики не запустился на $STATS_HTTP_BIND:$STATS_HTTP_PORT - подробности в $STATS_HTTP_LOG"
  return 1
}

backoff_delay() {
  # $1 = номер попытки подряд (1, 2, 3, ...). Печатает задержку в секундах
  # согласно $STATS_SERVICE_BACKOFF, дальше значений списка - последнее.
  attempt=$1
  idx=0
  result=0
  for d in $STATS_SERVICE_BACKOFF; do
    idx=$((idx + 1))
    result=$d
    [ "$idx" -ge "$attempt" ] && break
  done
  printf '%s' "$result"
}

on_term() {
  # Штатная остановка: помечаем STOPPING, чтобы основной цикл не пытался
  # трактовать это как неожиданное падение бэкенда, останавливаем сам
  # бэкенд (если запущен) и выходим - без повторного запуска.
  STOPPING=1
  if [ -n "$BACKEND_PID" ] && kill -0 "$BACKEND_PID" 2>/dev/null; then
    kill "$BACKEND_PID" 2>/dev/null
    wait "$BACKEND_PID" 2>/dev/null
  fi
  rm -f "$SUPERVISOR_PIDFILE" "$STATS_HTTP_PIDFILE" "$STATS_HTTP_PIDFILE.addr"
  say "Служба статистики остановлена (supervisor pid $$)"
  exit 0
}

supervise() {
  if [ "$STATS_HTTP_ENABLE" != 1 ]; then
    say "STATS_HTTP_ENABLE=0 - веб-сервис статистики отключён, supervisor не запускает бэкенд"
    return 0
  fi

  mkdir -p "$STATS_SERVICE_RUNTIME_DIR" 2>/dev/null || {
    echo "Не удалось создать $STATS_SERVICE_RUNTIME_DIR" >&2
    return 1
  }

  if [ ! -f "$STATS_HTTPD_PY" ] || ! command -v "$STATS_HTTPD_PY_CMD" >/dev/null 2>&1; then
    say "WARN: Python 3 или $STATS_HTTPD_PY не найден - веб-интерфейс не запущен"
    return 1
  fi

  existing=$(pid_from_file "$SUPERVISOR_PIDFILE")
  if [ -n "$existing" ] && kill -0 "$existing" 2>/dev/null; then
    say "Служба статистики уже запущена (supervisor pid $existing), повторный запуск не выполняется"
    return 0
  fi

  if ! echo "$$" > "$SUPERVISOR_PIDFILE"; then
    echo "Не удалось записать $SUPERVISOR_PIDFILE" >&2
    return 1
  fi

  trap on_term TERM INT

  attempt=0
  while :; do
    prepare || true   # ошибка подготовки docroot не должна останавливать supervisor -
                       # httpd, если уже был поднят раньше, продолжает раздавать
                       # прежнюю исправную копию (см. design, "Ошибки и журналирование")
    started_at=$(date +%s 2>/dev/null || echo 0)
    start_backend
    if [ -z "$BACKEND_PID" ]; then
      attempt=$((attempt + 1))
      delay=$(backoff_delay "$attempt")
      say "Не удалось поднять веб-сервис статистики, повтор через ${delay}s (попытка $attempt)"
      sleep "$delay"
      [ "$STOPPING" = 1 ] && break
      continue
    fi

    echo "$BACKEND_PID" > "$STATS_HTTP_PIDFILE"
    wait "$BACKEND_PID" 2>/dev/null
    rc=$?
    [ "$STOPPING" = 1 ] && break

    ended_at=$(date +%s 2>/dev/null || echo 0)
    ran_for=$((ended_at - started_at))
    rm -f "$STATS_HTTP_PIDFILE"
    if [ "$ran_for" -ge "$STATS_SERVICE_STABLE_SECONDS" ]; then
      attempt=0
    fi
    attempt=$((attempt + 1))
    delay=$(backoff_delay "$attempt")
    say "Веб-сервис статистики неожиданно завершился (код $rc, прожил ${ran_for}s), повтор через ${delay}s (попытка $attempt)"
    sleep "$delay"
    [ "$STOPPING" = 1 ] && break
  done
  rm -f "$SUPERVISOR_PIDFILE"
}

status() {
  sup_pid=$(pid_from_file "$SUPERVISOR_PIDFILE")
  http_pid=$(pid_from_file "$STATS_HTTP_PIDFILE")

  if [ -n "$sup_pid" ] && kill -0 "$sup_pid" 2>/dev/null; then
    if [ -n "$http_pid" ] && kill -0 "$http_pid" 2>/dev/null; then
      echo "supervisor: Работает (pid $sup_pid); httpd: работает (pid $http_pid)"
    else
      echo "supervisor: Работает (pid $sup_pid); httpd: не поднят (backoff или STATS_HTTP_ENABLE=0)"
    fi
    return 0
  fi
  echo "supervisor: Не работает"
  return 1
}

case "${1:-}" in
  prepare) prepare ;;
  supervise) supervise ;;
  status) status ;;
  *)
    echo "usage: $0 {prepare|supervise|status}" >&2
    exit 2
    ;;
esac
