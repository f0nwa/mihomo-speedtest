#!/bin/sh
# CGI-обёртка вкладки "Конфиг" веб-интерфейса: редактор config.yaml Mihomo
# с проверкой, починкой и откатом к бэкапам. Ставится install.sh в
# $DIR/stats_config.sh; копия внутри раздаваемого каталога (cgi-bin/configedit)
# пишется сама write_stats_config() из speedtest2.sh - править нужно этот
# файл, копия перезаписывается сама.
#
# Действие приходит в MST_CONFIG_ACTION (из API_ALIASES stats_httpd.py):
#   read            GET  - текущий config.yaml (текст + отпечаток base)
#   backups         GET  - список бэкапов (свои kind=edit и setup.sh kind=setup)
#   backup          GET  - текст бэкапа (?kind=edit|setup&name=...)
#   check           POST - mihomo -t для присланного текста, без записи
#   save            POST - проверить, сохранить бэкап, заменить, перезапустить
#   restore         POST - то же для выбранного бэкапа (?kind=&name=)
#   restore-working POST - найти самый свежий бэкап, проходящий mihomo -t, и применить
#   repair          POST - починка текста (?mode=format|template), без записи
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
BIN=${BIN:-/opt/sbin/mihomo}
XKEEN_BIN=${XKEEN_BIN:-/opt/sbin/xkeen}
PIDOF_CMD=${PIDOF_CMD:-pidof}
TMPROOT=${TMPROOT:-/tmp}
CONFIGEDIT_LOCK=${CONFIGEDIT_LOCK:-$TMPROOT/mst-configedit.lock}
RESTART_TIMEOUT=${RESTART_TIMEOUT:-30}
HEALTH_TIMEOUT=${HEALTH_TIMEOUT:-15}
HEALTH_STABLE=${HEALTH_STABLE:-2}
RESTORE_WORKING_MAX=${RESTORE_WORKING_MAX:-10}

WORK=
LOCK_HELD=0
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

fail_json() {
  # $1 = статус, $2 = код ошибки, $3 = необязательный текст
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
  waited=0
  while [ "$waited" -lt "$HEALTH_TIMEOUT" ]; do
    if "$PIDOF_CMD" mihomo > /dev/null 2>&1; then
      sleep "$HEALTH_STABLE"
      "$PIDOF_CMD" mihomo > /dev/null 2>&1 && return 0
    fi
    sleep 1; waited=$((waited + 1))
  done
  return 1
}

restart_mihomo() {
  [ -x "$XKEEN_BIN" ] || return 2
  bounded "$RESTART_TIMEOUT" "$XKEEN_BIN" -restart || return 1
  mihomo_healthy
}

# Применение кандидата $1 (уже в $WORK). Проверяет base, mihomo -t,
# делает бэкап, заменяет config.yaml, перезапускает ядро; при провале
# перезапуска - откат. Пишет JSON-ответ и завершает скрипт.
apply_candidate() {
  cand=$1
  target=$(config_target) || fail_json 500 config_path "Не удалось определить путь конфига"
  acquire_lock
  want=$(query_param base)
  if [ -n "$want" ] && [ "$want" != "$(fingerprint "$target")" ]; then
    fail_json 409 conflict "config.yaml изменился с момента открытия редактора - перезагрузите его"
  fi
  rc=0; check_file "$cand" || rc=$?
  if [ "$rc" != 0 ]; then
    printf '{"ok":false,"error":"check_failed","check":%s}\n' "$(check_json "$rc")" > "$WORK/resp"
    reply 422 "$WORK/resp"
  fi
  if [ -f "$target" ] && cmp -s "$cand" "$target"; then
    printf '{"ok":true,"unchanged":true,"base":"%s"}\n' "$(fingerprint "$target")" > "$WORK/resp"
    reply 200 "$WORK/resp"
  fi
  backup=
  if [ -f "$target" ]; then
    make_backup "$target" || fail_json 500 backup_failed "Не удалось сохранить бэкап, конфиг не тронут"
    backup=$BACKUP_NAME
  fi
  publish_config "$cand" "$target" || fail_json 500 write_failed "Не удалось записать config.yaml, конфиг не тронут"
  rrc=0; restart_mihomo || rrc=$?
  if [ "$rrc" = 0 ]; then
    printf '{"ok":true,"backup":%s,"restarted":true,"restored":%s,"base":"%s"}\n' "$(jstr "$backup")" "$(jstr "$RESTORED_NAME")" "$(fingerprint "$target")" > "$WORK/resp"
    reply 200 "$WORK/resp"
  fi
  if [ "$rrc" = 2 ]; then
    # xkeen не найден: конфиг записан, перезапуск - вручную.
    printf '{"ok":true,"backup":%s,"restarted":false,"restored":%s,"base":"%s"}\n' "$(jstr "$backup")" "$(jstr "$RESTORED_NAME")" "$(fingerprint "$target")" > "$WORK/resp"
    reply 200 "$WORK/resp"
  fi
  rolled=false
  if [ -n "$backup" ] && publish_config "$CONFIG_BACKUP_DIR/$backup" "$target"; then
    rolled=true
    restart_mihomo || true
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
  printf '{"ok":true,"mode":"%s","text":%s,"fixes":%s,"report":%s,"check":%s}\n' \
    "${mode:-format}" "$(jstr_file "$out")" "$(lines_json "$WORK/fixes")" \
    "$(lines_json "$WORK/report")" "$(check_json "$rc")" > "$WORK/resp"
  reply 200 "$WORK/resp"
}

cmd_restore_working() {
  target=$(config_target) || fail_json 500 config_path "Не удалось определить путь конфига"
  list_backups > "$WORK/list"
  tried=0
  while IFS="$(printf '\t')" read -r kind name path; do
    [ "$tried" -lt "$RESTORE_WORKING_MAX" ] || break
    [ -f "$target" ] && cmp -s "$path" "$target" && continue
    tried=$((tried + 1))
    cp "$path" "$WORK/cand.yaml" || continue
    if check_file "$WORK/cand.yaml"; then
      RESTORED_NAME=$name
      apply_candidate "$WORK/cand.yaml"
    fi
  done < "$WORK/list"
  fail_json 404 no_working_backup "Среди последних бэкапов нет ни одного, проходящего mihomo -t"
}

# ----- main -----

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
  restore:POST)
    p=$(backup_path "$(query_param kind)" "$(query_param name)") || fail_json 404 no_backup "Бэкап не найден"
    cp "$p" "$WORK/cand.yaml" || fail_json 500 read_failed "Не удалось прочитать бэкап"
    apply_candidate "$WORK/cand.yaml" ;;
  restore-working:POST)
    cmd_restore_working ;;
  repair:POST)
    cmd_repair ;;
  *)
    fail_json 405 method_not_allowed "" ;;
esac
