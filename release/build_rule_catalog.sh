#!/bin/sh
# build_rule_catalog.sh - собирает каталог наборов правил (.mrs) для поиска
# в конструкторе конфига (config-tools/rule-catalog.tsv). Запускается на
# машине выпуска с сетью до api.github.com, перед выпуском релиза:
#
#   sh release/build_rule_catalog.sh config-tools/rule-catalog.tsv
#
# С путём - пишет во временный файл и заменяет только при успехе (прежний
# каталог не портится, если нет сети или кончился лимит API); без пути -
# в stdout.
#
# Строка каталога: имя<TAB>вид<TAB>источник<TAB>адрес<TAB>название
#   вид - domain | ipcidr (поведение rule-provider); имя уникально в
#   пределах вида и годится для provider "имя@вид" (render_services.awk).
# Источники (порядок = приоритет при совпадении имени и вида):
#   zxc-rv     - ассеты последнего релиза zkeenip-rulesets (*@ipcidr.mrs)
#                и adlist из ad-filter (уже в шаблоне);
#   metacubex  - дерево ветки meta MetaCubeX/meta-rules-dat:
#                geo/geosite/*.mrs (domain), geo/geoip/*.mrs (ipcidr);
#                варианты с @ (steam@cn и т.п.) не берутся;
#   itdog      - ассеты последнего релиза itdoginfo/allow-domains
#                (*_domain.mrs, *_ipcidr.mrs), имя с префиксом itdog-;
#   legiz      - таблица ниже (legiz-ru/mihomo-rule-sets, README), префикс legiz-.
# Названия - release/rule-catalog-titles.tsv (нет - само имя).
#
# CATALOG_FIXTURES=DIR - брать ответы API из файлов DIR/metacubex-tree.json,
# DIR/zxc-ipcidr-release.json, DIR/itdog-release.json (тесты; начальный
# каталог в репозитории). CATALOG_DATE - дата в шапке (по умолчанию
# сегодня; окно конструктора показывает её как «базы обновлены»). GITHUB_TOKEN - необязательный токен API.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
TITLES=$ROOT/release/rule-catalog-titles.tsv
WORK=$(mktemp -d "${TMPDIR:-/tmp}/rule-catalog.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
fail() { echo "build_rule_catalog.sh: $1" >&2; exit 1; }

fetch() {
  # $1 - файл фикстуры, $2 - адрес API
  if [ -n "${CATALOG_FIXTURES:-}" ]; then
    cat "$CATALOG_FIXTURES/$1" 2>/dev/null || fail "нет фикстуры $CATALOG_FIXTURES/$1"
  elif [ -n "${GITHUB_TOKEN:-}" ]; then
    curl -fsSL -H "Authorization: Bearer $GITHUB_TOKEN" "$2" || fail "не удалось скачать $2"
  else
    curl -fsSL "$2" || fail "не удалось скачать $2 (лимит API? задайте GITHUB_TOKEN)"
  fi
}

API=https://api.github.com/repos
OUT=${1:-}
fetch metacubex-tree.json "$API/MetaCubeX/meta-rules-dat/git/trees/meta?recursive=1" > "$WORK/meta.json"
# Большое дерево API может отдать не целиком - тогда каталог неполный.
if grep -q '"truncated": *true' "$WORK/meta.json"; then fail "дерево MetaCubeX усечено API - каталог был бы неполным"; fi
fetch zxc-ipcidr-release.json "$API/zxc-rv/zkeenip-rulesets/releases/latest" > "$WORK/zxc.json"
fetch itdog-release.json "$API/itdoginfo/allow-domains/releases/latest" > "$WORK/itdog.json"

# Кандидаты: имя<TAB>вид<TAB>источник<TAB>адрес - в порядке приоритета.
{
  printf 'adlist\tdomain\tzxc-rv\thttps://github.com/zxc-rv/ad-filter/releases/latest/download/adlist.mrs\n'
  grep -o '"name": *"[^"]*@ipcidr\.mrs"' "$WORK/zxc.json" | sed 's/.*"\([^"]*\)@ipcidr\.mrs"$/\1/' |
    while read -r n; do printf '%s\tipcidr\tzxc-rv\thttps://github.com/zxc-rv/zkeenip-rulesets/releases/latest/download/%s@ipcidr.mrs\n' "$n" "$n"; done
  grep -oE '"path": *"geo/geo(site|ip)/[^"/@]*\.mrs"' "$WORK/meta.json" | sed 's/.*"\(geo\/[^"]*\)"$/\1/' |
    while read -r p; do
      n=${p##*/}; n=${n%.mrs}
      case $p in geo/geosite/*) k=domain ;; *) k=ipcidr ;; esac
      printf '%s\t%s\tmetacubex\thttps://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/meta/%s\n' "$n" "$k" "$p"
    done
  grep -oE '"name": *"[^"]*_(domain|ipcidr)\.mrs"' "$WORK/itdog.json" | sed 's/.*"\([^"]*\)"$/\1/' |
    while read -r a; do
      b=${a%.mrs}; k=${b##*_}; n=$(printf '%s' "${b%_*}" | tr '_' '-')
      printf 'itdog-%s\t%s\titdog\thttps://github.com/itdoginfo/allow-domains/releases/latest/download/%s\n' "$n" "$k" "$a"
    done
  L=https://github.com/legiz-ru/mihomo-rule-sets/raw/main
  printf 'legiz-ru-bundle\tdomain\tlegiz\t%s/ru-bundle/rule.mrs\n' "$L"
  printf 'legiz-rknasnblock\tipcidr\tlegiz\t%s/ru-bundle/rknasnblock.mrs\n' "$L"
  printf 'legiz-re-filter\tdomain\tlegiz\t%s/re-filter/domain-rule.mrs\n' "$L"
  printf 'legiz-re-filter-ip\tipcidr\tlegiz\t%s/re-filter/ip-rule.mrs\n' "$L"
  printf 'legiz-oisd-big\tdomain\tlegiz\t%s/oisd/big.mrs\n' "$L"
  printf 'legiz-oisd-small\tdomain\tlegiz\t%s/oisd/small.mrs\n' "$L"
  printf 'legiz-oisd-nsfw\tdomain\tlegiz\t%s/oisd/nsfw.mrs\n' "$L"
  printf 'legiz-torrent-trackers\tdomain\tlegiz\t%s/other/torrent-trackers.mrs\n' "$L"
  printf 'legiz-torrent-websites\tdomain\tlegiz\t%s/other/torrent-websites.mrs\n' "$L"
  printf 'legiz-discord-voice\tipcidr\tlegiz\t%s/other/discord-voice-ip-list.mrs\n' "$L"
} > "$WORK/cand"

n_meta=$(grep -c "	metacubex	" "$WORK/cand" || true)
[ "$n_meta" -gt 0 ] || fail "в ответе MetaCubeX нет наборов - каталог не собран"

{
printf '# rule-catalog.tsv - наборы правил для поиска в конструкторе конфига.\n'
printf '# Собирается release/build_rule_catalog.sh, руками не править.\n'
printf '# собран: %s\n' "${CATALOG_DATE:-$(date +%F)}"
printf '# имя<TAB>вид<TAB>источник<TAB>адрес<TAB>название\n'
# Апостроф в адресе отсекается index() - без \047 в регулярке (BSD awk).
awk -F'\t' -v titles="$TITLES" -v q="'" '
  BEGIN { while ((getline l < titles) > 0) { if (l ~ /^#/ || l == "") continue; split(l, t, "\t"); title[t[1]] = t[2] } }
  $1 !~ /^[A-Za-z0-9][A-Za-z0-9._!-]*$/ || $4 !~ /^https?:\/\/[^ "#]+$/ || index($4, q) { next }
  { k = $1 "@" $2; if (k in seen) next; seen[k] = 1
    print $1 "\t" $2 "\t" $3 "\t" $4 "\t" (($1 in title) ? title[$1] : $1) }
' "$WORK/cand"
} > "$WORK/catalog"
if [ -n "$OUT" ]; then
  cp "$WORK/catalog" "$OUT.new" && mv -f "$OUT.new" "$OUT" || fail "не удалось записать $OUT"
else
  cat "$WORK/catalog"
fi
