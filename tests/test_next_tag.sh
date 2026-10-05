#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
NEXT=$ROOT/release/next_tag.sh

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

# t "<теги через пробел>" "<аргументы>" "<ожидание: тег | ERR>"
t() {
  tags=$1
  args=$2
  want=$3
  # shellcheck disable=SC2086
  if got=$(printf '%s\n' $tags | sh "$NEXT" $args 2>/dev/null); then
    [ "$want" != ERR ] || fail "теги [$tags] аргументы [$args]: ожидалась ошибка, получено $got"
    [ "$got" = "$want" ] || fail "теги [$tags] аргументы [$args]: ожидалось $want, получено $got"
  else
    [ "$want" = ERR ] || fail "теги [$tags] аргументы [$args]: ожидалось $want, получена ошибка"
  fi
}

t "" "stable" 1.0.0
t "" "dev" 1.1.0
t "v26 v26.10.3.4" "stable" 1.0.0
t "1.0.0" "stable" 1.0.1
t "1.0.0" "dev" 1.1.0
t "1.0.0 1.1.0 1.1.1" "dev" 1.1.2
t "1.0.0 1.1.2" "stable --promote" 1.2.0
t "1.0.0 1.1.2 1.2.0" "dev" 1.3.0
t "1.0.0 1.1.2 1.2.0" "stable" 1.2.1
t "1.2.0" "stable --promote" ERR
t "1.2.0 1.1.5" "stable --promote" ERR
t "1.2.0 1.3.4" "stable --major" 2.0.0
t "1.2.0 1.3.4" "dev --major" 2.1.0
t "1.10.0 1.9.3" "stable" 1.10.1

rc=0
printf '\n' | sh "$NEXT" beta >/dev/null 2>&1 || rc=$?
[ "$rc" = 2 ] || fail "неизвестный канал: ожидался код 2, получен $rc"
rc=0
printf '\n' | sh "$NEXT" stable --bogus >/dev/null 2>&1 || rc=$?
[ "$rc" = 2 ] || fail "неизвестный аргумент: ожидался код 2, получен $rc"

echo "test_next_tag.sh: OK" >&2
