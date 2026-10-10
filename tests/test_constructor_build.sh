#!/bin/sh
# constructor_build.sh: шаблон + состояние конструктора + текущий config.yaml.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SCRIPT="$ROOT/config-tools/constructor_build.sh"
FAILED=0
WORK=$(mktemp -d /tmp/test-constructor-build.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

fail() { echo "FAIL: $*" >&2; FAILED=1; }

# Исходный config.yaml: шаблон со своей подпиской и своей группой.
sed 's#subscription-1.example.com/CHANGE_ME#subscription-1.example.com/PRIVATE_TOKEN#' \
  "$ROOT/config-tools/config.example.yaml" |
awk '{print} /# --- SERVICE_GROUPS:END ---/{print "  - name: Mine"; print "    <<: *select-default"; print ""}
     /^  - MATCH,DIRECT$/{}' |
sed 's/^  - MATCH,DIRECT$/  - DOMAIN-SUFFIX,mine.example,Mine\
  - MATCH,DIRECT/' > "$WORK/source.yaml"

# test_build_with_state
mkdir "$WORK/state"
printf '%s\n' 'del	spotify' 'svc	netflix	Netflix	media' 'src	netflix	netflix	domain	https://n/d.mrs' > "$WORK/state/services.tsv"
if sh "$SCRIPT" --state "$WORK/state" --source "$WORK/source.yaml" --output "$WORK/out1.yaml" --report "$WORK/rep1" > "$WORK/log1" 2>&1; then
  grep -q '^  - name: Spotify$' "$WORK/out1.yaml" && fail "del spotify не применился"
  grep -q '^  - name: Netflix$' "$WORK/out1.yaml" || fail "своего сервиса нет"
  grep -q 'RULE-SET,netflix@domain,Netflix' "$WORK/out1.yaml" || fail "правила своего сервиса нет"
  grep -q 'PRIVATE_TOKEN' "$WORK/out1.yaml" || fail "подписка из source не перенесена"
  grep -q 'name: Mine' "$WORK/out1.yaml" && fail "с явным состоянием группа вне его не переносится"
else
  fail "сборка с состоянием: $(cat "$WORK/log1")"
fi

# test_build_import: без состояния своя группа и её домен сохраняются
if sh "$SCRIPT" --import --source "$WORK/source.yaml" --output "$WORK/out2.yaml" --report "$WORK/rep2" > "$WORK/log2" 2>&1; then
  grep -q '^  - name: Mine$' "$WORK/out2.yaml" || fail "--import: своя группа потеряна"
  grep -q 'DOMAIN-SUFFIX,mine.example,Mine' "$WORK/out2.yaml" || fail "--import: свой домен потерян"
  grep -q '^  - name: Spotify$' "$WORK/out2.yaml" || fail "--import: встроенный сервис пропал"
  grep -q 'IMPORTED|svc|mine' "$WORK/rep2" || fail "--import: отчёт импорта не добавлен"
else
  fail "сборка с --import: $(cat "$WORK/log2")"
fi

# test_build_errors
rc=0; sh "$SCRIPT" --source "$WORK/source.yaml" --output "$WORK/o3" --report "$WORK/r3" > /dev/null 2>"$WORK/err" || rc=$?
[ "$rc" = 1 ] || fail "без --state и --import - код $rc вместо 1"
printf 'svc\tn\tN\tnosection\n' > "$WORK/state/services.tsv"
rc=0; sh "$SCRIPT" --state "$WORK/state" --source "$WORK/source.yaml" --output "$WORK/o4" --report "$WORK/r4" > /dev/null 2>"$WORK/err" || rc=$?
[ "$rc" = 1 ] || fail "ошибка в состоянии - код $rc вместо 1"
grep -q 'ERROR:' "$WORK/err" || fail "ошибка в состоянии - нет ERROR: $(cat "$WORK/err")"
[ ! -e "$WORK/o4" ] || fail "при ошибке выход не создаётся"

# test_build_subs_proxies: подписки и свои ноды из состояния заменяют источник
mkdir "$WORK/st2"
: > "$WORK/st2/services.tsv"
printf '%s\t%s\t%s\n' 'https://new.example/TOKEN2' 'clash.meta' 'newsub' 'https://two.example/T3' '' 'two' > "$WORK/st2/subscriptions.tsv"
printf '%s\n' "  - name: 'MyNode'" '    type: hysteria2' '    server: my.example' '    port: 443' > "$WORK/st2/proxies.yaml"
if sh "$SCRIPT" --state "$WORK/st2" --source "$WORK/source.yaml" --output "$WORK/out5.yaml" --report "$WORK/rep5" > "$WORK/log5" 2>&1; then
  grep -q '^  newsub:$' "$WORK/out5.yaml" || fail "подписки: newsub нет"
  grep -q 'TOKEN2' "$WORK/out5.yaml" || fail "подписки: адрес не подставлен"
  grep -q 'PRIVATE_TOKEN' "$WORK/out5.yaml" && fail "подписки: старая подписка осталась"
  grep -q 'sub-names: &sub-names \[newsub, two\]' "$WORK/out5.yaml" || fail "подписки: sub-names не обновлён"
  grep -q "name: 'MyNode'" "$WORK/out5.yaml" || fail "прокси: своя нода не подставлена"
  grep -q "proxies: \\[.*'MyNode'" "$WORK/out5.yaml" || fail "прокси: нода не попала в группы"
  grep -q 'proxy-node-1.example.com' "$WORK/out5.yaml" && fail "прокси: старые ноды остались"
  grep -q 'TOKEN2' "$WORK/rep5" && fail "отчёт содержит адрес подписки"
else
  fail "подписки/прокси: $(cat "$WORK/log5")"
fi
# пустой proxies.yaml - нод нет
: > "$WORK/st2/proxies.yaml"
sh "$SCRIPT" --state "$WORK/st2" --source "$WORK/source.yaml" --output "$WORK/out6.yaml" --report "$WORK/rep6" > "$WORK/log6" 2>&1 || fail "пустые прокси: $(cat "$WORK/log6")"
grep -q '^proxies:' "$WORK/out6.yaml" && ! grep -q 'name: .MyNode' "$WORK/out6.yaml" || fail "пустые прокси: нода осталась"
# ошибки
for bad in 'https://x"y	ua	n1' 'ftp://x	ua	n1' 'https://x	ua	bad name' 'https://x	u"a	n1'; do
  printf '%s\n' "$bad" > "$WORK/st2/subscriptions.tsv"
  rc=0; sh "$SCRIPT" --state "$WORK/st2" --source "$WORK/source.yaml" --output "$WORK/o7" --report "$WORK/r7" > /dev/null 2>"$WORK/err" || rc=$?
  [ "$rc" = 1 ] && grep -q 'ERROR: .*подписк' "$WORK/err" || fail "плохая подписка '$bad': код $rc, $(cat "$WORK/err")"
done
rm -f "$WORK/st2/subscriptions.tsv"
printf '%s\n' 'proxies-garbage' > "$WORK/st2/proxies.yaml"
rc=0; sh "$SCRIPT" --state "$WORK/st2" --source "$WORK/source.yaml" --output "$WORK/o8" --report "$WORK/r8" > /dev/null 2>"$WORK/err" || rc=$?
[ "$rc" = 1 ] && grep -q 'ERROR: .*прокси' "$WORK/err" || fail "плохие прокси: код $rc, $(cat "$WORK/err")"

# test_import_subs_proxies: --import достаёт подписки и ноды из source
mkdir "$WORK/st3"
awk -v defaults="$ROOT/config-tools/services.default.tsv" -v template="$ROOT/config-tools/config.example.yaml" \
  -v out_dir="$WORK/st3" -v report="$WORK/rep9" -f "$ROOT/config-tools/config_to_state.awk" "$WORK/source.yaml"
[ "$(grep -c . "$WORK/st3/subscriptions.tsv")" = 3 ] || fail "импорт: подписок не три"
awk -F'\t' 'NR==1 && $3=="provider-a" && $2=="v2rayNG/1.8.0" && $1 ~ /PRIVATE_TOKEN/ {ok=1} END{exit !ok}' "$WORK/st3/subscriptions.tsv" || fail "импорт: первая подписка"
awk -F'\t' 'NR==2 && $2=="" {ok=1} END{exit !ok}' "$WORK/st3/subscriptions.tsv" || fail "импорт: подписка без UA"
grep -q "^  - name: '🇩🇪 Hysteria2'$" "$WORK/st3/proxies.yaml" || fail "импорт: ноды"
grep -q '^    port: 443$' "$WORK/st3/proxies.yaml" || fail "импорт: поля ноды"
grep -q '^#' "$WORK/st3/proxies.yaml" && fail "импорт: комментарии в нодах"
# круг: импортированное состояние собирает тот же config
sh "$SCRIPT" --state "$WORK/st3" --source "$WORK/source.yaml" --output "$WORK/out10.yaml" --report "$WORK/rep10" > "$WORK/log10" 2>&1 || fail "круг: $(cat "$WORK/log10")"
sh "$SCRIPT" --import --source "$WORK/source.yaml" --output "$WORK/out11.yaml" --report "$WORK/rep11" > "$WORK/log11" 2>&1 || fail "круг import: $(cat "$WORK/log11")"
cmp -s "$WORK/out10.yaml" "$WORK/out11.yaml" || fail "круг: состояние и --import дали разные конфиги"

# test_build_bare_source: голый конфиг (пустой файл, заглушка XKeen без
# proxy-providers, только свои ноды) - нет подписок, которые можно потерять,
# поэтому сборка из состояния идёт на шаблоне (раньше: «в конфиге нет секции
# proxy-providers»).
mkdir "$WORK/bare"
printf '  - name: Blanc_DE_FRA_1\n    type: ss\n    server: 1.2.3.4\n    port: 1\n    cipher: aes-128-gcm\n    password: p\n' > "$WORK/bare/proxies.yaml"
: > "$WORK/bare-empty.yaml"
printf 'log-level: info\nmixed-port: 7890\n' > "$WORK/bare-stub.yaml"
printf 'proxies:\n  - name: Own1\n    type: ss\n    server: 5.6.7.8\n    port: 2\n    cipher: aes-128-gcm\n    password: q\n' > "$WORK/bare-static.yaml"
for b in bare-empty bare-stub bare-static; do
  if sh "$SCRIPT" --state "$WORK/bare" --source "$WORK/$b.yaml" --output "$WORK/out-$b.yaml" --report "$WORK/rep-$b" > "$WORK/log-$b" 2>&1; then
    grep -q 'name: Blanc_DE_FRA_1' "$WORK/out-$b.yaml" || fail "$b: нода из состояния потеряна"
    grep -q '^  - name: Spotify$' "$WORK/out-$b.yaml" || fail "$b: нет сервисов шаблона"
    grep -q 'sub-names: &sub-names \[\]' "$WORK/out-$b.yaml" || fail "$b: подписок быть не должно"
  else
    fail "$b: $(cat "$WORK/log-$b")"
  fi
done
grep -q 'name: Own1' "$WORK/out-bare-static.yaml" 2>/dev/null && fail "bare-static: с состоянием нод берётся состояние, а не источник"
# с --import свои ноды голого конфига сохраняются
sh "$SCRIPT" --import --source "$WORK/bare-static.yaml" --output "$WORK/out-bare-imp.yaml" --report "$WORK/rep-bare-imp" > "$WORK/log-bare-imp" 2>&1 || fail "bare --import: $(cat "$WORK/log-bare-imp")"
grep -q 'name: Own1' "$WORK/out-bare-imp.yaml" || fail "bare --import: своя нода потеряна"
# а конфиг, который ждёт подписок (группы с use:), но секции не имеет, - по-прежнему отказ
sed 's/^proxy-providers:/old-providers:/' "$WORK/source.yaml" > "$WORK/noprov.yaml"
rc=0; sh "$SCRIPT" --import --source "$WORK/noprov.yaml" --output "$WORK/out-noprov.yaml" --report "$WORK/rep-noprov" > "$WORK/log-noprov" 2>&1 || rc=$?
[ "$rc" = 1 ] || fail "переименованные providers при группах с use: должны отклоняться, код $rc"
grep -q 'нет секции proxy-providers' "$WORK/log-noprov" || fail "нет понятной причины отказа: $(cat "$WORK/log-noprov")"
[ ! -e "$WORK/out-noprov.yaml" ] || fail "при отказе кандидат создан"

# test_build_own_scope: ownscope all - свои ноды ещё и во всех сервисных группах
# (в якоре select-default), без него - только в базовых группах
mkdir "$WORK/os"
printf '  - name: Own1\n    type: ss\n    server: 5.6.7.8\n    port: 2\n    cipher: aes-128-gcm\n    password: q\n' > "$WORK/os/proxies.yaml"
printf 'https://sub.example/T\t\tprov1\n' > "$WORK/os/subscriptions.tsv"
anchor_line() { sed -n 's/^  select-default: &select-default \(.*\)$/\1/p' "$1"; }
: > "$WORK/os/services.tsv"
sh "$SCRIPT" --state "$WORK/os" --source "$WORK/source.yaml" --output "$WORK/out-os0.yaml" --report "$WORK/rep-os0" > "$WORK/log-os0" 2>&1 || fail "ownscope выключен: $(cat "$WORK/log-os0")"
anchor_line "$WORK/out-os0.yaml" | grep -q 'Own1' && fail "без ownscope своя нода не должна быть в якоре сервисных групп"
grep -q "name: '🚀 Авто по пингу'" "$WORK/out-os0.yaml" && sed -n "/name: '🚀 Авто по пингу'/,/^$/p" "$WORK/out-os0.yaml" | grep -q 'proxies: \[Own1\]' || fail "своя нода должна быть в базовых группах"
printf 'ownscope\tall\n' > "$WORK/os/services.tsv"
sh "$SCRIPT" --state "$WORK/os" --source "$WORK/source.yaml" --output "$WORK/out-os1.yaml" --report "$WORK/rep-os1" > "$WORK/log-os1" 2>&1 || fail "ownscope all: $(cat "$WORK/log-os1")"
anchor_line "$WORK/out-os1.yaml" | grep -q "Own1" || fail "ownscope all: своя нода не попала в якорь сервисных групп: $(anchor_line "$WORK/out-os1.yaml")"
grep -q '__OWN_NODES__' "$WORK/out-os1.yaml" && fail "служебный токен остался в конфиге"
# круг: собранный конфиг при импорте снова даёт ownscope all
mkdir "$WORK/os-rt"
awk -v defaults="$ROOT/config-tools/services.default.tsv" -v template="$ROOT/config-tools/config.example.yaml" \
    -v out_dir="$WORK/os-rt" -v report="$WORK/os-rt.report" -f "$ROOT/config-tools/config_to_state.awk" "$WORK/out-os1.yaml" 2>/dev/null || fail "импорт собранного конфига"
grep -qx 'ownscope	all' "$WORK/os-rt/services.tsv" || fail "круг: ownscope all потерян при импорте собранного конфига"
# нод нет (пустой proxies.yaml) - токен просто убирается, якорь как в шаблоне
: > "$WORK/os/proxies.yaml"
sh "$SCRIPT" --state "$WORK/os" --source "$WORK/source.yaml" --output "$WORK/out-os2.yaml" --report "$WORK/rep-os2" > "$WORK/log-os2" 2>&1 || fail "ownscope all без нод: $(cat "$WORK/log-os2")"
grep -q '__OWN_NODES__' "$WORK/out-os2.yaml" && fail "без нод служебный токен остался в конфиге"
[ "$(anchor_line "$WORK/out-os2.yaml")" = "$(anchor_line "$WORK/out-os0.yaml")" ] || fail "без нод якорь должен быть как без ownscope"

[ "$FAILED" = 0 ] && echo "OK test_constructor_build"
exit "$FAILED"
