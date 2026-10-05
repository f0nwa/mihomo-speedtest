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

[ "$FAILED" = 0 ] && echo "OK test_constructor_build"
exit "$FAILED"
