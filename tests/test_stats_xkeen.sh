#!/bin/sh
# Тесты web/stats_xkeen.sh - команды XKeen из веб-панели: белый список,
# запуск в фоне, вывод по частям, таймаут, общая блокировка с редактором
# конфига, демон с унаследованным stdout. xkeen подменяется заглушкой.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
SCRIPT=$ROOT/web/stats_xkeen.sh
TMP=$(mktemp -d /tmp/test-stats-xkeen.XXXXXX)
trap 'rm -rf "$TMP"' EXIT INT TERM
fail() { echo "FAIL: $*" >&2; exit 1; }
assert_contains() { case "$2" in *"$1"*) ;; *) fail "expected to find: $1 in: $2" ;; esac; }
assert_not_contains() { case "$2" in *"$1"*) fail "expected NOT to find: $1 in: $2" ;; esac; }

mkdir -p "$TMP/bin" "$TMP/dir"
cat > "$TMP/bin/xkeen" <<EOF2
#!/bin/sh
echo "\$1" >> "$TMP/calls"
case \$1 in
  -status) printf '\033[32mпрокси работает\033[0m\n'; x=; read -r x || true; echo "stdin:\$x" ;;
  -restart) echo restarted
    if grep -q KILLCORE "$TMP/xk/port_exclude.lst" 2>/dev/null; then echo down > "$TMP/state"; else echo up > "$TMP/state"; fi
    [ ! -f "$TMP/spawn-daemon" ] || ( sleep 4; echo DAEMON-LATE; touch "$TMP/daemon-ok" ) & ;;
  -diag) sleep 30 ;;
  -v) echo "XKeen 2.0"; exit 3 ;;
  *) echo "flag \$1" ;;
esac
EOF2
cat > "$TMP/bin/pidof" <<EOF2
#!/bin/sh
[ "\$(cat "$TMP/state" 2>/dev/null)" = up ]
EOF2
chmod +x "$TMP/bin/xkeen" "$TMP/bin/pidof"
echo up > "$TMP/state"
mkdir -p "$TMP/xk"

export DIR=$TMP/dir XKEEN_BIN=$TMP/bin/xkeen TMPROOT=$TMP CONFIGEDIT_LOCK=$TMP/lock \
  CONFIG_LIB=$ROOT/web/stats_config.sh XKEEN_RUN_TIMEOUT_SHORT=10 XKEEN_RUN_TIMEOUT_LONG=2 \
  XKEEN_DIR=$TMP/xk XKEEN_BACKUP_DIR=$TMP/xkb XKEEN_BACKUP_KEEP=2 PIDOF_CMD=$TMP/bin/pidof \
  HEALTH_TIMEOUT=2 HEALTH_STABLE=0

cgi() {
  # $1 = действие, $2 = метод, $3 = query
  MST_XKEEN_ACTION=$1 REQUEST_METHOD=$2 QUERY_STRING=$3 CONTENT_LENGTH=0 sh "$SCRIPT" </dev/null
}
jget() { python3 -c 'import json,sys; d=json.loads(sys.stdin.read().split("\n\n",1)[1]); print(eval("d"+sys.argv[1]))' "$1"; }
start() { out=$(cgi run POST "cmd=$1"); assert_contains 'Status: 200' "$out"; printf '%s' "$out" | jget '["id"]'; }
wait_done() {
  n=0
  while [ "$n" -lt 30 ]; do
    out=$(cgi run-log GET "id=$1&from=0")
    [ "$(printf '%s' "$out" | jget '["running"]')" = False ] && { printf '%s' "$out"; return 0; }
    sleep 0.5; n=$((n + 1))
  done
  fail "команда $1 не завершилась"
}

# --- 1: белый список: неизвестный ключ, сырой флаг, пусто - 400, xkeen не вызван
for q in cmd=rm cmd=-remove cmd= ''; do
  out=$(cgi run POST "$q")
  assert_contains 'Status: 400' "$out"
done
[ ! -f "$TMP/calls" ] || fail "1: xkeen вызван"

# --- 2: status: вывод без ANSI, stdin пустой, код 0, блокировка снята
id=$(start status)
out=$(wait_done "$id")
txt=$(printf '%s' "$out" | jget '["text"]')
assert_contains 'прокси работает' "$txt"
assert_not_contains "$(printf '\033')" "$txt"
assert_contains 'stdin:' "$txt"
[ "$(printf '%s' "$out" | jget '["exit"]')" = 0 ] || fail "2: exit"
[ "$(printf '%s' "$out" | jget '["stale"]')" = False ] || fail "2: stale"
[ ! -d "$TMP/lock" ] || fail "2: lock"

# --- 3: diag по таймауту; пока идёт - второй запуск 409
id=$(start diag)
out=$(cgi run POST cmd=status)
assert_contains 'Status: 409' "$out"
assert_contains 'busy' "$out"
out=$(wait_done "$id")
[ "$(printf '%s' "$out" | jget '["exit"]')" = 124 ] || fail "3: exit"
assert_contains 'остановлено по таймауту' "$(printf '%s' "$out" | jget '["text"]')"
[ ! -d "$TMP/lock" ] || fail "3: lock"

# --- 4: ненулевой код выхода
id=$(start version)
out=$(wait_done "$id")
[ "$(printf '%s' "$out" | jget '["exit"]')" = 3 ] || fail "4: exit"
grep -qx -- '-v' "$TMP/calls" || fail "4: флаг -v"

# --- 5: демон с унаследованным stdout не пишет в журнал и не гибнет от SIGPIPE
touch "$TMP/spawn-daemon"
id=$(start restart)
out=$(wait_done "$id")
sleep 5
out=$(cgi run-log GET "id=$id&from=0")
txt=$(printf '%s' "$out" | jget '["text"]')
assert_contains 'restarted' "$txt"
assert_not_contains 'DAEMON-LATE' "$txt"
[ -f "$TMP/daemon-ok" ] || fail "5: демон погиб"

# --- 6: чужой id - stale
out=$(cgi run-log GET "id=old&from=0")
[ "$(printf '%s' "$out" | jget '["stale"]')" = True ] || fail "6: stale"
[ "$(printf '%s' "$out" | jget '["text"]')" = "" ] || fail "6: text"

# --- 7: дочитывание с next
next=$(printf '%s' "$out" | jget '["next"]')
out=$(cgi run-log GET "id=$id&from=0")
next=$(printf '%s' "$out" | jget '["next"]')
out=$(cgi run-log GET "id=$id&from=$next")
[ "$(printf '%s' "$out" | jget '["text"]')" = "" ] || fail "7: text"
[ "$(printf '%s' "$out" | jget '["next"]')" = "$next" ] || fail "7: next"

# --- 8: прочие действия - 405
out=$(cgi run GET cmd=status)
assert_contains 'Status: 405' "$out"
rm -f "$TMP/spawn-daemon" "$TMP/calls"

# ===== Списки XKeen: read / save / backups / restore =====
cgip() {
  # $1 = действие, $2 = query, stdin = тело (POST)
  body=$(cat; echo x); body=${body%x}
  printf '%s' "$body" | MST_XKEEN_ACTION=$1 REQUEST_METHOD=POST QUERY_STRING=$2 \
    CONTENT_LENGTH=$(printf '%s' "$body" | wc -c | tr -d ' ') sh "$SCRIPT"
}
printf '#\n\n# пояснение\n' > "$TMP/xk/port_exclude.lst"
printf '80\n443\n596:599\n\n# хвост\n' > "$TMP/xk/port_proxying.lst"
printf '#192.168.0.0/16\n#2001:db8::/32\n\n#steam\n45.121.184.0/22\n' > "$TMP/xk/ip_exclude.lst"
restarts() { cat "$TMP/calls" 2>/dev/null | grep -c -- '-restart' || true; }

# --- 10: read - все 4 файла, xkeen.json нет
out=$(cgi read GET '')
assert_contains 'Status: 200' "$out"
[ "$(printf '%s' "$out" | jget '["files"]["port_proxying"]["text"]')" = "$(cat "$TMP/xk/port_proxying.lst")" ] || fail "10: text"
[ "$(printf '%s' "$out" | jget '["files"]["port_proxying"]["name"]')" = port_proxying.lst ] || fail "10: name"
[ "$(printf '%s' "$out" | jget '["files"]["xkeen_json"]["exists"]')" = False ] || fail "10: exists"
b_pe=$(printf '%s' "$out" | jget '["files"]["port_exclude"]["base"]')
b_ip=$(printf '%s' "$out" | jget '["files"]["ip_exclude"]["base"]')
b_js=$(printf '%s' "$out" | jget '["files"]["xkeen_json"]["base"]')

# --- 11: неверные строки - 422 с номерами, ничего не записано
out=$(printf '### MST-FILE port_exclude %s\n22\n70000\n599:596\n#ok\n5000:5100\n### MST-FILE ip_exclude %s\n10.0.0.0/8\n300.1.1.1\n10.0.0.0/33\n2001:db8::/32\nfe80::1\n1:2::3::4\nмусор\n### MST-FILE xkeen_json %s\n{"a":\n' "$b_pe" "$b_ip" "$b_js" | cgip save '')
assert_contains 'Status: 422' "$out"
errs=$(printf '%s' "$out" | jget '["errors"]')
for want in "'port_exclude', 'line': 2" "'port_exclude', 'line': 3" "'ip_exclude', 'line': 2" "'ip_exclude', 'line': 3" "'ip_exclude', 'line': 6" "'ip_exclude', 'line': 7" "'xkeen_json', 'line': 2"; do
  assert_contains "$want" "$errs"
done
assert_not_contains "'port_exclude', 'line': 1," "$errs"
assert_not_contains "'ip_exclude', 'line': 4" "$errs"
assert_not_contains "'ip_exclude', 'line': 5" "$errs"
[ ! -d "$TMP/xkb" ] || fail "11: backup"
[ "$(restarts)" = 0 ] || fail "11: restart"

# --- 12: удачный save двух файлов + новый xkeen.json: бэкап, запись, один перезапуск
out=$(printf '### MST-FILE port_exclude %s\n#\n22\n\n# пояснение\n### MST-FILE xkeen_json %s\n{}\n' "$b_pe" "$b_js" | cgip save '')
assert_contains 'Status: 200' "$out"
[ "$(printf '#\n22\n\n# пояснение\n')" = "$(cat "$TMP/xk/port_exclude.lst")" ] || fail "12: content"
[ "$(cat "$TMP/xk/xkeen.json")" = '{}' ] || fail "12: json"
[ "$(restarts)" = 1 ] || fail "12: restarts $(restarts)"
bk=$(printf '%s' "$out" | jget '["backup"]')
[ -f "$TMP/xkb/$bk/port_exclude.lst" ] || fail "12: backup file"
assert_contains 'xkeen.json' "$(cat "$TMP/xkb/$bk/.absent")"
new_pe=$(printf '%s' "$out" | jget '["files"]["port_exclude"]')

# --- 13: устаревший base - 409, ничего не записано
out=$(printf '### MST-FILE port_exclude %s\n23\n' "$b_pe" | cgip save '')
assert_contains 'Status: 409' "$out"
assert_contains '22' "$(cat "$TMP/xk/port_exclude.lst")"

# --- 14: то же содержимое - unchanged, без перезапуска
out=$(printf '### MST-FILE port_exclude %s\n#\n22\n\n# пояснение\n' "$new_pe" | cgip save '')
[ "$(printf '%s' "$out" | jget '["unchanged"]')" = True ] || fail "14: unchanged"
[ "$(restarts)" = 1 ] || fail "14: restart"

# --- 15: ядро не поднялось - откат файлов (новый файл удалён), второй перезапуск
b_js=$(cgi read GET '' | jget '["files"]["xkeen_json"]["base"]')
mv "$TMP/xk/xkeen.json" "$TMP/xkeen.json.keep"
b_js=$(cgi read GET '' | jget '["files"]["xkeen_json"]["base"]')
out=$(printf '### MST-FILE port_exclude %s\nKILLCORE\n### MST-FILE xkeen_json %s\n{}\n' "$new_pe" "$b_js" | cgip save '')
assert_contains 'Status: 422' "$out"
out=$(printf '### MST-FILE port_exclude %s\n# KILLCORE\n### MST-FILE xkeen_json %s\n{}\n' "$new_pe" "$b_js" | cgip save '')
assert_contains 'Status: 500' "$out"
[ "$(printf '%s' "$out" | jget '["rolled_back"]')" = True ] || fail "15: rolled_back"
assert_not_contains 'KILLCORE' "$(cat "$TMP/xk/port_exclude.lst")"
[ ! -f "$TMP/xk/xkeen.json" ] || fail "15: new file not removed"
[ "$(restarts)" = 3 ] || fail "15: restarts $(restarts)"
lg=$(cgi log GET '' | jget '["text"]')
assert_contains 'откат' "$lg"

# --- 16: лимит бэкапов (KEEP=2), список и restore
[ "$(ls "$TMP/xkb" | wc -l | tr -d ' ')" = 2 ] || fail "16: keep $(ls "$TMP/xkb")"
out=$(cgi backups GET '')
first=$(printf '%s' "$out" | jget '["backups"][0]["name"]')
assert_contains 'port_exclude.lst' "$(printf '%s' "$out" | jget '["backups"][0]["files"]')"
out=$(cgip restore "name=../etc" </dev/null)
assert_contains 'Status: 404' "$out"
printf '99\n' > "$TMP/xk/port_exclude.lst"
out=$(cgip restore "name=$first" </dev/null)
assert_contains 'Status: 200' "$out"
[ "$(cat "$TMP/xk/port_exclude.lst")" = "$(printf '#\n22\n\n# пояснение')" ] || fail "16: restore"
[ "$(restarts)" = 4 ] || fail "16: restarts $(restarts)"

# --- 9: подключение: маршруты, раздача модуля, установка и удаление
grep -q '"api/xkeen/run": ("stats_xkeen.sh"' "$ROOT/web/stats_httpd.py" || fail "9: нет маршрута api/xkeen/run"
grep -q '"api/xkeen/run-log": ("stats_xkeen.sh"' "$ROOT/web/stats_httpd.py" || fail "9: нет маршрута api/xkeen/run-log"
for a in read save backups restore log; do
  grep -q "\"MST_XKEEN_ACTION\": \"$a\"" "$ROOT/web/stats_httpd.py" || fail "9: нет маршрута для $a"
done
grep -q '"app-xkeen.js": "stats_app_xkeen.js"' "$ROOT/web/stats_httpd.py" || fail "9: модуль не раздаётся"
for f in stats_xkeen.sh stats_app_xkeen.js; do
  grep -q "$f" "$ROOT/install.sh" || fail "9: $f нет в install.sh"
  grep -q "$f" "$ROOT/uninstall.sh" || fail "9: $f нет в uninstall.sh"
  grep -q "|web/$f|" "$ROOT/release/components.txt" || fail "9: $f нет в components.txt"
done
grep -q 'href="/xkeen"' "$ROOT/web/stats_index.html" || fail "9: нет вкладки в меню"

echo "test_stats_xkeen.sh: OK"
