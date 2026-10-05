#!/bin/sh
# CGI-обёртка вкладки "Конфиг" веб-интерфейса: редактор config.yaml Mihomo
# с проверкой, починкой и откатом к бэкапам. Ставится install.sh в
# $DIR/stats_config.sh, stats_httpd.py запускает его оттуда.
#
# Действие приходит в MST_CONFIG_ACTION (из API_ROUTES stats_httpd.py):
#   read            GET  - текущий config.yaml (текст + отпечаток base)
#   backups         GET  - список бэкапов (свои kind=edit и setup.sh kind=setup)
#   backup          GET  - текст бэкапа (?kind=edit|setup&name=...)
#   check           POST - mihomo -t для присланного текста, без записи
#   save            POST - проверить, сохранить бэкап, заменить, перезапустить
#   restore         POST - то же для выбранного бэкапа (?kind=&name=)
#   restore-working POST - найти самый свежий бэкап, проходящий mihomo -t, и применить
#   repair          POST - починка текста (?mode=format|template), без записи;
#                          для template в ответе schema - схема установленного релиза
#   import-wg       POST - импорт WireGuard/AmneziaWG .conf в текст редактора,
#                          без записи: тело - блоки "### MST-WG <имя ноды>" с
#                          .conf и последним "### MST-CONFIG" с текстом
#                          редактора; ответ - новый текст, отчёт, mihomo -t
#   log             GET  - журнал последнего применения (save/restore/
#                          restore-working) и идёт ли оно сейчас: веб-вкладка
#                          опрашивает его, пока ждёт ответа на применение.
# MST_CONFIG_LIB=1 - подключение как библиотеки: функции и переменные
# определяются, действие не выполняется (см. stats_xkeen.sh).
#
# save принимает ?schema=N (текст из "Миграции к шаблону"): после успешного
# применения N пишется в $UPDATE_STATE_DIR/config-schema-version.
# save/restore/restore-working принимают ?base=<отпечаток из read>: если
# config.yaml успели поменять с момента открытия редактора - 409 conflict.
#
# Запись по правилам AGENTS.md: кандидат готовится и проверяется в /tmp,
# потом один раз копируется рядом с целью и атомарно заменяется mv.
# Если после xkeen -restart ядро не поднялось - конфиг сам откатывается к
# только что сделанному бэкапу и ядро перезапускается ещё раз.
#
# Свои бэкапы лежат в отдельном каталоге ($CONFIG_BACKUP_DIR), а не рядом с
# config.yaml: uninstall.sh считает "$CONFIG".*.bak бэкапами setup.sh и
# откатывается к самому свежему из них - правки из редактора не должны
# подменять точку отката удаления. Бэкапы setup.sh здесь только читаются.
set -eu

DIR=${DIR:-/opt/etc/mihomo-speedtest}
MIHOMO_DIR=${MIHOMO_DIR:-/opt/etc/mihomo}
CONFIG=${CONFIG:-$MIHOMO_DIR/config.yaml}
CONFIG_BACKUP_DIR=${CONFIG_BACKUP_DIR:-$MIHOMO_DIR/config-backups}
CONFIG_BACKUP_KEEP=${CONFIG_BACKUP_KEEP:-20}
CONFIG_MAX_BYTES=${CONFIG_MAX_BYTES:-1048576}
CONFIG_TEMPLATE=${CONFIG_TEMPLATE:-$DIR/config.example.yaml}
MIGRATE_SCRIPT=${MIGRATE_SCRIPT:-$DIR/migrate_config.sh}
WG_IMPORT_AWK=${WG_IMPORT_AWK:-$DIR/wg_import.awk}
FAST_WG_AWK=${FAST_WG_AWK:-$DIR/fast_wg.awk}
# Схема конфига: доступная - CONFIG_SCHEMA_VERSION установленного релиза,
# применённая - config-schema-version (её пишет save мигрированного текста,
# см. record_schema()); по ним вкладка «Обновления» показывает карточку
# «Доступно обновление конфига».
UPDATE_STATE_DIR=${UPDATE_STATE_DIR:-$DIR/.update}
BIN=${BIN:-/opt/sbin/mihomo}
XKEEN_BIN=${XKEEN_BIN:-/opt/sbin/xkeen}
PIDOF_CMD=${PIDOF_CMD:-pidof}
TMPROOT=${TMPROOT:-/tmp}
CONFIGEDIT_LOCK=${CONFIGEDIT_LOCK:-$TMPROOT/mst-configedit.lock}
RESTART_TIMEOUT=${RESTART_TIMEOUT:-30}
HEALTH_TIMEOUT=${HEALTH_TIMEOUT:-15}
HEALTH_STABLE=${HEALTH_STABLE:-2}
RESTORE_WORKING_MAX=${RESTORE_WORKING_MAX:-10}
# Журнал применения: этапы, вывод mihomo -t, результат xkeen -restart и
# проверки ядра, откат. В /tmp (tmpfs), перезаписывается каждым применением.
APPLY_LOG=${CONFIGEDIT_APPLY_LOG:-$TMPROOT/mst-configedit-apply.log}
# Журналы XKeen: после перезапуска в журнал применения попадает то, что в
# них дописалось за время перезапуска (если файлов нет - ничего). Сам вывод
# xkeen -restart не перехватывается: его наследует демон mihomo (см. bounded()).
XKEEN_LOG_FILES=${XKEEN_LOG_FILES:-/opt/var/log/xkeen/error.log /opt/var/log/xkeen/info.log}

WORK=
LOCK_HELD=0
APPLY_LOGGING=0
BACKUP_NAME=
RESTORED_NAME=
cleanup() {
  [ -z "$WORK" ] || rm -rf "$WORK"
  [ "$LOCK_HELD" != 1 ] || rm -rf "$CONFIGEDIT_LOCK"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' HUP TERM

# ----- ответы -----

reply() {
  # $1 = HTTP-статус, $2 = файл с JSON-телом
  echo "Status: $1"
  echo "Content-Type: application/json; charset=utf-8"
  echo "Cache-Control: no-store"
  echo
  cat "$2"
  exit 0
}

# ----- журнал применения -----

alog() {
  [ "$APPLY_LOGGING" = 1 ] || return 0
  printf '%s %s\n' "$(date '+%H:%M:%S')" "$*" >> "$APPLY_LOG" 2>/dev/null || true
}

# Файл $1 в журнал с отступом, не больше $2 последних строк.
alog_file() {
  [ "$APPLY_LOGGING" = 1 ] && [ -s "$1" ] || return 0
  tail -n "${2:-40}" "$1" | sed 's/^/         | /' >> "$APPLY_LOG" 2>/dev/null || true
}

apply_log_start() {
  # $1 = что делаем. Вызывается под блокировкой, один раз на запрос.
  [ "$APPLY_LOGGING" = 1 ] && return 0
  APPLY_LOGGING=1
  : > "$APPLY_LOG" 2>/dev/null || APPLY_LOGGING=0
  alog "=== $1 ==="
}

fail_json() {
  # $1 = статус, $2 = код ошибки, $3 = необязательный текст
  alog "ОШИБКА: ${3:-$2}"
  printf '{"ok":false,"error":"%s","message":%s}\n' "$2" "$(jstr "${3:-}")" > "$WORK/resp"
  reply "$1" "$WORK/resp"
}

# Файл -> одна JSON-строка в кавычках (многострочный текст целиком).
# Каждая строка файла получает "\n" в конце - файл без завершающего
# перевода строки приходит с ним, для YAML это безразлично.
jstr_file() {
  # Экранирование посимвольной склейкой, без gsub: у gsub в разных awk
  # по-разному трактуется обратная косая черта в замене (mawk и некоторые busybox
  # не удваивают обратную косую черту - JSON ломался на конфигах с
  # регулярками в exclude-filter). LC_ALL=C - работаем с байтами, UTF-8
  # проходит как есть.
  LC_ALL=C awk '
    BEGIN { printf "\""; for (k = 1; k < 128; k++) ord[sprintf("%c", k)] = k }
    function esc(s,   o, i, c, n) {
      if (s !~ /[\\"\001-\037\177]/) return s
      o = ""; n = length(s)
      for (i = 1; i <= n; i++) {
        c = substr(s, i, 1)
        if (c == "\\") o = o "\\\\"
        else if (c == "\"") o = o "\\\""
        else if (c == "\t") o = o "\\t"
        else if (c == "\r") o = o "\\r"
        else if (c ~ /[\001-\037\177]/) o = o sprintf("\\u%04x", ord[c])
        else o = o c
      }
      return o
    }
    { printf "%s\\n", esc($0) }
    END { printf "\"" }' "$1"
}

# Однострочное значение -> JSON-строка (без хвостового "\n" от jstr_file).
jstr() { printf '%s' "$1" | jstr_file - | sed 's/\\n"$/"/'; }

# ----- помощники -----

new_work() {
  WORK=$(mktemp -d "$TMPROOT/mst-configedit.XXXXXX") || { echo "Status: 500"; echo; exit 0; }
}

# Реальный файл конфига: если config.yaml - ссылка (профили панели Xkeen UI),
# пишем в её цель, саму ссылку не трогаем.
config_target() {
  if [ -L "$CONFIG" ]; then
    t=$(readlink "$CONFIG") || return 1
    case $t in
      /*) printf '%s\n' "$t" ;;
      *) printf '%s/%s\n' "$(dirname "$CONFIG")" "$t" ;;
    esac
  else
    printf '%s\n' "$CONFIG"
  fi
}

# Отпечаток для проверки "файл не меняли с момента открытия". Инструмент -
# первый доступный (тот же набор, что у update.sh; cksum есть не в каждом
# busybox), в конец добавляется размер.
fingerprint() {
  [ -f "$1" ] || { printf 'none'; return 0; }
  if command -v sha256sum > /dev/null 2>&1; then fp=$(sha256sum < "$1")
  elif busybox sha256sum < /dev/null > /dev/null 2>&1; then fp=$(busybox sha256sum < "$1")
  elif command -v openssl > /dev/null 2>&1; then fp=$(openssl dgst -sha256 < "$1")
  elif command -v cksum > /dev/null 2>&1; then fp=$(cksum < "$1")
  else fp=
  fi
  printf '%s-%s' "$(printf '%s' "$fp" | awk '{print (NF == 1 || $NF == "-" || $NF ~ /^[0-9]+$/) ? $1 : $NF}' | tr -cd 'A-Za-z0-9')" "$(wc -c < "$1" | tr -d ' ')"
}

query_param() {
  printf '%s' "${QUERY_STRING:-}" | tr '&' '\n' | sed -n "s/^$1=//p" | head -n 1
}

valid_name() {
  case $1 in ''|.*|*/*|*[!A-Za-z0-9._-]*) return 1 ;; esac
  return 0
}

read_body() {
  len=${CONTENT_LENGTH:-0}
  case $len in ''|*[!0-9]*) len=0 ;; esac
  [ "$len" -le "$CONFIG_MAX_BYTES" ] || fail_json 413 too_large "Конфиг больше $CONFIG_MAX_BYTES байт"
  if [ "$len" -gt 0 ]; then
    head -c "$len" > "$1"
  else
    : > "$1"
  fi
  [ -s "$1" ] || fail_json 400 empty "Пустой конфиг"
}

# mihomo -t: $1 = файл, вывод - в $WORK/check.log. 0 - конфиг принят.
check_file() {
  if [ ! -x "$BIN" ]; then
    echo "mihomo не найден: $BIN" > "$WORK/check.log"
    return 2
  fi
  "$BIN" -t -d "$MIHOMO_DIR" -f "$1" > "$WORK/check.log" 2>&1 < /dev/null
}

# JSON-объект результата проверки: {"ok":..,"output":"..","line":N|null}
check_json() {
  # $1 = код возврата check_file
  tail -n 40 "$WORK/check.log" > "$WORK/check.tail"
  line=$(sed -n 's/.*[Ll]ine \([0-9][0-9]*\).*/\1/p' "$WORK/check.log" | head -n 1)
  [ -n "$line" ] || line=null
  ok=false; [ "$1" = 0 ] && ok=true
  printf '{"ok":%s,"output":%s,"line":%s}' "$ok" "$(jstr_file "$WORK/check.tail")" "$line"
}

acquire_lock() {
  [ "$LOCK_HELD" = 1 ] && return 0
  if ! mkdir "$CONFIGEDIT_LOCK" 2>/dev/null; then
    old=$(cat "$CONFIGEDIT_LOCK/pid" 2>/dev/null || true)
    case $old in
      ''|*[!0-9]*) ;;
      *) if kill -0 "$old" 2>/dev/null; then fail_json 409 busy "Конфиг уже применяется"; fi ;;
    esac
    rm -rf "$CONFIGEDIT_LOCK"
    mkdir "$CONFIGEDIT_LOCK" 2>/dev/null || fail_json 409 busy "Конфиг уже применяется"
  fi
  LOCK_HELD=1
  echo $$ > "$CONFIGEDIT_LOCK/pid" || true
}

# Атомарная замена: копия рядом с целью (с правами цели) и mv.
publish_config() {
  # $1 = источник, $2 = цель
  pc_new=$2.mst-edit-new
  rm -f "$pc_new"
  if [ -f "$2" ]; then cp -p "$2" "$pc_new" || return 1; fi
  cat "$1" > "$pc_new" || { rm -f "$pc_new"; return 1; }
  cmp -s "$1" "$pc_new" || { rm -f "$pc_new"; return 1; }
  mv -f "$pc_new" "$2" || { rm -f "$pc_new"; return 1; }
}

make_backup() {
  # $1 = текущий конфиг; имя бэкапа - в $BACKUP_NAME (без подшелла $(...),
  # чтобы ошибка не терялась и не срабатывал trap cleanup)
  BACKUP_NAME=
  mkdir -p "$CONFIG_BACKUP_DIR" || return 1
  base=config.yaml.$(date '+%Y-%m-%d_%H%M%S')
  name=$base.bak; n=2
  while [ -e "$CONFIG_BACKUP_DIR/$name" ]; do name=$base-$n.bak; n=$((n + 1)); done
  cp "$1" "$CONFIG_BACKUP_DIR/$name.tmp" || { rm -f "$CONFIG_BACKUP_DIR/$name.tmp"; return 1; }
  mv -f "$CONFIG_BACKUP_DIR/$name.tmp" "$CONFIG_BACKUP_DIR/$name" || return 1
  # Лишние старые свои бэкапы - удаляем (имена сортируются по времени).
  cnt=$(ls "$CONFIG_BACKUP_DIR" 2>/dev/null | grep -c '^config\.yaml\..*\.bak$' || true)
  if [ "$cnt" -gt "$CONFIG_BACKUP_KEEP" ]; then
    ls "$CONFIG_BACKUP_DIR" | grep '^config\.yaml\..*\.bak$' | sort | head -n $((cnt - CONFIG_BACKUP_KEEP)) |
      while read -r old; do rm -f "$CONFIG_BACKUP_DIR/$old"; done
  fi
  BACKUP_NAME=$name
}

# Команда с ограничением по времени. Вывод - в /dev/null: xkeen -restart
# запускает демон mihomo, и унаследованный stdout CGI держал бы ответ
# открытым до таймаута stats_httpd.py.
bounded() {
  limit=$1; shift
  ( exec "$@" ) > /dev/null 2>&1 < /dev/null &
  bpid=$!
  waited=0
  while kill -0 "$bpid" 2>/dev/null; do
    if [ "$waited" -ge "$limit" ]; then
      kill "$bpid" 2>/dev/null || true
      return 124
    fi
    sleep 1; waited=$((waited + 1))
  done
  wait "$bpid"
}

mihomo_healthy() {
  alog "Жду процесс mihomo (до $HEALTH_TIMEOUT с, затем $HEALTH_STABLE с на устойчивость)"
  waited=0
  while [ "$waited" -lt "$HEALTH_TIMEOUT" ]; do
    if "$PIDOF_CMD" mihomo > /dev/null 2>&1; then
      sleep "$HEALTH_STABLE"
      if mh_pid=$("$PIDOF_CMD" mihomo 2>/dev/null); then
        alog "Ядро работает (pid ${mh_pid:-?})"
        return 0
      fi
      alog "Процесс mihomo появился и сразу завершился"
    fi
    sleep 1; waited=$((waited + 1))
  done
  alog "ОШИБКА: процесс mihomo не запущен за $HEALTH_TIMEOUT с"
  return 1
}

# Размеры журналов XKeen до перезапуска - в $WORK/xkeen-logs.pos.
xkeen_logs_mark() {
  : > "$WORK/xkeen-logs.pos"
  for xl in $XKEEN_LOG_FILES; do
    [ -f "$xl" ] || continue
    printf '%s\t%s\n' "$(wc -c < "$xl" | tr -d ' ')" "$xl" >> "$WORK/xkeen-logs.pos"
  done
}

# Что дописалось в журналы XKeen после xkeen_logs_mark (до 30 строк с файла).
xkeen_logs_new() {
  [ -s "$WORK/xkeen-logs.pos" ] || return 0
  while IFS="$(printf '\t')" read -r xpos xl; do
    [ -f "$xl" ] || continue
    xsize=$(wc -c < "$xl" | tr -d ' ')
    [ "$xsize" -gt "$xpos" ] 2>/dev/null || continue
    tail -c +"$((xpos + 1))" "$xl" > "$WORK/xkeen-new.log" 2>/dev/null || continue
    alog "Новое в $xl:"
    alog_file "$WORK/xkeen-new.log" 30
  done < "$WORK/xkeen-logs.pos"
}

restart_mihomo() {
  if [ ! -x "$XKEEN_BIN" ]; then
    alog "xkeen не найден ($XKEEN_BIN) - перезапустите ядро вручную"
    return 2
  fi
  xkeen_logs_mark
  alog "xkeen -restart (таймаут $RESTART_TIMEOUT с)..."
  rs_start=$(date +%s)
  rs_rc=0; bounded "$RESTART_TIMEOUT" "$XKEEN_BIN" -restart || rs_rc=$?
  rs_time=$(( $(date +%s) - rs_start ))
  case $rs_rc in
    0) alog "xkeen -restart завершился за $rs_time с" ;;
    124) alog "ОШИБКА: xkeen -restart не завершился за $RESTART_TIMEOUT с - остановлен" ;;
    *) alog "ОШИБКА: xkeen -restart завершился с кодом $rs_rc за $rs_time с" ;;
  esac
  hrc=1
  [ "$rs_rc" = 0 ] && { mihomo_healthy && hrc=0 || hrc=1; }
  xkeen_logs_new
  return "$hrc"
}

# Схема конфига установленного релиза (число) или пусто.
available_schema() {
  sed -n 's/^CONFIG_SCHEMA_VERSION=\([0-9][0-9]*\)$/\1/p' "$UPDATE_STATE_DIR/installed-manifest.txt" 2>/dev/null | head -n 1 | sed 's/^0*\([0-9]\)/\1/'
}

# После успешного применения (в том числе "не изменился") записывает
# ?schema=N в config-schema-version: редактор передаёт N, только если текст
# получен "Миграцией к шаблону". N - целое не больше доступной схемы, иначе
# игнорируется. Ошибка записи - WARN в журнал, не ошибка сохранения.
record_schema() {
  rs_n=$(query_param schema)
  case $rs_n in ''|*[!0-9]*) return 0 ;; esac
  rs_n=$(printf '%s' "$rs_n" | sed 's/^0*\([0-9]\)/\1/')
  rs_avail=$(available_schema)
  [ -n "$rs_avail" ] || return 0
  # Сравнение длинных целых без арифметики sh: по длине, затем по строке.
  awk -v n="$rs_n" -v a="$rs_avail" 'BEGIN { if (length(n) != length(a)) exit !(length(n) < length(a)); exit !(n "x" <= a "x") }' || return 0
  rs_tmp=$UPDATE_STATE_DIR/.config-schema-version.$$
  if mkdir -p "$UPDATE_STATE_DIR" 2>/dev/null && printf '%s\n' "$rs_n" > "$rs_tmp" 2>/dev/null &&
      chmod 0600 "$rs_tmp" 2>/dev/null && mv "$rs_tmp" "$UPDATE_STATE_DIR/config-schema-version" 2>/dev/null; then
    alog "Схема конфига: $rs_n"
  else
    rm -f "$rs_tmp" 2>/dev/null
    alog "WARN: не удалось записать схему конфига ($UPDATE_STATE_DIR/config-schema-version)"
  fi
}

# Применение кандидата $1 (уже в $WORK). Проверяет base, mihomo -t,
# делает бэкап, заменяет config.yaml, перезапускает ядро; при провале
# перезапуска - откат. Пишет JSON-ответ и завершает скрипт.
apply_candidate() {
  cand=$1
  target=$(config_target) || fail_json 500 config_path "Не удалось определить путь конфига"
  acquire_lock
  apply_log_start "Применение config.yaml"
  want=$(query_param base)
  if [ -n "$want" ] && [ "$want" != "$(fingerprint "$target")" ]; then
    fail_json 409 conflict "config.yaml изменился с момента открытия редактора - перезагрузите его"
  fi
  alog "Проверка: $BIN -t"
  rc=0; check_file "$cand" || rc=$?
  alog_file "$WORK/check.log" 40
  if [ "$rc" != 0 ]; then
    alog "ОШИБКА: конфиг не прошёл mihomo -t - ничего не записано, ядро не перезапускалось"
    printf '{"ok":false,"error":"check_failed","check":%s}\n' "$(check_json "$rc")" > "$WORK/resp"
    reply 422 "$WORK/resp"
  fi
  alog "Проверка пройдена"
  if [ -f "$target" ] && cmp -s "$cand" "$target"; then
    alog "Конфиг не изменился - запись и перезапуск не нужны"
    record_schema
    printf '{"ok":true,"unchanged":true,"base":"%s"}\n' "$(fingerprint "$target")" > "$WORK/resp"
    reply 200 "$WORK/resp"
  fi
  backup=
  if [ -f "$target" ]; then
    make_backup "$target" || fail_json 500 backup_failed "Не удалось сохранить бэкап, конфиг не тронут"
    backup=$BACKUP_NAME
    alog "Текущий конфиг сохранён в бэкап $CONFIG_BACKUP_DIR/$backup"
  fi
  publish_config "$cand" "$target" || fail_json 500 write_failed "Не удалось записать config.yaml, конфиг не тронут"
  alog "Записан $target"
  rrc=0; restart_mihomo || rrc=$?
  if [ "$rrc" = 0 ]; then
    alog "ГОТОВО: конфиг применён, ядро перезапущено"
    record_schema
    printf '{"ok":true,"backup":%s,"restarted":true,"restored":%s,"base":"%s"}\n' "$(jstr "$backup")" "$(jstr "$RESTORED_NAME")" "$(fingerprint "$target")" > "$WORK/resp"
    reply 200 "$WORK/resp"
  fi
  if [ "$rrc" = 2 ]; then
    # xkeen не найден: конфиг записан, перезапуск - вручную.
    alog "ГОТОВО: конфиг записан, ядро не перезапускалось"
    record_schema
    printf '{"ok":true,"backup":%s,"restarted":false,"restored":%s,"base":"%s"}\n' "$(jstr "$backup")" "$(jstr "$RESTORED_NAME")" "$(fingerprint "$target")" > "$WORK/resp"
    reply 200 "$WORK/resp"
  fi
  rolled=false
  alog "ОШИБКА: ядро не поднялось с новым конфигом - откатываю"
  if [ -n "$backup" ] && publish_config "$CONFIG_BACKUP_DIR/$backup" "$target"; then
    rolled=true
    alog "Возвращён прежний конфиг из бэкапа $backup, перезапуск"
    if restart_mihomo; then alog "Ядро работает на прежнем конфиге"; else alog "ОШИБКА: ядро не поднялось и на прежнем конфиге - проверьте по SSH"; fi
  else
    alog "ОШИБКА: откат не удался - проверьте конфиг по SSH"
  fi
  printf '{"ok":false,"error":"restart_failed","rolled_back":%s,"backup":%s,"base":"%s"}\n' \
    "$rolled" "$(jstr "$backup")" "$(fingerprint "$target")" > "$WORK/resp"
  reply 500 "$WORK/resp"
}

backup_path() {
  # $1 = kind, $2 = name
  valid_name "$2" || return 1
  case $1 in
    edit) p=$CONFIG_BACKUP_DIR/$2 ;;
    setup) case $2 in config.yaml.*.bak) p=$(dirname "$CONFIG")/$2 ;; *) return 1 ;; esac ;;
    *) return 1 ;;
  esac
  [ -f "$p" ] || return 1
  printf '%s\n' "$p"
}

# Список бэкапов: "kind<TAB>name<TAB>путь", свежие сверху. Сортировка по
# отметке времени в имени (config.yaml.YYYY-MM-DD_HHMMSS[-N].bak) - она
# одинаковая у своих бэкапов и у бэкапов setup.sh/uninstall.sh.
list_backups() {
  {
    for p in "$CONFIG_BACKUP_DIR"/config.yaml.*.bak; do
      [ -f "$p" ] && printf 'edit\t%s\t%s\n' "${p##*/}" "$p"
    done
    for p in "$CONFIG".*.bak; do
      [ -f "$p" ] && printf 'setup\t%s\t%s\n' "${p##*/}" "$p"
    done
  } | sort -t "$(printf '\t')" -k2,2r
}

# ----- починка -----

# Исправление формата: BOM, CRLF, неразрывные пробелы, табуляция в отступе,
# пробелы в конце строк. $1 -> $2, счётчики исправлений - в $WORK/fixes.
repair_format() {
  LC_ALL=C awk -v FIXES="$WORK/fixes" '
    {
      s = $0
      if (NR == 1 && substr(s, 1, 3) == "\357\273\277") { s = substr(s, 4); bom++ }
      if (s ~ /\r$/) { sub(/\r$/, "", s); crlf++ }
      if (index(s, "\302\240")) { gsub(/\302\240/, " ", s); nbsp++ }
      if (match(s, /^[ \t]+/) && index(substr(s, 1, RLENGTH), "\t")) {
        lead = substr(s, 1, RLENGTH); gsub(/\t/, "  ", lead)
        s = lead substr(s, RLENGTH + 1); tabs++
      }
      if (s ~ /[ \t]+$/) { sub(/[ \t]+$/, "", s); trail++ }
      print s
    }
    END {
      if (bom) print "bom|" bom > FIXES
      if (crlf) print "crlf|" crlf > FIXES
      if (nbsp) print "nbsp|" nbsp > FIXES
      if (tabs) print "tabs|" tabs > FIXES
      if (trail) print "trailing|" trail > FIXES
    }' "$1" > "$2"
  [ -f "$WORK/fixes" ] || : > "$WORK/fixes"
}

lines_json() {
  # файл строк -> JSON-массив строк
  printf '['
  first=1
  while IFS= read -r l; do
    [ -n "$l" ] || continue
    [ "$first" = 1 ] || printf ','
    first=0
    printf '%s' "$(jstr "$l")"
  done < "$1"
  printf ']'
}

cmd_repair() {
  read_body "$WORK/in.yaml"
  mode=$(query_param mode)
  repair_format "$WORK/in.yaml" "$WORK/fixed.yaml"
  : > "$WORK/report"
  out=$WORK/fixed.yaml
  case $mode in
    format|'') ;;
    template)
      [ -f "$MIGRATE_SCRIPT" ] && [ -f "$CONFIG_TEMPLATE" ] || fail_json 500 no_template "Шаблон или migrate_config.sh не найден - переустановите проект"
      if ! sh "$MIGRATE_SCRIPT" --source "$WORK/fixed.yaml" --template "$CONFIG_TEMPLATE" \
          --output "$WORK/migrated.yaml" --report "$WORK/report" > "$WORK/migrate.log" 2>&1; then
        fail_json 422 migrate_failed "$(tail -n 5 "$WORK/migrate.log")"
      fi
      out=$WORK/migrated.yaml ;;
    *) fail_json 400 bad_mode "Неизвестный режим починки" ;;
  esac
  rc=0; check_file "$out" || rc=$?
  schema=null
  if [ "$mode" = template ]; then schema=$(available_schema); [ -n "$schema" ] || schema=null; fi
  printf '{"ok":true,"mode":"%s","text":%s,"fixes":%s,"report":%s,"check":%s,"schema":%s}\n' \
    "${mode:-format}" "$(jstr_file "$out")" "$(lines_json "$WORK/fixes")" \
    "$(lines_json "$WORK/report")" "$(check_json "$rc")" "$schema" > "$WORK/resp"
  reply 200 "$WORK/resp"
}

cmd_import_wg() {
  [ -f "$WG_IMPORT_AWK" ] && [ -f "$FAST_WG_AWK" ] || fail_json 500 no_tools "wg_import.awk или fast_wg.awk не найден - переустановите проект"
  read_body "$WORK/body"
  mkdir "$WORK/wg" || fail_json 500 work "Не удалось подготовить каталог импорта"
  : > "$WORK/wg/list"; : > "$WORK/report"; : > "$WORK/in.yaml"
  # Разбор тела. Имя ноды: непустое, до 64 символов, без управляющих
  # символов и |, без пробелов по краям; иначе - ERROR, файл пропускается.
  if ! LC_ALL=C awk -v D="$WORK/wg" -v REPORT="$WORK/report" -v CFG="$WORK/in.yaml" '
    function chars(s) { gsub(/[\200-\277]/, "", s); return length(s) }
    { line = $0; sub(/\r$/, "", line) }
    !cfg && line ~ /^### MST-WG / {
      name = substr(line, 12); out = "/dev/null"; idx++
      if (name == "" || name ~ /[\001-\037\177|]/ || name ~ /^[ \t]/ || name ~ /[ \t]$/ || chars(name) > 64)
        printf "ERROR|%s|недопустимое имя ноды\n", name >> REPORT
      else { out = D "/" idx ".conf"; printf "%s\t%s\n", out, name >> (D "/list") }
      next
    }
    line == "### MST-CONFIG" { out = CFG; cfg = 1; next }
    out != "" { print > out }
    END { exit !cfg }' "$WORK/body"; then
    fail_json 400 bad_body "Нет блока ### MST-CONFIG с текстом конфига"
  fi
  awk -v LIST="$WORK/wg/list" -v REPORT="$WORK/report" -f "$WG_IMPORT_AWK" "$WORK/in.yaml" > "$WORK/imp.yaml" \
    || fail_json 422 import_failed "Не удалось вставить ноды в конфиг (повреждены маркеры STATIC_PROXIES?)"
  awk -f "$FAST_WG_AWK" "$WORK/imp.yaml" > "$WORK/out.yaml" 2> "$WORK/fastwg.log" \
    || fail_json 422 import_failed "$(head -n 1 "$WORK/fastwg.log")"
  rc=0; check_file "$WORK/out.yaml" || rc=$?
  printf '{"ok":true,"text":%s,"report":%s,"check":%s}\n' \
    "$(jstr_file "$WORK/out.yaml")" "$(lines_json "$WORK/report")" "$(check_json "$rc")" > "$WORK/resp"
  reply 200 "$WORK/resp"
}

cmd_restore_working() {
  target=$(config_target) || fail_json 500 config_path "Не удалось определить путь конфига"
  acquire_lock
  apply_log_start "Откат к рабочему бэкапу"
  list_backups > "$WORK/list"
  tried=0
  while IFS="$(printf '\t')" read -r kind name path; do
    [ "$tried" -lt "$RESTORE_WORKING_MAX" ] || break
    [ -f "$target" ] && cmp -s "$path" "$target" && continue
    tried=$((tried + 1))
    cp "$path" "$WORK/cand.yaml" || continue
    if check_file "$WORK/cand.yaml"; then
      alog "Бэкап $name проходит mihomo -t - применяю"
      RESTORED_NAME=$name
      apply_candidate "$WORK/cand.yaml"
    fi
    alog "Бэкап $name не проходит mihomo -t - пропускаю"
  done < "$WORK/list"
  fail_json 404 no_working_backup "Среди последних бэкапов нет ни одного, проходящего mihomo -t"
}

# ----- main -----
# MST_CONFIG_LIB=1: только определить функции (их подключает stats_xkeen.sh).

if [ "${MST_CONFIG_LIB:-0}" != 1 ]; then
new_work
method=${REQUEST_METHOD:-GET}
action=${MST_CONFIG_ACTION:-read}

case $action:$method in
  read:GET|read:HEAD)
    target=$(config_target) || fail_json 500 config_path "Не удалось определить путь конфига"
    [ -f "$target" ] || fail_json 404 no_config "Файл $CONFIG не найден"
    size=$(wc -c < "$target" | tr -d ' ')
    [ "$size" -le "$CONFIG_MAX_BYTES" ] || fail_json 413 too_large "Конфиг больше $CONFIG_MAX_BYTES байт"
    printf '{"path":%s,"base":"%s","size":%s,"text":%s}\n' "$(jstr "$CONFIG")" \
      "$(fingerprint "$target")" "$size" "$(jstr_file "$target")" > "$WORK/resp"
    reply 200 "$WORK/resp" ;;
  backups:GET|backups:HEAD)
    list_backups > "$WORK/list"
    {
      printf '{"backups":['
      first=1
      while IFS="$(printf '\t')" read -r kind name path; do
        [ "$first" = 1 ] || printf ','
        first=0
        printf '{"kind":"%s","name":"%s","size":%s}' "$kind" "$name" "$(wc -c < "$path" | tr -d ' ')"
      done < "$WORK/list"
      printf '],"keep":%s}\n' "$CONFIG_BACKUP_KEEP"
    } > "$WORK/resp"
    reply 200 "$WORK/resp" ;;
  backup:GET|backup:HEAD)
    p=$(backup_path "$(query_param kind)" "$(query_param name)") || fail_json 404 no_backup "Бэкап не найден"
    printf '{"name":%s,"text":%s}\n' "$(jstr "$(query_param name)")" "$(jstr_file "$p")" > "$WORK/resp"
    reply 200 "$WORK/resp" ;;
  check:POST)
    read_body "$WORK/cand.yaml"
    rc=0; check_file "$WORK/cand.yaml" || rc=$?
    printf '%s\n' "$(check_json "$rc")" > "$WORK/resp"
    reply 200 "$WORK/resp" ;;
  save:POST)
    read_body "$WORK/cand.yaml"
    apply_candidate "$WORK/cand.yaml" ;;
  log:GET|log:HEAD)
    running=false
    lp=$(cat "$CONFIGEDIT_LOCK/pid" 2>/dev/null || true)
    case $lp in ''|*[!0-9]*) ;; *) kill -0 "$lp" 2>/dev/null && running=true ;; esac
    if [ -f "$APPLY_LOG" ]; then tail -n 400 "$APPLY_LOG" > "$WORK/log"; else : > "$WORK/log"; fi
    printf '{"running":%s,"text":%s}\n' "$running" "$(jstr_file "$WORK/log")" > "$WORK/resp"
    reply 200 "$WORK/resp" ;;
  restore:POST)
    p=$(backup_path "$(query_param kind)" "$(query_param name)") || fail_json 404 no_backup "Бэкап не найден"
    cp "$p" "$WORK/cand.yaml" || fail_json 500 read_failed "Не удалось прочитать бэкап"
    apply_candidate "$WORK/cand.yaml" ;;
  restore-working:POST)
    cmd_restore_working ;;
  repair:POST)
    cmd_repair ;;
  import-wg:POST)
    cmd_import_wg ;;
  *)
    fail_json 405 method_not_allowed "" ;;
esac
fi
