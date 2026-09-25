#!/bin/sh
# CGI-скрипт кнопки "Запустить прогон сейчас" на странице статистики (см.
# README.md, раздел про stats_www/cgi-bin/run). Ставится install.sh в
# $DIR/stats_run.sh; в раздаваемый каталог (STATS_RUN_SCRIPT, обычно
# $DIR/stats_www/cgi-bin/run) его копирует write_stats_run() из
# speedtest2.sh при каждом запуске/перезапуске независимой службы
# (prepare() в stats_service.sh, порция 3) - править нужно этот файл,
# копия перезаписывается автоматически и правки в ней не сохранятся.
#
# GET  -> {"running":true|false} - идёт ли сейчас прогон (проверяется тот
#         же файл-блокировка $LOCK, что и у cron/--force, см. acquire_lock()
#         в speedtest2.sh).
# POST -> если блокировка свободна - запускает "$DIR/speedtest2.sh" --force
#         в фоне (полностью отвязанным от текущего CGI-процесса: stdin/out/err
#         не наследуются, иначе httpd/stats_httpd.py будет ждать EOF от
#         фонового процесса вместо немедленного ответа). Если блокировка уже
#         занята (cron или предыдущий клик по кнопке) - вторую копию не
#         плодит, у --force и так есть собственное ожидание чужой блокировки
#         (FORCE_WAIT), плодить ждущие процессы от повторных кликов незачем.
#         Отвечает тем же JSON, что и GET, плюс "started".
#
# Тот же приём, что и в stats_cgi.sh: подключаем speedtest2.sh с
# MST_LIB_ONLY=1, чтобы получить DIR/LOCK/... из окружения, которое
# stats_service.sh экспортирует дочернему httpd (и его CGI-процессам),
# без запуска main().

export MST_LIB_ONLY=1
[ -n "$DIR" ] && [ -f "$DIR/speedtest2.sh" ] && . "$DIR/speedtest2.sh"

json_error() {
  echo "Content-Type: application/json; charset=utf-8"
  echo
  printf '{"error":"%s"}\n' "$1"
  exit 0
}

if [ -z "$DIR" ] || [ -z "$LOCK" ] || [ ! -f "$DIR/speedtest2.sh" ]; then
  json_error "config: не удалось подключить speedtest2.sh (DIR=[$DIR])"
fi

is_running() {
  run_pid=$(cat "$LOCK/pid" 2>/dev/null)
  [ -n "$run_pid" ] && kill -0 "$run_pid" 2>/dev/null
}

method=${REQUEST_METHOD:-GET}
started=false
running=false

if [ "$method" = "POST" ]; then
  if is_running; then
    running=true
  else
    # MST_LIB_ONLY=1 экспортирован выше (см. шапку) - без явного
    # сброса до 0 дочерний speedtest2.sh унаследует его и main() у
    # него не запустится (см. условие "MST_LIB_ONLY != 1" в самом
    # низу speedtest2.sh).
    ( MST_LIB_ONLY=0 "$DIR/speedtest2.sh" --force </dev/null >/dev/null 2>&1 & )
    started=true
    running=true
  fi
else
  is_running && running=true
fi

echo "Content-Type: application/json; charset=utf-8"
echo
printf '{"running":%s,"started":%s}\n' "$running" "$started"
