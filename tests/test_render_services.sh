#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SCRIPT="$ROOT/config-tools/render_services.awk"
FAILED=0
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

fail() { echo "FAIL: $*" >&2; FAILED=1; }
assert_contains() {
  case "$2" in
    *"$1"*) ;;
    *) fail "ожидалось найти: $1 ($3)" ;;
  esac
}
assert_not_contains() {
  case "$2" in
    *"$1"*) fail "не ожидалось: $1 ($3)" ;;
  esac
}

T="$WORK/t.yaml"
cat > "$T" <<'Y'
proxy-groups:
  - name: base
  # --- SERVICE_GROUPS:BEGIN ---
  - name: old
  # --- SERVICE_GROUPS:END ---
rule-providers:
  # --- SERVICE_PROVIDERS:BEGIN ---
  # --- SERVICE_PROVIDERS:END ---
rules:
  # --- SERVICE_RULES:BEGIN ---
  # --- SERVICE_RULES:END ---
  - MATCH,DIRECT
Y

S="$WORK/s.tsv"
printf '%s\n' \
  '# комментарий' \
  '' \
  'section	media	Видео' \
  'section	misc	Прочее' \
  'svc	youtube	YouTube	media' \
  'icon	youtube	https://i/y.png' \
  'svc	ipdetect	IP Detect	misc' \
  'svc	adult	18+	media' \
  'svc	intel	intel	misc' \
  'gkey	intel	include-all: true' \
  'prov	youtube	youtube@domain: { <<: *domain, url: "https://y" }' \
  'prov	-	quic@inline: { <<: *inline }' \
  'rule	-	RULE-SET,quic@inline,REJECT # квик' \
  'rule	youtube	DOMAIN-SUFFIX,youtu.be,YouTube' \
  'rule	youtube	RULE-SET,youtube@domain,YouTube' \
  'rule	ipdetect	DOMAIN-SUFFIX,2ip.io,IP Detect' > "$S"

render() { awk -v services_file="$1" -f "$SCRIPT" "$2"; }

# test_groups_render
OUT=$(render "$S" "$T") || fail "сборка завершилась с ошибкой"
NL='
'
assert_contains "  # --- SERVICE_GROUPS:BEGIN ---${NL}  # --- Видео ---${NL}  - name: YouTube${NL}    <<: *select-default${NL}    icon: https://i/y.png${NL}${NL}" "$OUT" "группа YouTube"
assert_not_contains "- name: old" "$OUT" "старое содержимое заменено"
assert_contains "  # --- SERVICE_GROUPS:END ---" "$OUT" "маркер END сохранён"
assert_contains "  - name: base" "$OUT" "вне маркеров не трогается"

# test_quoting
assert_contains "- name: 'IP Detect'" "$OUT" "имя с пробелом в кавычках"
assert_contains "- name: '18+'" "$OUT" "имя с + в кавычках"
assert_contains "- name: intel${NL}" "$OUT" "простое имя без кавычек"

# test_gkey
assert_contains "  - name: intel${NL}    <<: *select-default${NL}    include-all: true${NL}" "$OUT" "gkey после select-default"

# секции в порядке section: Видео (YouTube, 18+), затем Прочее (IP Detect, intel)
assert_contains "  - name: '18+'${NL}    <<: *select-default${NL}${NL}  # --- Прочее ---${NL}  - name: 'IP Detect'" "$OUT" "порядок секций"

# providers
assert_contains "  # --- SERVICE_PROVIDERS:BEGIN ---${NL}  youtube@domain: { <<: *domain, url: \"https://y\" }${NL}  quic@inline: { <<: *inline }${NL}  # --- SERVICE_PROVIDERS:END ---" "$OUT" "providers"

# test_rules_headers
assert_contains "  # --- SERVICE_RULES:BEGIN ---${NL}  - RULE-SET,quic@inline,REJECT # квик${NL}${NL}  # --- YouTube ---${NL}  - DOMAIN-SUFFIX,youtu.be,YouTube${NL}  - RULE-SET,youtube@domain,YouTube${NL}${NL}  # --- IP Detect ---${NL}  - DOMAIN-SUFFIX,2ip.io,IP Detect${NL}  # --- SERVICE_RULES:END ---${NL}  - MATCH,DIRECT" "$OUT" "rules с заголовками"

# test_idempotent
printf '%s\n' "$OUT" > "$WORK/once.yaml"
render "$S" "$WORK/once.yaml" > "$WORK/twice.yaml" || fail "повторная сборка с ошибкой"
cmp -s "$WORK/once.yaml" "$WORK/twice.yaml" || fail "повторная сборка меняет файл"

# test_errors: код 2, пустой stdout, текст в stderr
expect_error() {
  # $1 - tsv, $2 - шаблон, $3 - подстрока stderr, $4 - описание
  rc=0
  render "$1" "$2" > "$WORK/eout" 2> "$WORK/eerr" || rc=$?
  [ "$rc" = 2 ] || fail "$4: код $rc вместо 2"
  [ ! -s "$WORK/eout" ] || fail "$4: stdout не пуст"
  grep -q -- "$3" "$WORK/eerr" || fail "$4: в stderr нет '$3': $(cat "$WORK/eerr")"
}
grep -v 'SERVICE_RULES' "$T" > "$WORK/t-norules.yaml"
expect_error "$S" "$WORK/t-norules.yaml" SERVICE_RULES "нет маркеров rules"
awk '{print} /SERVICE_GROUPS:BEGIN/{print}' "$T" > "$WORK/t-dup.yaml"
expect_error "$S" "$WORK/t-dup.yaml" SERVICE_GROUPS "повтор маркера"
awk '/SERVICE_RULES:BEGIN/{b=$0;next} {print} /SERVICE_RULES:END/{print b}' "$T" > "$WORK/t-order.yaml"
expect_error "$S" "$WORK/t-order.yaml" SERVICE_RULES "END раньше BEGIN"
{ cat "$S"; printf 'icon\tnope\tx\n'; } > "$WORK/s-ref.tsv"
expect_error "$WORK/s-ref.tsv" "$T" "строка 17" "ссылка на неизвестный сервис: номер строки"
expect_error "$WORK/s-ref.tsv" "$T" "nope" "ссылка на неизвестный сервис: id"
{ cat "$S"; printf 'rule\tyoutube\tA\tB\n'; } > "$WORK/s-tab.tsv"
expect_error "$WORK/s-tab.tsv" "$T" "табуляц" "лишняя табуляция"
{ cat "$S"; printf 'foo\tyoutube\tx\n'; } > "$WORK/s-kind.tsv"
expect_error "$WORK/s-kind.tsv" "$T" "foo" "неизвестный вид строки"
{ cat "$S"; printf 'svc\tyoutube\tYouTube2\tmedia\n'; } > "$WORK/s-dup.tsv"
expect_error "$WORK/s-dup.tsv" "$T" "повторяется" "повтор svc"
{ cat "$S"; printf 'svc\tnew\tNew\tnosection\n'; } > "$WORK/s-sec.tsv"
expect_error "$WORK/s-sec.tsv" "$T" "nosection" "неизвестная секция"
expect_error "$WORK/missing.tsv" "$T" "missing.tsv" "нет файла tsv"

# test_yaml_reserved_names: true/no/null и т.п. - в кавычках
printf '%s\n' 'section	m	M' 'svc	t	true	m' 'svc	n	No	m' 'svc	z	null	m' > "$WORK/s-res.tsv"
OUTR=$(render "$WORK/s-res.tsv" "$T") || fail "сборка с зарезервированными именами"
assert_contains "- name: 'true'" "$OUTR" "true в кавычках"
assert_contains "- name: 'No'" "$OUTR" "No в кавычках"
assert_contains "- name: 'null'" "$OUTR" "null в кавычках"

# test_unowned_rules_header: правила без сервиса после сервиса - под
# нейтральным заголовком, а не под заголовком предыдущего сервиса
printf '%s\n' 'section	m	M' 'svc	a	A	m' 'rule	a	DOMAIN,a.com,A' 'rule	-	DOMAIN,x.com,DIRECT' 'rule	-	DOMAIN,y.com,DIRECT' 'rule	a	DOMAIN,b.com,A' > "$WORK/s-own.tsv"
OUTO=$(render "$WORK/s-own.tsv" "$T") || fail "сборка с правилами без сервиса"
assert_contains "  - DOMAIN,a.com,A${NL}${NL}  # --- Особые правила ---${NL}  - DOMAIN,x.com,DIRECT${NL}  - DOMAIN,y.com,DIRECT${NL}${NL}  # --- A ---${NL}  - DOMAIN,b.com,A" "$OUTO" "нейтральный заголовок для правил без сервиса"

[ "$FAILED" = 0 ] && echo "OK test_render_services"
exit "$FAILED"
