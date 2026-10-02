#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SCRIPT="$ROOT/config-tools/setup.sh"
FAILED=0
T=$(printf '\t')

assert_eq() {
  if [ "$1" != "$2" ]; then
    echo "FAIL: '$1' != '$2' ($3)" >&2
    FAILED=1
  fi
}

# setup.sh сорсит version_check.sh через $SELFDIR даже под
# SETUP_LIB_ONLY=1 - см. пояснение в test_setup.sh.
SELFDIR=$(mktemp -d)
cp "$ROOT"/install.sh "$ROOT"/uninstall.sh "$ROOT"/*/*.sh "$ROOT"/*/*.awk "$ROOT"/*/*.py "$ROOT"/*/*.html "$ROOT"/*/*.css "$ROOT"/*/*.js "$ROOT"/*/*.yaml "$SELFDIR/" 2>/dev/null
SETUP_LIB_ONLY=1 . "$SCRIPT"

# --- domain_label(): эвристика "предпоследняя метка хоста" ---

assert_eq "$(domain_label 'https://vpnshop.example.com/sub/AAA')" "example" "поддомен"
assert_eq "$(domain_label 'https://example.com/sub/AAA')" "example" "обычный домен без поддомена"
assert_eq "$(domain_label 'https://EXAMPLE.COM:8443/sub/AAA')" "example" "хост с портом + нижний регистр"
assert_eq "$(domain_label 'https://localhost/sub/AAA')" "localhost" "однословный host (меньше двух меток)"
assert_eq "$(domain_label 'https://1.2.3.4/sub/AAA')" "3" "IP-хост - простая эвристика не спецкейсит IP (осознанное ограничение)"

# --- assign_provider_names(): подтверждение, коллизии, валидация ---

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# Строка 1: новая подписка (UA уже подобран, имени нет) -> кандидат по
#   домену "example", пользователь нажимает Enter - принимает кандидат.
# Строка 2: импортированная подписка (UA неизвестен, имя "provider-a"
#   перенесено) -> кандидат "provider-a", Enter - принимает.
# Строка 3: новая подписка, кандидат по домену тоже "example" -
#   коллизия с уже занятым именем из строки 1, пользователь вводит
#   "another".
# Строка 4: новая подписка, кандидат "bar" - сперва пользователь вводит
#   недопустимое имя "bad name!" (пробел и "!"), затем Enter -
#   принимает кандидат "bar".
printf '%s\t%s\t%s\n' 'https://myvpn.example.com/sub/AAA' 'clash.meta' '' > "$WORK/specs.txt"
printf '%s\t%s\t%s\n' 'https://old.example.org/sub/BBB' '' 'provider-a' >> "$WORK/specs.txt"
printf '%s\t%s\t%s\n' 'https://another.example.org/sub/CCC' '' '' >> "$WORK/specs.txt"
printf '%s\t%s\t%s\n' 'https://foo.bar.net/sub/DDD' '' '' >> "$WORK/specs.txt"

printf '\n\nanother\nbad name!\n\n' \
  | assign_provider_names "$WORK/specs.txt" > "$WORK/out.txt" 2>"$WORK/err.txt"

assert_eq "$(wc -l < "$WORK/out.txt" | tr -d ' ')" "4" "четыре строки на выходе"
grep -qxF "https://myvpn.example.com/sub/AAA${T}clash.meta${T}example" "$WORK/out.txt" \
  || { echo "FAIL: строка 1 (кандидат по домену, принят Enter'ом) не совпала" >&2; FAILED=1; }
grep -qxF "https://old.example.org/sub/BBB${T}${T}provider-a" "$WORK/out.txt" \
  || { echo "FAIL: строка 2 (перенесённое имя, принято Enter'ом) не совпала" >&2; FAILED=1; }
grep -qxF "https://another.example.org/sub/CCC${T}${T}another" "$WORK/out.txt" \
  || { echo "FAIL: строка 3 (коллизия по домену, ручной ввод) не совпала" >&2; FAILED=1; }
grep -qxF "https://foo.bar.net/sub/DDD${T}${T}bar" "$WORK/out.txt" \
  || { echo "FAIL: строка 4 (недопустимые символы отклонены, затем принят кандидат) не совпала" >&2; FAILED=1; }

grep -q 'уже занято' "$WORK/err.txt" \
  || { echo "FAIL: сообщение о коллизии имён не напечатано" >&2; FAILED=1; }
grep -q 'может содержать только' "$WORK/err.txt" \
  || { echo "FAIL: сообщение об недопустимых символах не напечатано" >&2; FAILED=1; }

if [ "$FAILED" = 1 ]; then
  echo "test_assign_provider_names.sh: FAILED" >&2
  exit 1
fi
echo "test_assign_provider_names.sh: OK"
