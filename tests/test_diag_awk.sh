#!/bin/sh
# Тесты web/diag.awk - логика вкладки «Диагностика» без сети: разбор ответа
# GET /proxies ядра и цепочек групп (mode=resolve), адреса проверки
# сервисов (mode=targets), сборка JSON состояния (mode=render).
# AWK можно подменить: AWK="busybox awk" sh tests/test_diag_awk.sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SCRIPT=$ROOT/web/diag.awk
FIX=$ROOT/tests/fixtures/diag
AWK=${AWK:-awk}
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
FAILED=0
fail() { echo "FAIL: $*" >&2; FAILED=1; }
assert_eq() { [ "$1" = "$2" ] || fail "$3
  ожидалось: $2
  получено:  $1"; }
T=$(printf '\t'); U=$(printf '\037')

[ -f "$SCRIPT" ] || { echo "FAIL: нет $SCRIPT" >&2; exit 1; }

# ----- resolve -----
printf '%s\n' GitHub Torrents Ads LB 'Via LB' Loop1 Nope 'A&B' > "$WORK/groups"
LC_ALL=C $AWK -v mode=resolve -v groups_file="$WORK/groups" -f "$SCRIPT" "$FIX/proxies.json" > "$WORK/res" || fail "resolve завершился с ошибкой"
line() { awk -F"$T" -v n="$1" '$1 == n' "$WORK/res"; }
assert_eq "$(line GitHub)" "GitHub${T}GitHub${U}⚡ FAST${U}NL \"03\" / x${T}NL \"03\" / x${T}node${T}NL \"03\" / x${U}DE-01" "GitHub: цепочка через вложенную группу, кандидаты без DIRECT и без повторов"
assert_eq "$(line Torrents | cut -f3,4)" "DIRECT${T}direct" "Torrents кончается на DIRECT"
assert_eq "$(line Torrents | cut -f5)" "NL \"03\" / x${U}DE-01" "Torrents: кандидаты из вложенной группы"
assert_eq "$(line Ads | cut -f4)" "reject" "Ads кончается на REJECT"
assert_eq "$(line LB | cut -f4,5)" "lb${T}DE-01${U}FI-02" "LoadBalance - lb с кандидатами"
assert_eq "$(line 'Via LB' | cut -f2,4)" "Via LB${U}LB${T}lb" "load-balance внутри цепочки"
assert_eq "$(line Loop1 | cut -f4)" "loop" "кольцо групп"
assert_eq "$(line Nope | cut -f2,3,4,5)" "Nope${T}${T}missing${T}" "группы нет в ядре"
assert_eq "$(line 'A&B' | cut -f3,4)" "FI-02${T}node" "\\u0026 в имени группы раскрыт"
assert_eq "$(wc -l < "$WORK/res" | tr -d ' ')" "8" "по строке на каждую запрошенную группу"
assert_eq "$(cut -f1 "$WORK/res" | tr '\n' '|')" "GitHub|Torrents|Ads|LB|Via LB|Loop1|Nope|A&B|" "порядок как в groups_file"

# ----- targets -----
cat > "$WORK/defs.tsv" <<'TSV'
# комментарий
section	media	Видео
svc	youtube	YouTube	media
icon	youtube	https://icon
check	youtube	https://www.youtube.com
check	youtube	https://m.youtube.com
svc	torrents	Torrents	media
rule	torrents	RULE-SET,torrents@domain,Torrents
rule	torrents	DOMAIN-SUFFIX,rutracker.org,Torrents
rule	torrents	DOMAIN,nnmclub.to,Torrents
svc	gone	Gone	media
check	gone	https://gone.example
svc	ipon	IP Only	media
rule	ipon	IP-ASN,714,IP Only
rule	-	MATCH,Final
TSV
printf 'del	gone
svc	my	My Svc	media
dom	my	keyword	foo
dom	my	suffix	example.org
svc	bare	Bare	media
check	torrents	https://rutracker.org/forum/
svc	youtube	YT	media
' > "$WORK/ov.tsv"
LC_ALL=C $AWK -v mode=targets -v overlay_file="$WORK/ov.tsv" -f "$SCRIPT" "$WORK/defs.tsv" > "$WORK/tg" || fail "targets завершился с ошибкой"
assert_eq "$(cat "$WORK/tg")" "YT${T}https://www.youtube.com https://m.youtube.com
Torrents${T}https://rutracker.org/forum/
IP Only${T}-
My Svc${T}https://example.org
Bare${T}-" "targets: порядок, имена из overlay, check overlay перекрывает, del убирает, домены из rule/dom"
LC_ALL=C $AWK -v mode=targets -v overlay_file= -f "$SCRIPT" "$WORK/defs.tsv" > "$WORK/tg2" || fail "targets без overlay"
assert_eq "$(sed -n 2p "$WORK/tg2")" "Torrents${T}https://rutracker.org" "targets: первый DOMAIN-SUFFIX из правил"
assert_eq "$(sed -n 3p "$WORK/tg2")" "Gone${T}https://gone.example" "targets: без overlay сервис на месте"

# ----- now (выбор одной группы из GET /proxies/<имя>) -----
printf '{"alive":true,"all":["a"],"name":"G","now":"NL \\"03\\" \\u0026 x","type":"Selector"}' > "$WORK/one.json"
assert_eq "$(LC_ALL=C $AWK -v mode=now -f "$SCRIPT" "$WORK/one.json")" 'NL "03" & x' "now: выбор группы с экранированием"

# ----- render -----
printf 'GitHub\tGitHub\037NL "03" \\ x\tNL "03" \\ x\tblocked\thttps://github.com\tHTTP 403\t84\t80\tdone\t15\t15\tDE-01\037FI-02\n' > "$WORK/svc.tsv"
printf 'Bare\tBare\t\tno_url\t\tНет адреса\t\t\tnone\t0\t0\t\n' >> "$WORK/svc.tsv"
printf 'id\t1-2\nrunning\t0\nstage\tdone\nerror\t\nstarted\t100\nfinished\t160\ncurrent\tИщу "x"\ntotal\t2\ndone\t2\n' > "$WORK/meta"
LC_ALL=C $AWK -v mode=render -v meta="$WORK/meta" -f "$SCRIPT" "$WORK/svc.tsv" > "$WORK/state.json" || fail "render завершился с ошибкой"
if command -v python3 >/dev/null 2>&1; then
  assert_eq "$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); s=d["services"]; print(d["running"], d["stage"], d["started"], d["current"], d["total"], "|".join(s[0]["chain"]), s[0]["node"], s[0]["ms"], s[0]["control_ms"], s[0]["alt"], s[1]["ms"], s[1]["alt"])' "$WORK/state.json")" \
    "False done 100 Ищу \"x\" 2 GitHub|NL \"03\" \\ x NL \"03\" \\ x 84 80 {'state': 'done', 'checked': 15, 'limit': 15, 'found': ['DE-01', 'FI-02']} None {'state': 'none', 'checked': 0, 'limit': 0, 'found': []}" "render: JSON состояния"
fi

# ----- order (порядок кандидатов для поиска замены) -----
# node_stability.tsv: name first last last_in_pool runs_seen runs_alive ...
printf '%s\n' 'A' 'B "q"' 'C' 'Cur' 'Dead' 'Low' 'New' 'Top' 'Few' > "$WORK/cands"
{
  printf 'A\tx\tx\tx\t10\t9\n'
  printf 'B "q"\tx\tx\tx\t10\t10\n'
  printf 'C\tx\tx\tx\t10\t9\n'
  printf 'Cur\tx\tx\tx\t10\t10\n'
  printf 'Dead\tx\tx\tx\t10\t0\n'
  printf 'Low\tx\tx\tx\t10\t5\n'
  printf 'Top\tx\tx\tx\t20\t20\n'
  printf 'Few\tx\tx\tx\t3\t0\n'
} > "$WORK/stab"
LC_ALL=C $AWK -v mode=order -v exclude=Cur -v min_uptime=80 -v min_runs=8 -v stab_file="$WORK/stab" -f "$SCRIPT" "$WORK/cands" > "$WORK/ord" || fail "order завершился с ошибкой"
assert_eq "$(tr '\n' '|' < "$WORK/ord")" 'B "q"|Top|A|C|New|Few|Low|' "order: стабильные по убыванию uptime, без статистики, слабые; мёртвая и текущая исключены"
LC_ALL=C $AWK -v mode=order -v exclude= -v min_uptime=80 -v min_runs=8 -v stab_file=/nonexistent -f "$SCRIPT" "$WORK/cands" > "$WORK/ord2" || fail "order без файла статистики"
assert_eq "$(tr '\n' '|' < "$WORK/ord2")" 'A|B "q"|C|Cur|Dead|Low|New|Top|Few|' "order: без статистики - исходный порядок"

printf '%s\n' 'A\B' 'C' > "$WORK/cands3"
assert_eq "$(DIAG_EXCLUDE='A\B' LC_ALL=C $AWK -v mode=order -v min_uptime=80 -v min_runs=8 -v stab_file= -f "$SCRIPT" "$WORK/cands3" | tr '\n' '|')" 'C|' "order: текущая нода с \\ в имени исключается (DIAG_EXCLUDE)"

# Нода из подписки: группа её выбрала и держит в all, но отдельной записи в
# /proxies нет (найдено на роутере: Twitter -> Fallback-Stable -> нода).
printf '%s' '{"proxies":{"Tw":{"all":["FB"],"name":"Tw","now":"FB","type":"Selector"},"FB":{"all":[" Prov-1(ss)","DE-01"],"name":"FB","now":" Prov-1(ss)","type":"Fallback"},"DE-01":{"name":"DE-01","type":"Vless"}}}' > "$WORK/prov.json"
printf 'Tw\nAbsent\n' > "$WORK/provg"
LC_ALL=C $AWK -v mode=resolve -v groups_file="$WORK/provg" -f "$SCRIPT" "$WORK/prov.json" > "$WORK/provres"
assert_eq "$(sed -n 1p "$WORK/provres" | cut -f3,4,5)" " Prov-1(ss)${T}node${T} Prov-1(ss)${U}DE-01" "нода без своей записи в /proxies - всё равно нода и кандидат"
assert_eq "$(sed -n 2p "$WORK/provres" | cut -f4)" missing "группы без записи - по-прежнему missing"

[ "$FAILED" = 0 ] || exit 1
echo "OK test_diag_awk"
