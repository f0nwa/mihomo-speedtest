#!/bin/sh
# release/build_rule_catalog.sh: каталог наборов правил для поиска в
# конструкторе конфига - из фикстур вместо GitHub API.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
SCRIPT=$ROOT/release/build_rule_catalog.sh
FIX=$ROOT/tests/fixtures/rule-catalog
fail() { echo "FAIL: $*" >&2; exit 1; }
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT

CATALOG_FIXTURES=$FIX sh "$SCRIPT" > "$WORK/cat.tsv" 2>"$WORK/err" || fail "сборка: $(cat "$WORK/err")"
T=$(printf '\t')
line() { grep "^$1$T$2$T" "$WORK/cat.tsv" || true; }

# формат: 5 полей, без пустых
awk -F'\t' '!/^#/ && (NF != 5 || $1 == "" || $4 == "") {print NR": "$0; bad=1} END {exit bad}' "$WORK/cat.tsv" || fail "строки не из 5 полей"
# MetaCubeX geosite: domain, адрес ветки meta
[ "$(line netflix domain)" = "netflix${T}domain${T}metacubex${T}https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/meta/geo/geosite/netflix.mrs${T}Netflix" ] || fail "netflix: $(line netflix domain)"
# варианты с @ и не-.mrs не берутся
grep -q '^steam@cn' "$WORK/cat.tsv" && fail "steam@cn попал в каталог"
[ "$(grep -c "^youtube${T}domain${T}" "$WORK/cat.tsv")" = 1 ] || fail "youtube domain должен быть один"
# zxc-rv ipcidr - приоритет над прочими ipcidr с тем же именем
[ "$(line telegram ipcidr)" = "telegram${T}ipcidr${T}zxc-rv${T}https://github.com/zxc-rv/zkeenip-rulesets/releases/latest/download/telegram@ipcidr.mrs${T}Telegram" ] || fail "telegram ipcidr: $(line telegram ipcidr)"
# adlist - как во встроенных
[ -n "$(line adlist domain)" ] || fail "нет adlist"
# itdog - с префиксом, подчёркивания -> дефисы
[ "$(line itdog-russia-inside domain)" = "itdog-russia-inside${T}domain${T}itdog${T}https://github.com/itdoginfo/allow-domains/releases/latest/download/russia_inside_domain.mrs${T}Заблокированное в РФ (itdog, Russia inside)" ] || fail "itdog russia_inside: $(line itdog-russia-inside domain)"
[ -n "$(line itdog-google-meet ipcidr)" ] || fail "itdog google_meet ipcidr"
grep -qE 'youtube\.srs|geosite\.dat' "$WORK/cat.tsv" && fail "не-mrs ассеты в каталоге"
# legiz - из таблицы скрипта
[ -n "$(line legiz-re-filter domain)" ] || fail "legiz re-filter"
[ -n "$(line legiz-rknasnblock ipcidr)" ] || fail "legiz rknasnblock"
# имя без заголовка - заголовок = имя
[ "$(line itdog-hodca domain | cut -f5)" = "itdog-hodca" ] || fail "заголовок по умолчанию"
# имена уникальны в пределах вида; все проходят проверку render_services.awk
[ -z "$(awk -F'\t' '!/^#/ {k=$1"@"$2; if (k in s) print k; s[k]=1}' "$WORK/cat.tsv")" ] || fail "повтор имени"
awk -F'\t' '!/^#/ && ($1 !~ /^[A-Za-z0-9][A-Za-z0-9._!-]*$/ || $4 !~ /^https?:\/\/[^ "'"'"'#]+$/) {print; bad=1} END {exit bad}' "$WORK/cat.tsv" || fail "имя или адрес не пройдут render_services.awk"
# встроенный в репозиторий каталог собран из этих же фикстур или полнее
[ -s "$ROOT/config-tools/rule-catalog.tsv" ] || fail "нет config-tools/rule-catalog.tsv"
for n in netflix itdog-russia-inside legiz-re-filter; do grep -q "^$n$T" "$ROOT/config-tools/rule-catalog.tsv" || fail "в rule-catalog.tsv нет $n"; done
# запись в файл: при ошибке прежний файл не трогается
printf 'old\n' > "$WORK/out.tsv"
CATALOG_FIXTURES=$FIX sh "$SCRIPT" "$WORK/out.tsv" 2>/dev/null || fail "запись в файл"
grep -q '^netflix' "$WORK/out.tsv" || fail "файл не записан"
printf 'old\n' > "$WORK/out.tsv"
mkdir "$WORK/trunc"; cp "$FIX"/*.json "$WORK/trunc/"
sed 's/"sha": "fixture"/"sha": "fixture", "truncated": true/' "$FIX/metacubex-tree.json" > "$WORK/trunc/metacubex-tree.json"
rc=0; CATALOG_FIXTURES=$WORK/trunc sh "$SCRIPT" "$WORK/out.tsv" 2>/dev/null || rc=$?
[ "$rc" != 0 ] || fail "усечённое дерево MetaCubeX должно давать ошибку"
[ "$(cat "$WORK/out.tsv")" = old ] || fail "при ошибке файл каталога испорчен"
# адреса совпадающих со встроенными наборов - те же, что в шаблоне
awk -F'\t' 'FNR==NR && $1=="prov" {split($3,a,":"); m=$3; sub(/.*url: "/,"",m); sub(/".*/,"",m); u[a[1]]=m; next}
  FNR!=NR && !/^#/ && (($1"@"$2) in u) && u[$1"@"$2] != $4 {print $1"@"$2; bad=1} END {exit bad}' \
  "$ROOT/config-tools/services.default.tsv" "$WORK/cat.tsv" || fail "адрес набора расходится со встроенным"

# без сети и без фикстур - ошибка, а не пустой каталог
rc=0; CATALOG_FIXTURES=$WORK/nope sh "$SCRIPT" > /dev/null 2>&1 || rc=$?
[ "$rc" != 0 ] || fail "без данных должен быть ненулевой код"
echo "OK test_build_rule_catalog"
