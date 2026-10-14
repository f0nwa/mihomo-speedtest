#!/bin/sh
# Тесты web/stats_diag.sh - вкладка «Диагностика»: запуск по кнопке,
# фоновая проверка сервисов через текущие ноды основного ядра, вердикты,
# состояние в /tmp и итог в $DIR/diag_last.json. Сети и mihomo нет:
# curl подменяется заглушкой через PATH (API ядра на 127.0.0.1:9090,
# сайты - через -x прокси), ответы задаются файлами сценария в $SC.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/stats-diag-test.XXXXXX")
cleanup() {
  p=$(cat "$TEST_ROOT/w/tmp/mst-diag/lock/pid" 2>/dev/null || true)
  [ -z "$p" ] || kill "$p" 2>/dev/null || true
  rm -rf "$TEST_ROOT"
}
trap cleanup EXIT INT TERM
FAILED=0
fail() { echo "FAIL: $*" >&2; FAILED=1; }
assert_eq() { [ "$1" = "$2" ] || fail "$3
  ожидалось: $2
  получено:  $1"; }
assert_contains() { case "$2" in *"$1"*) ;; *) fail "$3: нет «$1» в: $2" ;; esac; }

W=$TEST_ROOT/w
SC=$TEST_ROOT/sc
mkdir -p "$W/bin" "$W/tmp" "$W/mihomo" "$W/config-state" "$SC"
cp "$ROOT/speedtest-runtime/speedtest2.sh" "$W/speedtest2.sh"
cp "$ROOT/installer/netcheck.sh" "$W/netcheck.sh"
cp "$ROOT/web/diag.awk" "$W/diag.awk"
cp "$ROOT/web/stats_diag.sh" "$W/stats_diag.sh" 2>/dev/null || { echo "FAIL: нет web/stats_diag.sh" >&2; exit 1; }
chmod +x "$W/stats_diag.sh"
# DIAG_BUSYBOX=1 - как на роутере: busybox sh и утилиты busybox.
if [ "${DIAG_BUSYBOX:-0}" = 1 ]; then
  BB=$(command -v busybox) || { echo "SKIP test_stats_diag (busybox): нет busybox"; exit 0; }
  sed -i "1s|.*|#!$BB sh|" "$W/stats_diag.sh"
  for u in awk sed grep cut head tr wc sleep date mkdir rm mv cp cat; do
    printf '#!/bin/sh\nexec %s %s "$@"\n' "$BB" "$u" > "$W/bin/$u"; chmod +x "$W/bin/$u"
  done
fi
: > "$W/speedtest2.env"
printf 'redir-port: 5000\ntproxy-port: 5001\nexternal-controller: 0.0.0.0:9090\nsecret: ""\n' > "$W/mihomo/config.yaml"
T=$(printf '\t')
cat > "$W/services.default.tsv" <<TSV
section${T}s${T}Сервисы
svc${T}github${T}GitHub${T}s
check${T}github${T}https://github.com
svc${T}ai${T}A&B${T}s
check${T}ai${T}https://chatgpt.com
check${T}ai${T}https://claude.ai
svc${T}torrents${T}Torrents${T}s
check${T}torrents${T}https://rutracker.org
svc${T}ads${T}Ads${T}s
svc${T}lb${T}LB${T}s
check${T}lb${T}https://lb.example
svc${T}bare${T}Bare${T}s
svc${T}nope${T}Nope${T}s
svc${T}big${T}Big${T}s
check${T}big${T}https://big.example
check${T}nope${T}https://nope.example
TSV
cp "$ROOT/tests/fixtures/diag/proxies.json" "$SC/proxies.json"

# urlencode проекта - ключи файлов сценария для /proxies/<имя>.
enc() { ( MST_LIB_ONLY=1 DIR=$W TMPROOT=$W/tmp; . "$W/speedtest2.sh"; urlencode "$1" ); }
key() { printf '%s' "$1" | tr -c 'A-Za-z0-9' '_'; }
NL='NL "03" / x'
E_FAST=$(enc '⚡ FAST'); E_GH=$(enc GitHub); E_NL=$(enc "$NL"); E_DE=$(enc DE-01)
now_tsv() {
  # группа (urlencode) -> now в JSON-виде
  printf '%s\t%s\n' "$E_GH" '⚡ FAST' "$E_FAST" "${1:-NL \\\"03\\\" / x}" \
    "$(enc 'A&B')" FI-02 "$(enc Torrents)" DIRECT "$(enc Bare)" DE-01 > "$SC/now.tsv"
}

cat > "$W/bin/curl" <<STUB
#!/bin/sh
SC=$SC
STUB
cat >> "$W/bin/curl" <<'STUB'
echo "$*" >> "$SC/curl.log"
out=; fmt=; url=
while [ $# -gt 0 ]; do
  case $1 in
    -o) out=$2; shift ;;
    -w) fmt=$2; shift ;;
    -x|-K|-m|-A|-H|-X|--data-binary|--max-time|--connect-timeout|--max-filesize) shift ;;
    -*) ;;
    *) url=$1 ;;
  esac
  shift
done
emit() { if [ -n "$out" ]; then cat > "$out"; else cat; fi; }
[ -f "$SC/slow" ] && sleep "$(cat "$SC/slow")"
API=http://127.0.0.1:9090
case $url in
  "$API/proxies")
    n=$(cat "$SC/proxies.count" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$SC/proxies.count"
    f=$SC/proxies.json; [ "$n" -gt 1 ] && [ -f "$SC/proxies2.json" ] && f=$SC/proxies2.json
    emit < "$f"; exit 0 ;;
  "$API/proxies/"*"/delay"*)
    k=${url#"$API/proxies/"}; k=${k%%/delay*}
    q=${url#*\?}
    u=$(printf '%s' "$q" | tr '&' '\n' | sed -n 's/^url=//p')
    e=$(printf '%s' "$q" | tr '&' '\n' | sed -n 's/^expected=//p')
    d=fail
    case $u in
      *cp.cloudflare.com*|*msftconnecttest*|*captive.apple.com*) d=$(cat "$SC/delay-$k" 2>/dev/null || echo fail) ;;
      *)
        if [ -f "$SC/alt-$k" ]; then d=$(cat "$SC/alt-$k")
        else
          # как mihomo: ответ сайта с кодом из expected (пусто - любой) - задержка
          sk=$(printf '%s' "$u" | tr -c 'A-Za-z0-9' '_')
          if [ -f "$SC/site-$sk" ]; then read -r rc code < "$SC/site-$sk"; else rc=7; code=000; fi
          if [ "$rc" = 0 ] && awk -v c="$code" -v e="$e" 'BEGIN { if (e == "") exit 0; n = split(e, r, "/")
              for (i = 1; i <= n; i++) { m = split(r[i], ab, "-"); lo = ab[1] + 0; hi = (m > 1 ? ab[2] : ab[1]) + 0
                if (c + 0 >= lo && c + 0 <= hi) exit 0 } exit 1 }'; then d=96; fi
        fi ;;
    esac
    if [ "$d" = fail ]; then printf '{"message":"Timeout"}' | emit; else printf '{"delay":%s}' "$d" | emit; fi
    exit 0 ;;
  "$API/proxies/"*)
    k=${url#"$API/proxies/"}
    now=$(awk -F'\t' -v k="$k" '$1 == k { print $2 }' "$SC/now.tsv")
    printf '{"alive":true,"name":"x","now":"%s","type":"Selector"}' "$now" | emit; exit 0 ;;
esac
echo "unexpected request: $url" >> "$SC/unexpected.log"
exit 7
STUB
chmod +x "$W/bin/curl"

cgi() {
  # $1 - действие, $2 - метод, $3 - QUERY_STRING
  DIAG_ALT_MAX_SEC=${DIAG_ALT_MAX_SEC:-60} DIAG_TOTAL_MAX_SEC=${DIAG_TOTAL_MAX_SEC:-300} DIR=$W TMPROOT=$W/tmp LOCK=$W/tmp/mst.lock MIHOMO_DIR=$W/mihomo PATH="$W/bin:$PATH" \
    CONFIG_STATE_DIR=$W/config-state REQUEST_METHOD=$2 QUERY_STRING=${3:-} MST_DIAG_ACTION=$1 \
    DIAG_STATE_POLL=0 "$W/stats_diag.sh"
}
body() { sed '1,/^\r\{0,1\}$/d'; }
wait_done() {
  i=0
  while [ "$i" -lt 400 ]; do
    grep -q '"running":false' "$W/tmp/mst-diag/state.json" 2>/dev/null && return 0
    sleep 0.1; i=$((i + 1))
  done
  fail "диагностика не завершилась за 15 с: $(cat "$W/tmp/mst-diag/state.json" 2>/dev/null)"
}
reset_sc() { rm -f "$SC/unexpected.log" "$SC"/site-* "$SC"/body-* "$SC"/redir-* "$SC"/delay-* "$SC"/alt-* "$SC/proxies.count" "$SC/proxies2.json" "$SC/slow" "$SC/curl.log"; now_tsv; }
site() { printf '%s %s\n' "$2" "$3" > "$SC/site-$(key "$(enc "$1")")"; }
svc() {
  # svc ИМЯ ПОЛЕ - значение поля сервиса из state.json (через python3)
  python3 - "$W/tmp/mst-diag/state.json" "$1" "$2" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
for s in d["services"]:
    if s["name"] == sys.argv[2]:
        v = s
        for k in sys.argv[3].split("."):
            v = v[k]
        print(v if not isinstance(v, list) else "|".join(v))
        break
else:
    print("<нет сервиса>")
PY
}
run_diag() {
  r=$(cgi start POST | body)
  assert_contains '"started":true' "$r" "start: $1"
  wait_done
  python3 -m json.tool "$W/tmp/mst-diag/state.json" > /dev/null || fail "state.json не JSON ($1): $(cat "$W/tmp/mst-diag/state.json")"
}
command -v python3 > /dev/null || { echo "SKIP test_stats_diag: нет python3"; exit 0; }

# ----- пустое состояние -----
r=$(cgi status GET | body)
assert_contains '"stage":"none"' "$r" "до первой проверки"

# ----- A: 403, запасной адрес, DIRECT, REJECT, load-balance, без адреса, группы нет -----
reset_sc
ls "$W" > "$TEST_ROOT/dir.before"
site https://github.com 0 403; echo 84 > "$SC/delay-$E_NL"
site https://chatgpt.com 0 403; site https://claude.ai 0 200
site https://rutracker.org 0 200
run_diag A
assert_eq "$(svc GitHub verdict)" blocked "403 - сервис не пускает ноду"
assert_contains 403 "$(svc GitHub detail)" "detail с кодом"
assert_eq "$(svc GitHub control_ms)" 84 "контрольный запрос через ноду"
assert_eq "$(svc GitHub node)" "$NL" "текущая нода с кавычками"
assert_eq "$(svc GitHub chain)" "GitHub|⚡ FAST|$NL" "цепочка"
assert_eq "$(svc 'A&B' verdict)" blocked "несколько адресов - разные продукты: худший результат"
assert_eq "$(svc 'A&B' url)" https://chatgpt.com "url - тот, что дал вердикт"
assert_eq "$(svc Torrents verdict)" direct "DIRECT"
assert_eq "$(svc Ads verdict)" rejected "REJECT"
assert_eq "$(svc LB verdict)" lb "load-balance"
assert_eq "$(svc Bare verdict)" no_url "без адреса проверки"
assert_eq "$(svc Nope verdict)" missing "группы нет в ядре"
assert_eq "$(svc GitHub alt.state)" done "поиск замены для заблокированного"
assert_eq "$(svc GitHub alt.found)" "" "у DE-01 нет ответа - замены нет"
assert_eq "$(svc GitHub alt.checked)" 1 "кандидат один (текущая нода исключена)"
assert_eq "$(svc Telegram alt.state 2>/dev/null)" "<нет сервиса>" "служебная проверка svc"
assert_eq "$(svc Torrents alt.state)" none "сервису напрямую замена не ищется"
s=$(cat "$W/tmp/mst-diag/state.json")
assert_contains '"stage":"done"' "$s" "stage done"
grep -q -- '-X PUT' "$SC/curl.log" && fail "диагностика меняла выбор в группах (PUT)"
grep -q 'cp.cloudflare.com' "$SC/curl.log" || fail "контрольный адрес не cp.cloudflare.com"
[ -f "$W/diag_last.json" ] || fail "нет diag_last.json"
cmp -s "$W/diag_last.json" "$W/tmp/mst-diag/state.json" || fail "diag_last.json отличается от итога"
ls "$W" | grep -v '^diag_last.json$' > "$TEST_ROOT/dir.after"
cmp -s "$TEST_ROOT/dir.before" "$TEST_ROOT/dir.after" || fail "в \$DIR появились лишние файлы: $(cat "$TEST_ROOT/dir.after")"
[ ! -d "$W/tmp/mst-diag/lock" ] || fail "блокировка не снята"
r=$(cgi status GET | body)
assert_contains '"running":false' "$r" "status после прогона"

# ----- B: сервис отвечает ошибкой (не 403/451), нода жива -----
reset_sc
site https://github.com 0 503; echo 84 > "$SC/delay-$E_NL"
site https://chatgpt.com 0 302; site https://claude.ai 0 200
run_diag B
assert_eq "$(svc GitHub verdict)" suspect "503 - сервис ответил ошибкой"
assert_eq "$(svc 'A&B' verdict)" ok "редирект - работает"

# ----- I7: HTTP-ответ есть, контроль не прошёл - нода жива -----
reset_sc
site https://github.com 0 503
run_diag B3
assert_eq "$(svc GitHub verdict)" suspect "ответ сервиса пришёл - значит, нода работает"

# ----- контрольный адрес не совпадает с test-url групп -----
reset_sc
cp "$SC/proxies.json" "$TEST_ROOT/p.bak"
sed 's|"testUrl":"https://www.gstatic.com/generate_204"|"testUrl":"https://cp.cloudflare.com/generate_204"|' "$TEST_ROOT/p.bak" > "$SC/proxies.json"
site https://github.com 28 000; echo 84 > "$SC/delay-$E_NL"
run_diag T
grep -q 'cp.cloudflare.com' "$SC/curl.log" && fail "контрольный адрес совпал с test-url группы"
assert_eq "$(svc GitHub verdict)" suspect "контроль через другой адрес"
cp "$TEST_ROOT/p.bak" "$SC/proxies.json"

# ----- C/D: таймаут сервиса, контроль ok / fail -----
reset_sc
site https://github.com 28 000; echo 90 > "$SC/delay-$E_NL"
run_diag C
assert_eq "$(svc GitHub verdict)" suspect "таймаут, нода живая"
reset_sc
site https://github.com 28 000
run_diag D
assert_eq "$(svc GitHub verdict)" node_dead "таймаут и нода не отвечает"

# ----- I1: блокировка без pid (запуск ещё пишет её) - не «прервалась» -----
reset_sc
mkdir -p "$W/tmp/mst-diag/lock"; rm -f "$W/tmp/mst-diag/lock/pid"
printf 'running\t1\nstage\tphase1\n' > "$W/tmp/mst-diag/meta"; : > "$W/tmp/mst-diag/services.tsv"
r=$(cgi status GET | body)
[ -d "$W/tmp/mst-diag/lock" ] || fail "status снял блокировку, в которую запуск ещё не записал pid"
case $r in *'"stage":"error"'*) fail "status объявил ошибку во время запуска" ;; esac
rm -rf "$W/tmp/mst-diag/lock"

# ----- I8: остановка в фазе 1 - непроверенные помечаются, а не «проверяются» -----
reset_sc; echo 0.4 > "$SC/slow"; site https://github.com 0 403; echo 84 > "$SC/delay-$E_NL"
r=$(cgi start POST | body)
i=0; until grep -q '"done":1' "$W/tmp/mst-diag/state.json" 2>/dev/null || [ "$i" -ge 150 ]; do sleep 0.1; i=$((i + 1)); done
cgi cancel POST > /dev/null
wait_done; rm -f "$SC/slow"
s=$(cat "$W/tmp/mst-diag/state.json")
case $s in *'"verdict":"pending"'*) fail "после остановки остались строки «проверяется»" ;; esac
assert_contains '"verdict":"skipped"' "$s" "непроверенные - skipped"
# лимит времени фазы 2 - не начатые поиски помечены
reset_sc; site https://github.com 0 403; echo 84 > "$SC/delay-$E_NL"
DIAG_TOTAL_MAX_SEC=0 run_diag L
assert_eq "$(svc GitHub alt.state)" skipped "поиск не начат из-за лимита времени"

# ----- E: выбор группы сменился во время проверки -----
reset_sc
sed 's/"now":"NL \\"03\\" \/ x"/"now":"DE-01"/' "$SC/proxies.json" > "$SC/proxies2.json"
now_tsv DE-01
site https://github.com 0 200
run_diag E
assert_eq "$(svc GitHub node)" DE-01 "перепроверка через новую ноду"
assert_eq "$(svc GitHub verdict)" ok "вердикт по новой ноде"

# ----- блокировки: идёт прогон замеров / уже идёт диагностика -----
reset_sc
mkdir -p "$W/tmp/mst.lock"; sleep 30 & SP=$!; echo "$SP" > "$W/tmp/mst.lock/pid"
r=$(cgi start POST)
assert_contains 'Status: 409' "$r" "при прогоне замеров - 409"
assert_contains speedtest_running "$r" "код speedtest_running"
kill "$SP" 2>/dev/null; rm -rf "$W/tmp/mst.lock"
echo 0.3 > "$SC/slow"; site https://github.com 0 200
r=$(cgi start POST | body); assert_contains '"started":true' "$r" "первый start"
r=$(cgi start POST)
assert_contains 'Status: 409' "$r" "второй start - 409"
assert_contains diag_running "$r" "код diag_running"
r=$(cgi status GET | body); assert_contains '"running":true' "$r" "status во время прогона"
wait_done

# ----- нет external-controller -----
reset_sc
cp "$W/mihomo/config.yaml" "$TEST_ROOT/cfg"; printf 'mixed-port: 7890\n' > "$W/mihomo/config.yaml"
run_diag F
s=$(cat "$W/tmp/mst-diag/state.json")
assert_contains '"stage":"error"' "$s" "без API - stage error"
assert_contains 'external-controller' "$s" "текст ошибки называет external-controller"
cp "$TEST_ROOT/cfg" "$W/mihomo/config.yaml"

# ----- GET на start - 405 -----
r=$(cgi start GET); assert_contains 'Status: 405' "$r" "start только POST"

# ----- фаза 2: поиск рабочих нод -----
# Группа Big: 20 нод, выбрана N0.
python3 - "$SC/proxies.json" <<'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p))
names = ['N%d' % i for i in range(20)]
for n in names:
    d['proxies'][n] = {'name': n, 'type': 'Vless', 'history': []}
d['proxies']['Big'] = {'name': 'Big', 'type': 'Selector', 'now': 'N0', 'all': names}
json.dump(d, open(p, 'w'), ensure_ascii=False)
PY
alt() { echo "$2" > "$SC/alt-$(enc "$1")"; }
reset_sc; site https://big.example 0 403; echo 50 > "$SC/delay-$(enc N0)"
site https://github.com 0 403; echo 84 > "$SC/delay-$E_NL"; alt DE-01 90
run_diag P1
assert_eq "$(svc GitHub alt.found)" DE-01 "нашлась рабочая нода"
assert_eq "$(svc Big alt.state)" done "Big: поиск закончен"
assert_eq "$(svc Big alt.checked)" 15 "Big: не больше 15 нод"
assert_eq "$(svc Big alt.limit)" 15 "Big: лимит 15"
assert_eq "$(svc Big alt.found)" "" "Big: ни одна не подошла"
grep -q 'expected=200-399' "$SC/curl.log" || fail "поиск замены без expected=200-399"

reset_sc; site https://big.example 0 403; echo 50 > "$SC/delay-$(enc N0)"
for i in 3 5 6 7 9; do alt "N$i" 40; done
# порядок по статистике: N9 стабильнее всех, N5 - мёртвая
printf 'N9\tx\tx\tx\t10\t10\nN5\tx\tx\tx\t10\t0\nN3\tx\tx\tx\t10\t9\n' > "$W/node_stability.tsv"
run_diag P2
assert_eq "$(svc Big alt.found)" "N9|N3|N6" "три первые рабочие по порядку стабильности, мёртвая пропущена"
assert_eq "$(svc Big alt.checked)" 6 "остановка после трёх найденных (порядок N9 N3, затем без статистики N1 N2 N4 N6)"
rm -f "$W/node_stability.tsv"

reset_sc; site https://lb.example 7 000; alt DE-01 50
run_diag P3
assert_eq "$(svc LB verdict)" lb "load-balance"
assert_eq "$(svc LB alt.found)" DE-01 "load-balance: поиск по нодам группы"
assert_eq "$(svc LB alt.checked)" 2 "load-balance: обе ноды проверены"

reset_sc; site https://big.example 0 403; echo 50 > "$SC/delay-$(enc N0)"; echo 0.3 > "$SC/slow"
DIAG_ALT_MAX_SEC=1 run_diag P4
c=$(svc Big alt.checked)
[ "$c" -ge 1 ] && [ "$c" -lt 15 ] || fail "остановка по времени: проверено $c"

# остановка посреди поиска
reset_sc; site https://big.example 0 403; echo 50 > "$SC/delay-$(enc N0)"; echo 0.4 > "$SC/slow"
r=$(cgi start POST | body); assert_contains '"started":true' "$r" "start перед остановкой"
i=0; until grep -q '"state":"searching"' "$W/tmp/mst-diag/state.json" 2>/dev/null || [ "$i" -ge 150 ]; do sleep 0.1; i=$((i + 1)); done
r=$(cgi cancel POST | body); assert_contains '"cancelled":true' "$r" "cancel"
wait_done
assert_contains '"stage":"cancelled"' "$(cat "$W/tmp/mst-diag/state.json")" "stage cancelled"
assert_contains '"state":"stopped"' "$(cat "$W/tmp/mst-diag/state.json")" "поиск, на котором остановили, помечен остановленным"
[ ! -d "$W/tmp/mst-diag/lock" ] || fail "после остановки блокировка не снята"
rm -f "$SC/slow"
r=$(cgi start POST | body); assert_contains '"started":true' "$r" "новый start после остановки"
wait_done
grep -q -- '-X PUT' "$SC/curl.log" && fail "фаза 2 меняла выбор в группах (PUT)"

# ----- опрос состояния не подключает speedtest2.sh/netcheck.sh (лишняя нагрузка раз в 1,5 с) -----
cp "$W/speedtest2.sh" "$TEST_ROOT/st.bak"
{ echo 'touch "$DIR/.sourced"'; cat "$TEST_ROOT/st.bak"; } > "$W/speedtest2.sh"
cgi status GET > /dev/null
[ -f "$W/.sourced" ] && fail "status подключает speedtest2.sh"
rm -f "$W/.sourced"; cp "$TEST_ROOT/st.bak" "$W/speedtest2.sh"

# ----- без mixed-port (шаблон: только redir/tproxy) - всё через API ядра -----
grep -q -- ' -x ' "$SC/curl.log" && fail "запросы через прокси-порт, а его в конфиге нет"
[ ! -f "$SC/unexpected.log" ] || fail "запросы мимо API ядра: $(cat "$SC/unexpected.log")"

# ----- ручная проверка домена через группу other -----
python3 - "$SC/proxies.json" <<'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p))
d['proxies']['other'] = {'name': 'other', 'type': 'Selector', 'now': 'DE-01', 'all': ['DE-01', 'FI-02', 'N1']}
json.dump(d, open(p, 'w'), ensure_ascii=False)
PY
one() {
  i=0
  while [ "$i" -lt 400 ]; do
    grep -q '"running":false' "$W/tmp/mst-diag/one.json" 2>/dev/null && break
    [ -d "$W/tmp/mst-diag/lock" ] || [ "$i" -lt 20 ] || break
    sleep 0.1; i=$((i + 1))
  done
  python3 - "$W/tmp/mst-diag/one.json" "$1" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
if sys.argv[2] == 'stage': print(d['stage']); sys.exit()
if sys.argv[2] == 'error': print(d['error']); sys.exit()
s = d['services'][0]; v = s
for k in sys.argv[2].split('.'): v = v[k]
print(v if not isinstance(v, list) else '|'.join(v))
PY
}
reset_sc
cp "$W/diag_last.json" "$TEST_ROOT/last.bak"; cp "$W/tmp/mst-diag/state.json" "$TEST_ROOT/state.bak"
site https://rutracker.org 0 403; echo 50 > "$SC/delay-$(enc DE-01)"; alt FI-02 40
r=$(cgi check POST 'url=rutracker.org' | body); assert_contains '"started":true' "$r" "check: запуск"
assert_eq "$(one name)" rutracker.org "check: имя - домен"
assert_eq "$(one chain)" "other|DE-01" "check: через группу other"
assert_eq "$(one verdict)" blocked "check: 403"
assert_eq "$(one url)" https://rutracker.org "check: домен -> https://"
assert_eq "$(one alt.found)" FI-02 "check: найдена рабочая нода other"
cmp -s "$W/diag_last.json" "$TEST_ROOT/last.bak" || fail "check затёр последнюю полную диагностику"
cmp -s "$W/tmp/mst-diag/state.json" "$TEST_ROOT/state.bak" || fail "check изменил состояние полной диагностики"
r=$(cgi one GET | body); assert_contains '"name":"rutracker.org"' "$r" "GET /api/diag/one"
reset_sc; site https://rutracker.org/forum/index.php 0 200
cgi check POST 'url=https%3A%2F%2Frutracker.org%2Fforum%2Findex.php' > /dev/null
assert_eq "$(one url)" https://rutracker.org/forum/index.php "check: полный адрес"
assert_eq "$(one verdict)" ok "check: работает"
r=$(cgi check POST 'url=bad%20host'); assert_contains 'Status: 400' "$r" "check: неверный адрес"
r=$(cgi check GET 'url=a.ru'); assert_contains 'Status: 405' "$r" "check: только POST"
# пока идёт проверка домена, полная не запускается
reset_sc; echo 0.3 > "$SC/slow"
cgi check POST 'url=rutracker.org' > /dev/null
r=$(cgi start POST); assert_contains diag_running "$r" "полная во время проверки домена - 409"
one stage > /dev/null; rm -f "$SC/slow"
# группы other нет
cp "$SC/proxies.json" "$TEST_ROOT/p2.bak"
python3 - "$SC/proxies.json" <<'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p)); del d['proxies']['other']; json.dump(d, open(p, 'w'), ensure_ascii=False)
PY
reset_sc; cgi check POST 'url=rutracker.org' > /dev/null
assert_eq "$(one stage)" error "без other - ошибка"
assert_contains 'other' "$(one error)" "текст называет группу other"
cp "$TEST_ROOT/p2.bak" "$SC/proxies.json"
grep -q '"api/diag/check": ("stats_diag.sh"' "$ROOT/web/stats_httpd.py" || fail "нет маршрута api/diag/check"
grep -q '"api/diag/one": ("stats_diag.sh"' "$ROOT/web/stats_httpd.py" || fail "нет маршрута api/diag/one"

# ----- маршруты и списки файлов установки -----
for r in '"api/diag": ("stats_diag.sh"' '"api/diag/start": ("stats_diag.sh"' '"api/diag/cancel": ("stats_diag.sh"'; do
  grep -qF "$r" "$ROOT/web/stats_httpd.py" || fail "нет маршрута $r в stats_httpd.py"
done
for f in stats_diag.sh diag.awk; do
  grep -q "ALL_PROJECT_FILES=.* $f" "$ROOT/install.sh" || fail "$f нет в ALL_PROJECT_FILES"
  grep -q "atomic_install \"\$SELFDIR/$f\"" "$ROOT/install.sh" || fail "$f не ставится install_files()"
  grep -q "web/$f|/opt/etc/mihomo-speedtest/$f" "$ROOT/release/components.txt" || fail "$f нет в release/components.txt"
  grep -q "$f" "$ROOT/uninstall.sh" || fail "$f нет в uninstall.sh"
done

[ "$FAILED" = 0 ] || exit 1
echo "OK test_stats_diag"
