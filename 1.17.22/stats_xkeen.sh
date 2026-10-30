#!/bin/sh
# CGI вкладки "XKeen" веб-интерфейса: запуск команд XKeen из белого
# списка с выводом в окно-консоль. Ставится install.sh в
# $DIR/stats_xkeen.sh, stats_httpd.py запускает его оттуда.
#
# Действие приходит в MST_XKEEN_ACTION (из API_ROUTES stats_httpd.py):
#   run      POST ?cmd=<ключ>        - запустить команду в фоне, ответ сразу {ok,id}
#   run-log  GET  ?id=<id>&from=<N>  - вывод с байта N: {id,stale,text,next,running,exit,seconds}
#   input    POST ?id=<id>           - тело = одна строка ответа в stdin команды (только IA=1)
#   cancel   POST ?id=<id>           - прервать идущую команду
#   _runner  внутреннее: сам фоновый запуск (не маршрутизируется)
#   read     GET  - списки XKeen: {files:{<ключ>:{name,text,exists,base}}}
#   save     POST - тело блоками "### MST-FILE <ключ> <base>": проверить,
#                   бэкап, записать, xkeen -restart, при провале - откат
#   backups  GET  - бэкапы списков: {backups:[{name,files}],keep}
#   restore  POST ?name= - вернуть файлы из бэкапа (с перезапуском)
#   log      GET  - журнал последнего применения списков: {running,text}
#
# Списки (ключ -> файл в $XKEEN_DIR): port_exclude, port_proxying,
# ip_exclude (*.lst), xkeen_json (xkeen.json). Другие файлы XKeen не
# читаются и не пишутся. Формат строк: порт N или N:M; адрес IPv4/IPv6 с
# маской или без; "#..." - заголовок или выключенная запись; пустые строки.
# Бэкап - каталог на каждое сохранение в $XKEEN_BACKUP_DIR (вне каталога
# XKeen), в .absent - файлы, которых до сохранения не было.
#
# Принимается только ключ из cmd_flag(), флаг из запроса не берётся
# никогда. Команда идёт с stdin=/dev/null: если она что-то спросит,
# получит конец ввода и не повиснет. Таймаут - XKEEN_RUN_TIMEOUT_SHORT
# (60 с) или XKEEN_RUN_TIMEOUT_LONG (300 с, diag и ug), затем kill и код 124.
#
# Блокировка общая с редактором конфига (CONFIGEDIT_LOCK): команда и
# применение конфига не идут одновременно. Её берёт run, pid в ней -
# раннера, снимает раннер по завершении.
#
# Вывод - через FIFO, а не файл: xkeen -start/-restart запускают демон
# mihomo, он наследует stdout. В файл он писал бы вечно, а в пайп без
# читателя - умер бы от SIGPIPE. Фоновый читатель пишет строки в журнал,
# пока нет файла stop, потом читает и выбрасывает, пока демон жив.
# Всё лежит в $TMPROOT/mst-xkeen-run (tmpfs), каждый запуск - заново.
set -eu

DIR=${DIR:-/opt/etc/mihomo-speedtest}
CONFIG_LIB=${CONFIG_LIB:-$DIR/stats_config.sh}
MST_CONFIG_LIB=1 . "$CONFIG_LIB"
XKEEN_RUN_TIMEOUT_SHORT=${XKEEN_RUN_TIMEOUT_SHORT:-60}
XKEEN_RUN_TIMEOUT_LONG=${XKEEN_RUN_TIMEOUT_LONG:-300}
XKEEN_RUN_TIMEOUT_SESSION=${XKEEN_RUN_TIMEOUT_SESSION:-900}
XKEEN_RUN_TIMEOUT_INSTALL=${XKEEN_RUN_TIMEOUT_INSTALL:-1800}
RUN_DIR=$TMPROOT/mst-xkeen-run
XKEEN_DIR=${XKEEN_DIR:-/opt/etc/xkeen}
XKEEN_BACKUP_DIR=${XKEEN_BACKUP_DIR:-$DIR/xkeen-backups}
XKEEN_BACKUP_KEEP=${XKEEN_BACKUP_KEEP:-20}
APPLY_LOG=${XKEEN_APPLY_LOG:-$TMPROOT/mst-xkeen-apply.log}
LIST_KEYS="port_exclude port_proxying ip_exclude xkeen_json"

# Ключ -> FLAG (флаг XKeen, может быть с аргументом: "-sb on"), TMO и IA.
# 1 - ключа нет в списке. IA=1 - команда может задавать вопросы: ей даётся
# stdin из FIFO, который пользователь пишет через action=input; иначе
# stdin=/dev/null. Тот же список - в XKEEN_COMMANDS (stats_app_xkeen.js).
cmd_flag() {
  TMO=$XKEEN_RUN_TIMEOUT_SHORT
  IA=0
  case $1 in
    # Состояние и информация
    status) FLAG=-status ;;
    version) FLAG=-v ;;
    dscp) FLAG=-dscp ;;
    tp) FLAG=-tp ;;
    cp) FLAG=-cp ;;
    cpe) FLAG=-cpe ;;
    cfd) FLAG=-cfd ;;
    about) FLAG=-about ;;
    ad) FLAG=-ad ;;
    af) FLAG=-af ;;
    # Проверки и диагностика
    mtest) FLAG=-mtest ;;
    xtest) FLAG=-xtest ;;
    health) FLAG=-health ;;
    diag) FLAG=-diag; TMO=$XKEEN_RUN_TIMEOUT_LONG ;;
    # Управление
    start) FLAG=-start ;;
    restart) FLAG=-restart ;;
    stop) FLAG=-stop ;;
    # Режимы с аргументом, вопросов не задают
    sb_on) FLAG="-sb on" ;;
    sb_off) FLAG="-sb off" ;;
    sb_status) FLAG="-sb status" ;;
    pbr_on) FLAG="-pbr on" ;;
    pbr_off) FLAG="-pbr off" ;;
    pbr_status) FLAG="-pbr status" ;;
    pbr_codes) FLAG="-pbr codes" ;;
    killswitch_on) FLAG="-killswitch on" ;;
    killswitch_off) FLAG="-killswitch off" ;;
    killswitch_status) FLAG="-killswitch status" ;;
    # Обновление и обслуживание без вопросов
    ug) FLAG=-ug; TMO=$XKEEN_RUN_TIMEOUT_LONG ;;
    mb) FLAG=-mb ;;
    kb) FLAG=-kb ;;
    xb) FLAG=-xb ;;
    # Дальше - команды, которым может понадобиться ответ
    i) FLAG=-i; IA=1; TMO=$XKEEN_RUN_TIMEOUT_INSTALL ;;
    i_auto) FLAG="-i auto"; IA=1; TMO=$XKEEN_RUN_TIMEOUT_INSTALL ;;
    io) FLAG=-io; IA=1; TMO=$XKEEN_RUN_TIMEOUT_INSTALL ;;
    i_toff) FLAG="-i -toff"; IA=1; TMO=$XKEEN_RUN_TIMEOUT_INSTALL ;;
    k) FLAG=-k; IA=1; TMO=$XKEEN_RUN_TIMEOUT_INSTALL ;;
    g) FLAG=-g; IA=1; TMO=$XKEEN_RUN_TIMEOUT_INSTALL ;;
    gips) FLAG=-gips; IA=1; TMO=$XKEEN_RUN_TIMEOUT_INSTALL ;;
    ri) FLAG=-ri; IA=1 ;;
    uk) FLAG=-uk; IA=1; TMO=$XKEEN_RUN_TIMEOUT_INSTALL ;;
    ux) FLAG=-ux; IA=1; TMO=$XKEEN_RUN_TIMEOUT_INSTALL ;;
    um) FLAG=-um; IA=1; TMO=$XKEEN_RUN_TIMEOUT_INSTALL ;;
    uy) FLAG=-uy; IA=1; TMO=$XKEEN_RUN_TIMEOUT_INSTALL ;;
    ugc) FLAG=-ugc; IA=1; TMO=$XKEEN_RUN_TIMEOUT_SESSION ;;
    dgc) FLAG=-dgc; IA=1; TMO=$XKEEN_RUN_TIMEOUT_SESSION ;;
    kbr) FLAG=-kbr; IA=1; TMO=$XKEEN_RUN_TIMEOUT_SESSION ;;
    xbr) FLAG=-xbr; IA=1; TMO=$XKEEN_RUN_TIMEOUT_SESSION ;;
    mbr) FLAG=-mbr; IA=1; TMO=$XKEEN_RUN_TIMEOUT_SESSION ;;
    remove) FLAG=-remove; IA=1; TMO=$XKEEN_RUN_TIMEOUT_SESSION ;;
    dgs) FLAG=-dgs; IA=1; TMO=$XKEEN_RUN_TIMEOUT_SESSION ;;
    dgi) FLAG=-dgi; IA=1; TMO=$XKEEN_RUN_TIMEOUT_SESSION ;;
    dgips) FLAG=-dgips; IA=1; TMO=$XKEEN_RUN_TIMEOUT_SESSION ;;
    dx) FLAG=-dx; IA=1; TMO=$XKEEN_RUN_TIMEOUT_SESSION ;;
    dm) FLAG=-dm; IA=1; TMO=$XKEEN_RUN_TIMEOUT_SESSION ;;
    dk) FLAG=-dk; IA=1; TMO=$XKEEN_RUN_TIMEOUT_SESSION ;;
    ap) FLAG=-ap; IA=1; TMO=$XKEEN_RUN_TIMEOUT_SESSION ;;
    dp) FLAG=-dp; IA=1; TMO=$XKEEN_RUN_TIMEOUT_SESSION ;;
    ape) FLAG=-ape; IA=1; TMO=$XKEEN_RUN_TIMEOUT_SESSION ;;
    dpe) FLAG=-dpe; IA=1; TMO=$XKEEN_RUN_TIMEOUT_SESSION ;;
    auto) FLAG=-auto; IA=1; TMO=$XKEEN_RUN_TIMEOUT_SESSION ;;
    di) FLAG=-di; IA=1; TMO=$XKEEN_RUN_TIMEOUT_SESSION ;;
    d) FLAG=-d; IA=1; TMO=$XKEEN_RUN_TIMEOUT_SESSION ;;
    fd) FLAG=-fd; IA=1; TMO=$XKEEN_RUN_TIMEOUT_SESSION ;;
    channel) FLAG=-channel; IA=1; TMO=$XKEEN_RUN_TIMEOUT_SESSION ;;
    xray) FLAG=-xray; IA=1; TMO=$XKEEN_RUN_TIMEOUT_SESSION ;;
    mihomo) FLAG=-mihomo; IA=1; TMO=$XKEEN_RUN_TIMEOUT_SESSION ;;
    ipv6) FLAG=-ipv6; IA=1; TMO=$XKEEN_RUN_TIMEOUT_SESSION ;;
    dns) FLAG=-dns; IA=1; TMO=$XKEEN_RUN_TIMEOUT_SESSION ;;
    pr) FLAG=-pr; IA=1; TMO=$XKEEN_RUN_TIMEOUT_SESSION ;;
    startvb) FLAG=-startvb; IA=1; TMO=$XKEEN_RUN_TIMEOUT_SESSION ;;
    extmsg) FLAG=-extmsg; IA=1; TMO=$XKEEN_RUN_TIMEOUT_SESSION ;;
    cbk) FLAG=-cbk; IA=1; TMO=$XKEEN_RUN_TIMEOUT_SESSION ;;
    aghfix) FLAG=-aghfix; IA=1; TMO=$XKEEN_RUN_TIMEOUT_SESSION ;;
    *) return 1 ;;
  esac
}

take_lock() {
  if ! mkdir "$CONFIGEDIT_LOCK" 2>/dev/null; then
    old=$(cat "$CONFIGEDIT_LOCK/pid" 2>/dev/null || true)
    case $old in
      ''|*[!0-9]*) ;;
      *) if kill -0 "$old" 2>/dev/null; then fail_json 409 busy "Уже выполняется команда XKeen или применяется конфиг"; fi ;;
    esac
    rm -rf "$CONFIGEDIT_LOCK"
    mkdir "$CONFIGEDIT_LOCK" 2>/dev/null || fail_json 409 busy "Уже выполняется команда XKeen или применяется конфиг"
  fi
  echo $$ > "$CONFIGEDIT_LOCK/pid" || true
}

cmd_run() {
  key=$(query_param cmd)
  cmd_flag "$key" || fail_json 400 unknown_cmd "Такой команды нет в списке"
  take_lock
  rm -rf "$RUN_DIR"
  mkdir -p "$RUN_DIR" || { rm -rf "$CONFIGEDIT_LOCK"; fail_json 500 run_dir "Не удалось создать $RUN_DIR"; }
  id=$(date +%s)-$$
  echo "$id" > "$RUN_DIR/id"
  date +%s > "$RUN_DIR/started"
  : > "$RUN_DIR/log"
  if [ "$IA" = 1 ]; then
    mkfifo "$RUN_DIR/in" 2>/dev/null || { rm -rf "$CONFIGEDIT_LOCK"; fail_json 500 run_dir "Не удалось создать FIFO ввода"; }
    : > "$RUN_DIR/ia"
  fi
  MST_XKEEN_ACTION=_runner MST_XKEEN_CMD=$key sh "$0" < /dev/null > /dev/null 2>&1 &
  echo $! > "$CONFIGEDIT_LOCK/pid" || true
  printf '{"ok":true,"id":%s}\n' "$(jstr "$id")" > "$WORK/resp"
  reply 200 "$WORK/resp"
}

# Остановить команду и её подпроцессы (скрипты XKeen запускают wget и т.п.).
kill_run() {
  pkill -P "$1" 2>/dev/null || true
  kill "$1" 2>/dev/null || true
}

# id запроса совпадает с текущей командой, иначе ответ 409.
need_current() {
  want=$(query_param id)
  cur=$(cat "$RUN_DIR/id" 2>/dev/null || true)
  if [ -z "$cur" ] || [ "$want" != "$cur" ]; then
    fail_json 409 stale "Эта команда уже не выполняется"
  fi
  if [ -f "$RUN_DIR/exit" ]; then
    fail_json 409 finished "Команда уже завершилась"
  fi
}

# Строка ответа пользователя в stdin запущенной команды: тело запроса,
# одна строка до 512 байт, без управляющих символов. Пустая строка -
# это просто Enter (ответ по умолчанию), поэтому пустое тело допустимо.
cmd_input() {
  need_current
  { [ -f "$RUN_DIR/ia" ] && [ -p "$RUN_DIR/in" ]; } || fail_json 409 no_input "Эта команда не принимает ввод"
  len=${CONTENT_LENGTH:-0}
  case $len in ''|*[!0-9]*) len=0 ;; esac
  [ "$len" -le 512 ] || fail_json 413 too_large "Ответ длиннее 512 байт"
  if [ "$len" -gt 0 ]; then head -c "$len" > "$WORK/in"; else : > "$WORK/in"; fi
  head -n 1 "$WORK/in" | tr -d '\r' > "$WORK/line"
  if LC_ALL=C grep -q '[[:cntrl:]]' "$WORK/line"; then
    fail_json 400 bad_input "В ответе нельзя управляющие символы"
  fi
  # 1<> - открытие на чтение и запись: не блокируется, даже если читатель
  # ещё не открыл FIFO.
  { cat "$WORK/line"; echo; } 1<> "$RUN_DIR/in"
  printf '{"ok":true}\n' > "$WORK/resp"
  reply 200 "$WORK/resp"
}

# Прервать идущую команду.
cmd_cancel() {
  need_current
  xp=$(cat "$RUN_DIR/xpid" 2>/dev/null || true)
  case $xp in ''|*[!0-9]*) fail_json 409 not_started "Команда ещё не стартовала" ;; esac
  : > "$RUN_DIR/cancel"
  kill_run "$xp"
  printf '{"ok":true}\n' > "$WORK/resp"
  reply 200 "$WORK/resp"
}

cmd_runner() {
  cmd_flag "${MST_XKEEN_CMD:-}" || { rm -rf "$CONFIGEDIT_LOCK"; exit 0; }
  log=$RUN_DIR/log
  fifo=$RUN_DIR/fifo
  started=$(cat "$RUN_DIR/started" 2>/dev/null || date +%s)
  rm -f "$fifo"
  if ! mkfifo "$fifo" 2>/dev/null; then
    echo "--- не удалось создать FIFO $fifo" >> "$log"
    printf '1 0\n' > "$RUN_DIR/exit"
    rm -rf "$CONFIGEDIT_LOCK"
    exit 0
  fi
  if [ "$IA" = 1 ]; then
    # Вопросы без перевода строки ("Введите порт: ") должны быть видны до
    # ответа, поэтому читаем кусками, а не по строкам.
    ( exec 4< "$fifo"
      while :; do
        dd bs=4096 count=1 of="$RUN_DIR/chunk" <&4 2>/dev/null
        [ -s "$RUN_DIR/chunk" ] || break
        [ -f "$RUN_DIR/stop" ] || cat "$RUN_DIR/chunk" >> "$log"
      done ) &
    # Держим FIFO ввода открытым на запись: команда не получит конец ввода,
    # пока идёт, а запись из action=input не повиснет без читателя.
    exec 5<> "$RUN_DIR/in"
    insrc=$RUN_DIR/in
  else
    ( while IFS= read -r l || [ -n "$l" ]; do
        [ -f "$RUN_DIR/stop" ] || printf '%s\n' "$l" >> "$log"
      done < "$fifo" ) &
    insrc=/dev/null
  fi
  rc=
  if [ -x "$XKEEN_BIN" ]; then
    # FLAG - только из cmd_flag(), слова разделяются намеренно ("-sb on").
    # shellcheck disable=SC2086
    "$XKEEN_BIN" $FLAG < "$insrc" > "$fifo" 2>&1 &
    xp=$!
    echo "$xp" > "$RUN_DIR/xpid"
    waited=0
    while kill -0 "$xp" 2>/dev/null; do
      if [ "$waited" -ge "$TMO" ]; then
        kill_run "$xp"
        rc=124
        break
      fi
      sleep 1; waited=$((waited + 1))
    done
    if [ -z "$rc" ]; then rc=0; wait "$xp" || rc=$?; fi
  else
    echo "xkeen не найден: $XKEEN_BIN" > "$fifo"
    rc=127
  fi
  exec 5>&-
  sleep 1
  [ "$rc" != 124 ] || echo "--- остановлено по таймауту ($TMO с)" >> "$log"
  if [ -f "$RUN_DIR/cancel" ] && [ "$rc" != 0 ]; then echo "--- прервано пользователем" >> "$log"; fi
  : > "$RUN_DIR/stop"
  printf '%s %s\n' "$rc" "$(( $(date +%s) - started ))" > "$RUN_DIR/exit.tmp"
  mv -f "$RUN_DIR/exit.tmp" "$RUN_DIR/exit"
  rm -rf "$CONFIGEDIT_LOCK"
}

cmd_run_log() {
  want=$(query_param id)
  cur=$(cat "$RUN_DIR/id" 2>/dev/null || true)
  if [ -z "$cur" ] || [ "$want" != "$cur" ]; then
    printf '{"id":%s,"stale":true,"text":"","next":0,"running":false,"exit":null,"seconds":0}\n' "$(jstr "$cur")" > "$WORK/resp"
    reply 200 "$WORK/resp"
  fi
  from=$(query_param from)
  case $from in ''|*[!0-9]*) from=0 ;; esac
  size=0
  [ -f "$RUN_DIR/log" ] && size=$(wc -c < "$RUN_DIR/log" | tr -d ' ')
  [ "$from" -le "$size" ] || from=$size
  esc=$(printf '\033')
  tail -c +"$((from + 1))" "$RUN_DIR/log" 2>/dev/null | head -c "$((size - from))" |
    sed "s/${esc}\[[0-9;?]*[A-Za-z]//g" > "$WORK/chunk"
  if [ -s "$WORK/chunk" ]; then text=$(jstr_file "$WORK/chunk"); else text='""'; fi
  if [ -f "$RUN_DIR/exit" ]; then
    read -r xrc xsec < "$RUN_DIR/exit" || true
    running=false; xit=${xrc:-null}; secs=${xsec:-0}
  else
    running=true; xit=null
    st=$(cat "$RUN_DIR/started" 2>/dev/null || date +%s)
    secs=$(( $(date +%s) - st ))
  fi
  printf '{"id":%s,"stale":false,"text":%s,"next":%s,"running":%s,"exit":%s,"seconds":%s}\n' \
    "$(jstr "$cur")" "$text" "$size" "$running" "$xit" "$secs" > "$WORK/resp"
  reply 200 "$WORK/resp"
}

# ----- списки XKeen -----

key_name() {
  case $1 in
    port_exclude) echo port_exclude.lst ;;
    port_proxying) echo port_proxying.lst ;;
    ip_exclude) echo ip_exclude.lst ;;
    xkeen_json) echo xkeen.json ;;
    *) return 1 ;;
  esac
}

name_key() {
  for k in $LIST_KEYS; do [ "$(key_name "$k")" = "$1" ] && { echo "$k"; return 0; }; done
  return 1
}

key_kind() {
  case $1 in port_*) echo port ;; ip_*) echo ip ;; *) echo json ;; esac
}

# {"<ключ>":"<отпечаток>",...} по текущим файлам.
bases_json() {
  printf '{'
  sep=
  for k in $LIST_KEYS; do
    printf '%s"%s":"%s"' "$sep" "$k" "$(fingerprint "$XKEEN_DIR/$(key_name "$k")")"
    sep=,
  done
  printf '}'
}

# Проверка строк файла $2 вида $1 (port|ip): "строка<TAB>причина" на stdout.
validate_lines() {
  LC_ALL=C awk -v kind="$1" '
    function port_ok(v) { return v ~ /^[0-9]+$/ && v + 0 >= 1 && v + 0 <= 65535 }
    function check_port(t,   a) {
      if (t ~ /^[0-9]+$/) return port_ok(t) ? "" : "порт должен быть от 1 до 65535"
      if (t ~ /^[0-9]+:[0-9]+$/) {
        split(t, a, ":")
        if (!port_ok(a[1]) || !port_ok(a[2])) return "порт должен быть от 1 до 65535"
        if (a[1] + 0 > a[2] + 0) return "в диапазоне N:M начало больше конца"
        return ""
      }
      return "ожидается порт (22) или диапазон через двоеточие (596:599)"
    }
    function check_v4(s,   a, i) {
      if (s !~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) return 0
      split(s, a, "."); for (i = 1; i <= 4; i++) if (length(a[i]) > 3 || a[i] + 0 > 255) return 0
      return 1
    }
    function check_v6(s,   n, g, i, dbl, cnt) {
      if (s !~ /^[0-9A-Fa-f:]+$/ || s !~ /:/) return 0
      dbl = gsub(/::/, "::", s); if (dbl > 1) return 0
      if (s ~ /:::/) return 0
      n = split(s, g, ":"); cnt = 0
      for (i = 1; i <= n; i++) { if (length(g[i]) > 4) return 0; if (g[i] != "") cnt++ }
      if (dbl == 0) return n == 8 && cnt == 8
      return cnt <= 7
    }
    function check_ip(t,   addr, mask, p, max) {
      p = index(t, "/"); addr = t; mask = ""
      if (p) { addr = substr(t, 1, p - 1); mask = substr(t, p + 1) }
      if (check_v4(addr)) max = 32
      else if (check_v6(addr)) max = 128
      else return "ожидается адрес IPv4/IPv6 или подсеть (10.0.0.0/8)"
      if (p && (mask !~ /^[0-9]+$/ || mask + 0 > max)) return "маска подсети должна быть от 0 до " max
      return ""
    }
    {
      t = $0; sub(/\r$/, "", t); gsub(/^[ \t]+|[ \t]+$/, "", t)
      if (t == "" || substr(t, 1, 1) == "#") next
      r = (kind == "port") ? check_port(t) : check_ip(t)
      if (r != "") printf "%d\t%s\n", NR, r
    }' "$2"
}

# Проверка JSON: "строка<TAB>причина" на stdout (пусто - ок).
validate_json() {
  tr -d ' \t\r\n' < "$1" | grep -q . || return 0
  command -v python3 > /dev/null 2>&1 || return 0
  python3 -c '
import json, sys
try:
    json.load(open(sys.argv[1], encoding="utf-8"))
except ValueError as e:
    print("%d\t%s" % (getattr(e, "lineno", 1) or 1, "ошибка JSON: " + getattr(e, "msg", str(e))))
' "$1"
}

# Тело save -> $WORK/f.<ключ> и $WORK/plan ("ключ<TAB>base").
split_body() {
  : > "$WORK/plan"
  LC_ALL=C awk -v w="$WORK" '
    /^### MST-FILE [a-z_]+ [A-Za-z0-9-]*$/ {
      key = $3; f = w "/f." key; printf "" > f
      print key "\t" $4 >> (w "/plan"); next
    }
    f != "" { print >> f }' "$1"
}

backup_keep() {
  cnt=$(ls "$XKEEN_BACKUP_DIR" 2>/dev/null | grep -c '^20[0-9-]*_[0-9]*' || true)
  if [ "$cnt" -gt "$XKEEN_BACKUP_KEEP" ]; then
    ls "$XKEEN_BACKUP_DIR" | grep '^20[0-9-]*_[0-9]*' | sort | head -n $((cnt - XKEEN_BACKUP_KEEP)) |
      while read -r old; do rm -rf "${XKEEN_BACKUP_DIR:?}/$old"; done
  fi
}

# Вернуть изменённые файлы ($WORK/changed: "ключ") из бэкапа $1.
rollback_files() {
  ok=0
  while read -r k; do
    n=$(key_name "$k")
    if grep -qx "$n" "$XKEEN_BACKUP_DIR/$1/.absent" 2>/dev/null; then
      rm -f "$XKEEN_DIR/$n" || ok=1
    else
      publish_config "$XKEEN_BACKUP_DIR/$1/$n" "$XKEEN_DIR/$n" || ok=1
    fi
  done < "$WORK/changed"
  return "$ok"
}

# Применение файлов из $WORK/plan ("ключ<TAB>base", содержимое - $WORK/f.<ключ>).
# $1 = 1 - проверять base. Пишет JSON-ответ и завершает скрипт.
apply_lists() {
  acquire_lock
  apply_log_start "Применение списков XKeen"
  : > "$WORK/changed"
  while IFS="$(printf '\t')" read -r k want; do
    n=$(key_name "$k")
    if [ "$1" = 1 ] && [ "$want" != "$(fingerprint "$XKEEN_DIR/$n")" ]; then
      fail_json 409 conflict "$n изменился с момента открытия вкладки - перезагрузите её"
    fi
    if [ -f "$XKEEN_DIR/$n" ] && cmp -s "$WORK/f.$k" "$XKEEN_DIR/$n"; then continue; fi
    echo "$k" >> "$WORK/changed"
  done < "$WORK/plan"
  if [ ! -s "$WORK/changed" ]; then
    alog "Файлы не изменились - запись и перезапуск не нужны"
    printf '{"ok":true,"unchanged":true,"files":%s}\n' "$(bases_json)" > "$WORK/resp"
    reply 200 "$WORK/resp"
  fi
  mkdir -p "$XKEEN_BACKUP_DIR" || fail_json 500 backup_failed "Не удалось создать $XKEEN_BACKUP_DIR"
  base=$(date '+%Y-%m-%d_%H%M%S'); bk=$base; i=2
  while [ -e "$XKEEN_BACKUP_DIR/$bk" ]; do bk=$base-$i; i=$((i + 1)); done
  mkdir "$XKEEN_BACKUP_DIR/$bk.tmp" || fail_json 500 backup_failed "Не удалось сохранить бэкап, файлы не тронуты"
  : > "$XKEEN_BACKUP_DIR/$bk.tmp/.absent"
  while read -r k; do
    n=$(key_name "$k")
    if [ -f "$XKEEN_DIR/$n" ]; then
      cp -p "$XKEEN_DIR/$n" "$XKEEN_BACKUP_DIR/$bk.tmp/$n" || { rm -rf "$XKEEN_BACKUP_DIR/$bk.tmp"; fail_json 500 backup_failed "Не удалось сохранить бэкап, файлы не тронуты"; }
    else
      echo "$n" >> "$XKEEN_BACKUP_DIR/$bk.tmp/.absent"
    fi
  done < "$WORK/changed"
  mv "$XKEEN_BACKUP_DIR/$bk.tmp" "$XKEEN_BACKUP_DIR/$bk" || fail_json 500 backup_failed "Не удалось сохранить бэкап, файлы не тронуты"
  backup_keep
  alog "Бэкап: $XKEEN_BACKUP_DIR/$bk"
  while read -r k; do
    n=$(key_name "$k")
    fresh=0; [ -f "$XKEEN_DIR/$n" ] || fresh=1
    if ! publish_config "$WORK/f.$k" "$XKEEN_DIR/$n"; then
      alog "ОШИБКА: не удалось записать $n - возвращаю прежние файлы"
      rollback_files "$bk" || true
      fail_json 500 write_failed "Не удалось записать $n, прежние файлы возвращены"
    fi
    [ "$fresh" = 0 ] || chmod 644 "$XKEEN_DIR/$n" 2>/dev/null || true
    alog "Записан $XKEEN_DIR/$n"
  done < "$WORK/changed"
  rrc=0; restart_mihomo || rrc=$?
  if [ "$rrc" = 0 ] || [ "$rrc" = 2 ]; then
    restarted=true; [ "$rrc" = 0 ] || restarted=false
    alog "ГОТОВО: списки применены"
    printf '{"ok":true,"backup":%s,"restarted":%s,"files":%s}\n' "$(jstr "$bk")" "$restarted" "$(bases_json)" > "$WORK/resp"
    reply 200 "$WORK/resp"
  fi
  alog "ОШИБКА: ядро не поднялось с новыми списками - откат"
  rolled=false
  if rollback_files "$bk"; then
    rolled=true
    alog "Прежние файлы возвращены из бэкапа $bk, перезапуск"
    if restart_mihomo; then alog "Ядро работает на прежних списках"; else alog "ОШИБКА: ядро не поднялось и на прежних списках - проверьте по SSH"; fi
  else
    alog "ОШИБКА: откат не удался - проверьте файлы по SSH"
  fi
  printf '{"ok":false,"error":"restart_failed","rolled_back":%s,"backup":%s,"files":%s}\n' "$rolled" "$(jstr "$bk")" "$(bases_json)" > "$WORK/resp"
  reply 500 "$WORK/resp"
}

cmd_read() {
  printf '{"files":{' > "$WORK/resp"
  sep=
  for k in $LIST_KEYS; do
    n=$(key_name "$k"); f=$XKEEN_DIR/$n
    if [ -f "$f" ]; then ex=true; tx=$(jstr_file "$f"); else ex=false; tx='""'; fi
    # jstr_file добавляет "\n" к последней строке - отдаём текст как есть.
    if [ -f "$f" ] && [ -s "$f" ] && [ "$(tail -c 1 "$f" | od -An -c | tr -d ' ')" != '\n' ]; then
      tx=$(printf '%s' "$tx" | sed 's/\\n"$/"/')
    fi
    printf '%s"%s":{"name":"%s","exists":%s,"base":"%s","text":%s}' "$sep" "$k" "$n" "$ex" "$(fingerprint "$f")" "$tx" >> "$WORK/resp"
    sep=,
  done
  printf '}}\n' >> "$WORK/resp"
  reply 200 "$WORK/resp"
}

cmd_save() {
  read_body "$WORK/body"
  split_body "$WORK/body"
  [ -s "$WORK/plan" ] || fail_json 400 empty "Нет файлов для сохранения"
  : > "$WORK/errors"
  while IFS="$(printf '\t')" read -r k want; do
    key_name "$k" > /dev/null || fail_json 400 unknown_file "Неизвестный файл: $k"
    case $(key_kind "$k") in
      json) validate_json "$WORK/f.$k" ;;
      *) validate_lines "$(key_kind "$k")" "$WORK/f.$k" ;;
    esac | while IFS="$(printf '\t')" read -r ln why; do printf '%s\t%s\t%s\n' "$k" "$ln" "$why"; done >> "$WORK/errors"
  done < "$WORK/plan"
  if [ -s "$WORK/errors" ]; then
    {
      printf '{"ok":false,"error":"invalid","errors":['
      sep=
      while IFS="$(printf '\t')" read -r k ln why; do
        printf '%s{"key":"%s","line":%s,"reason":%s}' "$sep" "$k" "$ln" "$(jstr "$why")"
        sep=,
      done < "$WORK/errors"
      printf ']}\n'
    } > "$WORK/resp"
    reply 422 "$WORK/resp"
  fi
  apply_lists 1
}

cmd_backups() {
  {
    printf '{"backups":['
    sep=
    for d in $(ls "$XKEEN_BACKUP_DIR" 2>/dev/null | grep '^20[0-9-]*_[0-9]*' | grep -v '\.tmp$' | sort -r); do
      printf '%s{"name":"%s","files":[' "$sep" "$d"
      fs=
      for n in $(ls "$XKEEN_BACKUP_DIR/$d"); do name_key "$n" > /dev/null && { printf '%s"%s"' "$fs" "$n"; fs=,; }; done
      printf ']}'
      sep=,
    done
    printf '],"keep":%s}\n' "$XKEEN_BACKUP_KEEP"
  } > "$WORK/resp"
  reply 200 "$WORK/resp"
}

cmd_restore() {
  name=$(query_param name)
  valid_name "$name" && [ -d "$XKEEN_BACKUP_DIR/$name" ] || fail_json 404 no_backup "Бэкап не найден"
  : > "$WORK/plan"
  for n in $(ls "$XKEEN_BACKUP_DIR/$name"); do
    k=$(name_key "$n") || continue
    cp "$XKEEN_BACKUP_DIR/$name/$n" "$WORK/f.$k" || fail_json 500 read_failed "Не удалось прочитать бэкап"
    printf '%s\t-\n' "$k" >> "$WORK/plan"
  done
  [ -s "$WORK/plan" ] || fail_json 404 no_backup "В бэкапе нет файлов"
  apply_lists 0
}

cmd_log() {
  running=false
  lp=$(cat "$CONFIGEDIT_LOCK/pid" 2>/dev/null || true)
  case $lp in ''|*[!0-9]*) ;; *) kill -0 "$lp" 2>/dev/null && running=true ;; esac
  if [ -f "$APPLY_LOG" ]; then tail -n 400 "$APPLY_LOG" > "$WORK/log"; else : > "$WORK/log"; fi
  printf '{"running":%s,"text":%s}\n' "$running" "$(jstr_file "$WORK/log")" > "$WORK/resp"
  reply 200 "$WORK/resp"
}

method=${REQUEST_METHOD:-GET}
action=${MST_XKEEN_ACTION:-}
if [ "$action" = _runner ]; then
  cmd_runner
  exit 0
fi
new_work
case $action:$method in
  run:POST) cmd_run ;;
  run-log:GET|run-log:HEAD) cmd_run_log ;;
  input:POST) cmd_input ;;
  cancel:POST) cmd_cancel ;;
  read:GET|read:HEAD) cmd_read ;;
  save:POST) cmd_save ;;
  backups:GET|backups:HEAD) cmd_backups ;;
  restore:POST) cmd_restore ;;
  log:GET|log:HEAD) cmd_log ;;
  *) fail_json 405 method_not_allowed "" ;;
esac
