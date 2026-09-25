#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
COMPONENTS=${COMPONENTS:-$ROOT/release/components.txt}
PLAN_AWK=$ROOT/updater/update_plan.awk

usage() {
  echo "Использование: $0 <release_version> <min_updater_version> <config_schema_version> [release_tag]" >&2
  exit 2
}

[ $# -ge 3 ] && [ $# -le 4 ] || usage
RELEASE_VERSION=$1
MIN_UPDATER_VERSION=$2
CONFIG_SCHEMA_VERSION=$3
RELEASE_TAG=${4:-v$RELEASE_VERSION}

case $RELEASE_VERSION in (*[!0-9]*|'') echo "release_version должен быть целым числом" >&2; exit 2;; esac
case $MIN_UPDATER_VERSION in (*[!0-9]*|'') echo "min_updater_version должен быть целым числом" >&2; exit 2;; esac
case $CONFIG_SCHEMA_VERSION in (*[!0-9]*|'') echo "config_schema_version должен быть целым числом" >&2; exit 2;; esac

[ -f "$COMPONENTS" ] || { echo "не найден $COMPONENTS" >&2; exit 2; }
[ -f "$PLAN_AWK" ] || { echo "не найден $PLAN_AWK (нужен для самопроверки манифеста)" >&2; exit 2; }

# Проверка структуры декларации до чтения её исходных файлов. Правила
# полного манифеста остаются в update_plan.awk.
awk -F'|' '
  /^#/ || /^$/ { next }
  $1 ~ /^(COMPONENT|DEPENDS|ACTION|NOTE|CONFLICT)$/ && NF == 3 { next }
  $1 == "FILE" && NF == 6 {
    if ($3 ~ /^[A-Za-z0-9_.\/-]+$/ && $3 !~ /^\// && $3 !~ /\/\// &&
        $3 !~ /(^|\/)\.\.?(\/|$)/ && $3 !~ /\/$/) next
  }
  { print "components.txt: неверная структура или исходный путь, строка " NR > "/dev/stderr"; bad=1 }
  END { exit bad }
' "$COMPONENTS" || exit 1

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
  printf 'FORMAT_VERSION=2\n'
  printf 'RELEASE_TAG=%s\n' "$RELEASE_TAG"
  printf 'RELEASE_VERSION=%s\n' "$RELEASE_VERSION"
  printf 'MIN_UPDATER_VERSION=%s\n' "$MIN_UPDATER_VERSION"
  printf 'CONFIG_SCHEMA_VERSION=%s\n' "$CONFIG_SCHEMA_VERSION"

  while IFS='|' read -r rtype a b c d e || [ -n "$rtype" ]; do
    case $rtype in
      ''|'#'*) continue ;;
      COMPONENT|DEPENDS|ACTION|NOTE|CONFLICT)
        # Не терять лишние поля декларации при преобразовании.
        printf '%s|%s|%s\n' "$rtype" "$a" "$b" ;;

      FILE)
        src="$ROOT/$b"
        [ -f "$src" ] || { echo "components.txt: файл не найден: $src" >&2; exit 1; }
        sz=$(size_of "$src")
        sum=$(sha256_of "$src") || exit 1
        b_base=${b##*/}
        printf 'FILE|%s|%s|%s|%s|%s|%s|%s\n' "$a" "$b_base" "$c" "$sz" "$sum" "$d" "$e"
        ;;
      *)
        echo "components.txt: нераспознанный тип строки: $rtype" >&2
        exit 1
        ;;
    esac
  done < "$COMPONENTS"
} > "$OUT"

# Самопроверка: тот же update_plan.awk, который будет разбирать манифест на
# роутере, должен принять весь каталог без выбора конфликтующих компонентов - это
# единственная проверка манифеста, отдельной копии правил валидации у
# генератора нет (DRY: одна реализация разбора и для update.sh, и для
# самопроверки при выпуске релиза).
if ! awk -v MANIFEST="$OUT" -v VALIDATE_ONLY=1 -v FORMAT=text -f "$PLAN_AWK" >/dev/null; then
  echo "сгенерированный манифест не прошёл самопроверку update_plan.awk" >&2
  exit 1
fi

cat "$OUT"
