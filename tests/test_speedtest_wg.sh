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

# --- Прямые ссылки, атомарная запись и откат при ошибках применения ---
FAST_WG_AWK=$ROOT/config-tools/fast_wg.awk
CONFIGEDIT_LOCK=$T/config-lock
MIHOMO_DIR=$T
BIN=/usr/bin/true
cat > "$MAIN_CONFIG" <<'YAML'
proxies:
  - name: Blanc_NL_AMS_1
    type: wireguard
  - name: Other WG
    type: wireguard
proxy-groups:
  - name: '⚡ Быстрый пул'
    type: url-test
    # --- FAST_WG_REF:BEGIN ---
    # --- FAST_WG_REF:END ---
  # --- FAST_WG:BEGIN ---
  - name: 'FAST-WG Blanc_NL_AMS_1'
    type: select
    proxies: [REJECT, Blanc_NL_AMS_1]
  # --- FAST_WG:END ---
YAML
printf 'n0002\tBlanc_NL_AMS_1\nn0003\tOther WG\n' > "$WORK/wg_ok.txt"
printf '2000000 n0002\n3000000 n0003\n' > "$WORK/res.txt"
: > "$T/put"
curl() { printf '%s\n' "$*" >> "$T/put"; }
wg_publish_fast 1000000
grep -qF "proxies: ['Blanc_NL_AMS_1', 'Other WG']" "$MAIN_CONFIG" || fail "нет прямых ссылок на победителей"
! grep -qF "name: 'FAST-WG" "$MAIN_CONFIG" || fail "осталась техническая группа"
grep -q '/configs' "$T/put" || fail "конфиг не перечитан"
cp "$MAIN_CONFIG" "$T/good"
: > "$T/put"
wg_publish_fast 1000000
[ ! -s "$T/put" ] || fail "тот же состав вызывает перезагрузку"
printf '500000 n0002\n' > "$WORK/res.txt"
BIN=/usr/bin/false
wg_publish_fast 1000000
cmp -s "$MAIN_CONFIG" "$T/good" || fail "ошибка валидации изменила конфиг"
BIN=/usr/bin/true
(
  cp() {
    for dst do :; done
    case "$dst" in
      "$T"/.config.yaml.*) printf 'partial' > "$dst"; return 1 ;;
      *) command cp "$@" ;;
    esac
  }
  wg_publish_fast 1000000
)
cmp -s "$MAIN_CONFIG" "$T/good" || fail "ошибка записи повредила конфиг"
[ ! -d "$CONFIGEDIT_LOCK" ] || fail "ошибка записи оставила блокировку"
curl() { return 22; }
wg_publish_fast 1000000
cmp -s "$MAIN_CONFIG" "$T/good" || fail "ошибка API не откатила конфиг"
[ ! -d "$CONFIGEDIT_LOCK" ] || fail "блокировка не очищена"
curl() { printf '%s\n' "$*" >> "$T/put"; }
mkdir "$CONFIGEDIT_LOCK"
printf '%s\n' $$ > "$CONFIGEDIT_LOCK/pid"
wg_publish_fast 1000000
cmp -s "$MAIN_CONFIG" "$T/good" || fail "занятый конфиг изменён"
rm -rf "$CONFIGEDIT_LOCK"
# WG, исключённая из текущего замера, сохраняет прежнее участие.
printf 'n0002\tBlanc_NL_AMS_1\n' > "$WORK/wg_ok.txt"
wg_publish_fast 1000000
grep -qF "proxies: ['Other WG']" "$MAIN_CONFIG" || fail "медленная WG не удалена / незамеренная удалена"
: > "$WORK/res.txt"; : > "$T/put"
wg_publish_fast 1000000
[ ! -s "$T/put" ] || fail "без результатов состав изменён"

# config.yaml - ссылка на профиль (XKeen UI): правится цель, ссылка остаётся
mkdir -p "$T/profiles"
cp "$MAIN_CONFIG" "$T/profiles/p1.yaml"
sed -i "s/^proxies: \['Other WG'\]//" "$T/profiles/p1.yaml"
REAL_CONFIG=$MAIN_CONFIG
MAIN_CONFIG=$T/link.yaml
ln -s profiles/p1.yaml "$MAIN_CONFIG"
printf '2000000 n0002\n3000000 n0003\n' > "$WORK/res.txt"
wg_publish_fast 1000000
[ -L "$MAIN_CONFIG" ] || fail "ссылка конфига заменена файлом"
grep -qF "proxies: ['Blanc_NL_AMS_1', 'Other WG']" "$T/profiles/p1.yaml" || fail "победители не записаны в цель ссылки"
MAIN_CONFIG=$REAL_CONFIG
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
cat "$E/sources.yaml" >> "$E/config.yaml"
printf "proxy-groups:\n  - name: '⚡ Быстрый пул'\n    type: url-test\n    # --- FAST_WG_REF:BEGIN ---\n    # --- FAST_WG_REF:END ---\n" >> "$E/config.yaml"
(
  MST_LIB_ONLY=1 . "$SCRIPT"
  FORCE=1; BLOCK='Russia'; SOURCES=$E/sources.yaml; MAIN_CONFIG=$E/config.yaml
  PREP=$ROOT/speedtest-runtime/prep.awk; NODE_STATS_UPDATE=$ROOT/speedtest-runtime/node_stats_update.awk
  WORK=$E/work; RUN_LOG=$WORK/run.log; LOG=$E/speedtest.log; LOCK=$E/lock
  OUT=$E/fast.yaml; LAST=$E/last.txt; HISTORY_RUNS=$E/runs.tsv; HISTORY_NODES=$E/nodes.tsv
  HISTORY_STABILITY=$E/stability.tsv; STATS_PROGRESS=$E/www/progress.json; STATS_HTTP_ENABLE=0
  STATS_HTML=$E/www/stats.html; STATS_JSON=$E/www/stats.json
  BIN=/usr/bin/true
  FAST_WG_AWK=$ROOT/config-tools/fast_wg.awk; CONFIGEDIT_LOCK=$E/config-lock; MIHOMO_DIR=$E
  netstat() { printf '%s\n' 'tcp 0 0 127.0.0.1:7896 0.0.0.0:* LISTEN'; }
  curl() {
    printf '%s\n' "$*" >> "$E/curl.log"
    case "$*" in
      *127.0.0.1:9099*) return 7 ;;
      *'-X PUT'*'/proxies/MST'*|*'-X PUT'*'/configs'*) return 0 ;;
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

# --- тот же прогон, но канал медленный: WG проходит порог и попадает в пул напрямую ---
E=$T/e2e_win; mkdir -p "$E/www"
cat > "$E/sources.yaml" <<'YAML'
proxies:
  - name: Blanc_NL_AMS_1
    type: wireguard
    server: wg.example
    port: 51121
YAML
printf 'external-controller: 0.0.0.0:9090\nlisteners:\n  - name: mst-speedtest\n    port: 7896\n' > "$E/config.yaml"
cat "$E/sources.yaml" >> "$E/config.yaml"
printf "proxy-groups:\n  - name: '⚡ Быстрый пул'\n    type: url-test\n    # --- FAST_WG_REF:BEGIN ---\n    # --- FAST_WG_REF:END ---\n" >> "$E/config.yaml"
(
  MST_LIB_ONLY=1 . "$SCRIPT"
  FORCE=0; BLOCK='Russia'; SOURCES=$E/sources.yaml; MAIN_CONFIG=$E/config.yaml
  PREP=$ROOT/speedtest-runtime/prep.awk; NODE_STATS_UPDATE=$ROOT/speedtest-runtime/node_stats_update.awk
  WORK=$E/work; RUN_LOG=$WORK/run.log; LOG=$E/speedtest.log; LOCK=$E/lock
  OUT=$E/fast.yaml; LAST=$E/last.txt; HISTORY_RUNS=$E/runs.tsv; HISTORY_NODES=$E/nodes.tsv
  HISTORY_STABILITY=$E/stability.tsv; STATS_PROGRESS=$E/www/progress.json; STATS_HTTP_ENABLE=0
  STATS_HTML=$E/www/stats.html; STATS_JSON=$E/www/stats.json
  BIN=/usr/bin/true
  FAST_WG_AWK=$ROOT/config-tools/fast_wg.awk; CONFIGEDIT_LOCK=$E/config-lock; MIHOMO_DIR=$E
  netstat() { printf '%s\n' 'tcp 0 0 127.0.0.1:7896 0.0.0.0:* LISTEN'; }
  curl() {
    printf '%s\n' "$*" >> "$E/curl.log"
    case "$*" in
      *127.0.0.1:9099*) return 7 ;;
      *'-X PUT'*'/proxies/MST'*|*'-X PUT'*'/configs'*) return 0 ;;
      *'/proxies/MST'*|*'/proxies/FAST-WG'*) printf '%s' '{"all":["REJECT","Blanc_NL_AMS_1"],"now":"REJECT"}' ;;
      *'/delay?'*) printf '%s' '{"delay":126}' ;;
      *'127.0.0.1:7896'*) printf '%s' '200 1000000' ;;
      *'speed.cloudflare.com'*) printf '%s' '200 2000000' ;;
      *) return 7 ;;
    esac
  }
  main
) > "$E/out.txt" 2>&1 || true
grep -qF "proxies: ['Blanc_NL_AMS_1']" "$E/config.yaml" || fail "WG-победитель не включён напрямую"
grep -q "WG: Прямые ссылки в '⚡ Быстрый пул' обновлены" "$E/speedtest.log" || fail "нет строки о WG-победителе в пуле"
[ ! -e "$E/fast.yaml" ] || fail "WG-победитель записан в fast.yaml"

echo "test_speedtest_wg.sh: OK"
