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
printf 'mixed-port: 7890\nexternal-controller: 0.0.0.0:9090\nsecret: ""\n' > "$W/mihomo/config.yaml"
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
    -x|-K|-m|-A|-H|-X|--data-binary|--max-time|--connect-timeout) shift ;;
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
    d=$(cat "$SC/delay-$k" 2>/dev/null || echo fail)
    if [ "$d" = fail ]; then printf '{"message":"Timeout"}' | emit; else printf '{"delay":%s}' "$d" | emit; fi
    exit 0 ;;
  "$API/proxies/"*)
    k=${url#"$API/proxies/"}
    now=$(awk -F'\t' -v k="$k" '$1 == k { print $2 }' "$SC/now.tsv")
    printf '{"alive":true,"name":"x","now":"%s","type":"Selector"}' "$now" | emit; exit 0 ;;
esac
k=$(printf '%s' "$url" | tr -c 'A-Za-z0-9' '_')
if [ -f "$SC/site-$k" ]; then read -r rc code < "$SC/site-$k"; else rc=7; code=000; fi
if [ -f "$SC/body-$k" ]; then emit < "$SC/body-$k"; else : | emit; fi
[ -z "$fmt" ] || printf '%s 0.096' "$code"
exit "$rc"
STUB
chmod +x "$W/bin/curl"

cgi() {
  # $1 - действие, $2 - метод, $3 - QUERY_STRING
  DIR=$W TMPROOT=$W/tmp LOCK=$W/tmp/mst.lock MIHOMO_DIR=$W/mihomo PATH="$W/bin:$PATH" \
    CONFIG_STATE_DIR=$W/config-state REQUEST_METHOD=$2 QUERY_STRING=${3:-} MST_DIAG_ACTION=$1 \
    DIAG_STATE_POLL=0 "$W/stats_diag.sh"
}
body() { sed '1,/^\r\{0,1\}$/d'; }
wait_done() {
  i=0
  while [ "$i" -lt 150 ]; do
    grep -q '"running":false' "$W/tmp/mst-diag/state.json" 2>/dev/null && return 0
    sleep 0.1; i=$((i + 1))
  done
  fail "диагностика не завершилась за 15 с: $(cat "$W/tmp/mst-diag/state.json" 2>/dev/null)"
}
reset_sc() { rm -f "$SC"/site-* "$SC"/body-* "$SC"/delay-* "$SC/proxies.count" "$SC/proxies2.json" "$SC/slow" "$SC/curl.log"; now_tsv; }
site() { printf '%s %s\n' "$2" "$3" > "$SC/site-$(key "$1")"; }
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
site https://chatgpt.com 28 000; site https://claude.ai 0 200
site https://rutracker.org 0 200
run_diag A
assert_eq "$(svc GitHub verdict)" blocked "403 - сервис не пускает ноду"
assert_contains 403 "$(svc GitHub detail)" "detail с кодом"
assert_eq "$(svc GitHub control_ms)" 84 "контрольный запрос через ноду"
assert_eq "$(svc GitHub node)" "$NL" "текущая нода с кавычками"
assert_eq "$(svc GitHub chain)" "GitHub|⚡ FAST|$NL" "цепочка"
assert_eq "$(svc 'A&B' verdict)" ok "основной адрес не ответил, запасной - да"
assert_eq "$(svc 'A&B' url)" https://claude.ai "url - тот, что дал вердикт"
assert_eq "$(svc Torrents verdict)" direct "DIRECT"
assert_eq "$(svc Ads verdict)" rejected "REJECT"
assert_eq "$(svc LB verdict)" lb "load-balance"
assert_eq "$(svc Bare verdict)" no_url "без адреса проверки"
assert_eq "$(svc Nope verdict)" missing "группы нет в ядре"
assert_eq "$(svc GitHub alt.state)" none "фаза 2 пока не запускается"
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

# ----- B: страница блокировки при 200 -----
reset_sc
site https://github.com 0 200; printf '{"error":{"code":"unsupported_country"}}' > "$SC/body-$(key https://github.com)"
echo 84 > "$SC/delay-$E_NL"
run_diag B
assert_eq "$(svc GitHub verdict)" blocked "unsupported_country при 200"

# ----- C/D: таймаут сервиса, контроль ok / fail -----
reset_sc
site https://github.com 28 000; echo 90 > "$SC/delay-$E_NL"
run_diag C
assert_eq "$(svc GitHub verdict)" suspect "таймаут, нода живая"
reset_sc
site https://github.com 28 000
run_diag D
assert_eq "$(svc GitHub verdict)" node_dead "таймаут и нода не отвечает"

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
echo 1 > "$SC/slow"; site https://github.com 0 200
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
