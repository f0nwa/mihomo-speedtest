#!/bin/sh
# Деинсталлирует надстройку speedtest/stats, установленную install.sh
# (и, если найден бэкап, откатывает config.yaml к состоянию до
# последнего запуска setup.sh). Сам mihomo/XKeen не устанавливался этим
# проектом и не удаляется - трогается только то, что поставили
# install.sh/setup.sh.
#
# Проверка версий (version_check.sh) сюда намеренно не подключается:
# в отличие от установки, деинсталляция должна работать и на роутере
# с версиями ниже минимума из AGENTS.md - например, если владелец решил
# откатиться именно из-за несовместимости.
#
# Порядок действий: подтверждение -> остановка веб-службы статистики ->
# снятие cron-строки -> удаление установленных файлов надстройки ->
# откат config.yaml (если есть бэкап setup.sh) -> по запросу (PURGE_DATA=1)
# удаление журналов/истории/веб-статики. Каждый шаг использует rm -f/-rf
# и безопасен при повторном запуске на уже деинсталлированном каталоге.
set -eu

DIR=${DIR:-/opt/etc/mihomo}
BIN=${BIN:-/opt/sbin/mihomo}
API_MAIN=${API_MAIN:-127.0.0.1:9090}
CONFIG=${CONFIG:-$DIR/config.yaml}
INSTALLED_SCRIPT=${INSTALLED_SCRIPT:-$DIR/speedtest2.sh}
UPDATE_CHECK_SCRIPT=${UPDATE_CHECK_SCRIPT:-$DIR/stats_update.sh}
STATS_UPDATE_RUNTIME_DIR=${STATS_UPDATE_RUNTIME_DIR:-/tmp/mihomo-speedtest-update}
STATS_SERVICE_DEST=${STATS_SERVICE_DEST:-$DIR/stats_service.sh}
INITD_DIR=${INITD_DIR:-/opt/etc/init.d}
INITD_SCRIPT=${INITD_SCRIPT:-$INITD_DIR/S80speedtest-stats}
STATS_SERVICE_RUNTIME_DIR=${STATS_SERVICE_RUNTIME_DIR:-/tmp/mihomo-speedtest-stats}
STATS_AUTH_RUNTIME_DIR=${STATS_AUTH_RUNTIME_DIR:-/tmp/mihomo-speedtest-auth}
STATS_HTTP_DIR=${STATS_HTTP_DIR:-$DIR/stats_www}
# 1 - не спрашивать подтверждения (для запуска по SSH одной командой).
SKIP_CONFIRM=${SKIP_CONFIRM:-0}
# 1 - не трогать config.yaml, даже если рядом есть бэкап setup.sh.
SKIP_CONFIG_REVERT=${SKIP_CONFIG_REVERT:-0}
# 1 - дополнительно удалить журналы, историю замеров и веб-статику
# статистики (по умолчанию они остаются на диске).
PURGE_DATA=${PURGE_DATA:-0}

# Файлы самого спидтеста и веб-статистики - те же, что кладёт
# install_files() в install.sh (см. соответствующий список там).
CORE_FILES="speedtest2.sh prep.awk render_stats.awk stats_cgi.sh
stats_run.sh stats_update.sh stats_index.html stats_style.css stats_app.js stats_chart.js
stats_httpd.py stats_auth.py stats_auth.sh node_stats_update.awk sub_convert.awk render_progress.awk"

atomic_install() {
  src=$1
  dst=$2
  dstdir=${dst%/*}
  dstbase=${dst##*/}
  tmp=$dstdir/.$dstbase.$$
  if ! cp "$src" "$tmp"; then rm -f "$tmp"; return 1; fi
  if ! mv "$tmp" "$dst"; then rm -f "$tmp"; return 1; fi
}

pid_alive() {
  p=$(cat "$1" 2>/dev/null) || return 1
  case "$p" in
    ''|*[!0-9]*) return 1 ;;
  esac
  kill -0 "$p" 2>/dev/null
}

confirm() {
  [ "$SKIP_CONFIRM" = 1 ] && return 0
  echo "uninstall.sh: будут остановлена веб-служба статистики, снята cron-запись $INSTALLED_SCRIPT" >&2
  echo "uninstall.sh: и удалены установленные файлы спидтеста/статистики в $DIR." >&2
  if [ "$SKIP_CONFIG_REVERT" != 1 ] && [ -f "$CONFIG" ]; then
    echo "uninstall.sh: если рядом с $CONFIG найден бэкап setup.sh (*.bak), config.yaml будет откачен к нему, а текущий config.yaml сохранён своим бэкапом; xkeen перезапустится." >&2
  fi
  if [ "$PURGE_DATA" = 1 ]; then
    echo "uninstall.sh: PURGE_DATA=1 - также будут удалены журналы, история замеров, веб-статика статистики и учётные данные веб-интерфейса (логин и пароль)." >&2
  fi
  printf 'uninstall.sh: продолжить? [y/N] ' >&2
  read -r ans || ans=""
  case "$ans" in
    [Yy]*) return 0 ;;
    *) echo "uninstall.sh: отменено, ничего не изменено" >&2; return 1 ;;
  esac
}

stop_service() {
  if [ -x "$INITD_SCRIPT" ]; then
    "$INITD_SCRIPT" stop || echo "uninstall.sh: WARN - $INITD_SCRIPT stop не удался, продолжаю" >&2
    return 0
  fi
  # init-скрипт уже отсутствует (или так и не был установлен), но
  # supervisor мог остаться запущенным с прошлой сессии - гасим напрямую
  # по тем же pid-файлам, что использует do_stop() в stats_init.sh.
  sup_pidfile=$STATS_SERVICE_RUNTIME_DIR/supervisor.pid
  http_pidfile=$STATS_SERVICE_RUNTIME_DIR/httpd.pid
  if pid_alive "$sup_pidfile"; then
    kill "$(cat "$sup_pidfile")" 2>/dev/null || true
    sleep 1
  fi
  if pid_alive "$http_pidfile"; then
    kill "$(cat "$http_pidfile")" 2>/dev/null || true
  fi
  rm -f "$sup_pidfile" "$http_pidfile" "$http_pidfile.addr"
}

remove_cron() {
  current=$(crontab -l 2>/dev/null || true)
  if [ -z "$current" ] || ! printf '%s\n' "$current" | grep -qF "$INSTALLED_SCRIPT"; then
    return 0
  fi
  filtered=$(printf '%s\n' "$current" | grep -vF "$INSTALLED_SCRIPT" || true)
  printf '%s\n' "$filtered" | crontab -
  echo "uninstall.sh: cron-строка для $INSTALLED_SCRIPT удалена" >&2
}

remove_update_cron() {
  current=$(crontab -l 2>/dev/null || true)
  if [ -z "$current" ] || ! printf '%s\n' "$current" | grep -qF "$UPDATE_CHECK_SCRIPT"; then
    return 0
  fi
  filtered=$(printf '%s\n' "$current" | grep -vF "$UPDATE_CHECK_SCRIPT" || true)
  printf '%s\n' "$filtered" | crontab -
  echo "uninstall.sh: cron-строка для $UPDATE_CHECK_SCRIPT удалена" >&2
}

revert_config() {
  [ "$SKIP_CONFIG_REVERT" = 1 ] && return 0
  [ -f "$CONFIG" ] || return 0

  latest=""
  for b in "$CONFIG".*.bak; do
    [ -f "$b" ] || continue
    latest=$b
  done
  if [ -z "$latest" ]; then
    echo "uninstall.sh: рядом с $CONFIG нет бэкапов setup.sh (*.bak) - config.yaml оставлен как есть, providers/proxies надстройки при необходимости нужно убрать вручную" >&2
    return 0
  fi

  echo "uninstall.sh: найден бэкап $latest, проверяю mihomo -t" >&2
  if ! "$BIN" -t -d "$DIR" -f "$latest" >/dev/null 2>&1; then
    echo "uninstall.sh: WARN - $latest не проходит mihomo -t, config.yaml не тронут" >&2
    return 0
  fi

  own_backup="$CONFIG.$(date '+%Y-%m-%d_%H%M%S').bak"
  if ! cp "$CONFIG" "$own_backup"; then
    echo "uninstall.sh: WARN - не удалось сохранить $own_backup, config.yaml не тронут" >&2
    return 0
  fi
  echo "uninstall.sh: текущий config.yaml сохранён в $own_backup" >&2

  if ! atomic_install "$latest" "$CONFIG"; then
    echo "uninstall.sh: WARN - не удалось записать $CONFIG из $latest" >&2
    return 0
  fi
  echo "uninstall.sh: config.yaml откачен к $latest" >&2

  xkeen -restart
  i=0
  while [ "$i" -lt 20 ]; do
    curl -s -m 2 "http://$API_MAIN/version" >/dev/null 2>&1 && break
    sleep 1; i=$((i + 1))
  done
  if ! curl -s -m 2 "http://$API_MAIN/version" >/dev/null 2>&1; then
    echo "uninstall.sh: WARN - mihomo не поднялся после xkeen -restart, проверьте $CONFIG вручную" >&2
  fi
}

remove_files() {
  for f in $CORE_FILES; do
    rm -f "$DIR/$f"
  done
  rm -f "$STATS_SERVICE_DEST" "$DIR/speedtest2.env"
  rm -f "$INITD_SCRIPT"
  rm -rf "$STATS_SERVICE_RUNTIME_DIR"
  rm -rf "$STATS_AUTH_RUNTIME_DIR"
  rm -rf "$STATS_UPDATE_RUNTIME_DIR"
  rm -rf "$DIR/__pycache__"
}

purge_data() {
  [ "$PURGE_DATA" = 1 ] || return 0
  rm -f "$DIR/speedtest.log" "$DIR/speedtest_runs.tsv" "$DIR/speedtest_history.tsv" "$DIR/node_stability.tsv"
  rm -rf "$STATS_HTTP_DIR"
  rm -rf "$DIR/.stats-auth"
  echo "uninstall.sh: PURGE_DATA=1 - журналы, история замеров, веб-статика статистики и учётные данные веб-интерфейса удалены" >&2
}

main() {
  confirm || return 1
  stop_service
  remove_cron
  remove_update_cron
  revert_config
  remove_files
  purge_data
  echo "uninstall.sh: деинсталляция завершена" >&2
}

if [ "${UNINSTALL_LIB_ONLY:-0}" != 1 ]; then
  main "$@"
fi
