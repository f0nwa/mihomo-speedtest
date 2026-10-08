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
         config-tools/migrate_config.awk config-tools/fast_wg.awk config-tools/rule-catalog.tsv config-tools/wg_import.awk config-tools/detect_ua.sh web/stats_config.sh; do
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

# --- 4c: замер скорости меняет ссылки на WG-победителей в FAST_WG_REF -
#     это не ручная правка групп
cp "$M/config.yaml" "$TMP/pre-wg.yaml"
awk '{ print } /^ *# --- FAST_WG_REF:BEGIN ---/ { print "    proxies: [\x27WG-A\x27]" }' "$TMP/pre-wg.yaml" > "$M/config.yaml"
grep -q "proxies: \['WG-A'\]" "$M/config.yaml" || fail "4c: ссылка не вставлена"
out=$(cgi read GET '' </dev/null)
[ "$(printf '%s' "$out" | jget '["manual_edits"]')" = False ] || fail "4c: ссылки WG посчитаны ручной правкой"
cp "$TMP/pre-wg.yaml" "$M/config.yaml"

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

# --- 9: ?import=1 - перенос из config.yaml даже при наличии состояния
[ -f "$ST/services.tsv" ] || fail "9: нет состояния для проверки"
sed 's/^  - MATCH,DIRECT$/  - DOMAIN-SUFFIX,hand.example,DIRECT\
  - MATCH,DIRECT/' "$M/config.yaml" > "$TMP/c" && cat "$TMP/c" > "$M/config.yaml"
out=$(cgi read GET 'import=1' </dev/null)
[ "$(printf '%s' "$out" | jget '["imported"]')" = True ] || fail "9: imported"
[ "$(printf '%s' "$out" | jget '["manual_edits"]')" = False ] || fail "9: manual_edits при переносе"
assert_contains 'hand.example' "$(printf '%s' "$out" | jget '["user_rules"]')"

# --- 10: каталог наборов правил
out=$(cgi catalog GET '' </dev/null)
assert_contains 'Status: 200' "$out"
assert_contains 'netflix' "$(printf '%s' "$out" | jget '["text"]')"
mv "$D/rule-catalog.tsv" "$D/rule-catalog.tsv.off"
out=$(cgi catalog GET '' </dev/null)
assert_contains 'Status: 404' "$out"
mv "$D/rule-catalog.tsv.off" "$D/rule-catalog.tsv"

# --- 11: подписки и свои прокси - в чтении и в применении
out=$(cgi read GET '' </dev/null)
subs=$(printf '%s' "$out" | jget '["subscriptions"]')
assert_contains 'subscription-1.example.com' "$subs"
assert_contains 'provider-a' "$subs"
assert_contains "Hysteria2" "$(printf '%s' "$out" | jget '["proxies"]')"
tb=$(printf '%s' "$out" | jget '["template_base"]')
assert_contains 'select-default: &select-default' "$tb"
assert_contains "name: 'Заблок. сервисы'" "$tb"
assert_contains 'exclude-filter: &geofilter' "$tb"
assert_not_contains 'SERVICE_GROUPS' "$tb"
assert_not_contains 'rule-providers' "$tb"
base=$(printf '%s' "$out" | jget '["base"]')
body="### MST-STATE services.tsv${NL}### MST-STATE subscriptions.tsv${NL}https://zz.example/SECRET9	clash.meta	zz${NL}### MST-STATE proxies.yaml${NL}  - name: 'Own'${NL}    type: hysteria2${NL}    server: o.example${NL}    port: 443${NL}"
out=$(printf '%s' "$body" | cgi apply POST "base=$base")
assert_contains 'Status: 200' "$out"
grep -q 'SECRET9' "$M/config.yaml" || fail "11: подписка не применилась"
grep -q "name: 'Own'" "$M/config.yaml" || fail "11: своя нода не применилась"
grep -q 'zz.example' "$ST/subscriptions.tsv" || fail "11: подписки не в состоянии"
out=$(cgi read GET '' </dev/null)
assert_contains 'SECRET9' "$(printf '%s' "$out" | jget '["subscriptions"]')"
assert_contains "name: 'Own'" "$(printf '%s' "$out" | jget '["proxies"]')"

# --- 12: перевод .conf в ноду
conf="### MST-WG DE WG${NL}[Interface]${NL}PrivateKey = AAA=${NL}Address = 10.8.0.2/32${NL}[Peer]${NL}PublicKey = BBB=${NL}Endpoint = vpn.example.com:51820${NL}AllowedIPs = 0.0.0.0/0${NL}"
out=$(printf '%s' "$conf" | cgi wgconf POST '')
assert_contains 'Status: 200' "$out"
assert_contains "name: 'DE WG'" "$(printf '%s' "$out" | jget '["yaml"]')"
out=$(printf '### MST-WG X%s[Interface]%s' "$NL" "$NL" | cgi wgconf POST '')
assert_contains 'Status: 422' "$out"
out=$(printf 'мусор%s' "$NL" | cgi wgconf POST '')
assert_contains 'Status: 400' "$out"

# --- 13: фильтр нод конструктора - и в BLOCK спидтеста
export ENV=$TMP/speedtest2.env
printf "%s\n" "BLOCK='old|Берлин'" "TOPN='15'" > "$ENV"
out=$(cgi read GET '' </dev/null)
[ "$(printf '%s' "$out" | jget '["block"]')" = "old|Берлин" ] || fail "13: block в чтении"
rm -f "$ENV"
out=$(cgi read GET '' </dev/null)
[ "$(printf '%s' "$out" | jget '["block"]')" = "" ] || fail "13: block без speedtest2.env"
printf "%s\n" "BLOCK='old'" "TOPN='15'" > "$ENV"
out=$(cgi read GET '' </dev/null)
base=$(printf '%s' "$out" | jget '["base"]')
body="### MST-STATE services.tsv${NL}### MST-STATE geofilter.txt${NL}Russia${NL} Moscow ${NL}russia${NL}it's-bad${NL}"
out=$(printf '%s' "$body" | cgi preview POST '')
assert_contains 'Status: 422' "$out"
body="### MST-STATE services.tsv${NL}### MST-STATE geofilter.txt${NL}Russia${NL} Moscow ${NL}russia${NL}Берлин${NL}"
out=$(printf '%s' "$body" | cgi apply POST "base=$base")
assert_contains 'Status: 200' "$out"
grep -qxF "BLOCK='Russia|Moscow|Берлин'" "$ENV" || fail "13: BLOCK не обновлён: $(cat "$ENV")"
grep -qxF "TOPN='15'" "$ENV" || fail "13: остальные настройки потеряны"
grep -q "exclude-filter: &geofilter '(?i)Russia|Moscow|Берлин'" "$M/config.yaml" || fail "13: exclude-filter в config.yaml"
# --- 14: без своего фильтра - слова шаблона
out=$(cgi read GET '' </dev/null)
base=$(printf '%s' "$out" | jget '["base"]')
out=$(printf '### MST-STATE services.tsv\n' | cgi apply POST "base=$base")
assert_contains 'Status: 200' "$out"
grep -q "^BLOCK='.*Russia|.*'$" "$ENV" && ! grep -q 'Берлин' "$ENV" || fail "14: BLOCK не вернулся к шаблону: $(cat "$ENV")"
# --- 15: нет speedtest2.env - применение всё равно проходит
rm -f "$ENV"
out=$(cgi read GET '' </dev/null)
base=$(printf '%s' "$out" | jget '["base"]')
out=$(printf '### MST-STATE services.tsv\n### MST-STATE geofilter.txt\nX\n' | cgi apply POST "base=$base")
assert_contains 'Status: 200' "$out"
[ ! -e "$ENV" ] || fail "15: speedtest2.env не должен создаваться конструктором"

# --- 16: подбор User-Agent (curl - заглушка, ответ зависит от адреса и UA)
mkdir -p "$TMP/curlbin"
cat > "$TMP/curlbin/curl" <<'EOF_CURL'
#!/bin/sh
out="" ua="" url=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out=$2; shift 2 ;;
    -A) ua=$2; shift 2 ;;
    -w|-m|--proto|--proto-redir) shift 2 ;;
    -*) shift ;;
    *) url=$1; shift ;;
  esac
done
echo "$ua $url" >> "$CURL_LOG"
full='mixed-port: 7890
proxy-groups: []
proxies: []'
case $url in
  */dead) exit 7 ;;
  */full)
    case $ua in
      v2rayNG*) printf '[{"dns":{}}]' > "$out" ;;
      ClashforWindows*) printf 'proxies:\n  - name: a\n' > "$out" ;;
      clash-verge*) printf '%s\n' "$full" > "$out" ;;
      *) printf '<html>403</html>' > "$out" ;;
    esac ;;
  */short)
    case $ua in
      ClashforWindows*) printf 'proxies:\n  - name: a\n' > "$out" ;;
      *) printf '<html>403</html>' > "$out" ;;
    esac ;;
  */b64) printf 'dmxlc3M6Ly90ZXN0\n' > "$out" ;;
  *) printf '<html>403</html>' > "$out" ;;
esac
printf 200
EOF_CURL
chmod +x "$TMP/curlbin/curl"
export CURL_LOG=$TMP/curl.log
detect() { printf '%s' "$1" | PATH="$TMP/curlbin:$PATH" cgi detect-ua POST ''; }

: > "$CURL_LOG"
out=$(detect 'https://panel.test/SECRETKEY123/full')
assert_contains 'Status: 200' "$out"
[ "$(printf '%s' "$out" | jget '["ua"]')" = "clash-verge/v2.0.5" ] || fail "16: ua full: $out"
[ "$(printf '%s' "$out" | jget '["quality"]')" = full ] || fail "16: quality full"
[ "$(printf '%s' "$out" | jget '["reason"]')" = "" ] || fail "16: reason full"
[ "$(printf '%s' "$out" | jget '["tried"].__len__()')" = 4 ] || fail "16: перебор должен остановиться на подошедшем UA"
[ "$(printf '%s' "$out" | jget '["tried"][0]["http"]')" = 200 ] || fail "16: tried.http"
assert_contains 'JSON' "$(printf '%s' "$out" | jget '["tried"][0]["kind"]')"
assert_contains 'clash YAML, полный' "$(printf '%s' "$out" | jget '["kind"]')"
assert_not_contains 'SECRETKEY123' "$(printf '%s' "$out" | sed -n '/^{/,$p')"
[ "$(wc -l < "$CURL_LOG" | tr -d ' ')" = 4 ] || fail "16: число запросов curl"
grep -q '^ClashforWindows/0.20.39 https://panel.test/SECRETKEY123/full$' "$CURL_LOG" || fail "16: curl получил UA и адрес"

# base64-список подходит так же, как в setup.sh
out=$(detect 'http://panel.test/b64')
[ "$(printf '%s' "$out" | jget '["ua"]')" = "v2rayNG/1.8.0" ] || fail "16: base64"
[ "$(printf '%s' "$out" | jget '["quality"]')" = full ] || fail "16: base64 quality"

# только укороченный YAML - запасной вариант после перебора всех UA
out=$(detect 'https://panel.test/short')
[ "$(printf '%s' "$out" | jget '["ua"]')" = "ClashforWindows/0.20.39" ] || fail "16: short ua"
[ "$(printf '%s' "$out" | jget '["quality"]')" = short ] || fail "16: short quality"
ua_count=$( (DETECT_UA_LIB_ONLY=1; . "$ROOT/config-tools/detect_ua.sh"; printf '%s\n' "$UA_LIST" | grep -c .) )
[ "$(printf '%s' "$out" | jget '["tried"].__len__()')" = "$ua_count" ] || fail "16: short перебрал не все UA ($ua_count)"

# ничего не подошло
out=$(detect 'https://panel.test/none')
[ "$(printf '%s' "$out" | jget '["ua"]')" = "" ] || fail "16: none ua"
[ "$(printf '%s' "$out" | jget '["reason"]')" = none ] || fail "16: none reason"

# нет соединения - сразу, без 16 лишних запросов
: > "$CURL_LOG"
out=$(detect 'https://panel.test/dead')
assert_contains 'Status: 200' "$out"
[ "$(printf '%s' "$out" | jget '["reason"]')" = unreachable ] || fail "16: unreachable"
[ "$(wc -l < "$CURL_LOG" | tr -d ' ')" = 1 ] || fail "16: при недоступной сети нужен один запрос"

# плохие адреса и тело
for bad in 'ftp://x/y' 'file:///etc/passwd' 'https://x/y z' 'https://x/"y' 'https://x/\y' 'panel.test/sub' ''; do
  : > "$CURL_LOG"
  out=$(detect "$bad")
  assert_contains 'Status: 400' "$out"
  [ ! -s "$CURL_LOG" ] || fail "16: curl вызван для плохого адреса: $bad"
done
out=$(detect "https://a.test/1${NL}https://b.test/2")
assert_contains 'Status: 400' "$out"
out=$(printf 'https://a.test/1' | MST_CONSTRUCTOR_ACTION=detect-ua REQUEST_METHOD=GET sh "$SCRIPT")
assert_contains 'Status: 405' "$out"

echo "test_stats_constructor.sh: OK"
