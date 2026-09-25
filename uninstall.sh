#!/bin/sh
# Полностью деинсталлирует проект mihomo-speedtest, установленный install.sh
# (и, если найден бэкап, откатывает config.yaml к состоянию до последнего
# запуска setup.sh). Сам mihomo/XKeen не устанавливался этим проектом и не
# удаляется - трогается только то, что относится к проекту.
#
# Снос полный и намеренный: удаляются вообще все файлы проекта, включая
# version_check.sh, setup.sh, update.sh и сам себя/install.sh - после
# uninstall.sh переустановка всегда идёт через bootstrap install.sh
# (curl ... | sh, свежая закачка с GitHub), а не подхватом локальных
# файлов. Это НЕ отменяет офлайн-переустановку как таковую: пока проект не
# деинсталлирован, "sh install.sh" без сети на месте работает как и
# раньше (см. install.sh) - uninstall.sh просто ставит чёткую границу,
# после которой офлайн-путь закономерно недоступен.
#
# Список удаляемых файлов - $INSTALLED_MANIFEST_PATH (пишет install.sh
# после установки/bootstrap, см. install.sh:bootstrap_selfinstall) - это
# точное отражение того, что реально стоит на диске. Если файла нет
# (установка до этого изменения, ни разу не обновлялись через update.sh) -
# запасной список FALLBACK_PROJECT_FILES ниже. См. project_files_to_remove().
#
# Проверка версий (version_check.sh) сюда намеренно не подключается:
# в отличие от установки, деинсталляция должна работать и на роутере
# с версиями ниже минимума из AGENTS.md - например, если владелец решил
# откатиться именно из-за несовместимости.
#
# Порядок действий: подтверждение -> остановка веб-службы статистики ->
# снятие cron-строк -> откат config.yaml (если есть бэкап setup.sh) ->
# удаление всех файлов проекта (включая install.sh/uninstall.sh и
# служебное состояние обновлятора) -> по запросу (PURGE_DATA=1) удаление
# журналов/истории/веб-статики. Каждый шаг использует rm -f/-rf и безопасен
# при повторном запуске на уже деинсталлированном каталоге.
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
UPDATE_STATE_DIR=${UPDATE_STATE_DIR:-$DIR/.update}
INSTALLED_MANIFEST_PATH=${INSTALLED_MANIFEST_PATH:-$UPDATE_STATE_DIR/installed-manifest.txt}
# 1 - не спрашивать подтверждения (для запуска по SSH одной командой).
SKIP_CONFIRM=${SKIP_CONFIRM:-0}
# 1 - не трогать config.yaml, даже если рядом есть бэкап setup.sh.
SKIP_CONFIG_REVERT=${SKIP_CONFIG_REVERT:-0}
# 1 - откатывать config.yaml не к самому свежему бэкапу *.bak, а к самому
# свежему из тех бэкапов, где ещё нет провайдера "fast" (группы, которую
# ведёт speedtest2.sh - см. has_fast_group()/find_backup_before_fast()).
REVERT_BEFORE_FAST=${REVERT_BEFORE_FAST:-0}
# 1 - дополнительно удалить журналы, историю замеров и веб-статику
# статистики (по умолчанию они остаются на диске).
PURGE_DATA=${PURGE_DATA:-0}

# Полный набор файлов проекта (все 5 компонентов из release/components.txt) -
# запасной список на случай, если $INSTALLED_MANIFEST_PATH не найден
# (установка до этого изменения, ни разу не обновлялись через update.sh).
# Не включает $STATS_SERVICE_DEST/$INITD_SCRIPT - у них свои переменные с
# возможным переопределением пути, удаляются отдельно в remove_project_files().
FALLBACK_PROJECT_FILES="speedtest2.sh prep.awk providers.awk node_stats_update.awk sub_convert.awk
render_stats.awk stats_cgi.sh stats_run.sh stats_update.sh stats_httpd.py stats_auth.py stats_auth.sh
stats_index.html stats_style.css stats_app.js stats_chart.js render_progress.awk
uninstall.sh VERSIONS install.sh version_check.sh
migrate_config.sh migrate_config.awk config_diff.awk setup.sh detect_ua.sh render_config.awk existing_config.awk config.example.yaml
update_transaction.sh update_prepare.sh update.sh update_plan.awk"

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
  echo "uninstall.sh: будут остановлена веб-служба статистики, сняты cron-записи," >&2
  echo "uninstall.sh: удалены ВСЕ файлы проекта в $DIR (включая install.sh/uninstall.sh) и $UPDATE_STATE_DIR." >&2
  if [ "$SKIP_CONFIG_REVERT" != 1 ] && [ -f "$CONFIG" ]; then
    echo "uninstall.sh: если рядом с $CONFIG найден бэкап setup.sh (*.bak), config.yaml будет откачен к нему, а текущий config.yaml сохранён своим бэкапом; xkeen перезапустится." >&2
  fi
  if [ "$PURGE_DATA" = 1 ]; then
    echo "uninstall.sh: PURGE_DATA=1 - также будут удалены журналы, история замеров, веб-статика статистики и учётные данные веб-интерфейса (логин и пароль)." >&2
  fi
  printf 'uninstall.sh: продолжить? [y/N] ' >&2
  # Под "curl ... | sh" стандартный ввод занят телом самого uninstall.sh -
  # без переоткрытия от терминала read -r ниже сразу получит EOF, и
  # деинсталляция молча отменится (безопасный отказ, но не то, чего хочет
  # человек за интерактивным терминалом). "exec < /dev/tty" сам по себе
  # фатален для sh при неудаче (нет управляющего терминала - обычное дело
  # в автоматизации/тестах), поэтому сначала пробуем открыть /dev/tty в
  # отдельном подшелле: его неудача убивает только подшелл, uninstall.sh
  # просто продолжает читать исходный stdin (см. тот же приём в install.sh
  # перед хэндовером в setup.sh).
  if [ ! -t 0 ] && (exec < /dev/tty) 2>/dev/null; then
    exec < /dev/tty
  fi
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

# Отпечаток группы "fast" (proxy-providers -> fast -> path: ./fast.yaml,
# см. config.example.yaml) - именно этот провайдер speedtest2.sh ведёт
# автоматически, а не любое упоминание слова "fast" (например, в
# fastly@domain/fastly@ipcidr среди правил).
has_fast_group() {
  grep -qE '^[[:space:]]*path:[[:space:]]*\./fast\.yaml[[:space:]]*$' "$1" 2>/dev/null
}

# Среди $CONFIG.*.bak (тот же порядок перебора, что и обычный поиск
# "последнего" ниже) - самый свежий бэкап, где группы fast ещё нет.
find_backup_before_fast() {
  found=""
  for b in "$CONFIG".*.bak; do
    [ -f "$b" ] || continue
    has_fast_group "$b" || found=$b
  done
  printf '%s\n' "$found"
}

revert_config() {
  [ "$SKIP_CONFIG_REVERT" = 1 ] && return 0
  [ -f "$CONFIG" ] || return 0

  if [ "$REVERT_BEFORE_FAST" = 1 ]; then
    latest=$(find_backup_before_fast)
    if [ -z "$latest" ]; then
      echo "uninstall.sh: REVERT_BEFORE_FAST=1, но среди бэкапов $CONFIG.*.bak нет ни одного без группы fast - config.yaml оставлен как есть" >&2
      return 0
    fi
  else
    latest=""
    for b in "$CONFIG".*.bak; do
      [ -f "$b" ] || continue
      latest=$b
    done
    if [ -z "$latest" ]; then
      echo "uninstall.sh: рядом с $CONFIG нет бэкапов setup.sh (*.bak) - config.yaml оставлен как есть, providers/proxies надстройки при необходимости нужно убрать вручную" >&2
      return 0
    fi
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

# Абсолютные пути всех файлов проекта, один на строку: из
# $INSTALLED_MANIFEST_PATH, если он есть (точный список установленного -
# см. install.sh:bootstrap_selfinstall), иначе - FALLBACK_PROJECT_FILES.
project_files_to_remove() {
  if [ -f "$INSTALLED_MANIFEST_PATH" ]; then
    awk -F'|' '$1=="FILE"{print $4}' "$INSTALLED_MANIFEST_PATH"
    return 0
  fi
  for f in $FALLBACK_PROJECT_FILES; do
    printf '%s\n' "$DIR/$f"
  done
}

remove_project_files() {
  project_files_to_remove | while IFS= read -r p; do
    [ -n "$p" ] || continue
    rm -f "$p"
  done
  rm -f "$STATS_SERVICE_DEST" "$DIR/speedtest2.env"
  rm -f "$INITD_SCRIPT"
  rm -rf "$STATS_SERVICE_RUNTIME_DIR"
  rm -rf "$STATS_AUTH_RUNTIME_DIR"
  rm -rf "$STATS_UPDATE_RUNTIME_DIR"
  rm -rf "$DIR/__pycache__"
  rm -rf "$UPDATE_STATE_DIR"
  # Страховка: install.sh/uninstall.sh снимаются явно независимо от
  # источника списка выше (например, устаревший installed-manifest.txt от
  # версии до этого изменения мог не содержать их) - переустановка после
  # uninstall.sh должна безусловно идти через bootstrap, а не искать себя
  # рядом. Безопасно при запуске как "sh .../uninstall.sh" (Linux не
  # трогает уже открытый исполняемый файл до завершения процесса) и
  # пропускается сам собой, если файлов уже нет.
  rm -f "$DIR/install.sh" "$DIR/uninstall.sh"
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
  remove_project_files
  purge_data
  echo "uninstall.sh: деинсталляция завершена" >&2
}

if [ "${UNINSTALL_LIB_ONLY:-0}" != 1 ]; then
  main "$@"
fi
