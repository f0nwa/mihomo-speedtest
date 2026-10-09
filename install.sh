#!/bin/sh
# Устанавливает speedtest2 на роутере: извлекает SOURCES и фильтры из
# config.yaml, калибрует порог скорости, ставит cron и делает пробный запуск.
# Запускать из каталога, где рядом лежат speedtest2.sh, prep.awk, providers.awk.
set -eu

DIR=${DIR:-/opt/etc/mihomo-speedtest}
BIN=${BIN:-/opt/sbin/mihomo}
API_MAIN=${API_MAIN:-127.0.0.1:9090}
SPEED_URL=${SPEED_URL:-"https://speed.cloudflare.com/__down?bytes=10485760"}
TMPROOT=${TMPROOT:-/tmp}
# По умолчанию - $DIR, а не текущий каталог: при "curl ... | sh" (см. ниже)
# рядом со скриптом физически ничего нет, а единственный осмысленный
# каталог, где могут (или должны появиться) остальные файлы проекта - это
# DIR, целевой каталог установки. При обычном сценарии (ручной перенос
# файлов, "cd /opt/etc/mihomo && sh install.sh") DIR и "." совпадают, так
# что поведение не меняется.
SELFDIR=${SELFDIR:-$DIR}
MIHOMO_DIR=${MIHOMO_DIR:-/opt/etc/mihomo}
CONFIG=${CONFIG:-$MIHOMO_DIR/config.yaml}
# Полные инструменты проекта, нужные для планирования обновления (тот же
# список используется ниже в install_files()).
PROJECT_TOOLS="migrate_config.sh migrate_config.awk config_diff.awk install.sh uninstall.sh version_check.sh ui.sh update_interactive.sh setup.sh detect_ua.sh render_config.awk fast_wg.awk wg_import.awk existing_config.awk config.example.yaml render_services.awk services.default.tsv config_to_state.awk constructor_build.sh reset_config.sh rule-catalog.tsv update.sh update_plan.awk update_prepare.sh update_transaction.sh providers.awk mihomo-speedtest.sh"
# Единый полный список всех файлов проекта под $SELFDIR/$DIR - источник
# истины и для триггера bootstrap ниже, и для финальной проверки полноты
# в main() (было два отдельных списка с двумя разными файлами-часовыми -
# см. CHANGELOG: install.sh не замечал недостающий migrate_config.sh,
# т.к. триггер смотрел только на version_check.sh/speedtest2.sh).
ALL_PROJECT_FILES="$PROJECT_TOOLS speedtest2.sh prep.awk render_stats.awk stats_cgi.sh stats_run.sh stats_update.sh stats_config.sh stats_xkeen.sh stats_components.sh stats_constructor.sh stats_httpd.py stats_files.py stats_auth.py stats_auth.sh stats_index.html stats_style.css stats_app.js stats_app_core.js stats_app_stats.js stats_app_settings.js stats_app_updates.js stats_app_log.js stats_app_config.js stats_app_xkeen.js stats_app_files.js stats_app_components.js stats_app_constructor.js stats_app_constructor_model.js stats_app_constructor_modules.js stats_app_constructor_modules_model.js stats_codemirror.js stats_codemirror.css node_stats_update.awk sub_convert.awk render_progress.awk stats_service.sh stats_init.sh"
INSTALLED_SCRIPT=${INSTALLED_SCRIPT:-$DIR/speedtest2.sh}
STATS_SERVICE_DEST=${STATS_SERVICE_DEST:-$DIR/stats_service.sh}
INITD_DIR=${INITD_DIR:-/opt/etc/init.d}
INITD_SCRIPT=${INITD_SCRIPT:-$INITD_DIR/S80speedtest-stats}
UPDATE_CHECK_SCRIPT=${UPDATE_CHECK_SCRIPT:-$DIR/stats_update.sh}
# Те же дефолты, что в update.sh - единое состояние обновлятора, которым
# пользуется и install.sh (пишет installed-manifest.txt после установки),
# и update.sh, и uninstall.sh (читает его же для полного сноса).
UPDATE_STATE_DIR=${UPDATE_STATE_DIR:-$DIR/.update}
INSTALLED_MANIFEST_PATH=${INSTALLED_MANIFEST_PATH:-$UPDATE_STATE_DIR/installed-manifest.txt}

# >>> ui-bootstrap
# Встроенная копия функций UI из installer/ui.sh. Под "curl ... | sh"
# install.sh один на диске: до скачивания релиза (bootstrap ниже) ui.sh
# рядом ещё нет, а баннер, шаги и прогресс загрузки нужны уже тогда. Поэтому
# здесь лежит ДОСЛОВНАЯ копия ровно тех функций, которые вызывает путь
# бутстрапа (вместе с их помощниками); после загрузки релиза (и в обычном
# пути) настоящий ui.sh подключается ниже и перекрывает копию тем же кодом.
# Лёгкие действия (--stop-web и т.п.) на старой установке без ui.sh тоже
# обходятся этой копией. Не править функции вручную: tests/test_ui_bootstrap_sync.sh
# сравнивает каждую с installer/ui.sh и падает при расхождении.
#
# Значения по умолчанию ниже - не часть библиотеки: install.sh можно
# подключить как библиотеку (INSTALL_LIB_ONLY=1) без ui_init, и функции с
# `set -u` не должны падать на неустановленных переменных. До ui_init - plain.
UI_LOG=${UI_LOG:-/opt/var/log/mihomo-speedtest-install.log}
UI_LOG_MAX=262144
UI_MODE=${UI_MODE:-plain}
UI_COLS=${UI_COLS:-80}
: "${UI_C_ACC=}" "${UI_C_OK=}" "${UI_C_ERR=}" "${UI_C_WARN=}" "${UI_C_DIM=}" "${UI_C_B=}" "${UI_C_0=}"
UI_G_OK=${UI_G_OK:-[OK]}; UI_G_ERR=${UI_G_ERR:-[!!]}; UI_G_WARN=${UI_G_WARN:-[!]}
# Блоки (ui_note) и спиннер (ui_run) нужны и функциям, которые тесты зовут
# в режиме библиотеки без ui_init: ensure_python3, resolve_block и т.п.
UI_G_BAR=${UI_G_BAR:-|}; UI_SLEEP=${UI_SLEEP:-sleep 1}

ui__len() {
  printf '%s' "$1" | LC_ALL=C tr -d '\200-\277' | wc -c | tr -d ' '
}

ui__rep() {
  _n=$1; _r=
  while [ "$_n" -gt 0 ]; do _r="$_r$2"; _n=$((_n - 1)); done
  printf '%s' "$_r"
}

ui_init() {
  # Режим. Повторный вызов безопасен: всё вычисляется заново, а
  # разделитель в лог пишется один раз на значение UI_LOG.
  UI_MODE=plain
  if [ -t 2 ] && [ "${TERM:-}" != dumb ] && [ -n "${TERM:-}" ] \
     && [ -z "${NO_COLOR:-}" ] && [ "${UI:-}" != plain ]; then
    UI_MODE=live
  fi

  UI_COLS=$(stty size 2>/dev/null </dev/tty | awk '{print $2}')
  case $UI_COLS in ''|*[!0-9]*) UI_COLS=80 ;; esac
  [ "$UI_COLS" -gt 0 ] || UI_COLS=80

  if [ "$UI_MODE" = live ]; then
    UI_C_ACC=$(printf '\033[36m'); UI_C_OK=$(printf '\033[32m')
    UI_C_ERR=$(printf '\033[31m'); UI_C_WARN=$(printf '\033[33m')
    UI_C_DIM=$(printf '\033[2m');  UI_C_B=$(printf '\033[1m')
    UI_C_0=$(printf '\033[0m')
    UI_G_OK=✓; UI_G_ERR=✗; UI_G_WARN='!'; UI_G_BAR='┃'
  else
    UI_C_ACC=; UI_C_OK=; UI_C_ERR=; UI_C_WARN=; UI_C_DIM=; UI_C_B=; UI_C_0=
    UI_G_OK='[OK]'; UI_G_ERR='[!!]'; UI_G_WARN='[!]'; UI_G_BAR='|'
  fi

  # Короткий sleep для спиннера (Task 2): дробный sleep есть не везде.
  if sleep 0.1 2>/dev/null; then UI_SLEEP='sleep 0.1'
  elif command -v usleep >/dev/null 2>&1; then UI_SLEEP='usleep 100000'
  else UI_SLEEP='sleep 1'
  fi

  ui__log_prepare
  # Выход: вернуть курсор, убить спиннер, выполнить хуки. Ставим и в plain
  # (хуки нужны всегда). Поэтому в тестах ui_init - только в подшеллах.
  trap ui__exit EXIT
  # Коды выхода по сигналу - как без ui_init: INT 130 (128+2), TERM 143
  # (128+15). Общая ловушка на оба превращала TERM в 130.
  trap 'ui__exit; exit 130' INT
  trap 'ui__exit; exit 143' TERM
  return 0
}

ui__log_prepare() {
  [ "${UI__LOG_READY:-}" = "$UI_LOG" ] && return 0
  if [ "$UI_LOG" != /dev/null ]; then
    mkdir -p "$(dirname "$UI_LOG")" 2>/dev/null || :
    if [ -f "$UI_LOG" ] && [ "$(wc -c < "$UI_LOG" 2>/dev/null || echo 0)" -gt "$UI_LOG_MAX" ]; then
      # 2>/dev/null ставим ДО файловых редиректов: они применяются слева
      # направо, иначе ошибка открытия файла утечёт в настоящий stderr.
      tail -300 "$UI_LOG" 2>/dev/null > "$UI_LOG.tmp" \
        && cat "$UI_LOG.tmp" 2>/dev/null > "$UI_LOG" || :
      rm -f "$UI_LOG.tmp" 2>/dev/null || :
    fi
    if ! printf '===== %s %s =====\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$0" 2>/dev/null >> "$UI_LOG"; then
      UI_LOG=/dev/null
    fi
  fi
  UI__LOG_READY=$UI_LOG
}

ui_log() {
  printf '%s %s\n' "$(date +%H:%M:%S)" "$*" 2>/dev/null >> "${UI_LOG:-/dev/null}" || :
  return 0
}

ui_banner() {
  if [ "${UI_CONTINUE:-}" = 1 ]; then
    # Продолжение установки из другого скрипта: рамку уже показали.
    if [ "$UI_MODE" = live ]; then
      printf '\n %s%s%s\n' "$UI_C_B" "$2" "$UI_C_0" >&2
    else
      printf '== %s ==\n' "$2" >&2
    fi
    return 0
  fi
  if [ "$UI_MODE" != live ]; then
    printf '== %s — %s ==\n' "$1" "$2" >&2
    return 0
  fi
  _t=$(ui__len "$1"); _s=$(ui__len "$2")
  _w=$_t; [ "$_s" -gt "$_w" ] && _w=$_s
  _w=$((_w + 4)); [ "$_w" -ge 38 ] || _w=38   # внутренняя ширина рамки
  _l=$(ui__rep "$_w" ─)
  printf '\n %s╭%s╮%s\n' "$UI_C_ACC" "$_l" "$UI_C_0" >&2
  printf ' %s│%s  %s%s%s%s%s│%s\n' "$UI_C_ACC" "$UI_C_0" "$UI_C_B" "$1" "$UI_C_0" \
    "$(ui__rep $((_w - _t - 2)) ' ')" "$UI_C_ACC" "$UI_C_0" >&2
  printf ' %s│%s  %s%s%s%s%s│%s\n' "$UI_C_ACC" "$UI_C_0" "$UI_C_DIM" "$2" "$UI_C_0" \
    "$(ui__rep $((_w - _s - 2)) ' ')" "$UI_C_ACC" "$UI_C_0" >&2
  printf ' %s╰%s╯%s\n' "$UI_C_ACC" "$_l" "$UI_C_0" >&2
}

ui_kv() {
  # Ключ с двоеточием, выровненный до 13 символов.
  _k="$1:"
  _p=$((13 - $(ui__len "$_k"))); [ "$_p" -ge 0 ] || _p=0
  printf '  %s%s%s%s  %s\n' "$UI_C_DIM" "$_k" "$UI_C_0" "$(ui__rep "$_p" ' ')" "$2" >&2
}

ui_step() {
  UI_STEP_CUR=$(printf '%02d' "$1"); UI_STEP_TOTAL=$(printf '%02d' "$2")
  printf ' %s%s/%s%s  %s%s%s\n' \
    "$UI_C_ACC" "$UI_STEP_CUR" "$UI_STEP_TOTAL" "$UI_C_0" "$UI_C_B" "$3" "$UI_C_0" >&2
}

ui__sub() {
  _sec=
  [ -n "${4:-}" ] && _sec=" $UI_C_DIM$4 с$UI_C_0"
  printf '    %s%s%s %s%s\n' "$1" "$2" "$UI_C_0" "$3" "$_sec" >&2
}

ui_ok()   { ui__sub "$UI_C_OK"   "$UI_G_OK"   "$@"; }

ui_fail() { ui__sub "$UI_C_ERR"  "$UI_G_ERR"  "$@"; }

ui_warn() { ui__sub "$UI_C_WARN" "$UI_G_WARN" "$@"; }

ui__cut() {
  printf '%s' "$1" | awk -v n="$2" '{ print substr($0, 1, n) }'
}

ui__frame() {
  _i=$(($1 % 10))
  set -- ⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏
  shift "$_i"
  UI_FR=$1
}

ui_progress() {
  _pc=$2; _pt=$3
  if [ "$UI_MODE" = live ]; then
    # Ширина строки: кадр+пробел (2), два пробела, "ТЕК/ВСЕГО", пробел,
    # полоса ▕..▏ (12), пробел - 18 символов плюс счётчик, плюс 1 колонка
    # запаса (печать в последнюю колонку на части терминалов переносит
    # строку). Заголовок режем до COLS-26, подписи - что осталось; не
    # осталось места - подпись не печатаем вовсе (иначе строка переполнит
    # узкий терминал и \r перестанет перерисовывать её на месте).
    _ptl=$(ui__cut "$1" $((UI_COLS - 26)))
    _pb=$((UI_COLS - 19 - $(ui__len "$_ptl") - $(ui__len "$_pc/$_pt")))
    _pn=
    [ "$_pb" -gt 0 ] && _pn=$(ui__cut "${4:-}" "$_pb")
    _pf=0; [ "$_pt" -gt 0 ] && _pf=$((_pc * 10 / _pt))
    [ "$_pf" -le 10 ] || _pf=10
    ui__frame "$_pc"
    printf '\r%s%s%s %s  %s/%s %s▕%s%s▏%s %s\033[K' "$UI_C_ACC" "$UI_FR" "$UI_C_0" \
      "$_ptl" "$_pc" "$_pt" \
      "$UI_C_ACC" "$(ui__rep "$_pf" █)" "$(ui__rep $((10 - _pf)) ░)" "$UI_C_0" "$_pn" >&2
    return 0
  fi
  if [ "$_pc" -eq 1 ] || [ "$_pc" -eq "$_pt" ] || [ $((_pc % 10)) -eq 0 ]; then
    printf '[..] %s %s/%s%s\n' "$1" "$_pc" "$_pt" "${4:+ $4}" >&2
  fi
  return 0
}

ui_progress_end() {
  [ "$UI_MODE" = live ] && printf '\n' >&2
  return 0
}

ui_on_exit() {
  UI_EXIT_HOOKS=${UI_EXIT_HOOKS:+$UI_EXIT_HOOKS
}$1
}

ui__exit() {
  [ "${UI__EXITED:-}" = 1 ] && return 0
  UI__EXITED=1
  # Спиннер крутится вокруг фонового процесса - не оставляем сироту.
  if [ -n "${UI_SPIN_PID:-}" ]; then
    kill "$UI_SPIN_PID" 2>/dev/null || :
    UI_SPIN_PID=
  fi
  # Курсор скрыт спиннером; вернуть и сбросить цвет можно только в live,
  # в plain ни одного байта ESC.
  [ "${UI_MODE:-}" = live ] && printf '\033[?25h\033[0m' >&2
  if [ -n "${UI_EXIT_HOOKS:-}" ]; then eval "$UI_EXIT_HOOKS" || :; fi
  return 0
}
ui_note() {
  _c=$UI_C_ACC; [ "${1:-}" = warn ] && _c=$UI_C_WARN
  while IFS= read -r _line || [ -n "$_line" ]; do
    printf '  %s%s%s %s\n' "$_c" "$UI_G_BAR" "$UI_C_0" "$_line" >&2
  done
}

ui_menu() {
  _mt=$1; _md=$2; shift 2
  _mn=1
  {
    printf '%s\n' "$_mt"
    for _mi in "$@"; do
      _ms=
      [ "$_mn" = "$_md" ] && _ms="  $UI_C_DIM(по умолчанию)$UI_C_0"
      printf ' %s) %s%s\n' "$_mn" "$_mi" "$_ms"
      _mn=$((_mn + 1))
    done
  } | ui_note info
}

ui_ask() {
  if [ "$UI_MODE" = live ]; then
    printf '  %s›%s %s: ' "$UI_C_ACC" "$UI_C_0" "$1" >&2
  else
    printf '[??] %s: ' "$1" >&2
  fi
}
# <<< ui-bootstrap

# --- Bootstrap для однострочной установки ---------------------------------
# Позволяет ставить проект командой
#   curl -fsSL https://raw.githubusercontent.com/f0nwa/mihomo-speedtest/main/install.sh | sh
# (см. README.md/docs/guide.md, "Установка с нуля"). raw.githubusercontent
# отдаёт ТОЛЬКО сам install.sh - остального набора файлов проекта рядом со
# скриптом при таком запуске нет. Блок ниже срабатывает именно в этом
# случае (и в любом другом, где рядом с install.sh не оказалось
# version_check.sh - например, незавершённый перенос файлов) и скачивает
# остальные файлы с уже опубликованного релиза на GitHub, тем же способом,
# каким их получает update.sh при последующих обновлениях: манифест
# релиза (manifest.txt) и сам контент файлов - через закреплённый тег
# релиза (PINNED_BASE = .../releases/download/<RELEASE_TAG>/<файл>), с
# проверкой размера и SHA256 каждого файла по манифесту. Отдельного
# raw.githubusercontent-канала для содержимого файлов нет: это сознательный
# выбор в пользу переиспользования уже проверенной инфраструктуры
# релизов/манифеста, а не второй параллельный механизм раздачи (см.
# update.sh:bootstrap_header/pinned_base/bootstrap_prepare - тот же
# протокол, только там он берёт из манифеста строки FILE только
# компонента updater, а здесь - все компоненты, т.к. ставится весь проект).
#
# Обычный сценарий (файлы перенесены на роутер вручную, см. README) блок
# не трогает: version_check.sh уже лежит рядом, проверка ниже сразу
# проходит, никакой сети. Также не запускается при подключении install.sh
# как библиотеки (INSTALL_LIB_ONLY=1, см. tests/test_install.sh) - сорсинг
# файла не должен иметь сетевых побочных эффектов.

bootstrap_manifest_field() { awk -F= -v k="$2" '$1==k{print $2; exit}' "$1"; }

bootstrap_sha256_tool() {
  if command -v sha256sum >/dev/null 2>&1; then echo sha256sum
  elif command -v openssl >/dev/null 2>&1; then echo openssl
  elif command -v busybox >/dev/null 2>&1 && printf '' | busybox sha256sum >/dev/null 2>&1; then echo busybox
  else return 1; fi
}

bootstrap_sha256_of() {
  case $BOOTSTRAP_SHA_TOOL in
    sha256sum) hash_output=$(sha256sum "$1") || return 1 ;;
    openssl) hash_output=$(openssl dgst -sha256 "$1") || return 1 ;;
    busybox) hash_output=$(busybox sha256sum "$1") || return 1 ;;
  esac
  hash_value=$(printf '%s
' "$hash_output" | awk '{if ($1 ~ /^[0-9a-f]{64}$/) print $1; else if ($NF ~ /^[0-9a-f]{64}$/) print $NF}')
  [ "${#hash_value}" = 64 ] || return 1
  printf '%s
' "$hash_value"
}

bootstrap_http_get() {
  # Код возврата - код curl: по нему bootstrap_download_to() объясняет
  # причину отказа (bootstrap_curl_reason). BOOTSTRAP_PROXY непуст - качаем
  # через прокси (см. bootstrap_enable_proxy); TLS при этом сквозной.
  if [ -n "${UPDATE_HTTP_CMD:-}" ]; then $UPDATE_HTTP_CMD "$1"
  elif command -v curl >/dev/null 2>&1; then
    bhg_url=$1
    set -- --max-time "${UPDATE_HTTP_TIMEOUT:-30}" --max-filesize "$2"
    [ -z "${BOOTSTRAP_PROXY:-}" ] || set -- "$@" -x "$BOOTSTRAP_PROXY"
    case $bhg_url in
      https://*) curl -fsSL --proto '=https' --proto-redir '=https' "$@" "$bhg_url" 2>/dev/null ;;
      http://*) curl -fsSL --proto '=http' --proto-redir '=http' --max-redirs 0 "$@" "$bhg_url" 2>/dev/null ;;
      *) return 1 ;;
    esac
  else
    echo "Для установки нужен curl с поддержкой HTTPS" >&2
    return 1
  fi
}

bootstrap_curl_reason() {
  case $1 in
    6) echo "не удалось определить адрес сервера (DNS)" ;;
    7) echo "не удалось подключиться к серверу" ;;
    28) echo "сервер не ответил вовремя (таймаут)" ;;
    35|52|56) echo "соединение оборвано (часто так выглядит блокировка у провайдера)" ;;
    51|58|60|77) echo "ошибка проверки сертификата (проверьте время на роутере и пакет ca-certificates)" ;;
    22) echo "сервер вернул ошибку HTTP (нет файла или лимит запросов GitHub)" ;;
    63) echo "файл больше заявленного размера" ;;
    5) echo "не удалось определить адрес прокси" ;;
    97) echo "прокси отказал в соединении" ;;
    *) echo "ошибка загрузки (код curl $1)" ;;
  esac
}

bootstrap_fetch_once() {
  write_limit=$3
  [ "$write_limit" -ge 262144 ] || write_limit=262144
  bfo_rc=0
  (ulimit -f "$(( (write_limit + 511) / 512 ))"; bootstrap_http_get "$1" "$3") > "$2" || bfo_rc=$?
  return "$bfo_rc"
}

bootstrap_retryable() {
  # Повторять имеет смысл только быстрые сетевые сбои: DNS, отказ в
  # соединении, обрыв. Таймаут (28) уже ждал UPDATE_HTTP_TIMEOUT - вместо
  # повтора сразу переходим к обходу через mihomo. Ошибки HTTP, размера и
  # сертификата повтор не исправит.
  case $1 in 6|7|35|52|56) return 0 ;; *) return 1 ;; esac
}

bootstrap_fetch_retry() {
  # До INSTALL_RETRIES попыток (по умолчанию 3) с паузой INSTALL_RETRY_DELAY
  # секунд (по умолчанию 2), растущей с номером попытки.
  bfr_max=${INSTALL_RETRIES:-3}
  case $bfr_max in ''|*[!0-9]*|0) bfr_max=1 ;; esac
  bfr_try=1
  while :; do
    bfr_rc=0
    bootstrap_fetch_once "$1" "$2" "$3" || bfr_rc=$?
    [ "$bfr_rc" -ne 0 ] || return 0
    bootstrap_retryable "$bfr_rc" && [ "$bfr_try" -lt "$bfr_max" ] || return "$bfr_rc"
    # Причину пишем только в журнал, на экране - лишь подпись у полосы
    # прогресса ("повтор 2/3"): иначе повтор ломал бы строку прогресса.
    ui_log "Сбой загрузки ($(bootstrap_curl_reason "$bfr_rc")), повтор $((bfr_try + 1)) из $bfr_max..."
    [ -z "${BOOTSTRAP_PROG_TOTAL:-}" ] || ui_progress "$BOOTSTRAP_PROG_TITLE" "$BOOTSTRAP_PROG_IDX" "$BOOTSTRAP_PROG_TOTAL" "повтор $((bfr_try + 1))/$bfr_max"
    sleep $(( ${INSTALL_RETRY_DELAY:-2} * bfr_try ))
    bfr_try=$((bfr_try + 1))
  done
}

# Строка прогресса загрузки: параметры храним в переменных, чтобы
# bootstrap_fetch_retry мог перерисовать её с подписью "повтор N/M".
bootstrap_prog() {
  BOOTSTRAP_PROG_TITLE=$1; BOOTSTRAP_PROG_IDX=$2; BOOTSTRAP_PROG_TOTAL=$3
  ui_progress "$1" "$2" "$3" "${4:-}"
}

# Закончить строку прогресса перед любым другим сообщением (в live она
# перерисовывается через \r и без перевода строки склеится с ним).
bootstrap_prog_close() {
  [ -z "${BOOTSTRAP_PROG_TOTAL:-}" ] || ui_progress_end
  BOOTSTRAP_PROG_TOTAL=
}

bootstrap_download_to() {
  bdt_rc=0
  bootstrap_fetch_retry "$1" "$2" "$3" || bdt_rc=$?
  if [ "$bdt_rc" -ne 0 ] && [ -z "${BOOTSTRAP_PROXY:-}" ]; then
    # Напрямую не вышло - один раз пробуем через mihomo, дальше все
    # файлы качаются через тот же прокси.
    ui_log "Не удалось скачать $1 напрямую: $(bootstrap_curl_reason "$bdt_rc")"
    # Сообщения bootstrap_enable_proxy идут обычным echo - сначала
    # заканчиваем строку прогресса, чтобы они не склеились с ней.
    bootstrap_prog_close
    if bootstrap_enable_proxy; then
      bdt_rc=0
      bootstrap_fetch_retry "$1" "$2" "$3" || bdt_rc=$?
    else
      BOOTSTRAP_FAIL_HINT=1
      return 1
    fi
  fi
  if [ "$bdt_rc" -ne 0 ]; then
    bootstrap_prog_close
    if [ -n "${BOOTSTRAP_PROXY:-}" ]; then
      ui_log "Не удалось скачать $1 через прокси $BOOTSTRAP_PROXY: $(bootstrap_curl_reason "$bdt_rc")"
    else
      ui_log "Не удалось скачать $1: $(bootstrap_curl_reason "$bdt_rc")"
    fi
    ui_fail "${1##*/}: $(bootstrap_curl_reason "$bdt_rc")"
    BOOTSTRAP_FAIL_HINT=1
    return 1
  fi
  download_size=$(wc -c < "$2" | tr -d ' ')
  [ "$download_size" -gt 0 ] && [ "$download_size" -le "$3" ] || {
    bootstrap_prog_close
    ui_fail "Пустой файл или превышен лимит загрузки: $1"
    return 1
  }
}

# --- Обход блокировки GitHub через сам mihomo ------------------------------
# Собственный трафик роутера XKeen обычно не проксирует, и github.com /
# release-assets.githubusercontent.com может быть недоступен напрямую.
# mihomo при этом уже запущен, поэтому повторяем загрузку через него:
# 1) INSTALL_PROXY из окружения (http://..., socks5h://...) - как есть;
# 2) mixed-port / port / socks-port из config.yaml, если он уже открыт;
# 3) иначе временно открываем mixed-port через API (PATCH /configs, в
#    файл конфига не пишется) и закрываем его после загрузки
#    (bootstrap_disable_proxy). TLS через прокси сквозной, а SHA256
#    файлов сверяется по манифесту, так что безопасность та же.
BOOTSTRAP_TEMP_PORT=${INSTALL_TEMP_PROXY_PORT:-17890}

bootstrap_config_value() {
  # Однострочное значение ключа верхнего уровня config.yaml без кавычек.
  [ -f "$CONFIG" ] || return 0
  sed -n "s/^$1:[[:space:]]*['\"]\{0,1\}\([^'\"#[:space:]]*\).*/\1/p" "$CONFIG" | head -n 1
}

bootstrap_api_init() {
  bai_ctl=$(bootstrap_config_value external-controller)
  [ -n "$bai_ctl" ] || bai_ctl=$API_MAIN
  bai_port=${bai_ctl##*:}
  case $bai_port in ''|*[!0-9]*) return 1 ;; esac
  BOOTSTRAP_API="127.0.0.1:$bai_port"
  BOOTSTRAP_API_SECRET=$(bootstrap_config_value secret)
}

bootstrap_api_patch() {
  # $1 - тело JSON. secret передаём через -K из stdin, не в argv.
  command -v curl >/dev/null 2>&1 || return 1
  if [ -n "${BOOTSTRAP_API_SECRET:-}" ]; then
    printf 'header = "Authorization: Bearer %s"\n' "$BOOTSTRAP_API_SECRET" |
      curl -fsS -m 5 -K - -X PATCH -H 'Content-Type: application/json' \
        -d "$1" "http://$BOOTSTRAP_API/configs" >/dev/null 2>&1
  else
    curl -fsS -m 5 -X PATCH -H 'Content-Type: application/json' \
      -d "$1" "http://$BOOTSTRAP_API/configs" >/dev/null 2>&1
  fi
}

bootstrap_enable_proxy() {
  [ -z "${BOOTSTRAP_PROXY_TRIED:-}" ] || return 1
  BOOTSTRAP_PROXY_TRIED=1
  if [ -n "${INSTALL_PROXY:-}" ]; then
    BOOTSTRAP_PROXY=$INSTALL_PROXY
    echo "Пробую через прокси из INSTALL_PROXY: $BOOTSTRAP_PROXY" >&2
    return 0
  fi
  # INSTALL_PROXY_FALLBACK=0 - не трогать mihomo (тесты, ручной отказ).
  [ "${INSTALL_PROXY_FALLBACK:-1}" != 0 ] || return 1
  for bep_key in mixed-port port socks-port; do
    bep_port=$(bootstrap_config_value "$bep_key")
    case $bep_port in ''|0|*[!0-9]*) continue ;; esac
    case $bep_key in
      socks-port) BOOTSTRAP_PROXY="socks5h://127.0.0.1:$bep_port" ;;
      *) BOOTSTRAP_PROXY="http://127.0.0.1:$bep_port" ;;
    esac
    echo "Пробую через mihomo ($bep_key $bep_port из конфига)" >&2
    return 0
  done
  bootstrap_api_init || return 1
  if bootstrap_api_patch "{\"mixed-port\": $BOOTSTRAP_TEMP_PORT}"; then
    BOOTSTRAP_TEMP_PROXY_OPEN=1
    BOOTSTRAP_PROXY="http://127.0.0.1:$BOOTSTRAP_TEMP_PORT"
    echo "Пробую через mihomo: временно открыт mixed-port $BOOTSTRAP_TEMP_PORT (только на время загрузки)" >&2
    sleep 1
    return 0
  fi
  echo "Обойти через mihomo не вышло: API $BOOTSTRAP_API недоступен или mihomo не запущен" >&2
  return 1
}

bootstrap_disable_proxy() {
  [ -n "${BOOTSTRAP_TEMP_PROXY_OPEN:-}" ] || return 0
  bootstrap_api_patch '{"mixed-port": 0}' ||
    echo "Не удалось закрыть временный mixed-port $BOOTSTRAP_TEMP_PORT - закроется при перезапуске mihomo" >&2
  BOOTSTRAP_TEMP_PROXY_OPEN=
}

bootstrap_fail_hint() {
  [ -n "${BOOTSTRAP_FAIL_HINT:-}" ] || return 0
  cat >&2 <<'EOF'

Не удалось скачать релиз с GitHub. Что можно сделать:
  - в XKeen включить проксирование трафика самого роутера и проверить, что
    github.com и *.githubusercontent.com идут через стабильную ноду;
  - указать прокси вручную (например, mixed-port mihomo):
      curl -fsSL https://raw.githubusercontent.com/f0nwa/mihomo-speedtest/main/install.sh | INSTALL_PROXY=http://127.0.0.1:7890 sh
  - скопировать файлы проекта на роутер вручную (см. README.md).
EOF
}

bootstrap_check_download() {
  [ "$(wc -c < "$1" | tr -d ' ')" = "$2" ] || { bootstrap_prog_close; ui_fail "Неверный размер файла релиза: $1"; return 1; }
  [ "$(bootstrap_sha256_of "$1")" = "$3" ] || { bootstrap_prog_close; ui_fail "Неверная сумма SHA256 файла релиза: $1"; return 1; }
}

bootstrap_awk_syntax() {
  printf 'BEGIN { exit 0 }\nEND { exit 0 }\n' > "$BOOTSTRAP_WORK/awk-guard"
  awk -f "$BOOTSTRAP_WORK/awk-guard" -f "$1" /dev/null >/dev/null 2>&1 || {
    bootstrap_prog_close
    ui_fail "Файл не прошёл проверку синтаксиса AWK: $1"
    return 1
  }
}

bootstrap_header() {
  # Тот же протокол разбора, что update.sh:bootstrap_header, но берёт ВСЕ
  # строки FILE (все компоненты), а не только updater - первичная
  # установка ставит весь проект, а не только обновлятор.
  awk -F'|' '
    function bad(){exit 1}
    /^[A-Z_]+=/ {
      if (split($0,h,"=") != 2 || seen[h[1]]++) bad()
      if (h[1]=="FORMAT_VERSION") fmt=h[2]
      if (h[1]=="RELEASE_TAG") tag=h[2]
      if (h[1] ~ /^(RELEASE_VERSION|MIN_UPDATER_VERSION|CONFIG_SCHEMA_VERSION)$/ && h[2] !~ /^[0-9]+$/) bad()
      next
    }
    $1=="FILE" {
      if (NF!=8 || used[$3]++) bad()
      if ($3 !~ /^[A-Za-z0-9_.-]+$/) bad()
      if ($5 !~ /^[0-9]+$/ || $5+0<1 || $5+0>10485760 || $6 !~ /^[0-9a-f]{64}$/) bad()
      if ($7 !~ /^[0-7]{3,4}$/) bad()
      if ($8 !~ /^(sh|awk|py|none)$/) bad()
      row[++n]=$0
    }
    END {
      if (fmt!="2" || tag !~ /^[A-Za-z0-9][A-Za-z0-9_.-]*$/ || tag ~ /\.\./ || n<1 ||
          !seen["RELEASE_VERSION"] || !seen["MIN_UPDATER_VERSION"] || !seen["CONFIG_SCHEMA_VERSION"]) exit 1
      for (i=1;i<=n;i++) print row[i]
    }
  ' "$BOOTSTRAP_MANIFEST" > "$BOOTSTRAP_WORK/files" || {
    echo "Манифест релиза не прошёл проверку - установка остановлена" >&2
    return 1
  }
}

bootstrap_pinned_base() {
  case $UPDATE_RELEASE_BASE in
    */releases/latest/download)
      if [ -n "${BOOTSTRAP_DEV_TAG:-}" ]; then
        # Канал dev: манифест скачан по тегу из списка релизов - он обязан
        # описывать именно этот релиз (та же проверка, что в update.sh).
        [ "$(bootstrap_manifest_field "$BOOTSTRAP_MANIFEST" RELEASE_TAG)" = "$BOOTSTRAP_DEV_TAG" ] || {
          ui_fail "Манифест не соответствует выбранному релизу $BOOTSTRAP_DEV_TAG"
          return 1
        }
      fi
      BOOTSTRAP_PINNED_BASE=${UPDATE_RELEASE_BASE%/latest/download}/download/$(bootstrap_manifest_field "$BOOTSTRAP_MANIFEST" RELEASE_TAG) ;;
    *) echo "Для установки нужен источник вида .../releases/latest/download" >&2; return 1 ;;
  esac
}

# --- Канал обновлений при установке с нуля --------------------------------
# Спрашиваем только здесь, в бутстрапе: при переустановке поверх файлы уже
# на роутере, и смена канала ничего бы не скачала (канал меняется в
# веб-интерфейсе, вкладка «Обновления»). Результат - INSTALL_CHANNEL
# (stable|dev); его экспортируют, чтобы он пережил exec в setup.sh и
# обратно, а write_env записал его в speedtest2.env как UPDATE_CHANNEL.
# UPDATE_CHANNEL в окружении - ответ без вопроса. Ответ читаем прямо из
# терминала (INSTALL_TTY, по умолчанию /dev/tty): под "curl | sh" stdin -
# тело скрипта, а reopen_tty объявлена ниже. Нет терминала - stable.
bootstrap_choose_channel() {
  case ${UPDATE_CHANNEL:-} in
    dev|stable) INSTALL_CHANNEL=$UPDATE_CHANNEL; return 0 ;;
    '') ;;
    *) ui_warn "Неизвестный UPDATE_CHANNEL=$UPDATE_CHANNEL (ждали stable или dev) - ставлю стабильный"
       INSTALL_CHANNEL=stable; return 0 ;;
  esac
  # По умолчанию - канал, уже сохранённый в speedtest2.env (незавершённая
  # прошлая установка), иначе stable.
  bcc_def=1
  case $(sed -n "s/^UPDATE_CHANNEL=['\"]*\([a-z]*\).*/\1/p" "$DIR/speedtest2.env" 2>/dev/null | tail -n 1) in
    dev) bcc_def=2 ;;
  esac
  INSTALL_CHANNEL=stable
  [ "$bcc_def" = 2 ] && INSTALL_CHANNEL=dev
  bcc_tty=${INSTALL_TTY:-/dev/tty}
  # Терминал должен реально открываться на чтение (не просто существовать).
  # Проба в подоболочке: ошибка перенаправления у спецкоманды ":" завершила
  # бы под POSIX sh весь скрипт, а не только эту проверку.
  ( : < "$bcc_tty" ) 2>/dev/null || return 0
  ui_menu "Канал обновлений" "$bcc_def" "стабильный" "разработка (dev) - новые функции раньше, возможны ошибки"
  ui_ask "Номер или Enter"
  bcc_ans=
  { read -r bcc_ans < "$bcc_tty"; } 2>/dev/null || { bcc_ans=; printf '\n' >&2; }
  case $bcc_ans in
    1) INSTALL_CHANNEL=stable ;;
    2) INSTALL_CHANNEL=dev ;;
  esac
  return 0
}

# Канал dev: наибольший тег x.y.z среди последних релизов GitHub (включая
# pre-release). Не первый по дате: стабильный hotfix (1.4.2), вышедший
# после dev 1.5.0, не должен откатывать канал. Тот же алгоритм, что
# update.sh:resolve_channel_base - установка и обновления dev берут один и
# тот же релиз. Нет списка - установка останавливается: тихо поставить
# stable вместо выбранного dev было бы обманом.
bootstrap_resolve_dev() {
  bootstrap_download_to "${UPDATE_RELEASES_API:-https://api.github.com/repos/f0nwa/mihomo-speedtest/releases?per_page=5}" \
      "$BOOTSTRAP_WORK/releases.json" 4194304 || {
    # API недоступен (403 - лимит запросов на IP): теги со страницы релизов.
    bootstrap_download_to "${UPDATE_RELEASES_FALLBACK:-https://github.com/f0nwa/mihomo-speedtest/releases}" \
        "$BOOTSTRAP_WORK/releases.html" 4194304 &&
      grep -Eo '/releases/tag/[0-9]+\.[0-9]+\.[0-9]+' "$BOOTSTRAP_WORK/releases.html" |
        sed 's|.*/|{"tag_name":"|; s|$|"}|' > "$BOOTSTRAP_WORK/releases.json" || {
      ui_fail "Не удалось получить список релизов для канала dev"
      return 1
    }
  }
  BOOTSTRAP_DEV_TAG=$(awk '
    function newer(a, b,   x, y, i) {
      split(a, x, "."); split(b, y, ".")
      for (i = 1; i <= 3; i++) if (x[i] + 0 != y[i] + 0) return x[i] + 0 > y[i] + 0
      return 0
    }
    {
      s = $0
      while (match(s, /"tag_name"[ \t]*:[ \t]*"[^"]*"/)) {
        t = substr(s, RSTART, RLENGTH); s = substr(s, RSTART + RLENGTH)
        sub(/^"tag_name"[ \t]*:[ \t]*"/, "", t); sub(/"$/, "", t)
        if (t ~ /^[0-9]+\.[0-9]+\.[0-9]+$/ && (best == "" || newer(t, best))) best = t
      }
    }
    END { if (best != "") print best }' "$BOOTSTRAP_WORK/releases.json")
  [ -n "$BOOTSTRAP_DEV_TAG" ] || {
    ui_fail "В списке релизов нет тега вида x.y.z для канала dev"
    return 1
  }
}

bootstrap_selfinstall() {
  BOOTSTRAP_SHA_TOOL=$(bootstrap_sha256_tool) || {
    echo "Не найден инструмент SHA256 (sha256sum/openssl/busybox) - установка остановлена" >&2
    return 1
  }
  bootstrap_tmproot=${TMPROOT:-/tmp}
  BOOTSTRAP_WORK=$(mktemp -d "$bootstrap_tmproot/mst-install-bootstrap.XXXXXX") || return 1
  BOOTSTRAP_MANIFEST=$BOOTSTRAP_WORK/manifest.txt

  ui_step 1 6 "Загрузка релиза"
  echo "Рядом нет файлов проекта - скачиваю релиз с GitHub ($UPDATE_RELEASE_BASE)" >&2

  # Канал dev: манифест берём не из releases/latest (там всегда
  # стабильный), а из наибольшего тега списка релизов.
  BOOTSTRAP_DEV_TAG=
  bootstrap_manifest_url=$UPDATE_RELEASE_BASE/manifest.txt
  bootstrap_channel_note=
  if [ "${INSTALL_CHANNEL:-stable}" = dev ]; then
    case $UPDATE_RELEASE_BASE in
      */releases/latest/download) ;;
      *) echo "Для установки нужен источник вида .../releases/latest/download" >&2; rm -rf "$BOOTSTRAP_WORK"; return 1 ;;
    esac
    bootstrap_resolve_dev || { rm -rf "$BOOTSTRAP_WORK"; return 1; }
    bootstrap_manifest_url=${UPDATE_RELEASE_BASE%/latest/download}/download/$BOOTSTRAP_DEV_TAG/manifest.txt
    bootstrap_channel_note=" (dev)"
  fi
  bootstrap_download_to "$bootstrap_manifest_url" "$BOOTSTRAP_MANIFEST" 262144 || { rm -rf "$BOOTSTRAP_WORK"; return 1; }
  bootstrap_header || { rm -rf "$BOOTSTRAP_WORK"; return 1; }
  bootstrap_pinned_base || { rm -rf "$BOOTSTRAP_WORK"; return 1; }
  ui_ok "Манифест $(bootstrap_manifest_field "$BOOTSTRAP_MANIFEST" RELEASE_TAG)$bootstrap_channel_note"

  mkdir -p "$DIR" || { echo "Не удалось создать $DIR" >&2; rm -rf "$BOOTSTRAP_WORK"; return 1; }

  # Проход 1: скачать и проверить всё во временном каталоге. Ничего не
  # пишем в DIR, пока не убедимся, что весь набор цел - иначе отказ на
  # середине списка оставил бы в DIR наполовину установленный проект.
  # Полоса прогресса N/TOTAL перед каждым файлом - иначе на медленной
  # сети скачивание полного набора (см. release/components.txt) выглядит
  # как зависший скрипт. Одна перерисовываемая строка, а не по строке на
  # файл: так экран не зарастает десятками "Скачиваю файл...".
  bootstrap_total=$(wc -l < "$BOOTSTRAP_WORK/files" | tr -d ' ')
  bootstrap_idx=0
  bootstrap_t0=$(date +%s)
  while IFS='|' read -r kind cid src dest bytes sum mode check; do
    bootstrap_idx=$((bootstrap_idx + 1))
    bootstrap_prog "Файлы релиза" "$bootstrap_idx" "$bootstrap_total" "$src"
    bootstrap_download_to "$BOOTSTRAP_PINNED_BASE/$src" "$BOOTSTRAP_WORK/$src" "$bytes" || { rm -rf "$BOOTSTRAP_WORK"; return 1; }
    bootstrap_check_download "$BOOTSTRAP_WORK/$src" "$bytes" "$sum" || { rm -rf "$BOOTSTRAP_WORK"; return 1; }
    case $check in
      sh) sh -n "$BOOTSTRAP_WORK/$src" || { bootstrap_prog_close; ui_fail "Неверный синтаксис sh: $src"; rm -rf "$BOOTSTRAP_WORK"; return 1; } ;;
      awk) bootstrap_awk_syntax "$BOOTSTRAP_WORK/$src" || { rm -rf "$BOOTSTRAP_WORK"; return 1; } ;;
    esac
  done < "$BOOTSTRAP_WORK/files"
  bootstrap_prog_close
  ui_ok "Файлы релиза ($bootstrap_total) проверены" $(($(date +%s) - bootstrap_t0))

  # Проход 2: весь набор проверен - переносим в DIR.
  while IFS='|' read -r kind cid src dest bytes sum mode check; do
    mv "$BOOTSTRAP_WORK/$src" "$DIR/$src" || { echo "Не удалось записать $DIR/$src" >&2; rm -rf "$BOOTSTRAP_WORK"; return 1; }
    chmod "$mode" "$DIR/$src" || { echo "Не удалось задать режим $DIR/$src" >&2; return 1; }
  done < "$BOOTSTRAP_WORK/files"

  # Тег - хвост BOOTSTRAP_PINNED_BASE (.../download/<RELEASE_TAG>), берём
  # ДО удаления временного каталога с манифестом ниже.
  bootstrap_tag=${BOOTSTRAP_PINNED_BASE##*/}

  # Сохраняем сам манифест релиза как installed-manifest.txt - тот же файл
  # и формат, что пишет update_transaction.sh после обновления (см.
  # update.sh:INSTALLED_MANIFEST_PATH). Это единый источник истины о том,
  # что реально установлено - его читает uninstall.sh при полном сносе
  # проекта, вместо отдельного захардкоженного списка. Неудача записи не
  # должна валить установку - при её отсутствии uninstall.sh просто
  # использует запасной список (см. uninstall.sh:FALLBACK_PROJECT_FILES).
  if mkdir -p "$UPDATE_STATE_DIR" 2>/dev/null; then
    bootstrap_manifest_tmp="$UPDATE_STATE_DIR/.installed-manifest.$$.tmp"
    if cp "$BOOTSTRAP_MANIFEST" "$bootstrap_manifest_tmp" 2>/dev/null; then
      chmod 0600 "$bootstrap_manifest_tmp" 2>/dev/null || true
      mv "$bootstrap_manifest_tmp" "$INSTALLED_MANIFEST_PATH" 2>/dev/null || rm -f "$bootstrap_manifest_tmp"
    fi
  fi

  rm -rf "$BOOTSTRAP_WORK"
  ui_ok "Файлы проекта загружены и проверены (тег $bootstrap_tag)"
  SELFDIR=$DIR
}

bootstrap_needed() {
  for bf in $ALL_PROJECT_FILES; do
    [ -f "$SELFDIR/$bf" ] || return 0
  done
  return 1
}

# Лёгкие действия (--stop-web/--start-web/--show-url/--version) - чисто
# локальные операции (флаг STATS_HTTP_ENABLE в speedtest2.env, чтение уже
# сохранённого installed-manifest.txt, init.d-скрипт) - им не нужен ни
# полный набор файлов проекта, ни сеть. Раньше бутстрап-проверка выше
# запускалась безусловно, до разбора аргументов (см. case в самом низу
# файла) - поэтому "mihomo-speedtest stop-web" на роутере с неполным $DIR
# неожиданно тащил весь релиз с GitHub вместо простого локального
# переключения (см. CHANGELOG).
bootstrap_skip_for_action() {
  case "${1:-}" in
    --stop-web | --start-web | --show-url | --version) return 0 ;;
    *) return 1 ;;
  esac
}

if [ "${INSTALL_LIB_ONLY:-0}" != 1 ] && ! bootstrap_skip_for_action "${1:-}" && bootstrap_needed; then
  UPDATE_RELEASE_BASE=${UPDATE_RELEASE_BASE:-https://github.com/f0nwa/mihomo-speedtest/releases/latest/download}
  UPDATE_RELEASE_BASE=${UPDATE_RELEASE_BASE%/}
  [ -z "${INSTALL_PROXY:-}" ] || bootstrap_enable_proxy
  # Баннер - один раз за процесс (флаг UI_BANNER_SHOWN, его же проверяет
  # main()). UI_STEPS_BOOT=1: бутстрап занял шаг 1 из 6, дальнейшие шаги
  # main() нумерует с учётом этого (без бутстрапа шагов 5).
  ui_init
  ui_banner "MIHOMO-SPEEDTEST" "быстрый пул · статистика нод"
  UI_BANNER_SHOWN=1
  UI_STEPS_BOOT=1
  # Прерывание (Ctrl+C) не должно оставить открытым временный mixed-port:
  # хук выполнится на выходе (EXIT/INT/TERM); он идемпотентен.
  ui_on_exit bootstrap_disable_proxy
  # Прежний тег - до того, как бутстрап перезапишет installed-manifest.txt
  # (для строки «Режим: Переустановка (было → станет)» в main()).
  MST_PREV_TAG=$(bootstrap_manifest_field "$INSTALLED_MANIFEST_PATH" RELEASE_TAG 2>/dev/null) || MST_PREV_TAG=
  # Канал обновлений - до загрузки: от него зависит, какой релиз качать.
  bootstrap_choose_channel
  export INSTALL_CHANNEL
  bootstrap_rc=0
  bootstrap_selfinstall || bootstrap_rc=$?
  bootstrap_prog_close
  bootstrap_disable_proxy
  BOOTSTRAP_PROXY=
  [ "$bootstrap_rc" -eq 0 ] || {
    bootstrap_fail_hint
    echo "Автоматическая установка не удалась. Скопируйте файлы проекта на роутер вручную (см. README.md) и запустите sh install.sh снова" >&2
    exit 1
  }
fi

. "$SELFDIR/version_check.sh"
# Настоящая библиотека перекрывает встроенную копию. Файла может не быть:
# лёгкие действия (--stop-web и т.п.) идут мимо бутстрапа и на старой
# установке без ui.sh обходятся встроенной копией; под set -e голый
# `[ -f ] && .` при отсутствии файла прервал бы скрипт, поэтому if.
if [ -f "$SELFDIR/ui.sh" ]; then . "$SELFDIR/ui.sh"; fi

# Минимальный гео-фильтр, если в конфиге его нет: только российские ноды
# (подстроки без учёта регистра, см. prep.awk).
MIN_BLOCK='🇷🇺|Russia|Россия|RU-|RU_|Moscow|Москва|MSK|SPB|СПб'

normalize_block() {
  # BLOCK - список подстрок через | (см. prep.awk), не regex: убираем
  # пробелы вокруг | и по краям и префикс "(?i)" у кусков (след копирования
  # exclude-filter из config.yaml). Та же функция есть в web/stats_cgi.sh.
  printf '%s\n' "$1" | sed -e 's/[[:space:]]*|[[:space:]]*/|/g' \
    -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
    -e 's/^(?i)//' -e 's/|(?i)/|/g'
}

warn_regex_block() {
  # Куски BLOCK с символами регулярных выражений (\ ^ $ * + ? ( ) [ ] { }):
  # в спидтесте они ищутся буквально, так что такой кусок почти наверняка
  # ничего не отсечёт. Установку не останавливает - только предупреждает
  # (то же правило, что замечание в веб-форме, stats_app_settings.js:geoWarnings()).
  bad=$(printf '%s\n' "$1" | awk -F'|' '{
    for (i = 1; i <= NF; i++) if ($i ~ /[][\\^$*+?(){}]/) printf "  %s\n", $i
  }')
  [ -n "$bad" ] || return 0
  # Жёлтым блоком: установку не останавливает, но пропустить глазами не должно.
  {
    echo "ВНИМАНИЕ: гео-фильтр спидтеста (BLOCK) - не регулярное выражение, а список"
    echo "слов через |: нода пропускается, если её имя содержит любое из них."
    echo "Эти куски похожи на регулярное выражение и будут искаться буквально,"
    echo "поэтому, скорее всего, ничего не отсекут:"
    printf '%s\n' "$bad"
    echo "Поправьте фильтр в веб-интерфейсе (Настройки -> «Какие ноды не проверять»)"
    echo "или переустановите с BLOCK='слово1|слово2' sh install.sh."
  } | ui_note warn
}

# В конфиге нет ни подписок, ни своих нод: ядро без них не запускают, а
# подписку или WireGuard-ноду добавляют уже из веб-интерфейса (вкладка
# «Конфиг»). Провайдер fast (файл с победителями спидтеста) нодами не
# считается. Код 0 - нод нет.
config_no_nodes() {
  awk '
    /^[A-Za-z0-9_-]+:/ { sect = ($0 ~ /^proxy-providers:/) ? 1 : (($0 ~ /^proxies:/) ? 2 : 0); next }
    sect == 1 && /^  [A-Za-z0-9_-]+:[ ]*$/ { if ($1 != "fast:") found = 1 }
    sect == 2 && /^  - / { found = 1 }
    END { exit found ? 1 : 0 }
  ' "$1" 2>/dev/null
}

# Слова гео-фильтра из exclude-filter: &geofilter конфига (без префикса (?i)).
config_geofilter_block() {
  sed -n "s/.*exclude-filter: &geofilter '\([^']*\)'.*/\1/p" "$1" 2>/dev/null | head -n 1 | sed 's/^(?i)//'
}

# Проверка окружения: пока нет конфига или в нём нет нод, ядро не обязано
# работать (так и задумано - его не запускают без нод), нужны только версии.
install_env_check() {
  if [ ! -f "$CONFIG" ] || config_no_nodes "$CONFIG"; then
    check_versions
  else
    check_mihomo_process && check_versions
  fi
}

resolve_block() {
  resolve_block_raw || return 1
  BLOCK=$(normalize_block "$BLOCK")
  if [ -z "$BLOCK" ]; then
    ui_fail "Пустой фильтр недопустим. Повторите с BLOCK='...' sh install.sh"
    return 1
  fi
  warn_regex_block "$BLOCK"
  return 0
}

resolve_block_raw() {
  if [ -n "${BLOCK:-}" ]; then
    BLOCK_SOURCE="переменная окружения"
    return 0
  fi

  count=${BLOCK_COUNT:-0}

  if [ "$count" -eq 1 ]; then
    BLOCK=$BLOCK_1
    BLOCK_SOURCE="из конфига"
    return 0
  fi

  if [ "$count" -gt 1 ]; then
    # Пункты меню - позиционные параметры (у функции своих аргументов нет);
    # варианта по умолчанию нет (0): Enter даёт пустой фильтр и отказ.
    set --
    i=1
    while [ "$i" -le "$count" ]; do
      eval "val=\$BLOCK_$i"
      set -- "$@" "$val"
      i=$((i + 1))
    done
    ui_menu "Найдено несколько разных гео-фильтров:" 0 "$@"
    ui_ask "Введите номер варианта или свой фильтр"
    read -r choice || choice=""
    case $choice in
      ''|*[!0-9]*)
        BLOCK=$choice
        BLOCK_SOURCE="введён вручную"
        ;;
      *)
        if [ "$choice" -ge 1 ] && [ "$choice" -le "$count" ]; then
          eval "BLOCK=\$BLOCK_$choice"
          BLOCK_SOURCE="из конфига (вариант $choice)"
        else
          ui_fail "Номер вне диапазона"
          BLOCK=""
        fi
        ;;
    esac
    if [ -z "$BLOCK" ]; then
      ui_fail "Пустой или неверный фильтр недопустим. Повторите с BLOCK='...' sh install.sh"
      return 1
    fi
    return 0
  fi

  # Фильтра в конфиге нет (или parser его не нашёл). Не отказываем, а
  # предлагаем выбор: минимальный (только российские ноды), стандартный
  # (якорь &geofilter из config.example.yaml - тот же, что мастер setup.sh
  # пишет в новый конфиг) или свой. Enter и отсутствие ответа (нет
  # терминала) - минимальный: он всегда есть и решает главную задачу.
  default=$(default_block)
  # Заголовок меню - две строки (перевод строки внутри), пункт 2 - только
  # если в config.example.yaml нашёлся якорь &geofilter.
  set -- "минимальный - только российские ноды: $MIN_BLOCK"
  if [ -n "$default" ]; then
    set -- "$@" "стандартный из config.example.yaml - Россия, ряд дальних стран, служебные группы"
  fi
  ui_menu "Гео-фильтр (exclude-filter) не найден в конфиге.
Без него спидтест может выбрать российскую ноду, выигравшую замер по пингу." 1 "$@"
  ui_ask "Введите номер, свой фильтр (слова через |) или Enter для 1"
  read -r input || { input=""; echo >&2; }
  case $input in
    ''|1)
      BLOCK=$MIN_BLOCK
      BLOCK_SOURCE="минимальный"
      ;;
    2)
      if [ -n "$default" ]; then
        BLOCK=$default
        BLOCK_SOURCE="стандартный из config.example.yaml"
      else
        BLOCK=$input
        BLOCK_SOURCE="введён вручную"
      fi
      ;;
    *)
      BLOCK=$input
      BLOCK_SOURCE="введён вручную"
      ;;
  esac
  return 0
}

default_block() {
  # Значение якоря &geofilter из config.example.yaml (лежит рядом с
  # install.sh, входит в PROJECT_TOOLS). Пусто, если файла или якоря нет.
  [ -f "$SELFDIR/config.example.yaml" ] || return 0
  sed -n "s/.*exclude-filter:[[:space:]]*&geofilter[[:space:]]*'\([^']*\)'.*/\1/p" \
    "$SELFDIR/config.example.yaml" | head -n 1
}

reopen_tty() {
  # Под "curl ... | sh" стандартный ввод занят телом самого install.sh -
  # без переоткрытия от терминала интерактивные read -r сразу получат EOF
  # вместо ответов пользователя. Если stdin уже терминал (обычный
  # "sh install.sh") - трогать не нужно; если терминала нет вовсе -
  # оставляем как есть.
  # "exec < /dev/tty" сам по себе фатален для sh при неудаче (нет
  # управляющего терминала - это нормально для не-интерактивных
  # запусков), даже с последующим "|| true" - POSIX требует, чтобы shell
  # завершился при ошибке редиректа у голого exec без команды. Поэтому
  # сначала пробуем открыть /dev/tty в отдельном подшелле: его неудача
  # убивает только подшелл, а не install.sh.
  if [ ! -t 0 ] && (exec < /dev/tty) 2>/dev/null; then
    exec < /dev/tty
  fi
}

install_cron() {
  cron_line="0 */3 * * * $INSTALLED_SCRIPT"
  current=$(crontab -l 2>/dev/null || true)
  if printf '%s\n' "$current" | grep -qF "$INSTALLED_SCRIPT"; then
    return 0
  fi
  printf '%s\n' "$current" > "$TMPROOT/cron.bak"
  { [ -n "$current" ] && printf '%s\n' "$current"; echo "$cron_line"; } | crontab -
}

install_update_check_cron() {
  # Фоновая проверка обновлений раз в UPDATE_CHECK_HOURS часов (по
  # умолчанию 12, поле "Проверять обновления" в настройках веб-интерфейса;
  # см. cmd_cron_sync() в web/stats_update.sh - та же формула, здесь
  # продублирована: install.sh не подключает stats_update.sh). Отдельная
  # от install_cron() cron-строка и отдельный бэкап-файл (cron-update.bak,
  # не cron.bak), чтобы обе функции не затирали бэкап друг друга при
  # последовательном вызове из main(). Минута 17 выбрана так, чтобы не
  # совпадать с минутой "0" cron-строки speedtest2.sh. Уже стоящую строку
  # с другой частотой (например, старую ежедневную "17 5") заменяет.
  hours=$(sed -n "s/^UPDATE_CHECK_HOURS=['\"]\{0,1\}\([0-9]*\)['\"]\{0,1\}\$/\1/p" "${ENVFILE:-$DIR/speedtest2.env}" 2>/dev/null | tail -n 1)
  case $hours in
    24) cron_line="17 5 * * * $UPDATE_CHECK_SCRIPT check" ;;
    1) cron_line="17 * * * * $UPDATE_CHECK_SCRIPT check" ;;
    2|3|4|6|8|12) cron_line="17 */$hours * * * $UPDATE_CHECK_SCRIPT check" ;;
    *) cron_line="17 */12 * * * $UPDATE_CHECK_SCRIPT check" ;;
  esac
  current=$(crontab -l 2>/dev/null || true)
  if [ "$(printf '%s\n' "$current" | grep -F "$UPDATE_CHECK_SCRIPT")" = "$cron_line" ]; then
    return 0
  fi
  printf '%s\n' "$current" > "$TMPROOT/cron-update.bak"
  rest=$(printf '%s\n' "$current" | grep -vF "$UPDATE_CHECK_SCRIPT" || true)
  { [ -n "$rest" ] && printf '%s\n' "$rest"; echo "$cron_line"; } | crontab -
}

atomic_install() {
  src=$1
  dst=$2
  dstdir=${dst%/*}
  dstbase=${dst##*/}
  tmp=$dstdir/.$dstbase.$$
  if ! cp "$src" "$tmp"; then rm -f "$tmp"; return 1; fi
  case $src in *.sh) mode=0755 ;; *) mode=0644 ;; esac
  if ! chmod "$mode" "$tmp"; then rm -f "$tmp"; return 1; fi
  if ! mv "$tmp" "$dst"; then rm -f "$tmp"; return 1; fi
}

ensure_mihomo_speedtest_symlink() {
  # $1 - путь к mihomo-speedtest.sh, $2/$3 - каталоги-кандидаты для ссылки
  # (по умолчанию /opt/sbin и /opt/bin - см. вызов ниже; параметризовано
  # ради тестируемости без системных путей). Публикация символической
  # ссылки через манифест/транзакцию обновлятора невозможна (см.
  # docs/superpowers/specs/2026-09-26-mihomo-speedtest-cli-design.md,
  # раздел 3) - функция продублирована здесь, в update.sh и в uninstall.sh
  # по образцу уже существующего дублирования has_fast_group().
  target=$1
  for bindir in "${2:-/opt/sbin}" "${3:-/opt/bin}"; do
    [ -d "$bindir" ] && [ -w "$bindir" ] || continue
    link=$bindir/mihomo-speedtest
    if [ -e "$link" ] && [ ! -L "$link" ]; then
      ui_warn "$link уже существует и не является символической ссылкой - не трогаю, пробую следующий каталог"
      continue
    fi
    current=$(readlink "$link" 2>/dev/null) || current=""
    # Ссылка уже на месте (переустановка) - тоже галочка: строка шага
    # «Установка файлов и служб» перечисляет всё, что проверено.
    if [ "$current" = "$target" ] || ln -sf "$target" "$link" 2>/dev/null; then
      ui_ok "Команда доступна как: mihomo-speedtest (симлинк в $bindir)"
      return 0
    fi
  done
  ui_warn "не удалось создать символическую ссылку mihomo-speedtest в /opt/sbin или /opt/bin - используйте полный путь: sh $target"
  return 0
}

# PROJECT_TOOLS определён выше, рядом с DIR/SELFDIR (нужен и bootstrap-
# триггеру, который срабатывает раньше этого места файла).
install_files() {
  for project_file in $PROJECT_TOOLS; do
    atomic_install "$SELFDIR/$project_file" "$DIR/$project_file" || return 1
  done
  atomic_install "$SELFDIR/speedtest2.sh" "$DIR/speedtest2.sh" || return 1
  chmod +x "$DIR/speedtest2.sh"
  atomic_install "$SELFDIR/prep.awk" "$DIR/prep.awk" || return 1
  atomic_install "$SELFDIR/render_stats.awk" "$DIR/render_stats.awk" || return 1
  atomic_install "$SELFDIR/stats_cgi.sh" "$DIR/stats_cgi.sh" || return 1
  chmod +x "$DIR/stats_cgi.sh"
  atomic_install "$SELFDIR/stats_run.sh" "$DIR/stats_run.sh" || return 1
  chmod +x "$DIR/stats_run.sh"
  atomic_install "$SELFDIR/stats_update.sh" "$DIR/stats_update.sh" || return 1
  chmod +x "$DIR/stats_update.sh"
  atomic_install "$SELFDIR/stats_config.sh" "$DIR/stats_config.sh" || return 1
  chmod +x "$DIR/stats_config.sh"
  atomic_install "$SELFDIR/stats_xkeen.sh" "$DIR/stats_xkeen.sh" || return 1
  chmod +x "$DIR/stats_xkeen.sh"
  atomic_install "$SELFDIR/stats_components.sh" "$DIR/stats_components.sh" || return 1
  chmod +x "$DIR/stats_components.sh"
  atomic_install "$SELFDIR/stats_constructor.sh" "$DIR/stats_constructor.sh" || return 1
  chmod +x "$DIR/stats_constructor.sh"
  # статические файлы SPA-shell (см. docs/plans/2026-09-12-web-spa-migration-design.md)
  # веб-сервиса статистики - stats_httpd.py раздаёт их прямо из $DIR;
  # исполняемый бит не нужен.
  atomic_install "$SELFDIR/stats_index.html" "$DIR/stats_index.html" || return 1
  atomic_install "$SELFDIR/stats_style.css" "$DIR/stats_style.css" || return 1
  atomic_install "$SELFDIR/stats_app.js" "$DIR/stats_app.js" || return 1
  for m in core stats settings updates log config xkeen components constructor constructor_model constructor_modules constructor_modules_model; do
    atomic_install "$SELFDIR/stats_app_$m.js" "$DIR/stats_app_$m.js" || return 1
  done
  # stats_codemirror.js/.css - вендоренный CodeMirror 5 для вкладки "Конфиг".
  atomic_install "$SELFDIR/stats_codemirror.js" "$DIR/stats_codemirror.js" || return 1
  atomic_install "$SELFDIR/stats_codemirror.css" "$DIR/stats_codemirror.css" || return 1
  # обязательный веб-сервер на python3 (см. docs/guide.md, "Обязательная
  # авторизация веб-интерфейса") - запускается start_backend() в
  # stats_service.sh (порция 3, независимая служба); исполняемый бит не
  # нужен, он вызывается как "python3 stats_httpd.py", а не напрямую.
  # stats_auth.py - ядро авторизации (импортируется stats_httpd.py),
  # stats_auth.sh - сброс логина и пароля по SSH (sh stats_auth.sh reset).
  atomic_install "$SELFDIR/stats_httpd.py" "$DIR/stats_httpd.py" || return 1
  atomic_install "$SELFDIR/stats_auth.py" "$DIR/stats_auth.py" || return 1
  atomic_install "$SELFDIR/stats_auth.sh" "$DIR/stats_auth.sh" || return 1
  # вызывается напрямую через "awk -f", как prep.awk/render_stats.awk -
  # исполняемый бит не нужен.
  atomic_install "$SELFDIR/node_stats_update.awk" "$DIR/node_stats_update.awk" || return 1
  # вызывается напрямую через "awk -f" в speedtest2.sh - исполняемый бит не нужен.
  atomic_install "$SELFDIR/sub_convert.awk" "$DIR/sub_convert.awk" || return 1
  # прогресс скоростного теста по нодам текущего прогона (write_progress()
  # в speedtest2.sh) - вызывается напрямую через "awk -f", исполняемый бит
  # не нужен.
  atomic_install "$SELFDIR/render_progress.awk" "$DIR/render_progress.awk" || return 1
  # независимая служба веб-интерфейса статистики (порция 3, см.
  # docs/superpowers/specs/2026-09-15-independent-stats-service-design.md) -
  # supervisor ставится рядом с остальными файлами в $DIR, а сам
  # init-скрипт - прямо в каталог автозапуска Entware, чтобы rc.unslung
  # подхватил его при следующей загрузке /opt без отдельного шага.
  atomic_install "$SELFDIR/stats_service.sh" "$STATS_SERVICE_DEST" || return 1
  chmod +x "$STATS_SERVICE_DEST"
  mkdir -p "$INITD_DIR" 2>/dev/null || true
  atomic_install "$SELFDIR/stats_init.sh" "$INITD_SCRIPT" || return 1
  chmod +x "$INITD_SCRIPT"
  # Символическая ссылка mihomo-speedtest ставится отдельным подшагом в
  # main() (ensure_mihomo_speedtest_symlink) - после галочки файлов.
}

format_mbit() {
  # байт/с -> Мбит/с с одним знаком, как в журнале speedtest2.sh
  LC_ALL=C awk -v speed="$1" 'BEGIN { printf "%.1f", speed / 125000 }'
}

write_env() {
  dst=$1
  dstdir=${dst%/*}
  dstbase=${dst##*/}
  tmp=$dstdir/.$dstbase.$$
  {
    echo "# создано install.sh $(date '+%F %T')"
    echo "# фильтр: $BLOCK_SOURCE"
    printf "SOURCES='%s'\n" "$SOURCES"
    # EXTYPE из окружения установщика - как раньше; иначе сохраняем то,
    # что пользователь задал в веб-настройках.
    if [ -n "${EXTYPE:-}" ]; then
      printf "EXTYPE='%s'\n" "$EXTYPE"
    else
      sed -n '/^EXTYPE=/p' "$dst" 2>/dev/null | tail -1
    fi
    printf "BLOCK='%s'\n" "$BLOCK"
    printf "MIN_SPEED='%s'\n" "$MIN_SPEED"
    # При повторной установке сохраняем пользовательские лимиты отбора.
    for limit_key in MAX_TESTED TOPN ENOUGH MIN_WINNERS; do
      saved_limit=$(sed -n "/^$limit_key=/p" "$dst" 2>/dev/null | tail -1)
      if [ -n "$saved_limit" ]; then
        printf '%s\n' "$saved_limit"
      else
        case $limit_key in
          MAX_TESTED) limit_default=40 ;;
          TOPN) limit_default=15 ;;
          ENOUGH) limit_default=20 ;;
          MIN_WINNERS) limit_default=3 ;;
        esac
        printf "%s='%s'\n" "$limit_key" "$(read_speedtest_const "$limit_key" "$limit_default")"
      fi
    done
    # Остальные поля веб-настроек (stats_cgi.sh) при переустановке тоже не
    # сбрасываем к умолчаниям: пишем прежнюю строку, если она была. Список
    # явный, чтобы удалённые из проекта настройки (например MAX_PING_MS)
    # по-прежнему вычищались переустановкой.
    for keep_key in SIZE DL_TIMEOUT MIN_RATIO MIN_FLOOR STABILITY_WINDOW STABILITY_DROP_AFTER \
        HISTORY_KEEP_RUNS HISTORY_KEEP_DAYS STATS_NODE_CAP UPDATE_CHECK_HOURS; do
      sed -n "/^$keep_key=/p" "$dst" 2>/dev/null | tail -1
    done
    # Канал обновлений: выбранный при установке с нуля (INSTALL_CHANNEL из
    # бутстрапа) важнее прежнего; иначе сохраняем канал из веб-настроек.
    case ${INSTALL_CHANNEL:-} in
      dev|stable) printf "UPDATE_CHANNEL='%s'\n" "$INSTALL_CHANNEL" ;;
      *) sed -n "/^UPDATE_CHANNEL=/p" "$dst" 2>/dev/null | tail -1 ;;
    esac
    # STATS_HTTP_ENABLE - персистентный флаг stop-web/start-web (см.
    # docs/superpowers/specs/2026-09-26-mihomo-speedtest-cli-design.md,
    # раздел 4): фиксированный дефолт '1', а не число из read_speedtest_const -
    # у read_speedtest_const's awk-парсера свой формат под NAME=число, а не
    # под NAME=${NAME:-1}, как объявлен STATS_HTTP_ENABLE в speedtest2.sh.
    # Без кавычек - web/stats_init.sh:stats_enabled() читает эту переменную
    # наивным sed-разбором (s/^STATS_HTTP_ENABLE=//p), не полноценным ".",
    # и кавычки попали бы в значение буквально (val="'1'" != "1") - служба
    # решила бы, что флаг выключен, хотя он включён. В отличие от прочих
    # полей этого файла (BLOCK, лимиты и т.п.), которые читает только
    # обычный "." - там кавычки безопасны и стилистически единообразны.
    saved_web_enable=$(sed -n '/^STATS_HTTP_ENABLE=/p' "$dst" 2>/dev/null | tail -1)
    if [ -n "$saved_web_enable" ]; then
      printf '%s\n' "$saved_web_enable"
    else
      printf "STATS_HTTP_ENABLE=1\n"
    fi
  } > "$tmp" && mv "$tmp" "$dst" || { rm -f "$tmp"; return 1; }
}

recalibrate_env() {
  dst=$1
  new_min=$2
  [ -f "$dst" ] || { echo "$dst не найден, сначала обычная установка" >&2; return 1; }
  dstdir=${dst%/*}
  dstbase=${dst##*/}
  tmp=$dstdir/.$dstbase.$$
  awk -v v="$new_min" -v q="'" '
    /^MIN_SPEED=/ { print "MIN_SPEED=" q v q; done = 1; next }
    { print }
    END { if (!done) print "MIN_SPEED=" q v q }
  ' "$dst" > "$tmp" && mv "$tmp" "$dst" || { rm -f "$tmp"; return 1; }
}

read_speedtest_const() {
  # Читает числовую константу вида "ИМЯ=значение  # комментарий" из
  # шапки speedtest2.sh. Используется, чтобы MIN_RATIO/MIN_FLOOR не
  # дублировались magic-числами в install.sh (см. compute_threshold()
  # в speedtest2.sh - источник истины для этой арифметики).
  name=$1
  default=$2
  val=$(awk -v n="$name" '
    $0 ~ "^" n "=" {
      v = $0
      sub("^" n "=", "", v)
      sub(/[ \t]*#.*/, "", v)
      gsub(/[ \t]+$/, "", v)
      print v
      exit
    }
  ' "$SELFDIR/speedtest2.sh" 2>/dev/null) || val=""
  if [ -n "$val" ]; then
    echo "$val"
  else
    echo "$default"
  fi
}

env_number() {
  # Число NAME из уже существующего speedtest2.env (в кавычках или без);
  # возврат 1, если файла/строки нет или значение не число.
  en_val=$(sed -n "s/^$1=['\"]\{0,1\}\([0-9.]*\)['\"]\{0,1\}\$/\1/p" "${ENVFILE:-$DIR/speedtest2.env}" 2>/dev/null | tail -1)
  case $en_val in ''|*[!0-9.]*|.*|*.*.*) return 1 ;; esac
  printf '%s\n' "$en_val"
}

compute_min_speed() {
  # $1 = CHANNEL (байт/с прямого замера).
  # Дублирует compute_threshold() из speedtest2.sh на числах, прочитанных
  # оттуда же через read_speedtest_const; 0.25/524288 ниже - fallback
  # ТОЛЬКО если строки MIN_RATIO=/MIN_FLOOR= не найдены в speedtest2.sh
  # (они ДОЛЖНЫ совпадать с дефолтами в его шапке).
  # Если пользователь уже менял долю канала/минимум в веб-настройках
  # (переустановка, recalibrate), считаем по его значениям.
  channel=$1
  ratio=$(env_number MIN_RATIO) || ratio=$(read_speedtest_const MIN_RATIO 0.25)
  floor=$(env_number MIN_FLOOR) || floor=$(read_speedtest_const MIN_FLOOR 524288)
  awk -v c="$channel" -v r="$ratio" -v f="$floor" 'BEGIN {
    t = int(c * r)
    print (t > f) ? t : f
  }'
}

measure_channel() {
  METRICS=$(curl -s -m 15 -o /dev/null -w '%{http_code} %{speed_download}' \
            "$SPEED_URL" 2>/dev/null) || METRICS=""
  status=${METRICS%% *}
  raw=${METRICS#* }
  case $status in
    2[0-9][0-9]) echo "${raw%%.*}" ;;
    *) echo 0 ;;
  esac
}

# Замер канала со спиннером: measure_channel печатает число в stdout,
# поэтому запускаем её в фоне в файл и крутим спиннер (замер идёт до
# 15 с). Результат - CHANNEL, время - UI_SEC. ui__spin, а не
# ui_spin_until: та печатает свою галочку, а итог рисует вызывающий код.
measure_channel_spin() {
  mc_out=$TMPROOT/mst-install-channel.$$
  measure_channel >"$mc_out" 2>/dev/null &
  ui__spin "Замер канала" $!
  CHANNEL=$(cat "$mc_out" 2>/dev/null) || CHANNEL=
  rm -f "$mc_out" 2>/dev/null || :
}

have_python3() {
  command -v python3 >/dev/null 2>&1
}

have_opkg() {
  command -v opkg >/dev/null 2>&1
}

ensure_python3() {
  # Полная авторизация реализована в stats_httpd.py, поэтому незащищённого
  # BusyBox fallback больше нет. Неудача не отменяет CLI и speedtest, но
  # веб-службу после такой установки запускать нельзя.
  have_python3 && return 0

  if ! have_opkg; then
    ui_warn "python3 не найден, а opkg недоступен - веб-интерфейс не будет запущен. Поставьте python3 вручную, выполните sh $DIR/stats_auth.sh initialize и затем $INITD_SCRIPT restart"
    return 1
  fi

  # Вывод opkg (десятки строк загрузки пакетов) - в журнал установки через
  # ui_run, на экране - спиннер и итог. Итог решает have_python3, а не код
  # opkg: тот бывает нулевым и без установленного пакета.
  ui_log "python3 не найден, пробую поставить через opkg install python3..."
  if ! ui_run "Python 3 (opkg install python3)" opkg install python3; then
    ui_warn "opkg install python3 не удался с первого раза, обновляю список пакетов (opkg update) и пробую ещё раз..."
    ui_run "Список пакетов (opkg update)" opkg update || true
    ui_run "Python 3 (opkg install python3, повтор)" opkg install python3 || true
  fi

  if have_python3; then
    ui_ok "python3 успешно установлен через opkg"
    return 0
  else
    ui_warn "Не удалось автоматически поставить python3 через opkg - веб-интерфейс не будет запущен. Поставьте python3 вручную, выполните sh $DIR/stats_auth.sh initialize и затем $INITD_SCRIPT restart"
    return 1
  fi
}

initialize_web_auth() {
  code=$(python3 "$DIR/stats_auth.py" initialize \
    --state-dir "$DIR/.stats-auth" \
    --runtime-dir "${STATS_AUTH_RUNTIME_DIR:-/tmp/mihomo-speedtest-auth}") || return 1
  if [ -n "$code" ]; then
    # Код нужен человеку прямо сейчас - отдельным блоком, чтобы не
    # затерялся среди галочек.
    host=$(advertise_host "${STATS_HTTP_BIND:-0.0.0.0}")
    [ -n "$host" ] || host="<адрес роутера>"
    {
      echo "Одноразовый код первичной настройки: $code"
      echo "Откройте http://$host:${STATS_HTTP_PORT:-8899}/setup и задайте логин и пароль"
    } | ui_note info
  fi
}

advertise_host() {
  # $1 = STATS_HTTP_BIND. Печатает адрес роутера для ссылки на
  # веб-интерфейс, когда служба слушает 0.0.0.0.
  #
  # Нельзя брать просто первый частный адрес: если роутер стоит за
  # роутером провайдера, WAN тоже получает "серый" адрес (на Keenetic
  # eth3 192.168.101.2), и он идёт в списке раньше LAN-моста - ссылка
  # указывала на WAN. Порядок выбора:
  #   1) br0 - LAN-мост "Домашняя сеть" (Bridge0) на Keenetic;
  #   2) первый частный адрес на интерфейсе, через который НЕ идёт
  #      маршрут по умолчанию (это WAN), и не /32 (служебные вроде
  #      ezcfg0 на Keenetic);
  #   3) первый частный адрес вообще, затем просто первый адрес.
  case "$1" in
    0.0.0.0|"") ;;
    *) printf '%s' "$1"; return 0 ;;
  esac
  ah_ip=${STATS_HTTPD_IP_CMD:-ip}
  command -v "$ah_ip" >/dev/null 2>&1 || return 0
  ah_wan=$("$ah_ip" -4 route show default 2>/dev/null \
    | awk '{ for (i = 1; i < NF; i++) if ($i == "dev") print $(i + 1) }' \
    | tr '\n' ' ')
  "$ah_ip" -4 -o addr show scope global 2>/dev/null | awk -v wan=" $ah_wan " '
    function is_private(ip,    o, n) {
      n = split(ip, o, ".")
      if (n != 4) return 0
      if (o[1] == 10) return 1
      if (o[1] == 192 && o[2] == 168) return 1
      if (o[1] == 172 && o[2] >= 16 && o[2] <= 31) return 1
      return 0
    }
    {
      dev = $2; sub(/@.*/, "", dev)
      addr = ""
      for (i = 1; i < NF; i++) if ($i == "inet") { addr = $(i + 1); break }
      if (addr == "") next
      split(addr, a, "/"); ip = a[1]; plen = a[2]
    }
    !got_any { first = ip; got_any = 1 }
    is_private(ip) && !got_priv { priv = ip; got_priv = 1 }
    dev == "br0" && !got_br0 { br0 = ip; got_br0 = 1 }
    index(wan, " " dev " ") { next }
    plen == "32" { next }
    is_private(ip) && !got_lan { lan = ip; got_lan = 1 }
    END {
      if (got_br0) print br0
      else if (got_lan) print lan
      else if (got_priv) print priv
      else if (got_any) print first
    }
  '
}

print_web_url() {
  envfile=${ENVFILE:-$DIR/speedtest2.env}
  if [ ! -f "$envfile" ]; then
    echo "$envfile не найден - сначала выполните установку (mihomo-speedtest install)" >&2
    return 1
  fi
  . "$envfile"
  if [ "${STATS_HTTP_ENABLE:-1}" != 1 ]; then
    echo "Веб-сервис статистики отключён (mihomo-speedtest start-web - включить)" >&2
    return 0
  fi
  host=$(advertise_host "${STATS_HTTP_BIND:-0.0.0.0}")
  [ -n "$host" ] || host="<не удалось определить IP - смотрите ip addr на роутере>"
  echo "Веб-интерфейс статистики: http://$host:${STATS_HTTP_PORT:-8899}/stats" >&2
}

show_url_main() {
  print_web_url
  # if/then, а не "&&" отдельной командой функции: check возвращает
  # ненулевой статус, когда служба остановлена (это его штатное поведение),
  # а такая функция, вызванная простой командой (например, из case-
  # диспетчера конца файла), под set -eu обрывалась бы здесь, не доходя до
  # "return 0" (найдено финальным обзором ветки 2026-09-26 - см. ledger
  # плана).
  if [ -x "$INITD_SCRIPT" ]; then
    "$INITD_SCRIPT" check || true
  fi
  return 0
}

set_env_flag() {
  # $1=имя, $2=значение - точечная атомарная замена одной строки в
  # $DIR/speedtest2.env без потери остальных (тот же приём, что
  # web/stats_cgi.sh:set_env_var(), продублирован здесь - install.sh не
  # подключает stats_cgi.sh). БЕЗ кавычек вокруг значения (в отличие от
  # set_env_var()) - единственный вызывающий на сегодня, STATS_HTTP_ENABLE,
  # читает web/stats_init.sh:stats_enabled() наивным sed-разбором без
  # снятия кавычек (см. комментарий в write_env()); в кавычках значение
  # '1' != 1 сломало бы проверку.
  name=$1; val=$2
  envfile=${ENVFILE:-$DIR/speedtest2.env}
  [ -f "$envfile" ] || { echo "$envfile не найден, сначала обычная установка" >&2; return 1; }
  tmp="$envfile.$$"
  { grep -v "^$name=" "$envfile"; printf "%s=%s\n" "$name" "$val"; } > "$tmp" \
    && mv "$tmp" "$envfile" || { rm -f "$tmp"; ui_fail "Не удалось записать $envfile"; return 1; }
}

stop_web_main() {
  set_env_flag STATS_HTTP_ENABLE 0 || return 1
  [ -x "$INITD_SCRIPT" ] && "$INITD_SCRIPT" stop >/dev/null 2>&1
  ui_ok "Веб-сервис статистики остановлен и отключён - при переустановке/обновлении проекта он не будет запускаться автоматически (mihomo-speedtest start-web - включить обратно)"
  return 0
}

start_web_main() {
  set_env_flag STATS_HTTP_ENABLE 1 || return 1
  if [ -x "$INITD_SCRIPT" ] && "$INITD_SCRIPT" restart >/dev/null 2>&1; then
    # Адрес - строка print_web_url (та же, что у --show-url, без оформления).
    ui_ok "Веб-сервис статистики запущен"
    print_web_url
  else
    ui_fail "$INITD_SCRIPT restart не удался, веб-сервис статистики не поднят - проверьте вручную"
  fi
}

# Читает $INSTALLED_MANIFEST_PATH (тот же файл, что пишет
# bootstrap_selfinstall и читает update.sh --check) и печатает установленную
# версию релиза. Чисто локальная команда: не трогает сеть и не требует
# полного набора файлов проекта (см. bootstrap_skip_for_action выше).
version_main() {
  installed_version=
  if [ -f "$INSTALLED_MANIFEST_PATH" ]; then
    installed_version=$(bootstrap_manifest_field "$INSTALLED_MANIFEST_PATH" RELEASE_VERSION)
  fi
  if [ -n "$installed_version" ]; then
    installed_tag=$(bootstrap_manifest_field "$INSTALLED_MANIFEST_PATH" RELEASE_TAG)
    echo "Версия релиза: ${installed_tag:-v$installed_version} (номер $installed_version)" >&2
  else
    echo "Установленный релиз не отслеживается" >&2
  fi
  return 0
}

# Отпечаток провайдера fast (path: ./fast.yaml) - именно его ведёт
# speedtest2.sh. Копия has_fast_group() из uninstall.sh (см. комментарий
# там же).
has_fast_group() {
  grep -qE '^[[:space:]]*path:[[:space:]]*[^[:space:]]*/?fast\.yaml[[:space:]]*$' "$1" 2>/dev/null
}

no_nodes_notice() {
  {
    echo "Ядро mihomo не запущено: в конфиге пока нет ни подписок, ни нод."
    echo "  Откройте веб-интерфейс (адрес ниже), вкладка «Конфиг» -> «Конструктор»:"
    echo "  добавьте подписку или WireGuard-ноду (из .conf) и нажмите"
    echo "  «Проверить и применить» - конфиг проверится, и ядро запустится."
  } | ui_note warn
}

own_config_notice() {
  # Жёлтый блок; пустые строки по краям не нужны - блок и так отделён чертой.
  {
    echo "ВНИМАНИЕ: остаётся ваш конфиг - быстрый пул НЕ применяется."
    echo "  Спидтест будет замерять ноды и вести статистику, но лучшие ноды"
    echo "  (fast.yaml) не попадут в маршрутизацию, пока в конфиге нет провайдера fast."
    echo "  Чтобы включить пул самостоятельно, добавьте в $CONFIG:"
    echo "    в proxy-providers:"
    echo "      fast:"
    echo "        type: file"
    echo "        path: ./fast.yaml"
    echo "    и группу с use: [fast] (например, type: url-test), на которую ссылаются ваши правила."
    echo "  Или мигрируйте позже: веб-интерфейс, раздел «Починка» -> «Миграция к шаблону»,"
    echo "  либо переустановка с CONFIG_MODE=template."
  } | ui_note warn
}

# Конфиг без быстрого пула: мигрировать к шаблону или остаться на своём.
# Результат - в CONFIG_MODE_CHOSEN (template/own). CONFIG_MODE=template|own
# в окружении - ответ без вопроса. Enter и отсутствие терминала (cron,
# обновлятор) - свой конфиг: это ничего не меняет в рабочем config.yaml.
choose_config_mode() {
  CONFIG_MODE_CHOSEN=own
  case "${CONFIG_MODE:-}" in
    template|own) CONFIG_MODE_CHOSEN=$CONFIG_MODE; return 0 ;;
    '') ;;
    *) ui_warn "Неизвестный CONFIG_MODE=$CONFIG_MODE (ждали template или own) - оставляю свой конфиг"; return 0 ;;
  esac
  # Пояснения к пункту 1 - продолжение того же пункта (перевод строки
  # внутри): ui_menu печатает пункт как есть, ui_note ставит черту на
  # каждую строку, так что они остаются в блоке меню.
  ui_menu "В конфиге нет быстрого пула (провайдер fast и группы шаблона проекта)" 2 \
    "мигрировать конфиг к шаблону проекта: подписки, свои ноды, DNS, свои входы
    и локальные настройки (порты, external-controller, sniffer и т.п.) сохранятся;
    группы, rule-providers и правила будут из шаблона (ваши останутся только в бэкапе)" \
    "оставить свой конфиг - только статистика, быстрый пул настраиваете сами"
  ui_ask "Введите номер или Enter для 2"
  read -r cm_input || { cm_input=""; echo >&2; }
  case $cm_input in
    1) CONFIG_MODE_CHOSEN=template ;;
  esac
}

# Сводка отчёта migrate_config.sh: только имена, без значений. Блоком
# (ui_note info): строки идут без своего отступа, черта блока его заменяет.
print_migration_report() {
  awk -F'|' '
    function add(k, v) { list[k] = list[k] sep[k] v; sep[k] = ", " }
    $1 == "PRESERVED" && $2 == "subscription" { add("subs", $3) }
    $1 == "PRESERVED" && $2 == "section" { add("sections", $3) }
    $1 == "PRESERVED" && $2 == "local-key" { add("keys", $3) }
    $1 == "REVIEW" && $2 == "managed-section-replaced" { add("replaced", $3) }
    $1 == "REVIEW" && $2 == "unknown-top-key" { add("dropped", $3) }
    $1 == "REVIEW" && $2 == "file-provider-replaced" { add("files", $3) }
    END {
      print "Миграция подготовлена:"
      if (list["subs"] != "") print "сохранятся подписки: " list["subs"]
      if (list["sections"] != "") print "сохранятся секции: " list["sections"]
      if (list["keys"] != "") print "сохранятся настройки: " list["keys"]
      if (list["replaced"] != "") print "будут заменены шаблоном: " list["replaced"]
      if (list["dropped"] != "") print "НЕ перенесутся (шаблон их не знает): " list["dropped"]
      if (list["files"] != "") print "НЕ перенесутся file-провайдеры: " list["files"]
    }
  ' "$1" | ui_note info
}

# xkeen -restart и ожидание API ядра (как в setup.sh). Вывод xkeen - в
# /dev/null: иначе запущенный им демон держит stdout установщика.
restart_core_and_wait() {
  "${XKEEN_BIN:-xkeen}" -restart >/dev/null 2>&1 </dev/null || true
  rc_i=0
  while [ "$rc_i" -lt "${CORE_WAIT:-20}" ]; do
    curl -s -m 2 "http://$API_MAIN/version" >/dev/null 2>&1 && return 0
    sleep 1; rc_i=$((rc_i + 1))
  done
  return 1
}

# Файл, в который реально пишется конфиг: при config.yaml-ссылке (XKeen UI
# держит профили в profiles/*.yaml и переключает активный ссылкой) - сам
# профиль, ссылка не трогается. Копия stats_config.sh:config_target().
config_target() {
  if [ -L "$CONFIG" ]; then
    ct=$(readlink "$CONFIG") || return 1
    case $ct in
      /*) printf '%s\n' "$ct" ;;
      *) printf '%s/%s\n' "$(dirname "$CONFIG")" "$ct" ;;
    esac
  else
    printf '%s\n' "$CONFIG"
  fi
}

# Атомарная замена содержимого $2 файлом $1 с сохранением прав и владельца
# $2 (в конфиге - secret и ссылки подписок, не делаем его 0644).
replace_config_file() {
  rc_new=$2.mst-install-new
  rm -f "$rc_new"
  if [ -f "$2" ]; then cp -p "$2" "$rc_new" || { rm -f "$rc_new"; return 1; }; fi
  cat "$1" > "$rc_new" || { rm -f "$rc_new"; return 1; }
  cmp -s "$1" "$rc_new" || { rm -f "$rc_new"; return 1; }
  mv -f "$rc_new" "$2" || { rm -f "$rc_new"; return 1; }
}

# 0 - конфиг мигрирован и ядро работает; 1 - конфиг не тронут (или
# возвращён из бэкапа и ядро поднялось); 2 - ядро не поднялось даже на
# прежнем конфиге, продолжать установку нельзя.
migrate_to_template() {
  mt_work=$(mktemp -d "$TMPROOT/mst-install-migrate.XXXXXX") || { ui_fail "Не удалось создать временный каталог"; return 1; }
  mt_target=$(config_target) || { ui_fail "Не удалось определить файл конфига"; rm -rf "$mt_work"; return 1; }
  # migrate_config.sh не читает символические ссылки - даём ему копию.
  if ! cp "$CONFIG" "$mt_work/source.yaml"; then
    ui_fail "Не удалось прочитать $CONFIG"; rm -rf "$mt_work"; return 1
  fi
  if ! sh "$SELFDIR/migrate_config.sh" --source "$mt_work/source.yaml" --template "$SELFDIR/config.example.yaml" \
      --output "$mt_work/config.yaml" --report "$mt_work/report" >"$mt_work/log" 2>&1; then
    mt_reason=$(sed -n 's/^ERROR: //p' "$mt_work/log" | head -n 1)
    ui_warn "Миграция невозможна: ${mt_reason:-$(tail -n 1 "$mt_work/log")}"
    rm -rf "$mt_work"; return 1
  fi
  print_migration_report "$mt_work/report"
  ui_ask "Применить новый конфиг (старый сохранится бэкапом рядом)? [y/N]"
  read -r mt_ans || { mt_ans=""; echo >&2; }
  case $mt_ans in
    [Yy]*) ;;
    *) ui_warn "Миграция отменена, конфиг не тронут"; rm -rf "$mt_work"; return 1 ;;
  esac
  # Вывод mihomo -t - в журнал установки; ui_run при ошибке сам покажет его
  # последние строки (раньше это делал tail -n 5).
  if ! ui_run "Новый конфиг: mihomo -t" "$BIN" -t -d "$MIHOMO_DIR" -f "$mt_work/config.yaml"; then
    ui_warn "Новый конфиг не прошёл mihomo -t, $CONFIG не тронут"
    rm -rf "$mt_work"; return 1
  fi
  mt_backup="$CONFIG.$(date '+%Y-%m-%d_%H%M%S').bak"
  if ! cp -p "$CONFIG" "$mt_backup"; then
    ui_fail "Не удалось сохранить бэкап $mt_backup, конфиг не тронут"
    rm -rf "$mt_work"; return 1
  fi
  ui_ok "Старый конфиг сохранён в $mt_backup"
  if ! replace_config_file "$mt_work/config.yaml" "$mt_target"; then
    ui_fail "Не удалось записать $mt_target, конфиг не тронут"
    rm -rf "$mt_work"; return 1
  fi
  rm -rf "$mt_work"
  if ui_run "Перезапускаю ядро с новым конфигом (xkeen -restart)" restart_core_and_wait; then
    ui_ok "Конфиг мигрирован к шаблону, ядро работает"
    return 0
  fi
  ui_warn "mihomo не поднялся с новым конфигом - возвращаю прежний из $mt_backup"
  if replace_config_file "$mt_backup" "$mt_target" && ui_run "Перезапуск ядра на прежнем конфиге" restart_core_and_wait; then
    ui_ok "Ядро работает на прежнем конфиге"
    return 1
  fi
  ui_fail "ОШИБКА: ядро не поднялось и на прежнем конфиге - проверьте по SSH (бэкап: $mt_backup)"
  return 2
}

# Конфиг приведён к шаблону установленного релиза (миграция или мастер
# setup.sh): схема из installed-manifest.txt пишется в config-schema-version,
# иначе веб-интерфейс показал бы лишнюю карточку «Доступно обновление
# конфига». Нет манифеста (файлы перенесены вручную) - ничего не делаем.
# Ошибка записи установку не останавливает.
record_config_schema() {
  rcs_n=$(sed -n 's/^CONFIG_SCHEMA_VERSION=\([0-9][0-9]*\)$/\1/p' "$INSTALLED_MANIFEST_PATH" 2>/dev/null | head -n 1)
  [ -n "$rcs_n" ] || return 0
  rcs_tmp=$UPDATE_STATE_DIR/.config-schema-version.$$
  if mkdir -p "$UPDATE_STATE_DIR" 2>/dev/null && printf '%s\n' "$rcs_n" > "$rcs_tmp" 2>/dev/null &&
      chmod 0600 "$rcs_tmp" 2>/dev/null && mv "$rcs_tmp" "$UPDATE_STATE_DIR/config-schema-version" 2>/dev/null; then
    return 0
  fi
  rm -f "$rcs_tmp" 2>/dev/null
  ui_warn "не удалось записать схему конфига в $UPDATE_STATE_DIR/config-schema-version"
  return 0
}

# Нет провайдера fast: спросить, что делать с конфигом. 0 - продолжать
# установку (конфиг мигрирован или остаётся свой), 1 - остановиться.
# MST_CONFIG_FROM_TEMPLATE=1 - конфиг только что собрал мастер setup.sh.
# Остаётся свой конфиг - MST_OWN_CONFIG=1: само предупреждение
# (own_config_notice) main() печатает прямо перед сводкой, а не здесь -
# посреди шага его прокрутили бы следующие строки установки.
resolve_config_mode() {
  MST_OWN_CONFIG=0
  if has_fast_group "$CONFIG"; then
    [ "${MST_CONFIG_FROM_TEMPLATE:-0}" != 1 ] || record_config_schema
    return 0
  fi
  choose_config_mode
  if [ "$CONFIG_MODE_CHOSEN" = template ]; then
    mtt_rc=0; migrate_to_template || mtt_rc=$?
    if [ "$mtt_rc" = 0 ]; then record_config_schema; return 0; fi
    [ "$mtt_rc" = 2 ] && return 1
  fi
  MST_OWN_CONFIG=1
  return 0
}

# Пробный прогон speedtest2.sh при установке/переустановке может занимать
# от десятков секунд до нескольких минут (зависит от числа нод), а сам
# speedtest2.sh обычным ходом ничего не пишет в консоль - весь его лог
# идёт в файл (см. log() в speedtest-runtime/speedtest2.sh). Без обратной
# связи это выглядит как зависший install.sh. Фоновый "тик" каждые
# TRIAL_HEARTBEAT_INTERVAL секунд - самый надёжный вариант для POSIX sh:
# не портит вывод при логировании в файл или по SSH с задержкой, в
# отличие от анимации через \r.
run_trial_with_heartbeat() {
  # Тик в plain-режиме печатает сам ui_spin_until раз в UI_TICK секунд.
  UI_TICK=${TRIAL_HEARTBEAT_INTERVAL:-8}
  # Вывод speedtest2.sh - в журнал UI_LOG, на экране только спиннер.
  # Сбой пробного прогона установку не прерывает (как и раньше "|| true"):
  # функция всегда возвращает 0. Но одной строки "[!!] Пробный прогон N с"
  # мало - по ней не понять, что случилось. Поэтому при ненулевом коде
  # показываем 3 последние строки speedtest.log (свой журнал speedtest2.sh,
  # причина сбоя обычно там) и путь к нему - в том же виде, что ui_run.
  "$DIR/speedtest2.sh" </dev/null >>"$UI_LOG" 2>&1 &
  rt_rc=0
  ui_spin_until "Пробный прогон" $! trial_status || rt_rc=$?
  if [ "$rt_rc" -ne 0 ]; then
    tail -3 "$DIR/speedtest.log" 2>/dev/null | while IFS= read -r rt_l; do
      printf '      %s%s%s\n' "$UI_C_DIM" "$rt_l" "$UI_C_0" >&2
    done
    printf '      Подробности: %s\n' "$DIR/speedtest.log" >&2
  fi
  return 0
}

# Подпись спиннера пробного прогона: "Проверка нод T/N" по progress.json,
# который пишет speedtest2.sh. Зовётся каждый тик - обязана быть тихой:
# файла ещё нет, он пустой или total=0 (прогон только готовится) -
# "подготовка". Ошибки чтения глушим.
trial_status() {
  ts_prog=${STATS_PROGRESS:-$TMPROOT/mihomo-speedtest-progress.json}
  ts_val=$(sed -n 's/.*"total":\([0-9]*\),"tested":\([0-9]*\).*/\2\/\1/p' "$ts_prog" 2>/dev/null | head -1)
  case $ts_val in
    '' | */0) echo "подготовка" ;;
    *) echo "Проверка нод $ts_val" ;;
  esac
}

# Хвост журнала пробного прогона - в журнал UI_LOG (на экране не нужен;
# итоговую строку со статусом уже напечатал ui_spin_until, вторую
# галочку не рисуем). Порядок редиректов важен: ">>файл 2>/dev/null".
print_trial_log_tail() {
  ui_log "Хвост журнала пробного прогона:"
  tail -5 "$DIR/speedtest.log" 2>/dev/null >> "${UI_LOG:-/dev/null}" || true
}

# Что именно ставится - для первой и последней строки установки. Файлы
# из $DIR (после загрузки с GitHub или переустановка поверх) описывает
# installed-manifest.txt; файлы из другого каталога (SELFDIR=... sh
# install.sh, ручной перенос) версии не несут.
install_release_label() {
  if [ "$SELFDIR" = "$DIR" ] && [ -f "$INSTALLED_MANIFEST_PATH" ]; then
    irl_tag=$(bootstrap_manifest_field "$INSTALLED_MANIFEST_PATH" RELEASE_TAG)
    if [ -n "$irl_tag" ]; then
      printf 'релиз %s\n' "$irl_tag"
      return 0
    fi
  fi
  printf 'файлы из %s, версия релиза неизвестна\n' "$SELFDIR"
}

# Режим для шапки установки: новая установка или переустановка поверх
# (speedtest2.env уже есть). «Было» - тег из installed-manifest.txt до
# загрузки релиза (бутстрап перезаписывает манифест, поэтому он сохраняет
# прежний тег в MST_PREV_TAG заранее), «станет» - устанавливаемый релиз.
install_mode_label() {
  [ -f "$DIR/speedtest2.env" ] || { printf 'Новая установка\n'; return 0; }
  if [ "${MST_PREV_TAG+set}" = set ]; then
    iml_old=$MST_PREV_TAG
  else
    iml_old=$(bootstrap_manifest_field "$INSTALLED_MANIFEST_PATH" RELEASE_TAG 2>/dev/null) || iml_old=
  fi
  case $INSTALL_LABEL in
    'релиз '*) iml_new=${INSTALL_LABEL#релиз } ;;
    *) iml_new='?' ;;
  esac
  printf 'Переустановка (%s → %s)\n' "${iml_old:-?}" "$iml_new"
}

# Ссылка на веб-интерфейс для итоговой сводки (stdout). Тот же расчёт
# адреса, что print_web_url, но без его текстов: print_web_url печатает
# готовую фразу для --show-url, а сводке нужно только значение.
install_web_url() {
  (
    . "$DIR/speedtest2.env" 2>/dev/null || exit 0
    if [ "${STATS_HTTP_ENABLE:-1}" != 1 ]; then
      echo "веб-интерфейс отключён (mihomo-speedtest start-web - включить)"
      exit 0
    fi
    host=$(advertise_host "${STATS_HTTP_BIND:-0.0.0.0}")
    [ -n "$host" ] || host="<адрес роутера>"
    echo "http://$host:${STATS_HTTP_PORT:-8899}/stats"
  )
}

# Обновить кэш подписки через API ядра и дождаться файла (для ui_run:
# вывод уходит в журнал, на экране - спиннер «Подписка NAME»).
refresh_provider_cache() {
  curl -f -s -m 10 -X PUT "http://$API_MAIN/providers/proxies/$1" >/dev/null 2>&1 || true
  sleep 3
  [ -f "$2" ]
}

main() {
  # Баннер - один раз за процесс: при бутстрапе его уже показали. Пришли
  # из мастера setup.sh (UI_CONTINUE=1) - вместо рамки строка раздела.
  if [ "${UI_BANNER_SHOWN:-}" != 1 ]; then
    ui_init
    if [ "${UI_CONTINUE:-}" = 1 ]; then
      ui_banner "MIHOMO-SPEEDTEST" "Установка"
    else
      ui_banner "MIHOMO-SPEEDTEST" "быстрый пул · статистика нод"
    fi
    UI_BANNER_SHOWN=1
  fi
  # Нумерация шагов: при бутстрапе «Загрузка релиза» был шагом 1 из 6.
  if [ "${UI_STEPS_BOOT:-}" = 1 ]; then st_n=1; st_total=6; else st_n=0; st_total=5; fi

  INSTALL_LABEL=$(install_release_label)
  printf '  Устанавливается: %s\n' "$INSTALL_LABEL" >&2
  ui_kv "Режим" "$(install_mode_label)"
  # Канал обновлений: выбранный при установке с нуля или уже сохранённый.
  im_ch=${INSTALL_CHANNEL:-$(sed -n "s/^UPDATE_CHANNEL=['\"]*\([a-z]*\).*/\1/p" "$DIR/speedtest2.env" 2>/dev/null | tail -n 1)}
  case $im_ch in
    dev) ui_kv "Обновления" "разработка (dev)" ;;
    *) ui_kv "Обновления" "стабильный" ;;
  esac

  # Проверки до шапки: версии для строк «Архитектура»/«Ядро» берутся из
  # check_versions (VC_*), а его диагностику покажем уже под шагом -
  # копим её во временном файле. Запуск в текущей оболочке (не $(...)),
  # иначе VC_* потерялись бы в подоболочке.
  # Нет записи в TMPROOT - проверяем без перехвата (диагностика выйдет
  # сразу), а не считаем проверку проваленной из-за редиректа.
  env_err=$TMPROOT/mst-install-check.$$
  env_ok=1
  if : 2>/dev/null >"$env_err"; then
    { install_env_check; } 2>"$env_err" || env_ok=0
  else
    env_err=/dev/null
    { install_env_check; } || env_ok=0
  fi
  env_arch=$(uname -m 2>/dev/null) || env_arch=
  ui_kv "Архитектура" "${env_arch:-?}${VC_KOS:+ · KeeneticOS $VC_KOS}"
  if [ -n "${VC_MIHOMO:-}${VC_XKEEN:-}" ]; then
    ui_kv "Ядро" "mihomo ${VC_MIHOMO:-?} · XKeen ${VC_XKEEN:-?}"
  fi

  st_n=$((st_n + 1)); ui_step "$st_n" "$st_total" "Проверка окружения"
  if [ "$env_ok" != 1 ]; then
    # Каждая причина version_check - своей строкой ✗ (тексты прежние).
    env_n=0
    while IFS= read -r env_line; do
      ui_fail "$env_line"; env_n=$((env_n + 1))
    done < "$env_err"
    [ "$env_n" -gt 0 ] || ui_fail "Процесс mihomo, версии"
    [ "$env_err" = /dev/null ] || rm -f "$env_err" 2>/dev/null || :
    return 1
  fi
  [ "$env_err" = /dev/null ] || rm -f "$env_err" 2>/dev/null || :
  ui_ok "Процесс mihomo, версии"

  if [ ! -f "$CONFIG" ]; then
    # Новый роутер: config.yaml ещё нет. Вместо отказа передаём управление
    # мастеру настройки (setup.sh, который сам в конце вызывает install.sh
    # ещё раз - см. setup.sh) - это второй из двух сценариев однострочной
    # установки (см. bootstrap-блок в начале файла): "конфиг уже настроен"
    # обрабатывается штатным продолжением main() ниже, "конфига нет" - тут.
    [ -f "$SELFDIR/setup.sh" ] || { ui_fail "$CONFIG не найден и $SELFDIR/setup.sh недоступен для настройки"; return 1; }
    ui_ok "config.yaml не найден - запускаю мастер настройки"
    # Мастер продолжит оформление строкой раздела (без второй рамки) и
    # пишет в тот же журнал; env переживает exec.
    export UI_CONTINUE=1 UI_LOG
    # Интерактивные read -r в setup.sh должны читать терминал, а не тело
    # install.sh под "curl ... | sh" (см. reopen_tty()).
    reopen_tty
    export SELFDIR DIR CONFIG
    exec sh "$SELFDIR/setup.sh"
  fi
  for f in $ALL_PROJECT_FILES; do
    [ -f "$SELFDIR/$f" ] || {
      ui_fail "$SELFDIR/$f не найден рядом с install.sh"
      return 1
    }
  done
  ui_ok "Файлы проекта на месте"
  NO_NODES=0
  if config_no_nodes "$CONFIG"; then NO_NODES=1; fi
  if [ "$NO_NODES" = 1 ]; then
    ui_warn "В конфиге нет ни подписок, ни нод: проверка mihomo -t и запуск ядра пропущены"
  else
    ui_run "Конфиг проходит mihomo -t" "$BIN" -t -d "$MIHOMO_DIR" -f "$CONFIG" || {
      ui_fail "$CONFIG не проходит mihomo -t"
      return 1
    }
  fi

  st_n=$((st_n + 1)); ui_step "$st_n" "$st_total" "Конфиг и фильтр"
  # Вопросы о конфиге и гео-фильтре должны читать терминал, а не тело
  # install.sh под "curl ... | sh" (см. reopen_tty()). Миграция - до
  # разбора провайдеров: дальше всё работает уже с итоговым конфигом
  # (в том числе гео-фильтр &geofilter из шаблона).
  reopen_tty
  if [ "$NO_NODES" = 1 ]; then
    # Нет подписок - нечего разбирать и кэшировать; фильтр - из конфига.
    SOURCES=
    BLOCK_COUNT=1
    BLOCK_1=$(config_geofilter_block "$CONFIG")
    [ -n "$BLOCK_1" ] || BLOCK_1=$MIN_BLOCK
  else
    resolve_config_mode || return 1
    if ! PARSED=$(awk -v CONFIG="$CONFIG" -v CONFDIR="$MIHOMO_DIR" -f "$SELFDIR/providers.awk" "$CONFIG"); then
      ui_fail "providers.awk не смог разобрать $CONFIG"
      return 1
    fi
    eval "$PARSED"
  fi

  for src in $SOURCES; do
    [ -f "$src" ] && continue
    name=$(basename "$src" .yaml)
    ui_run "Подписка $name" refresh_provider_cache "$name" "$src" || {
      ui_fail "Кэш $src не появился, сначала чините подписку $name"
      return 1
    }
  done

  # Вопросы resolve_block() тоже должны читать терминал, а не тело
  # install.sh под "curl ... | sh" - иначе read сразу получает EOF.
  reopen_tty
  resolve_block || return 1
  ui_ok "Фильтр ($BLOCK_SOURCE): $BLOCK"

  st_n=$((st_n + 1)); ui_step "$st_n" "$st_total" "Замер канала"
  # Итог здесь - строка с каналом и порогом (см. measure_channel_spin).
  measure_channel_spin
  if [ "$CHANNEL" -gt 0 ] 2>/dev/null; then
    MIN_SPEED=$(compute_min_speed "$CHANNEL")
    ui_ok "Канал $(format_mbit "$CHANNEL") Мбит/с, порог $(format_mbit "$MIN_SPEED") Мбит/с" "$UI_SEC"
  else
    # MIN_SPEED в шапке speedtest2.sh - не в кавычках (число), в отличие
    # от BLOCK; читаем тем же read_speedtest_const, что и MIN_RATIO/MIN_FLOOR.
    MIN_SPEED=$(read_speedtest_const MIN_SPEED 1048576)
    ui_warn "Прямой замер канала не удался, порог из дефолта: $(format_mbit "$MIN_SPEED") Мбит/с" "$UI_SEC"
  fi

  st_n=$((st_n + 1)); ui_step "$st_n" "$st_total" "Установка файлов и служб"
  write_env "$DIR/speedtest2.env" || {
    ui_fail "Не удалось записать speedtest2.env"
    return 1
  }
  ui_ok "Настройки: speedtest2.env"
  install_files || {
    ui_fail "Не удалось установить файлы"
    return 1
  }
  ui_ok "Файлы установлены в $DIR"
  # Простые вызовы, как и раньше: сбой crontab под set -e прерывает установку.
  install_cron
  ui_ok "Cron: замер раз в 3 часа"
  install_update_check_cron
  ui_ok "Cron: проверка обновлений"
  ensure_mihomo_speedtest_symlink "$DIR/mihomo-speedtest.sh"

  # Ставим python3 (если получится) ДО запуска веб-службы: без него
  # stats_httpd.py не запустится, а резервного сервера без пароля больше
  # нет - веб-интерфейс тогда просто не поднимается (см. ensure_python3).
  web_ready=1
  ensure_python3 || web_ready=0

  # Порция 3 (см. design): веб-интерфейс статистики поднимается независимо
  # от пробного прогона speedtest - "restart", а не "start", чтобы при
  # переустановке (изменился порт/bind/логин в $CONFIG или окружении)
  # уже запущенная служба сразу подхватила свежий speedtest2.env, а не
  # промолчала как "уже запущена" на старых настройках.
  if [ "$web_ready" = 1 ] && ! initialize_web_auth; then
    web_ready=0
    ui_warn "не удалось инициализировать авторизацию, веб-интерфейс не запущен"
  fi
  # Что показать в сводке в строке «Открыть».
  web_open="веб-интерфейс не запущен"
  if [ "$web_ready" = 1 ] && [ -x "$INITD_SCRIPT" ]; then
    # Вывод init-скрипта - в журнал (ui_run); раньше он шёл в /dev/null.
    if ui_run "Веб-интерфейс" "$INITD_SCRIPT" restart; then
      web_open=$(install_web_url) || web_open=
    else
      ui_warn "$INITD_SCRIPT restart не удался, веб-сервис статистики не поднят - проверьте вручную"
    fi
  elif [ "$web_ready" = 1 ]; then
    ui_warn "$INITD_SCRIPT не найден после установки, веб-сервис статистики не запущен"
  else
    [ ! -x "$INITD_SCRIPT" ] || "$INITD_SCRIPT" stop >/dev/null 2>&1 || true
    ui_warn "CLI, speedtest и обновлятор установлены; веб-интерфейс отключён до установки Python 3"
    web_open="веб-интерфейс отключён до установки Python 3"
  fi

  # Пробный прогон - оформление спиннером в отдельной задаче; пока - как было.
  st_n=$((st_n + 1)); ui_step "$st_n" "$st_total" "Пробный прогон"
  if [ "$NO_NODES" = 1 ]; then
    ui_warn "Пробный прогон пропущен: в конфиге нет нод"
  elif [ "${SKIP_TRIAL:-0}" != 1 ]; then
    run_trial_with_heartbeat
    print_trial_log_tail
  else
    ui_warn "Пробный прогон пропущен"
  fi

  case $INSTALL_LABEL in
    'релиз '*) done_tag="${INSTALL_LABEL#релиз } " ;;
    *) done_tag= ;;
  esac
  # Свой конфиг без быстрого пула - жёлтый блок прямо перед сводкой.
  [ "${MST_OWN_CONFIG:-0}" != 1 ] || own_config_notice
  [ "$NO_NODES" != 1 ] || no_nodes_notice
  ui_done "mihomo-speedtest ${done_tag}установлен"
  # Ссылку выделяем цветом рамки заголовка (жирный акцент); пояснения вроде
  # «веб-интерфейс отключён» остаются обычным текстом.
  case ${web_open:-} in
    http://*|https://*) ui_kv "Открыть" "$UI_C_ACC$UI_C_B$web_open$UI_C_0" ;;
    *) ui_kv "Открыть" "${web_open:-?}" ;;
  esac
  ui_kv "Фильтр" "$BLOCK"
  ui_kv "Порог" "$(format_mbit "$MIN_SPEED") Мбит/с"
  ui_kv "Диагностика" "$UI_LOG"
}

# Фатальная ошибка main() (return 1 или сбой под set -e) завершает процесс
# раньше, чем код после вызова main успеет что-то сказать, - поэтому строка
# «Установка остановлена на шаге NN/MM» печатается хуком выхода. Флаг
# INSTALL_MAIN_DONE ставится только после успешного main; exec setup.sh
# заменяет процесс, хуки тогда не выполняются вовсе.
# ui_abort - из installer/ui.sh, во встроенной копии его нет: без ui.sh
# рядом (неполный набор файлов) хук молчит, причина уже на экране.
install_abort_hook() {
  [ "${INSTALL_MAIN_DONE:-1}" = 1 ] && return 0
  command -v ui_abort >/dev/null 2>&1 && ui_abort
  return 0
}

recalibrate_main() {
  ENVFILE=${ENVFILE:-$DIR/speedtest2.env}
  [ -f "$ENVFILE" ] || {
    ui_fail "$ENVFILE не найден, сначала обычная установка"
    return 1
  }
  measure_channel_spin
  if [ "$CHANNEL" -gt 0 ] 2>/dev/null; then
    NEW_MIN=$(compute_min_speed "$CHANNEL")
  else
    ui_fail "Прямой замер канала не удался, MIN_SPEED не изменён" "$UI_SEC"
    return 1
  fi
  recalibrate_env "$ENVFILE" "$NEW_MIN" || return 1
  ui_ok "Порог пересчитан: $(format_mbit "$NEW_MIN") Мбит/с" "$UI_SEC"
}

if [ "${INSTALL_LIB_ONLY:-0}" != 1 ]; then
  case "${1:-}" in
    # ui_init без баннера; --stop-web/--start-web идут мимо бутстрапа
    # (на старой установке ui.sh может не быть) - им хватает встроенной копии.
    --recalibrate) ui_init; recalibrate_main ;;
    --stop-web) ui_init; stop_web_main ;;
    --start-web) ui_init; start_web_main ;;
    --show-url) show_url_main ;;
    --version) version_main ;;
    *)
      INSTALL_MAIN_DONE=0
      ui_on_exit install_abort_hook
      main "$@"
      INSTALL_MAIN_DONE=1
      ;;
  esac
  # Явный выход обязателен: под "curl ... | sh" reopen_tty() переключает
  # stdin процесса sh на /dev/tty, и без exit оболочка после main стала бы
  # читать "продолжение скрипта" с терминала - установка как будто висит
  # без приглашения консоли, а набранное выполнилось бы как команды.
  exit $?
fi
