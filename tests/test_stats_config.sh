#!/bin/sh
# Тесты web/stats_config.sh - CGI вкладки "Конфиг" (редактор config.yaml:
# чтение, проверка mihomo -t, сохранение с бэкапом и перезапуском, откат
# при неудачном перезапуске, откат к бэкапу, починка). mihomo, xkeen и
# pidof подменяются скриптами-заглушками - реальный роутер не нужен.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
SCRIPT=$ROOT/web/stats_config.sh
TMP=$(mktemp -d /tmp/test-stats-config.XXXXXX)
trap 'rm -rf "$TMP"' EXIT INT TERM
fail() { echo "FAIL: $*" >&2; exit 1; }
assert_contains() { case "$2" in *"$1"*) ;; *) fail "expected to find: $1 in: $2" ;; esac; }
assert_not_contains() { case "$2" in *"$1"*) fail "expected NOT to find: $1 in: $2" ;; esac; }

M=$TMP/mihomo; mkdir -p "$M" "$TMP/bin" "$TMP/dir"
# Заглушка mihomo -t: конфиг с "BROKEN" не проходит (как ошибка YAML).
cat > "$TMP/bin/mihomo" <<'EOF'
#!/bin/sh
while [ $# -gt 0 ]; do [ "$1" = -f ] && f=$2; shift; done
if grep -q BROKEN "$f"; then echo "yaml: line 3: did not find expected key"; exit 1; fi
echo "configuration file test is successful"
EOF
# Заглушка xkeen: пишет факт перезапуска; "здоровье" ядра задаёт файл state.
cat > "$TMP/bin/xkeen" <<EOF
#!/bin/sh
echo restart >> "$TMP/xkeen.log"
if grep -q KILLCORE "$M/config.yaml"; then echo down > "$TMP/state"; else echo up > "$TMP/state"; fi
EOF
cat > "$TMP/bin/pidof" <<EOF
#!/bin/sh
[ "\$(cat "$TMP/state" 2>/dev/null)" = up ]
EOF
chmod +x "$TMP/bin/mihomo" "$TMP/bin/xkeen" "$TMP/bin/pidof"
echo up > "$TMP/state"

export DIR=$TMP/dir MIHOMO_DIR=$M BIN=$TMP/bin/mihomo XKEEN_BIN=$TMP/bin/xkeen \
  PIDOF_CMD=$TMP/bin/pidof HEALTH_TIMEOUT=2 HEALTH_STABLE=0 TMPROOT=$TMP \
  CONFIGEDIT_LOCK=$TMP/lock

cgi() {
  # $1 = действие, $2 = метод, $3 = query, stdin = тело
  body=$(cat)
  printf '%s' "$body" | MST_CONFIG_ACTION=$1 REQUEST_METHOD=$2 QUERY_STRING=$3 \
    CONTENT_LENGTH=$(printf '%s' "$body" | wc -c | tr -d ' ') sh "$SCRIPT"
}
jget() { python3 -c 'import json,sys; d=json.loads(sys.stdin.read().split("\n\n",1)[1]); print(eval("d"+sys.argv[1]))' "$1"; }
jlog() { cgi log GET '' </dev/null | jget '["text"]'; }

printf 'mixed-port: 7890\nproxies: []\n' > "$M/config.yaml"
printf 'old: 1\n' > "$M/config.yaml.2026-01-01_000000.bak"

# --- 1: read отдаёт текст, путь и отпечаток
out=$(cgi read GET '' </dev/null)
assert_contains 'Status: 200' "$out"
[ "$(printf '%s' "$out" | jget '["text"]')" = "$(printf 'mixed-port: 7890\nproxies: []\n')" ] || fail "1: text"
base=$(printf '%s' "$out" | jget '["base"]')

# --- 2: check не пишет файл и возвращает строку ошибки
out=$(printf 'a: 1\nBROKEN\n' | cgi check POST '')
[ "$(printf '%s' "$out" | jget '["ok"]')" = False ] || fail "2: ok"
[ "$(printf '%s' "$out" | jget '["line"]')" = 3 ] || fail "2: line"
out=$(printf 'a: 1\n' | cgi check POST '')
[ "$(printf '%s' "$out" | jget '["ok"]')" = True ] || fail "2: valid"

# --- 3: save с неверным конфигом - 422, файл не тронут, бэкапа нет
out=$(printf 'BROKEN\n' | cgi save POST "base=$base")
assert_contains 'Status: 422' "$out"
assert_contains 'mixed-port' "$(cat "$M/config.yaml")"
[ ! -d "$M/config-backups" ] || [ -z "$(ls "$M/config-backups")" ] || fail "3: backup created"
# журнал применения: вывод mihomo -t и причина отказа
lg=$(jlog)
assert_contains 'did not find expected key' "$lg"
assert_contains 'не прошёл mihomo -t' "$lg"

# --- 4: save с устаревшим base - 409
out=$(printf 'a: 2\n' | cgi save POST "base=0-0")
assert_contains 'Status: 409' "$out"
assert_contains 'conflict' "$out"

# --- 5: удачный save - бэкап в своём каталоге, замена, перезапуск
out=$(printf 'mixed-port: 7891\n' | cgi save POST "base=$base")
assert_contains 'Status: 200' "$out"
[ "$(cat "$M/config.yaml")" = 'mixed-port: 7891' ] || fail "5: not written"
[ "$(wc -l < "$TMP/xkeen.log" | tr -d ' ')" = 1 ] || fail "5: no restart"
bk=$(printf '%s' "$out" | jget '["backup"]')
assert_contains 'mixed-port: 7890' "$(cat "$M/config-backups/$bk")"
# бэкапы setup.sh рядом с config.yaml не множатся (uninstall.sh их не спутает)
[ "$(ls "$M" | grep -c '\.bak$')" = 1 ] || fail "5: bak next to config"
# журнал применения: все этапы по порядку, блокировка снята
lg=$(jlog)
for step in 'Проверка пройдена' 'сохранён в бэкап' 'Записан' 'xkeen -restart завершился' 'Ядро работает' 'ГОТОВО'; do
  assert_contains "$step" "$lg"
done
[ "$(cgi log GET '' </dev/null | jget '["running"]')" = False ] || fail "5: running after finish"

# --- 6: ядро не поднялось - автоматический откат к бэкапу
base=$(cgi read GET '' </dev/null | jget '["base"]')
out=$(printf 'KILLCORE: 1\n' | cgi save POST "base=$base")
assert_contains 'Status: 500' "$out"
[ "$(printf '%s' "$out" | jget '["rolled_back"]')" = True ] || fail "6: rolled_back"
[ "$(cat "$M/config.yaml")" = 'mixed-port: 7891' ] || fail "6: not restored"
[ "$(cat "$TMP/state")" = up ] || fail "6: core not restarted after rollback"
lg=$(jlog)
assert_contains 'процесс mihomo не запущен' "$lg"
assert_contains 'откатываю' "$lg"
assert_contains 'Ядро работает на прежнем конфиге' "$lg"
# новые строки журнала XKeen попадают в журнал применения
printf 'old line\n' > "$TMP/xkeen-error.log"
cat >> "$TMP/bin/xkeen" <<EOF2
echo "xkeen: core started" >> "$TMP/xkeen-error.log"
EOF2
base=$(cgi read GET '' </dev/null | jget '["base"]')
export XKEEN_LOG_FILES="$TMP/xkeen-error.log $TMP/nope.log"
printf 'mixed-port: 7892\n' | cgi save POST "base=$base" >/dev/null
unset XKEEN_LOG_FILES
lg=$(jlog)
assert_contains 'xkeen: core started' "$lg"
assert_not_contains 'old line' "$lg"
printf 'mixed-port: 7891\n' > "$M/config.yaml"

# --- 7: список бэкапов содержит свои и setup.sh, свежие сверху
out=$(cgi backups GET '' </dev/null)
list=$(printf '%s' "$out" | python3 -c 'import json,sys; d=json.loads(sys.stdin.read().split("\n\n",1)[1]); print(" ".join(b["kind"] for b in d["backups"]))')
[ "$list" = "edit edit edit setup" ] || fail "7: order $list"

# --- 8: чтение и restore бэкапа setup.sh; неверное имя - 404
out=$(cgi backup GET 'kind=setup&name=config.yaml.2026-01-01_000000.bak' </dev/null)
[ "$(printf '%s' "$out" | jget '["text"]')" = "$(printf 'old: 1\n')" ] || fail "8: backup text"
out=$(cgi backup GET 'kind=setup&name=../config.yaml' </dev/null)
assert_contains 'Status: 404' "$out"
out=$(cgi restore POST 'kind=setup&name=config.yaml.2026-01-01_000000.bak' </dev/null)
assert_contains 'Status: 200' "$out"
[ "$(cat "$M/config.yaml")" = 'old: 1' ] || fail "8: restore"

# --- 9: restore-working пропускает сломанные бэкапы и совпадающий с текущим
printf 'BROKEN\n' > "$M/config-backups/config.yaml.2099-01-01_000000.bak"
printf 'BROKEN\n' > "$M/config.yaml"
out=$(cgi restore-working POST '' </dev/null)
assert_contains 'Status: 200' "$out"
restored=$(printf '%s' "$out" | jget '["restored"]')
[ "$restored" != config.yaml.2099-01-01_000000.bak ] || fail "9: broken restored"
assert_not_contains BROKEN "$(cat "$M/config.yaml")"
lg=$(jlog)
assert_contains 'Откат к рабочему бэкапу' "$lg"
assert_contains 'проходит mihomo -t - применяю' "$lg"

# --- 10: repair format - BOM, CRLF, табы в отступе, NBSP, хвостовые пробелы
printf '\357\273\277a:\r\n\tb: 1  \nc:\302\240x\n' > "$TMP/raw"
out=$(cgi repair POST 'mode=format' < "$TMP/raw")
[ "$(printf '%s' "$out" | jget '["text"]')" = "$(printf 'a:\n  b: 1\nc: x\n')" ] || fail "10: fixed text"
fixes=$(printf '%s' "$out" | jget '["fixes"]')
for k in bom crlf tabs nbsp trailing; do assert_contains "$k|" "$fixes"; done
assert_contains "$(printf 'a:\r\n')" "$(cat "$TMP/raw")"   # вход не тронут

# --- 11: repair template вызывает migrate_config.sh со шаблоном
cat > "$DIR/migrate_config.sh" <<'EOF'
while [ $# -gt 0 ]; do case $1 in --output) o=$2;; --report) r=$2;; --source) s=$2;; esac; shift 2; done
{ cat "$s"; echo 'proxy-groups: []'; } > "$o"; echo 'REVIEW|managed-section-replaced|proxy-groups' > "$r"
EOF
printf 'x: 1\n' > "$DIR/config.example.yaml"
out=$(printf 'a: 1\n' | cgi repair POST 'mode=template')
assert_contains 'proxy-groups' "$(printf '%s' "$out" | jget '["text"]')"
assert_contains 'managed-section-replaced' "$(printf '%s' "$out" | jget '["report"]')"

# --- 12: занятая блокировка живым процессом - 409 busy
mkdir "$TMP/lock"; echo $$ > "$TMP/lock/pid"
out=$(printf 'a: 1\n' | cgi save POST '')
assert_contains 'busy' "$out"
rm -rf "$TMP/lock"

# --- 13: спецсимволы в JSON экранируются корректно
printf 'k: "q\\\\ \001"\n' > "$M/config.yaml"
cgi read GET '' </dev/null | jget '["text"]' > /dev/null || fail "13: invalid json"

# --- 13b: обратная косая черта, кавычки, табы, CR, управляющие символы и
#     UTF-8 дают корректный JSON под каждым доступным awk (mawk и часть
#     busybox не удваивали "\\" в замене gsub - вкладка открывалась пустой)
printf 'a: "x\\\\.y \\d+"\n\tb: '"'"'q"z'"'"'\r\nc: \001\177 Москва\n' > "$M/config.yaml"
for impl in busybox gawk mawk awk; do
  command -v "$impl" > /dev/null 2>&1 || continue
  mkdir -p "$TMP/awk-$impl"
  if [ "$impl" = busybox ]; then
    busybox awk 'BEGIN{}' 2>/dev/null || continue
    printf '#!/bin/sh\nexec busybox awk "$@"\n' > "$TMP/awk-$impl/awk"
  else
    printf '#!/bin/sh\nexec %s "$@"\n' "$(command -v "$impl")" > "$TMP/awk-$impl/awk"
  fi
  chmod +x "$TMP/awk-$impl/awk"
  PATH="$TMP/awk-$impl:$PATH" MST_CONFIG_ACTION=read REQUEST_METHOD=GET sh "$SCRIPT" > "$TMP/out-$impl"
  python3 - "$TMP/out-$impl" "$M/config.yaml" <<'PY' || fail "13b: неверный JSON под $impl"
import json, sys
d = json.loads(open(sys.argv[1], encoding="utf-8").read().split("\n\n", 1)[1])
assert d["text"] == open(sys.argv[2], encoding="utf-8", newline="").read(), repr(d["text"])
PY
done

# --- 14: config.yaml - ссылка: пишется её цель, ссылка остаётся
printf 'p: 1\n' > "$M/profile.yaml"; rm -f "$M/config.yaml"; ln -s profile.yaml "$M/config.yaml"
base=$(cgi read GET '' </dev/null | jget '["base"]')
out=$(printf 'p: 2\n' | cgi save POST "base=$base")
assert_contains 'Status: 200' "$out"
[ -L "$M/config.yaml" ] || fail "14: link replaced"
[ "$(cat "$M/profile.yaml")" = 'p: 2' ] || fail "14: target"

# --- 15: лишние свои бэкапы удаляются (CONFIG_BACKUP_KEEP)
export CONFIG_BACKUP_KEEP=2
for i in 1 2 3; do
  base=$(cgi read GET '' </dev/null | jget '["base"]')
  printf 'p: 1%s\n' "$i" | cgi save POST "base=$base" > /dev/null
done
unset CONFIG_BACKUP_KEEP
[ "$(ls "$M/config-backups" | wc -l | tr -d ' ')" = 2 ] || fail "15: keep"

# --- 16: проводка - файлы в релизе, установке и раздаваемом каталоге
for f in web/stats_config.sh web/stats_codemirror.js web/stats_codemirror.css; do
  grep -q "^FILE|web|$f|" "$ROOT/release/components.txt" || fail "16: $f нет в components.txt"
  grep -q "${f#web/}" "$ROOT/install.sh" || fail "16: ${f#web/} не ставится install.sh"
done
grep -q 'write_stats_config' "$ROOT/web/stats_service.sh" || fail "16: prepare() не пишет cgi-bin/configedit"
grep -q '"api/config/save": ("cgi-bin/configedit"' "$ROOT/web/stats_httpd.py" || fail "16: нет алиаса api/config/save"
grep -q '"api/config/log": ("cgi-bin/configedit"' "$ROOT/web/stats_httpd.py" || fail "16: нет алиаса api/config/log"
grep -q 'href="/config"' "$ROOT/web/stats_index.html" || fail "16: нет вкладки в меню"

echo "test_stats_config.sh: OK"
