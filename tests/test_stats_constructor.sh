#!/bin/sh
# Тесты web/stats_constructor.sh - API конструктора конфига (чтение
# состояния, предпросмотр, применение). mihomo, xkeen и pidof - заглушки.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
SCRIPT=$ROOT/web/stats_constructor.sh
TMP=$(mktemp -d /tmp/test-stats-constructor.XXXXXX)
trap 'rm -rf "$TMP"' EXIT INT TERM
fail() { echo "FAIL: $*" >&2; exit 1; }
assert_contains() { case "$2" in *"$1"*) ;; *) fail "expected to find: $1 in: $2" ;; esac; }
assert_not_contains() { case "$2" in *"$1"*) fail "expected NOT to find: $1" ;; esac; }

M=$TMP/mihomo; D=$TMP/dir; mkdir -p "$M" "$TMP/bin" "$D"
cat > "$TMP/bin/mihomo" <<'EOF'
#!/bin/sh
while [ $# -gt 0 ]; do [ "$1" = -f ] && f=$2; shift; done
if grep -q BROKEN "$f"; then echo "yaml: line 3: bad"; exit 1; fi
echo "configuration file test is successful"
EOF
cat > "$TMP/bin/xkeen" <<EOF
#!/bin/sh
echo up > "$TMP/state"
EOF
cat > "$TMP/bin/pidof" <<EOF
#!/bin/sh
[ "\$(cat "$TMP/state" 2>/dev/null)" = up ]
EOF
chmod +x "$TMP/bin/mihomo" "$TMP/bin/xkeen" "$TMP/bin/pidof"
echo up > "$TMP/state"
for f in config-tools/config.example.yaml config-tools/services.default.tsv config-tools/render_services.awk \
         config-tools/config_to_state.awk config-tools/constructor_build.sh config-tools/migrate_config.sh \
         config-tools/migrate_config.awk config-tools/fast_wg.awk web/stats_config.sh; do
  cp "$ROOT/$f" "$D/"
done
cp "$D/config.example.yaml" "$M/config.yaml"

export DIR=$D MIHOMO_DIR=$M BIN=$TMP/bin/mihomo XKEEN_BIN=$TMP/bin/xkeen \
  PIDOF_CMD=$TMP/bin/pidof HEALTH_TIMEOUT=2 HEALTH_STABLE=0 TMPROOT=$TMP \
  CONFIGEDIT_LOCK=$TMP/lock
ST=$D/config-state

cgi() {
  body=$(cat)
  printf '%s' "$body" | MST_CONSTRUCTOR_ACTION=$1 REQUEST_METHOD=$2 QUERY_STRING=$3 \
    CONTENT_LENGTH=$(printf '%s' "$body" | wc -c | tr -d ' ') sh "$SCRIPT"
}
jget() { python3 -c 'import json,sys; d=json.loads(sys.stdin.read().split("\n\n",1)[1]); print(eval("d"+sys.argv[1]))' "$1"; }
NL='
'

# --- 1: чтение без состояния - импорт из config.yaml
out=$(cgi read GET '' </dev/null)
assert_contains 'Status: 200' "$out"
[ "$(printf '%s' "$out" | jget '["imported"]')" = True ] || fail "1: imported"
[ "$(printf '%s' "$out" | jget '["manual_edits"]')" = False ] || fail "1: manual_edits"
[ "$(printf '%s' "$out" | jget '["services"]')" = "" ] || fail "1: пустые отличия"
assert_contains "svc${TAB:-	}youtube" "$(printf '%s' "$out" | jget '["defaults"]')"
base=$(printf '%s' "$out" | jget '["base"]')

# --- 2: предпросмотр ничего не пишет
body="### MST-STATE services.tsv${NL}del	spotify${NL}"
out=$(printf '%s' "$body" | cgi preview POST '')
assert_contains 'Status: 200' "$out"
txt=$(printf '%s' "$out" | jget '["text"]')
assert_not_contains '- name: Spotify' "$txt"
assert_contains '- name: YouTube' "$txt"
[ "$(printf '%s' "$out" | jget '["check"]["ok"]')" = True ] || fail "2: check"
[ ! -e "$ST" ] || fail "2: предпросмотр создал состояние"
cmp -s "$M/config.yaml" "$D/config.example.yaml" || fail "2: предпросмотр изменил config.yaml"

# --- 3: применение пишет config.yaml, состояние и managed.sig
out=$(printf '%s' "$body" | cgi apply POST "base=$base")
assert_contains 'Status: 200' "$out"
grep -q '^  - name: Spotify$' "$M/config.yaml" && fail "3: Spotify остался в config.yaml"
[ "$(cat "$ST/services.tsv")" = "$(printf 'del\tspotify')" ] || fail "3: services.tsv"
[ -s "$ST/managed.sig" ] || fail "3: нет managed.sig"
[ ! -e "$ST/geofilter.txt" ] || fail "3: лишний geofilter.txt"

# --- 4: повторное чтение - состояние, без ручных правок
out=$(cgi read GET '' </dev/null)
[ "$(printf '%s' "$out" | jget '["imported"]')" = False ] || fail "4: imported"
[ "$(printf '%s' "$out" | jget '["manual_edits"]')" = False ] || fail "4: manual_edits"
[ "$(printf '%s' "$out" | jget '["services"]')" = "$(printf 'del\tspotify')" ] || fail "4: services"
base=$(printf '%s' "$out" | jget '["base"]')

cp "$M/config.yaml" "$TMP/built.yaml"
# --- 4b: прерванная замена состояния (осталось только .old) - восстанавливается
mv "$ST" "$ST.old"
out=$(cgi read GET '' </dev/null)
[ "$(printf '%s' "$out" | jget '["imported"]')" = False ] || fail "4b: состояние из .old не восстановлено"
[ -d "$ST" ] && [ ! -e "$ST.old" ] || fail "4b: каталоги после восстановления"

# --- 5: ручная правка правил - manual_edits
sed 's/^  - MATCH,DIRECT$/  - DOMAIN-SUFFIX,hand.example,DIRECT\
  - MATCH,DIRECT/' "$M/config.yaml" > "$TMP/c" && cat "$TMP/c" > "$M/config.yaml"
out=$(cgi read GET '' </dev/null)
[ "$(printf '%s' "$out" | jget '["manual_edits"]')" = True ] || fail "5: manual_edits"
# правка подписок (вне управляемых разделов) - не ручная правка управляемых
cp "$M/config.yaml" "$TMP/hand.yaml"
sed 's#subscription-2.example.com/CHANGE_ME#subscription-2.example.com/OTHER#' "$TMP/hand.yaml" > "$M/config.yaml"
out=$(cgi read GET '' </dev/null)
[ "$(printf '%s' "$out" | jget '["manual_edits"]')" = True ] || fail "5: правка rules всё ещё видна"
base=$(printf '%s' "$out" | jget '["base"]')

# --- 5b: сохранение в YAML-режиме текста, совпадающего со сборкой из
#     состояния, снимает manual_edits (managed.sig обновляется)
cfg() {
  body=$(cat)
  printf '%s' "$body" | MST_CONFIG_ACTION=$1 REQUEST_METHOD=$2 QUERY_STRING=$3 \
    CONTENT_LENGTH=$(printf '%s' "$body" | wc -c | tr -d ' ') sh "$D/stats_config.sh"
}
# шаблон обновился: сборка из того же состояния даёт другие разделы
sed 's/^  # Ручной выбор узла\.$/  # Ручной выбор узла (новый шаблон)./' "$D/config.example.yaml" > "$TMP/tpl" && cat "$TMP/tpl" > "$D/config.example.yaml"
grep -q 'новый шаблон' "$D/config.example.yaml" || fail "5b: шаблон не изменён"
printf '### MST-STATE services.tsv\ndel\tspotify\n' | cgi preview POST '' | jget '["text"]' > "$TMP/built.yaml"
out=$(cfg save POST "base=$base" < "$TMP/built.yaml")
assert_contains 'Status: 200' "$out"
out=$(cgi read GET '' </dev/null)
[ "$(printf '%s' "$out" | jget '["manual_edits"]')" = False ] || fail "5b: manual_edits после сохранения сборки"
base=$(printf '%s' "$out" | jget '["base"]')

# --- 6: применение, не прошедшее mihomo -t, не трогает состояние
cp "$ST/services.tsv" "$TMP/st.before"
body6="### MST-STATE services.tsv${NL}del	twitch${NL}### MST-STATE user-rules.txt${NL}DOMAIN,BROKEN.example,DIRECT${NL}"
out=$(printf '%s' "$body6" | cgi apply POST "base=$base")
assert_contains 'Status: 422' "$out"
cmp -s "$ST/services.tsv" "$TMP/st.before" || fail "6: состояние изменилось при ошибке"
[ ! -e "$ST/user-rules.txt" ] || fail "6: user-rules.txt записан при ошибке"

# --- 7: неизвестный блок и текст вне блоков - 400
out=$(printf '### MST-STATE evil.sh\nx\n' | cgi preview POST '')
assert_contains 'Status: 400' "$out"
out=$(printf 'junk\n### MST-STATE services.tsv\n' | cgi preview POST '')
assert_contains 'Status: 400' "$out"

# --- 8: ошибка в состоянии - 422 с понятным текстом
out=$(printf '### MST-STATE services.tsv\nsvc\tn\tN\tnosection\n' | cgi preview POST '')
assert_contains 'Status: 422' "$out"
assert_contains 'nosection' "$out"

echo "test_stats_constructor.sh: OK"
