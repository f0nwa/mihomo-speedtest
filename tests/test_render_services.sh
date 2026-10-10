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

# ===== Отличия (overlay), фильтр и свои правила =====
D="$WORK/d.tsv"
printf '%s\n' \
  'section	media	Видео' \
  'section	other	Прочее' \
  'svc	youtube	YouTube	media' \
  'svc	spotify	Spotify	media' \
  'svc	kinopub	KinoPub	media' \
  'prov	youtube	youtube@domain: { <<: *domain, url: "https://y" }' \
  'prov	spotify	spotify@domain: { <<: *domain, url: "https://s" }' \
  'rule	kinopub	DOMAIN-SUFFIX,pkr.ovh,KinoPub' \
  'rule	kinopub	GEOSITE,kinopub,KinoPub' \
  'rule	-	RULE-SET,category-ru@domain,DIRECT' \
  'rule	youtube	RULE-SET,youtube@domain,YouTube' \
  'rule	spotify	RULE-SET,spotify@domain,Spotify' > "$D"
ov() { printf '%s\n' "$@" > "$WORK/o.tsv"; }
renderov() { awk -v services_file="$D" -v overlay_file="$WORK/o.tsv" "$@" -f "$SCRIPT" "$T"; }

# test_overlay_del
ov 'del	spotify'
OV=$(renderov) || fail "del: ошибка сборки"
assert_not_contains "Spotify" "$OV" "del убирает группу и правило"
assert_not_contains "spotify@domain" "$OV" "del убирает provider"
assert_contains "- name: YouTube" "$OV" "остальные на месте"

# test_overlay_unrule
ov 'unrule	kinopub	DOMAIN-SUFFIX,pkr.ovh,KinoPub'
OV=$(renderov) || fail "unrule: ошибка сборки"
assert_not_contains "pkr.ovh" "$OV" "unrule убирает правило"
assert_contains "GEOSITE,kinopub,KinoPub" "$OV" "второе правило осталось"

# test_overlay_stale_ignored: del/unrule того, чего уже нет в шаблоне
ov 'del	gone' 'unrule	kinopub	DOMAIN-SUFFIX,gone.example,KinoPub'
renderov > /dev/null 2>"$WORK/err" || fail "устаревшие del/unrule должны пропускаться: $(cat "$WORK/err")"

# test_overlay_user_service
ov 'svc	netflix	Netflix	media' 'icon	netflix	https://i/n.png' \
   'src	netflix	netflix	domain	https://n/d.mrs' 'src	netflix	netflix	ipcidr	https://n/i.mrs'
OV=$(renderov) || fail "свой сервис: ошибка сборки"
assert_contains "  - name: KinoPub${NL}    <<: *select-default${NL}${NL}  - name: Netflix${NL}    <<: *select-default${NL}    icon: https://i/n.png${NL}" "$OV" "своя группа после встроенных своего раздела"
assert_contains '  netflix@domain: { <<: *domain, url: "https://n/d.mrs" }' "$OV" "provider domain"
assert_contains '  netflix@ipcidr: { <<: *ipcidr, url: "https://n/i.mrs" }' "$OV" "provider ipcidr"
assert_contains "  # --- Netflix ---${NL}  - RULE-SET,netflix@domain,Netflix${NL}  - RULE-SET,netflix@ipcidr,Netflix,no-resolve${NL}" "$OV" "правила своего сервиса"

# test_overlay_src_dedup: src на встроенный provider и одинаковый src у двух сервисов
ov 'svc	a	A	other' 'svc	b	B	other' 'src	a	youtube	domain	https://y' 'src	a	x	domain	https://x' 'src	b	x	domain	https://x'
OV=$(renderov) || fail "dedup: ошибка сборки"
[ "$(printf '%s\n' "$OV" | grep -c '^  youtube@domain:')" = 1 ] || fail "встроенный provider продублирован"
[ "$(printf '%s\n' "$OV" | grep -c '^  x@domain:')" = 1 ] || fail "общий provider продублирован"
assert_contains "  - RULE-SET,x@domain,B" "$OV" "правило второго сервиса"

# test_overlay_dom
ov 'dom	kinopub	suffix	kino.pub' 'dom	youtube	full	www.youtube.com' 'dom	youtube	keyword	ytimg'
OV=$(renderov) || fail "dom: ошибка сборки"
assert_contains "  # --- SERVICE_RULES:BEGIN ---${NL}${NL}  # --- Свои домены ---${NL}  - DOMAIN-SUFFIX,kino.pub,KinoPub${NL}  - DOMAIN,www.youtube.com,YouTube${NL}  - DOMAIN-KEYWORD,ytimg,YouTube${NL}${NL}  # --- KinoPub ---" "$OV" "свои домены первыми"
ov 'dom	kinopub	suffix	bad domain,x'
rc=0; renderov > "$WORK/eout" 2>"$WORK/eerr" || rc=$?
[ "$rc" = 2 ] && [ ! -s "$WORK/eout" ] || fail "плохой домен должен давать ошибку"
ov 'dom	kinopub	regex	x.com'
rc=0; renderov > /dev/null 2>&1 || rc=$?; [ "$rc" = 2 ] || fail "неизвестный тип домена"

# test_overlay_errors
# (svc с id встроенного заменяет его, ссылки на убранный сервис пропускаются -
#  см. «Ревью порции 2» ниже)
for bad in 'svc	n	N	nosection' 'svc	n	N	other|svc	n	M	other' 'svc	a	A	other|svc	b	A	other' 'icon	youtube	https://i/y.png'; do
  printf '%s\n' "$bad" | tr '|' '\n' > "$WORK/o.tsv"
  rc=0; renderov > "$WORK/eout" 2>"$WORK/eerr" || rc=$?
  [ "$rc" = 2 ] && [ ! -s "$WORK/eout" ] || fail "overlay '$bad' должен давать ошибку (код $rc)"
done

# test_geofilter
G="$WORK/tg.yaml"
{ cat "$T"; printf "anchors:\n  p: &p { type: http, exclude-filter: &geofilter '(?i)RU|old' }\n"; } > "$G"
printf '%s\n' 'Россия' '🇷🇺' 'whitelist' > "$WORK/g.txt"
OG=$(awk -v services_file="$D" -v geofilter_file="$WORK/g.txt" -f "$SCRIPT" "$G") || fail "geofilter: ошибка сборки"
assert_contains "exclude-filter: &geofilter '(?i)Россия|🇷🇺|whitelist' }" "$OG" "фильтр подставлен"
for badg in "it's" 'a|b' ''; do
  printf '%s\n' "$badg" > "$WORK/g.txt"
  [ -n "$badg" ] || : > "$WORK/g.txt"
  rc=0; awk -v services_file="$D" -v geofilter_file="$WORK/g.txt" -f "$SCRIPT" "$G" > "$WORK/eout" 2>/dev/null || rc=$?
  [ "$rc" = 2 ] && [ ! -s "$WORK/eout" ] || fail "фильтр '$badg' должен давать ошибку"
done

# test_user_rules_order
ov 'dom	kinopub	suffix	kino.pub'
printf '%s\n' 'DOMAIN-SUFFIX,a.ru,DIRECT' '' 'AND,((NETWORK,UDP),(DST-PORT,123)),REJECT' > "$WORK/u.txt"
OV=$(renderov -v user_rules_file="$WORK/u.txt") || fail "user-rules: ошибка сборки"
assert_contains "  # --- SERVICE_RULES:BEGIN ---${NL}${NL}  # --- Свои правила ---${NL}  - DOMAIN-SUFFIX,a.ru,DIRECT${NL}  - AND,((NETWORK,UDP),(DST-PORT,123)),REJECT${NL}${NL}  # --- Свои домены ---${NL}  - DOMAIN-SUFFIX,kino.pub,KinoPub" "$OV" "свои правила первыми"
printf '%s\n' '- DOMAIN,x,DIRECT' > "$WORK/u.txt"
rc=0; renderov -v user_rules_file="$WORK/u.txt" > /dev/null 2>&1 || rc=$?; [ "$rc" = 2 ] || fail "user-rule с '- ' должна давать ошибку"

# test_overlay_idempotent
ov 'del	spotify' 'svc	netflix	Netflix	media' 'src	netflix	netflix	domain	https://n/d.mrs' 'dom	kinopub	suffix	kino.pub'
renderov > "$WORK/ov1.yaml" || fail "idempotent: сборка"
awk -v services_file="$D" -v overlay_file="$WORK/o.tsv" -f "$SCRIPT" "$WORK/ov1.yaml" > "$WORK/ov2.yaml" || fail "idempotent: повтор"
cmp -s "$WORK/ov1.yaml" "$WORK/ov2.yaml" || fail "повторная сборка с отличиями меняет файл"

# ===== Ревью порции 2 =====
# test_stale_refs_skipped: dom/src/icon на сервис, которого больше нет
ov 'dom	gone	suffix	a.com' 'src	gone	x	domain	https://x' 'icon	gone	https://i'
renderov > /dev/null 2>"$WORK/err" || fail "устаревшие dom/src/icon должны пропускаться: $(cat "$WORK/err")"
# test_user_svc_replaces_default: свой сервис с id или именем встроенного заменяет его
ov 'svc	youtube	YouTube	other' 'dom	youtube	suffix	yt.example'
OV=$(renderov) || fail "свой сервис с id встроенного: ошибка сборки"
[ "$(printf '%s\n' "$OV" | grep -c '^  - name: YouTube$')" = 1 ] || fail "группа YouTube должна быть одна"
assert_not_contains "youtube@domain" "$OV" "правила встроенного YouTube убраны"
assert_contains "DOMAIN-SUFFIX,yt.example,YouTube" "$OV" "домен своего YouTube"
ov 'svc	my	Spotify	other'
OV=$(renderov) || fail "свой сервис с именем встроенного: ошибка сборки"
[ "$(printf '%s\n' "$OV" | grep -c "^  - name: Spotify$")" = 1 ] || fail "группа Spotify должна быть одна"
# test_user_name_icon_validation
for bad in 'svc	a	My, Group	other' 'svc	a	A # x	other' 'svc	a	A: b	other' "svc	a	 A	other" 'svc	a	A|icon	a	https://i/x y.png' 'svc	a	A|icon	a	foo: bar'; do
  printf '%s\n' "$bad" | tr '|' '\n' > "$WORK/o.tsv"
  rc=0; renderov > /dev/null 2>&1 || rc=$?
  [ "$rc" = 2 ] || fail "overlay '$bad' должен давать ошибку (код $rc)"
done
# test_user_gkey: доп. ключи своей группы
ov 'svc	a	A	other' 'gkey	a	filter: (?i)NL' 'gkey	a	hidden: true'
OV=$(renderov) || fail "gkey: ошибка сборки"
assert_contains "  - name: A${NL}    <<: *select-default${NL}    filter: (?i)NL${NL}    hidden: true${NL}" "$OV" "gkey своей группы"
for bad in 'svc	a	A	other|gkey	youtube	hidden: true' 'svc	a	A	other|gkey	a	name: B' 'svc	a	A	other|gkey	a	nokey'; do
  printf '%s\n' "$bad" | tr '|' '\n' > "$WORK/o.tsv"
  rc=0; renderov > /dev/null 2>&1 || rc=$?
  [ "$rc" = 2 ] || fail "gkey '$bad' должен давать ошибку (код $rc)"
done
# test_geofilter_escape: пробелы обрезаются, спецсимволы экранируются, пустые слова - ошибка
printf '%s\n' ' RU ' 'C++' 'a.b' > "$WORK/g.txt"
OG=$(awk -v services_file="$D" -v geofilter_file="$WORK/g.txt" -f "$SCRIPT" "$G") || fail "geofilter escape: ошибка"
assert_contains "&geofilter '(?i)RU|C\+\+|a\.b'" "$OG" "экранирование фильтра"
printf '%s\n' ' ' > "$WORK/g.txt"
rc=0; awk -v services_file="$D" -v geofilter_file="$WORK/g.txt" -f "$SCRIPT" "$G" > /dev/null 2>&1 || rc=$?
[ "$rc" = 2 ] || fail "фильтр из пробела должен давать ошибку"

# test_base_groups: bset/bfirst на базовых группах шаблона
B="$WORK/b.yaml"
cat > "$B" <<'Y'
anchors:
  select-default: &select-default { type: select, use: *sub-names, proxies: [DIRECT, 'Заблок. сервисы', '⚙️Manual'] }
proxy-groups:
  - name: '🚀 Авто'
    type: url-test
    interval: 600
    tolerance: 50
  - name: 'Заблок. сервисы'
    type: select
    proxies: ['⚡ Самые быстрые', DIRECT, '⚙️Manual']
  # --- SERVICE_GROUPS:BEGIN ---
  # --- SERVICE_GROUPS:END ---
rule-providers:
  # --- SERVICE_PROVIDERS:BEGIN ---
  # --- SERVICE_PROVIDERS:END ---
rules:
  # --- SERVICE_RULES:BEGIN ---
  # --- SERVICE_RULES:END ---
  - MATCH,DIRECT
Y
renderb() { awk -v services_file="$S" -v overlay_file="$WORK/o.tsv" -f "$SCRIPT" "$B"; }
printf 'bset\t🚀 Авто\tinterval\t300\nbset\t🚀 Авто\ttolerance\t0\nbfirst\tЗаблок. сервисы\tDIRECT\nbfirst\t*\t⚙️Manual\n' > "$WORK/o.tsv"
OB=$(renderb) || fail "base: ошибка сборки"
assert_contains "    interval: 300${NL}    tolerance: 0${NL}" "$OB" "bset: значения"
assert_contains "proxies: [DIRECT, '⚡ Самые быстрые', '⚙️Manual']" "$OB" "bfirst: группа"
assert_contains "proxies: ['⚙️Manual', DIRECT, 'Заблок. сервисы'] }" "$OB" "bfirst *: якорь"
printf '%s\n' "$OB" > "$WORK/b2.yaml"
OB2=$(awk -v services_file="$S" -v overlay_file="$WORK/o.tsv" -f "$SCRIPT" "$WORK/b2.yaml")
[ "$OB2" = "$OB" ] || fail "base: повторная сборка меняет результат"
# test_own_scope: ownscope all - в якорь сервисных групп добавляется служебный
# токен __OWN_NODES__; migrate_config.awk заменит его своими нодами (или уберёт)
printf 'ownscope\tall\n' > "$WORK/o.tsv"
OB=$(renderb) || fail "ownscope: ошибка сборки"
assert_contains "proxies: [DIRECT, 'Заблок. сервисы', '⚙️Manual', __OWN_NODES__] }" "$OB" "ownscope: токен в якоре"
assert_not_contains "__OWN_NODES__" "$(printf '%s\n' "$OB" | sed -n '/^proxy-groups:/,$p')" "ownscope: токен только в якоре, не в группах"
printf '%s\n' "$OB" > "$WORK/b3.yaml"
OB3=$(awk -v services_file="$S" -v overlay_file="$WORK/o.tsv" -f "$SCRIPT" "$WORK/b3.yaml")
[ "$OB3" = "$OB" ] || fail "ownscope: повторная сборка добавляет токен ещё раз"
printf 'ownscope\tall\nbfirst\t*\t⚙️Manual\n' > "$WORK/o.tsv"
OB=$(renderb) || fail "ownscope+bfirst: ошибка сборки"
assert_contains "proxies: ['⚙️Manual', DIRECT, 'Заблок. сервисы', __OWN_NODES__] }" "$OB" "ownscope вместе с bfirst *"
printf '' > "$WORK/o.tsv"
assert_not_contains "__OWN_NODES__" "$(renderb)" "без ownscope токена нет"
for bad in 'ownscope	none' 'ownscope	all	x' 'ownscope'; do
  printf '%s\nownscope\tall\n' "$bad" | head -n 1 > "$WORK/o.tsv"
  if renderb >/dev/null 2>&1; then fail "ownscope: '$bad' должен быть ошибкой"; fi
done
printf 'ownscope\tall\nownscope\tall\n' > "$WORK/o.tsv"
if renderb >/dev/null 2>&1; then fail "ownscope задан повторно - ошибка"; fi
# устаревшее (нет группы, ключа, значения) молча пропускается
printf 'bset\tнет\tinterval\t300\nbfirst\tЗаблок. сервисы\tнет-такого\nbfirst\tнет\tx\n' > "$WORK/o.tsv"
OB=$(renderb) || fail "base: устаревшее роняет сборку"
assert_contains "    interval: 600${NL}" "$OB" "base: устаревшее не меняет шаблон"
for bad in 'bset	🚀 Авто	interval	5' 'bset	🚀 Авто	interval	abc' 'bset	🚀 Авто	tolerance	99999' 'bset	🚀 Авто	url	1' 'bset	🚀 Авто	interval	70|bset	🚀 Авто	interval	80' 'bfirst	*	a|bfirst	*	b' 'bset	🚀 Авто	interval'; do
  printf '%s\n' "$bad" | tr '|' '\n' > "$WORK/o.tsv"
  rc=0; renderb > /dev/null 2>&1 || rc=$?
  [ "$rc" = 2 ] || fail "base '$bad' должен давать ошибку (код $rc)"
done

[ "$FAILED" = 0 ] && echo "OK test_render_services"
exit "$FAILED"
