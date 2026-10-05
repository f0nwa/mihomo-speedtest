#!/bin/sh
# ui.sh - общая библиотека цветного вывода установщика (баннер, шаги NN/MM,
# подшаги ✓/✗, блоки с ┃). Подключается как `. ./ui.sh`; при подключении
# ничего не делает и ничего не печатает - режим выбирается явным ui_init
# (как у version_check.sh). Только POSIX sh / BusyBox ash: без tput и
# bash-измов, ESC только через printf '\033'.
#
# Режимы: live (stderr - терминал, TERM не dumb, NO_COLOR пуст, UI не plain)
# - цвет и глифы; иначе plain - префиксы [OK]/[!!]/[!] и ни одного байта ESC.
# Весь вывод - в stderr, stdout не трогаем (его могут разбирать вызывающие).
# Всё, что печатается, дублировать в журнал вызывающий код может через ui_log.

UI_LOG=${UI_LOG:-/opt/var/log/mihomo-speedtest-install.log}
UI_LOG_MAX=262144   # байт; больше - оставляем хвост в 300 строк

# ui__len СТРОКА - длина в СИМВОЛАХ (не байтах): BusyBox ${#var} на
# кириллице может считать байты, а выравнивание должно быть по символам.
# Отбрасываем continuation-байты UTF-8 (0x80-0xBF).
ui__len() {
  printf '%s' "$1" | LC_ALL=C tr -d '\200-\277' | wc -c | tr -d ' '
}

# ui__rep N СТРОКА - повтор строки N раз (без seq/yes).
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

# Подготовка журнала: каталог, обрезка, разделитель. Любой сбой - /dev/null,
# установка не должна падать из-за журнала.
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

# ui__sub ЦВЕТ ГЛИФ ТЕКСТ [СЕК] - общий вид подшага с отступом 4.
ui__sub() {
  _sec=
  [ -n "${4:-}" ] && _sec=" $UI_C_DIM$4 с$UI_C_0"
  printf '    %s%s%s %s%s\n' "$1" "$2" "$UI_C_0" "$3" "$_sec" >&2
}
ui_ok()   { ui__sub "$UI_C_OK"   "$UI_G_OK"   "$@"; }
ui_fail() { ui__sub "$UI_C_ERR"  "$UI_G_ERR"  "$@"; }
ui_warn() { ui__sub "$UI_C_WARN" "$UI_G_WARN" "$@"; }

# ui_note LEVEL - текст из stdin построчно, каждая строка с вертикальной
# чертой. warn - жёлтая, info - акцентная.
ui_note() {
  _c=$UI_C_ACC; [ "${1:-}" = warn ] && _c=$UI_C_WARN
  while IFS= read -r _line || [ -n "$_line" ]; do
    printf '  %s%s%s %s\n' "$_c" "$UI_G_BAR" "$UI_C_0" "$_line" >&2
  done
}

ui_done() {
  printf ' %s%s %s%s\n' "$UI_C_OK$UI_C_B" "$UI_G_OK" "$1" "$UI_C_0" >&2
}

ui_abort() {
  _at=
  [ -n "${UI_STEP_CUR:-}" ] && _at=" на шаге $UI_STEP_CUR/$UI_STEP_TOTAL"
  printf ' %s%s Установка остановлена%s%s\n' "$UI_C_ERR$UI_C_B" "$UI_G_ERR" "$_at" "$UI_C_0" >&2
  printf '   Подробности: %s\n' "$UI_LOG" >&2
}

# ui__cut ТЕКСТ N - обрезать до N байт (awk substr). UTF-8 считается по
# байтам - допустимо: режем с запасом, на узком терминале важнее не переполнить строку.
ui__cut() {
  printf '%s' "$1" | awk -v n="$2" '{ print substr($0, 1, n) }'
}

# ui__frame N - кадр спиннера номер N кладём в UI_FR (без подоболочки:
# на роутере лишний fork на каждый тик ни к чему).
ui__frame() {
  _i=$(($1 % 10))
  set -- ⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏
  shift "$_i"
  UI_FR=$1
}

# ui_progress ЗАГОЛОВОК ТЕКУЩИЙ ВСЕГО [ПОДПИСЬ] - полоса ▕█░▏ шириной 10.
# live: одна строка, перерисовывается через \r. plain: строка только на
# первом, последнем и каждом десятом шаге, чтобы не засорять журнал.
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

# Завершить строку прогресса (в plain строки и так законченные).
ui_progress_end() {
  [ "$UI_MODE" = live ] && printf '\n' >&2
  return 0
}

# ui_on_exit КОМАНДА - добавить хук очистки (временные файлы, возврат
# сервиса и т.п.); хуки выполняются по порядку добавления, один раз.
ui_on_exit() {
  UI_EXIT_HOOKS=${UI_EXIT_HOOKS:+$UI_EXIT_HOOKS
}$1
}

# Обработчик выхода (EXIT, INT, TERM). Флаг защищает от двойного запуска:
# по Ctrl+C сработают и INT-обработчик, и следом EXIT.
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

# ui__spin ЗАГОЛОВОК PID [СТАТУС_ФУНКЦИЯ] - общий цикл ожидания фонового
# процесса. Результат: UI_RC (код wait) и UI_SEC (секунды).
#
# Экономим fork'и: на mipsel-роутере спиннер не должен отнимать CPU у
# измерения канала и пробного прогона. Раньше каждый тик (0.1 с) звал
# date, sleep и функцию статуса (sed/head) - ~70 процессов в секунду.
# Теперь live: кадр рисуется каждый тик (только sleep), а date, статус и
# обрезка строки - раз в 10 тиков (~1 с), текст кэшируется в _rest.
# plain: кадров нет, поэтому спим по 1 с; date раз в секунду оставляем,
# чтобы тик печатался ровно раз в UI_TICK секунд.
ui__spin() {
  _st=${3:-}
  UI_SPIN_PID=$2
  _t0=$(date +%s); _last=$_t0; _k=0
  if [ "$UI_MODE" = live ]; then
    _ttl=$(ui__cut "$1" $((UI_COLS - 12)))
    # Без дробного sleep (UI_SLEEP='sleep 1') тик и так секундный -
    # обновляем подпись каждый тик, иначе секунды шли бы раз в 10 с.
    _per=10; [ "$UI_SLEEP" = 'sleep 1' ] && _per=1
    printf '\033[?25l' >&2
  else
    printf '[..] %s\n' "$1" >&2
  fi
  while kill -0 "$2" 2>/dev/null; do
    if [ "$UI_MODE" = live ]; then
      if [ $((_k % _per)) -eq 0 ]; then
        _now=$(date +%s)
        _rest=" $_ttl  $((_now - _t0)) с"
        if [ -n "$_st" ]; then
          _rest=$(ui__cut "$_rest  $($_st)" $((UI_COLS - 4)))
        fi
      fi
      ui__frame "$_k"
      printf '\r%s%s%s%s\033[K' "$UI_C_ACC" "$UI_FR" "$UI_C_0" "$_rest" >&2
      $UI_SLEEP
    else
      _now=$(date +%s)
      if [ $((_now - _last)) -ge "${UI_TICK:-8}" ]; then
        # Без tty - «тик», чтобы по ssh/в логе было видно, что не завис.
        printf '[..] %s ещё выполняется, ждите...\n' "$1" >&2
        _last=$_now
      fi
      sleep 1
    fi
    _k=$((_k + 1))
  done
  UI_RC=0
  wait "$2" || UI_RC=$?
  UI_SEC=$(($(date +%s) - _t0))
  UI_SPIN_PID=
  [ "$UI_MODE" = live ] && printf '\r\033[K\033[?25h' >&2
  return 0
}

# ui_run ЗАГОЛОВОК КОМАНДА [АРГУМЕНТЫ] - команда в фоне, вывод в журнал;
# возвращает её код. stdin закрыт (</dev/null): иначе команда съест ввод,
# который вызывающий скрипт читает после (read -r).
ui_run() {
  _rt=$1; shift
  [ "$UI_MODE" = live ] && _rt=$(ui__cut "$_rt" $((UI_COLS - 12)))
  ui_log "\$ $*"
  _mark=$(wc -l < "$UI_LOG" 2>/dev/null || echo 0)
  "$@" </dev/null >>"$UI_LOG" 2>&1 &
  ui__spin "$_rt" $!
  _rc=$UI_RC
  if [ "$_rc" -eq 0 ]; then
    ui_ok "$_rt" "$UI_SEC"
  else
    ui_fail "$_rt" "$UI_SEC"
    # До 3 последних строк вывода именно этой команды.
    tail -n +$((_mark + 1)) "$UI_LOG" 2>/dev/null | tail -3 | while IFS= read -r _l; do
      printf '      %s%s%s\n' "$UI_C_DIM" "$_l" "$UI_C_0" >&2
    done
    printf '      Подробности: %s\n' "$UI_LOG" >&2
  fi
  return "$_rc"
}

# ui_spin_until ЗАГОЛОВОК PID [СТАТУС_ФУНКЦИЯ] - то же для уже запущенного
# процесса (пробный прогон); СТАТУС_ФУНКЦИЯ печатает доп. подпись.
ui_spin_until() {
  _rt=$1
  [ "$UI_MODE" = live ] && _rt=$(ui__cut "$_rt" $((UI_COLS - 12)))
  ui__spin "$_rt" "$2" "${3:-}"
  _rc=$UI_RC
  if [ "$_rc" -eq 0 ]; then ui_ok "$_rt" "$UI_SEC"; else ui_fail "$_rt" "$UI_SEC"; fi
  return "$_rc"
}

# ui_menu ЗАГОЛОВОК НОМЕР_ПО_УМОЛЧАНИЮ ПУНКТ... - только печатает блок
# с пунктами, ввод читает вызывающий (read -r + ui_ask).
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

# ui_ask ПРИГЛАШЕНИЕ - печатает приглашение без перевода строки; read -r
# (и обработка EOF/reopen_tty) остаются у вызывающего кода.
ui_ask() {
  if [ "$UI_MODE" = live ]; then
    printf '  %s›%s %s: ' "$UI_C_ACC" "$UI_C_0" "$1" >&2
  else
    printf '[??] %s: ' "$1" >&2
  fi
}
