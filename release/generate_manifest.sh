#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
COMPONENTS=${COMPONENTS:-$ROOT/release/components.txt}
PLAN_AWK=$ROOT/update_plan.awk

usage() {
  echo "Использование: $0 <release_version> <min_updater_version> <config_schema_version>" >&2
  exit 2
}

[ $# -eq 3 ] || usage
RELEASE_VERSION=$1
MIN_UPDATER_VERSION=$2
CONFIG_SCHEMA_VERSION=$3

case $RELEASE_VERSION in (*[!0-9]*|'') echo "release_version должен быть целым числом" >&2; exit 2;; esac
case $MIN_UPDATER_VERSION in (*[!0-9]*|'') echo "min_updater_version должен быть целым числом" >&2; exit 2;; esac
case $CONFIG_SCHEMA_VERSION in (*[!0-9]*|'') echo "config_schema_version должен быть целым числом" >&2; exit 2;; esac

[ -f "$COMPONENTS" ] || { echo "не найден $COMPONENTS" >&2; exit 2; }
[ -f "$PLAN_AWK" ] || { echo "не найден $PLAN_AWK (нужен для самопроверки манифеста)" >&2; exit 2; }

sha256_of() {
  f=$1
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$f" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$f" | awk '{print $1}'
  elif command -v openssl >/dev/null 2>&1; then
    openssl dgst -sha256 "$f" | awk '{print $NF}'
  else
    echo "не найден sha256sum/shasum/openssl - невозможно посчитать контрольную сумму" >&2
    return 1
  fi
}

size_of() {
  wc -c < "$1" | tr -d ' '
}

OUT=$(mktemp "${TMPDIR:-/tmp}/mst-manifest.XXXXXX")
trap 'rm -f "$OUT"' EXIT INT TERM

{
  printf 'FORMAT_VERSION=1\n'
  printf 'RELEASE_VERSION=%s\n' "$RELEASE_VERSION"
  printf 'MIN_UPDATER_VERSION=%s\n' "$MIN_UPDATER_VERSION"
  printf 'CONFIG_SCHEMA_VERSION=%s\n' "$CONFIG_SCHEMA_VERSION"

  while IFS='|' read -r rtype a b c d e || [ -n "$rtype" ]; do
    case $rtype in
      ''|'#'*) continue ;;
      COMPONENT) printf 'COMPONENT|%s|%s\n' "$a" "$b" ;;
      DEPENDS) printf 'DEPENDS|%s|%s\n' "$a" "$b" ;;
      ACTION) printf 'ACTION|%s|%s\n' "$a" "$b" ;;
      FILE)
        src="$ROOT/$b"
        [ -f "$src" ] || { echo "components.txt: файл не найден: $src" >&2; exit 1; }
        sz=$(size_of "$src")
        sum=$(sha256_of "$src") || exit 1
        printf 'FILE|%s|%s|%s|%s|%s|%s|%s\n' "$a" "$b" "$c" "$sz" "$sum" "$d" "$e"
        ;;
      *)
        echo "components.txt: нераспознанный тип строки: $rtype" >&2
        exit 1
        ;;
    esac
  done < "$COMPONENTS"
} > "$OUT"

# Самопроверка: тот же update_plan.awk, который будет разбирать манифест на
# роутере, должен принять готовый файл целиком (все компоненты сразу) - это
# единственная проверка манифеста, отдельной копии правил валидации у
# генератора нет (DRY: одна реализация разбора и для update.sh, и для
# самопроверки при выпуске релиза).
ALL_IDS=$(awk -F'|' '$1=="COMPONENT"{printf "%s%s", (n++?",":""), $2}' "$OUT")
if ! awk -v MANIFEST="$OUT" -v SELECTED="$ALL_IDS" -v FORMAT=text -f "$PLAN_AWK" >/dev/null; then
  echo "сгенерированный манифест не прошёл самопроверку update_plan.awk" >&2
  exit 1
fi

cat "$OUT"
