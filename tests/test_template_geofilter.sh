#!/bin/sh
# Гео-фильтр шаблона и минимальный фильтр установщика: Беларусь отсекается
# так же, как Россия; слова whitelist в шаблоне нет.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
FAILED=0
fail() { echo "FAIL: $*" >&2; FAILED=1; }

TPL=$(sed -n "s/.*exclude-filter: &geofilter '\([^']*\)'.*/\1/p" "$ROOT/config-tools/config.example.yaml" | head -n 1 | sed 's/^(?i)//')
[ -n "$TPL" ] || fail "в шаблоне не найден exclude-filter: &geofilter"
MIN=$(sed -n "s/^MIN_BLOCK='\(.*\)'$/\1/p" "$ROOT/install.sh" | head -n 1)
[ -n "$MIN" ] || fail "в install.sh не найден MIN_BLOCK"

has_word() { # $1 - фильтр, $2 - слово целиком между | (или по краям)
  case "|$1|" in *"|$2|"*) return 0 ;; *) return 1 ;; esac
}
for w in '🇧🇾' Belarus Беларусь Белоруссия Minsk Минск; do
  has_word "$TPL" "$w" || fail "шаблон: нет слова Беларуси '$w'"
done
for w in '🇧🇾' Belarus Беларусь Minsk Минск; do
  has_word "$MIN" "$w" || fail "MIN_BLOCK: нет слова Беларуси '$w'"
done
# Россия на месте
for w in '🇷🇺' Russia Россия; do
  has_word "$TPL" "$w" || fail "шаблон: пропало слово России '$w'"
  has_word "$MIN" "$w" || fail "MIN_BLOCK: пропало слово России '$w'"
done
case "$TPL" in *[Ww][Hh][Ii][Tt][Ee][Ll][Ii][Ss][Tt]*) fail "в шаблоне остался whitelist" ;; esac
[ "$FAILED" = 0 ] || exit 1
echo "OK test_template_geofilter"
