#!/bin/sh
# config_to_state.awk: состояние конструктора из config.yaml.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TOOLS="$ROOT/config-tools"
FAILED=0
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

fail() { echo "FAIL: $*" >&2; FAILED=1; }
assert_eq() { [ "$1" = "$2" ] || fail "$3: ожидалось
$2
получено
$1"; }

T="$WORK/template.yaml"
cat > "$T" <<'Y'
anchors:
  p: &p { type: http, exclude-filter: &geofilter '(?i)RU|old' }
proxy-groups:
  - name: 'Заблок. сервисы'
    type: select
  # --- SERVICE_GROUPS:BEGIN ---
  # --- SERVICE_GROUPS:END ---
rule-providers:
  # --- SERVICE_PROVIDERS:BEGIN ---
  # --- SERVICE_PROVIDERS:END ---
  user@classical:
    type: inline
    payload:
      - DOMAIN-SUFFIX,2ip.io
rules:
  - RULE-SET,adlist@domain,REJECT # реклама
  # --- SERVICE_RULES:BEGIN ---
  # --- SERVICE_RULES:END ---
  - MATCH,DIRECT
Y
D="$WORK/d.tsv"
printf '%s\n' \
  'section	media	Видео' \
  'section	other	Прочее' \
  'svc	youtube	YouTube	media' \
  'svc	spotify	Spotify	media' \
  'svc	kinopub	KinoPub	media' \
  'svc	ipdetect	IP Detect	other' \
  'icon	youtube	https://i/y.png' \
  'prov	-	adlist@domain: { <<: *domain, url: "https://a" }' \
  'prov	youtube	youtube@domain: { <<: *domain, url: "https://y" }' \
  'prov	spotify	spotify@domain: { <<: *domain, url: "https://s" }' \
  'rule	kinopub	DOMAIN-SUFFIX,pkr.ovh,KinoPub' \
  'rule	kinopub	GEOSITE,kinopub,KinoPub' \
  'rule	-	OR,((DOMAIN-SUFFIX,gql.twitch.tv)),⚙️Manual # twitch' \
  'rule	youtube	RULE-SET,youtube@domain,YouTube' \
  'rule	spotify	RULE-SET,spotify@domain,Spotify' \
  'rule	ipdetect	DOMAIN-SUFFIX,2ip.io,IP Detect' > "$D"

build() {
  # $1 - отличия (файл или пусто), $2 - фильтр, $3 - свои правила, вывод - config
  awk -v services_file="$D" -v overlay_file="$1" -v geofilter_file="$2" -v user_rules_file="$3" \
    -f "$TOOLS/render_services.awk" "$T"
}
import() {
  # $1 - config; результат - в $WORK/st
  rm -rf "$WORK/st"; mkdir "$WORK/st"
  awk -v defaults="$D" -v template="$T" -v out_dir="$WORK/st" -v report="$WORK/report" \
    -f "$TOOLS/config_to_state.awk" "$1"
}

# test_import_default_is_empty
build '' '' '' > "$WORK/c0.yaml"
import "$WORK/c0.yaml" || fail "импорт шаблона с ошибкой"
assert_eq "$(cat "$WORK/st/services.tsv")" "" "шаблон -> пустые отличия"
[ ! -e "$WORK/st/geofilter.txt" ] || fail "шаблон -> нет geofilter.txt"
[ ! -e "$WORK/st/user-rules.txt" ] || fail "шаблон -> нет user-rules.txt"

# test_import_del_unrule
grep -v -e '- name: Spotify' -e 'pkr.ovh' -e 'gql.twitch' "$WORK/c0.yaml" > "$WORK/c1.yaml"
import "$WORK/c1.yaml" || fail "импорт del/unrule с ошибкой"
assert_eq "$(cat "$WORK/st/services.tsv")" "$(printf 'del\tspotify\nunrule\tkinopub\tDOMAIN-SUFFIX,pkr.ovh,KinoPub\nunrule\t-\tOR,((DOMAIN-SUFFIX,gql.twitch.tv)),⚙️Manual # twitch')" "del и unrule"
# убранное особое правило не возвращается при сборке
build "$WORK/st/services.tsv" '' '' > "$WORK/c1b.yaml" || fail "сборка с unrule -"
grep -q 'gql.twitch' "$WORK/c1b.yaml" && fail "unrule - не убрал особое правило"
grep -q 'IMPORTED|del|spotify' "$WORK/report" || fail "в отчёте нет del"

# test_import_dom_on_default + user rules + prov
sed 's/^  - MATCH,DIRECT$/  - DOMAIN-SUFFIX,kino.pub,KinoPub\
  - DOMAIN,www.youtube.com,YouTube\
  - AND,((NETWORK,UDP),(DST-PORT,123)),REJECT\
  - RULE-SET,my@domain,DIRECT\
  - RULE-SET,user@classical,DIRECT\
  - MATCH,DIRECT/; s/^  user@classical:$/  my@domain: { <<: *domain, url: "https:\/\/m" }\
  user@classical:/' "$WORK/c0.yaml" > "$WORK/c2.yaml"
import "$WORK/c2.yaml" || fail "импорт доменов с ошибкой"
assert_eq "$(cat "$WORK/st/services.tsv")" "$(printf 'dom\tkinopub\tsuffix\tkino.pub\ndom\tyoutube\tfull\twww.youtube.com\nprov\t-\tmy@domain: { <<: *domain, url: "https://m" }')" "dom и prov"
assert_eq "$(cat "$WORK/st/user-rules.txt")" "$(printf 'AND,((NETWORK,UDP),(DST-PORT,123)),REJECT\nRULE-SET,my@domain,DIRECT\nRULE-SET,user@classical,DIRECT')" "свои правила"

# test_import_custom_service
awk '{print} /# --- SERVICE_GROUPS:END ---/{print "  - name: Netflix"; print "    <<: *select-default"; print "    icon: https://i/n.png"; print "  - name: Mine"; print "    type: url-test"; print "  - name: FAST-WG node1"; print "    type: select"}
  /^  user@classical:$/{}' "$WORK/c0.yaml" |
  sed 's/^  user@classical:$/  netflix@domain: { <<: *domain, url: "https:\/\/n\/d.mrs" }\
  netflix@ipcidr: { <<: *ipcidr, url: "https:\/\/n\/i.mrs" }\
  user@classical:/; s/^  - MATCH,DIRECT$/  - RULE-SET,netflix@domain,Netflix\
  - RULE-SET,netflix@ipcidr,Netflix,no-resolve\
  - DOMAIN-KEYWORD,nflx,Netflix\
  - MATCH,DIRECT/' > "$WORK/c3.yaml"
import "$WORK/c3.yaml" || fail "импорт своего сервиса с ошибкой"
assert_eq "$(cat "$WORK/st/services.tsv")" "$(printf 'svc\tnetflix\tNetflix\tother\nicon\tnetflix\thttps://i/n.png\nsrc\tnetflix\tnetflix\tdomain\thttps://n/d.mrs\nsrc\tnetflix\tnetflix\tipcidr\thttps://n/i.mrs\ndom\tnetflix\tkeyword\tnflx')" "свой сервис"
grep -q 'REVIEW|custom-group|Mine' "$WORK/report" || fail "своя не-select группа - в отчёт"
grep -q 'FAST-WG' "$WORK/report" && fail "группы FAST-WG ведёт fast_wg.awk - не в отчёт"

# test_import_geofilter
sed "s/&geofilter '(?i)RU|old'/\&geofilter '(?i)RU|Россия|whitelist'/" "$WORK/c0.yaml" > "$WORK/c4.yaml"
import "$WORK/c4.yaml" || fail "импорт фильтра с ошибкой"
assert_eq "$(cat "$WORK/st/geofilter.txt")" "$(printf 'RU\nРоссия\nwhitelist')" "фильтр"

# test_roundtrip
printf '%s\n' 'del	spotify' 'unrule	kinopub	DOMAIN-SUFFIX,pkr.ovh,KinoPub' 'svc	netflix	Netflix	other' \
  'icon	netflix	https://i/n.png' 'src	netflix	netflix	domain	https://n/d.mrs' 'dom	youtube	suffix	youtu.be' \
  'dom	netflix	keyword	nflx' 'prov	-	my@domain: { <<: *domain, url: "https://m" }' > "$WORK/ov.tsv"
printf '%s\n' 'RU' 'Россия' > "$WORK/g.txt"
printf '%s\n' 'RULE-SET,my@domain,DIRECT' > "$WORK/u.txt"
build "$WORK/ov.tsv" "$WORK/g.txt" "$WORK/u.txt" > "$WORK/c5.yaml" || fail "сборка для roundtrip"
import "$WORK/c5.yaml" || fail "импорт roundtrip"
assert_eq "$(cat "$WORK/st/services.tsv")" "$(cat "$WORK/ov.tsv")" "roundtrip: отличия"
assert_eq "$(cat "$WORK/st/geofilter.txt")" "$(cat "$WORK/g.txt")" "roundtrip: фильтр"
assert_eq "$(cat "$WORK/st/user-rules.txt")" "$(cat "$WORK/u.txt")" "roundtrip: свои правила"

# нечитаемые входы - код 2
rc=0; awk -v defaults="$WORK/nope.tsv" -v template="$T" -v out_dir="$WORK/st" -v report="$WORK/report" \
  -f "$TOOLS/config_to_state.awk" "$WORK/c0.yaml" 2>/dev/null || rc=$?
[ "$rc" = 2 ] || fail "нет таблицы - код $rc вместо 2"

# ===== Ревью порции 2 =====
# test_import_custom_group_keys: однострочные ключи своей группы -> gkey, вложенные -> REVIEW
awk '{print} /# --- SERVICE_GROUPS:END ---/{print "  - name: NL"; print "    <<: *select-default"; print "    filter: (?i)NL"; print "    hidden: true"; print "    proxies:"; print "      - DIRECT"}' "$WORK/c0.yaml" > "$WORK/c6.yaml"
import "$WORK/c6.yaml" || fail "импорт ключей группы"
assert_eq "$(cat "$WORK/st/services.tsv")" "$(printf 'svc\tnl\tNL\tother\ngkey\tnl\tfilter: (?i)NL\ngkey\tnl\thidden: true')" "ключи своей группы"
grep -q 'REVIEW|custom-group-keys|NL' "$WORK/report" || fail "вложенный ключ группы - в отчёт"
# test_import_prov_of_deleted_service: правило на provider удалённого встроенного сервиса
grep -v -e '- name: Spotify' "$WORK/c0.yaml" | sed 's/^  - MATCH,DIRECT$/  - RULE-SET,spotify@domain,DIRECT\
  - MATCH,DIRECT/' > "$WORK/c7.yaml"
import "$WORK/c7.yaml" || fail "импорт provider удалённого сервиса"
grep -q '^prov	-	spotify@domain: ' "$WORK/st/services.tsv" || fail "provider удалённого сервиса не перенесён"
build "$WORK/st/services.tsv" '' "$WORK/st/user-rules.txt" > "$WORK/c7b.yaml" || fail "сборка c7"
grep -q '^  spotify@domain: ' "$WORK/c7b.yaml" || fail "provider удалённого сервиса пропал при сборке"
# test_import_geofilter_regex: экранированные слова -> обычные, регулярка -> REVIEW, фильтр шаблона
sed "s/&geofilter '(?i)RU|old'/\&geofilter '(?i)RU|C\\\\+\\\\+'/" "$WORK/c0.yaml" > "$WORK/c8.yaml"
import "$WORK/c8.yaml" || fail "импорт экранированного фильтра"
assert_eq "$(cat "$WORK/st/geofilter.txt")" "$(printf 'RU\nC++')" "экранированный фильтр"
sed "s/&geofilter '(?i)RU|old'/\&geofilter '(?i)RU|.*VIP'/" "$WORK/c0.yaml" > "$WORK/c9.yaml"
import "$WORK/c9.yaml" || fail "импорт фильтра-регулярки"
[ ! -e "$WORK/st/geofilter.txt" ] || fail "регулярку нельзя переносить словами"
grep -q 'REVIEW|geofilter-regex' "$WORK/report" || fail "регулярка в фильтре - в отчёт"
# test_import_bad_group_name: имя, которое нельзя вставить в правило -> REVIEW
awk '{print} /# --- SERVICE_GROUPS:END ---/{print "  - name: \"A, B\""; print "    <<: *select-default"}' "$WORK/c0.yaml" > "$WORK/c10.yaml"
import "$WORK/c10.yaml" || fail "импорт плохого имени"
assert_eq "$(cat "$WORK/st/services.tsv")" "" "плохое имя не импортируется"
grep -q 'REVIEW|custom-group-name' "$WORK/report" || fail "плохое имя - в отчёт"

[ "$FAILED" = 0 ] && echo "OK test_config_to_state"
exit "$FAILED"
