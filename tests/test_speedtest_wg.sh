#!/bin/sh
# WireGuard/AmneziaWG через основное ядро (порция 2 плана
# 2026-09-28-wg-main-core-speedtest): адрес/secret API из рабочего конфига,
# состав служебной группы, отбор и пропуск с причиной, задержка с прогревом.
# curl/netstat подменяются функциями оболочки - ни сети, ни mihomo не нужно.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
SCRIPT=$ROOT/speedtest-runtime/speedtest2.sh
T=$(mktemp -d "${TMPDIR:-/tmp}/speedtest-wg-test.XXXXXX")
trap 'rm -rf "$T"' EXIT INT TERM
fail() { echo "FAIL: $*" >&2; exit 1; }
assert_eq() { [ "$1" = "$2" ] || fail "expected [$2], got [$1] ($3)"; }

MST_LIB_ONLY=1 . "$SCRIPT"
WORK=$T/work; mkdir -p "$WORK"; RUN_LOG=$WORK/run.log; FORCE=0
MAIN_CONFIG=$T/config.yaml

# --- main_api_init: 0.0.0.0 -> 127.0.0.1, secret в файл настроек curl ---
printf 'log-level: silent\nexternal-controller: 0.0.0.0:9191\nsecret: "s3cr3t" # комментарий\n' > "$MAIN_CONFIG"
main_api_init || fail "main_api_init failed"
assert_eq "$API_MAIN" "127.0.0.1:9191" "адрес API"
assert_eq "$MAIN_API_OK" 1 "MAIN_API_OK"
assert_eq "$(cat "$MAIN_CURL_CFG")" 'header = "Authorization: Bearer s3cr3t"' "заголовок secret"
printf 'external-controller: 127.0.0.1:9090\nsecret: "a\\"b"\n' > "$MAIN_CONFIG"
if main_api_init; then fail "secret с кавычкой должен отклоняться"; fi
assert_eq "$MAIN_API_OK" 0 "MAIN_API_OK после отказа"
printf 'external-controller: 127.0.0.1:9090\n' > "$MAIN_CONFIG"
main_api_init || fail "без secret"
assert_eq "$(wc -c < "$MAIN_CURL_CFG" | tr -d ' ')" 0 "без secret файл пуст"

# --- urlencode / json_escape ---
assert_eq "$(urlencode 'a b')" "a%20b" "urlencode"
assert_eq "$(urlencode '⚡ Пул (1)')" "%E2%9A%A1%20%D0%9F%D1%83%D0%BB%20%281%29" "urlencode UTF-8"
assert_eq "$(urlencode 'MST-FAST_WG.1~')" "MST-FAST_WG.1~" "urlencode безопасные символы"
# без od: минимальный BusyBox od на роутере не знает -t (урок: запросы уходили на /proxies/)
od() { return 1; }
assert_eq "$(urlencode 'a b')" "a%20b" "urlencode не зависит от od"
unset -f od
curl() { printf '%s' '{"proxies":{"G":{"all":["Blanc_NL_AMS_1"]}}}'; }
if wg_group_members > /dev/null; then fail "ответ /proxies/ (все прокси) нельзя принимать за состав группы"; fi
assert_eq "$(json_escape 'x"y\z')" 'x\"y\\z' "json_escape"

# --- wg_group_members: поле all, экранирование ---
curl() { printf '%s' '{"all":["Blanc_NL_AMS_1","B \"q\"","C<D","EЖ"],"name":"MST-SPEEDTEST","now":"x"}'; }
wg_group_members > "$T/members" || fail "wg_group_members failed"
assert_eq "$(sed -n 1p "$T/members")" "Blanc_NL_AMS_1" "член 1"
assert_eq "$(sed -n 2p "$T/members")" 'B "q"' "член 2 (кавычки)"
assert_eq "$(sed -n 3p "$T/members")" 'C<D' "член 3 (\\u003c)"
curl() { printf '%s' '{"message":"resource not found"}'; }
if wg_group_members > /dev/null; then fail "нет поля all - должна быть ошибка"; fi

# --- wg_prepare ---
printf 'n0001\tvless-one\nn0002\tBlanc_NL_AMS_1\nn0003\tOther WG\nn0004\tDup WG\nn0005\tDup WG\n' > "$WORK/map.txt"
printf 'n0002\tBlanc_NL_AMS_1\nn0003\tOther WG\nn0004\tDup WG\nn0005\tDup WG\n' > "$WORK/wg.txt"
netstat() { printf '%s\n' 'tcp 0 0 127.0.0.1:7896 0.0.0.0:* LISTEN'; }
curl() { printf '%s' '{"all":["vless-one","Blanc_NL_AMS_1","Dup WG"]}'; }

# нет входа в конфиге - все WG пропущены с причиной
printf 'external-controller: 127.0.0.1:9090\n' > "$MAIN_CONFIG"; main_api_init
: > "$RUN_LOG"; wg_prepare
assert_eq "$(tr '\n' ' ' < "$WORK/wg_skip.txt")" "n0002 n0003 n0004 n0005 " "без входа - все пропущены"
assert_eq "$(wc -c < "$WORK/wg_ok.txt" | tr -d ' ')" 0 "без входа - никого"
grep -q "нет входа mst-speedtest" "$RUN_LOG" || fail "нет причины пропуска в логе"

# вход есть, но не слушает
printf 'external-controller: 127.0.0.1:9090\nlisteners:\n  - name: mst-speedtest\n    port: 7896\n' > "$MAIN_CONFIG"; main_api_init
netstat() { printf '%s\n' 'tcp 0 0 127.0.0.1:17896 0.0.0.0:* LISTEN'; }
: > "$RUN_LOG"; wg_prepare
assert_eq "$(wc -l < "$WORK/wg_skip.txt" | tr -d ' ')" 4 "вход не слушает - все пропущены"
grep -q "не слушает" "$RUN_LOG" || fail "нет причины 'не слушает'"

# всё на месте: Blanc - ok, Other - нет в группе, Dup - неоднозначное имя
netstat() { printf '%s\n' 'tcp 0 0 127.0.0.1:7896 0.0.0.0:* LISTEN'; }
: > "$RUN_LOG"; wg_prepare
assert_eq "$(cat "$WORK/wg_ok.txt")" "$(printf 'n0002\tBlanc_NL_AMS_1')" "проверяемые WG"
assert_eq "$(tr '\n' ' ' < "$WORK/wg_skip.txt")" "n0003 n0004 n0005 " "пропущенные WG"
grep -q "Other WG - нет в группе MST-SPEEDTEST" "$RUN_LOG" || fail "нет причины 'нет в группе'"
grep -q "Dup WG - имя встречается в пуле несколько раз" "$RUN_LOG" || fail "нет причины 'дубль имени'"

# --- wg_delays: первый запрос - прогрев, в зачёт второй ---
: > "$T/calls"
curl() {
  echo x >> "$T/calls"
  if [ "$(wc -l < "$T/calls" | tr -d ' ')" = 1 ]; then printf '%s' '{"delay":2417}'; else printf '%s' '{"delay":126}'; fi
}
: > "$WORK/alive.raw"; wg_delays
assert_eq "$(cat "$WORK/alive.raw")" "126 n0002" "задержка после прогрева"
assert_eq "$(wc -l < "$T/calls" | tr -d ' ')" 2 "два запроса задержки"

# --- wg_select: PUT в служебную группу основного ядра ---
curl() { printf '%s\n' "$@" > "$T/select_args"; }
wg_select 'Blanc "NL"' || fail "wg_select failed"
grep -qx 'http://127.0.0.1:9090/proxies/MST-SPEEDTEST' "$T/select_args" || fail "wg_select: неверный URL группы"
grep -qxF '{"name":"Blanc \"NL\""}' "$T/select_args" || fail "wg_select: неверное тело"

# --- wg_publish_fast: у каждой WG-ноды свой пропуск "FAST-WG <имя>";
#     выше порога -> нода, замерена ниже порога -> REJECT, иначе не трогаем ---
printf 'n0002\tBlanc_NL_AMS_1\nn0003\tOther WG\n' > "$WORK/wg_ok.txt"
publish_case() {  # $1 now (MISSING - группы нет), $2 res.txt
  printf '%s' "$2" > "$WORK/res.txt"; : > "$T/put"; : > "$RUN_LOG"
  PUB_NOW=$1
  curl() {
    case "$*" in
      *'-X PUT'*) printf '%s\n' "$*" >> "$T/put" ;;
      *) [ "$PUB_NOW" = MISSING ] && return 22; printf '{"all":["REJECT"],"now":"%s","type":"Selector"}' "$PUB_NOW" ;;
    esac
  }
  wg_publish_fast 1000000
}
publish_case REJECT '2000000 n0002
3000000 n0003
'
grep -qF 'proxies/FAST-WG%20Blanc_NL_AMS_1' "$T/put" && grep -qF '{"name":"Blanc_NL_AMS_1"}' "$T/put" || fail "первый WG выше порога не выбран в своём пропуске"
grep -qF 'proxies/FAST-WG%20Other%20WG' "$T/put" && grep -qF '{"name":"Other WG"}' "$T/put" || fail "второй WG выше порога не выбран в своём пропуске"
publish_case 'Other WG' '3000000 n0003
'
[ "$(grep -c PUT "$T/put")" = 0 ] || fail "Other WG уже выбран, а Blanc не замерен - PUT не нужен"
publish_case Blanc_NL_AMS_1 '500000 n0002
'
grep -qF 'proxies/FAST-WG%20Blanc_NL_AMS_1' "$T/put" && grep -qF '{"name":"REJECT"}' "$T/put" || fail "WG ниже порога должен получить REJECT"
grep -q 'Other%20WG' "$T/put" && fail "не замеренный WG трогать нельзя"
publish_case Blanc_NL_AMS_1 ''
[ ! -s "$T/put" ] || fail "не ответивший или не замеренный WG не трогаем - пул сам пропускает его по пингу"
publish_case MISSING '2000000 n0002
'
[ ! -s "$T/put" ] || fail "без групп-пропусков выбирать нечего"
grep -q 'нет групп FAST-WG <имя>' "$RUN_LOG" || fail "нет причины про отсутствие пропусков"
unset -f curl

# --- main(): пул только из WG - второе ядро не запускается, замер через
#     вход 7896 основного ядра, в fast.yaml WG не пишется, окно стабильности A ---
E=$T/e2e; mkdir -p "$E/www"
cat > "$E/sources.yaml" <<'YAML'
proxies:
  - name: Blanc_NL_AMS_1
    type: wireguard
    server: wg.example
    port: 51121
YAML
printf 'external-controller: 0.0.0.0:9090\nlisteners:\n  - name: mst-speedtest\n    port: 7896\n' > "$E/config.yaml"
(
  MST_LIB_ONLY=1 . "$SCRIPT"
  FORCE=1; BLOCK='Russia'; SOURCES=$E/sources.yaml; MAIN_CONFIG=$E/config.yaml
  PREP=$ROOT/speedtest-runtime/prep.awk; NODE_STATS_UPDATE=$ROOT/speedtest-runtime/node_stats_update.awk
  WORK=$E/work; RUN_LOG=$WORK/run.log; LOG=$E/speedtest.log; LOCK=$E/lock
  OUT=$E/fast.yaml; LAST=$E/last.txt; HISTORY_RUNS=$E/runs.tsv; HISTORY_NODES=$E/nodes.tsv
  HISTORY_STABILITY=$E/stability.tsv; STATS_PROGRESS=$E/www/progress.json; STATS_HTTP_ENABLE=0
  STATS_HTML=$E/www/stats.html; STATS_JSON=$E/www/stats.json
  BIN=/bin/false
  netstat() { printf '%s\n' 'tcp 0 0 127.0.0.1:7896 0.0.0.0:* LISTEN'; }
  curl() {
    printf '%s\n' "$*" >> "$E/curl.log"
    case "$*" in
      *127.0.0.1:9099*) return 7 ;;
      *'-X PUT'*'/proxies/MST'*|*'-X PUT'*'/proxies/FAST-WG'*) return 0 ;;
      *'/proxies/MST'*|*'/proxies/FAST-WG'*) printf '%s' '{"all":["REJECT","Blanc_NL_AMS_1"],"now":"REJECT"}' ;;
      *'/delay?'*) printf '%s' '{"delay":126}' ;;
      *'127.0.0.1:7896'*) printf '%s' '200 1000000' ;;
      *'speed.cloudflare.com'*) printf '%s' '200 10000000' ;;
      *) return 7 ;;
    esac
  }
  main
) > "$E/out.txt" 2>&1 || true
grep -q '9099' "$E/curl.log" && fail "второе ядро опрашивалось при пуле только из WG"
[ "$(grep -c '127.0.0.1:7896' "$E/curl.log")" = 1 ] || fail "замер скорости WG не через вход 7896 основного ядра"
grep -q -- '-X PUT.*MST' "$E/curl.log" 2>/dev/null || grep -q 'PUT' "$E/curl.log" || fail "служебная группа не переключалась"
[ ! -e "$E/fast.yaml" ] || fail "WG-нода записана в fast.yaml"
grep -q 'WG: 8.0 Мбит/с  Blanc_NL_AMS_1' "$E/speedtest.log" || fail "нет строки о WG-результате в логе"
grep -q '  8.0 Мбит/с  Blanc_NL_AMS_1' "$E/out.txt" || fail "живой вывод не в Мбит/с"
grep -q 'Канал: 80.0 Мбит/с' "$E/speedtest.log" || fail "Канал не в Мбит/с"
grep -q 'Лучший результат: 8.0 Мбит/с' "$E/speedtest.log" || fail "лучший результат не в Мбит/с"
grep -q 'МБ/с' "$E/speedtest.log" && fail "в журнале остались МБ/с"
[ "$(awk -F '\t' '$1 == "Blanc_NL_AMS_1" { print $10 }' "$E/stability.tsv")" = "A" ] || fail "окно стабильности WG-ноды не A"

# --- тот же прогон, но канал медленный: WG проходит порог и попадает в пул через свой пропуск ---
E=$T/e2e_win; mkdir -p "$E/www"
cat > "$E/sources.yaml" <<'YAML'
proxies:
  - name: Blanc_NL_AMS_1
    type: wireguard
    server: wg.example
    port: 51121
YAML
printf 'external-controller: 0.0.0.0:9090\nlisteners:\n  - name: mst-speedtest\n    port: 7896\n' > "$E/config.yaml"
(
  MST_LIB_ONLY=1 . "$SCRIPT"
  FORCE=0; BLOCK='Russia'; SOURCES=$E/sources.yaml; MAIN_CONFIG=$E/config.yaml
  PREP=$ROOT/speedtest-runtime/prep.awk; NODE_STATS_UPDATE=$ROOT/speedtest-runtime/node_stats_update.awk
  WORK=$E/work; RUN_LOG=$WORK/run.log; LOG=$E/speedtest.log; LOCK=$E/lock
  OUT=$E/fast.yaml; LAST=$E/last.txt; HISTORY_RUNS=$E/runs.tsv; HISTORY_NODES=$E/nodes.tsv
  HISTORY_STABILITY=$E/stability.tsv; STATS_PROGRESS=$E/www/progress.json; STATS_HTTP_ENABLE=0
  STATS_HTML=$E/www/stats.html; STATS_JSON=$E/www/stats.json
  BIN=/bin/false
  netstat() { printf '%s\n' 'tcp 0 0 127.0.0.1:7896 0.0.0.0:* LISTEN'; }
  curl() {
    printf '%s\n' "$*" >> "$E/curl.log"
    case "$*" in
      *127.0.0.1:9099*) return 7 ;;
      *'-X PUT'*'/proxies/MST'*|*'-X PUT'*'/proxies/FAST-WG'*) return 0 ;;
      *'/proxies/MST'*|*'/proxies/FAST-WG'*) printf '%s' '{"all":["REJECT","Blanc_NL_AMS_1"],"now":"REJECT"}' ;;
      *'/delay?'*) printf '%s' '{"delay":126}' ;;
      *'127.0.0.1:7896'*) printf '%s' '200 1000000' ;;
      *'speed.cloudflare.com'*) printf '%s' '200 2000000' ;;
      *) return 7 ;;
    esac
  }
  main
) > "$E/out.txt" 2>&1 || true
grep -q -- '-X PUT.*FAST-WG%20Blanc_NL_AMS_1' "$E/curl.log" || fail "WG выше порога не выбран в своём пропуске"
grep -q "WG: Blanc_NL_AMS_1 -> '⚡ Быстрый пул'" "$E/speedtest.log" || fail "нет строки о WG-победителе в пуле"
[ ! -e "$E/fast.yaml" ] || fail "WG-победитель записан в fast.yaml"

echo "test_speedtest_wg.sh: OK"
