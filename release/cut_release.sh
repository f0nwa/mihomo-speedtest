#!/bin/sh
# Собирает и публикует очередной релиз проекта на GitHub (releases/latest/
# download/...) - канал, из которого install.sh (curl | sh) и update.sh
# реально качают файлы; git push его не трогает и не пересобирает (см.
# AGENTS.md, "После коммита и пуша - сразу инструкции по публикации
# релиза"). Запускается владельцем на своей машине с настоящим доступом к
# github.com - публикацию (gh release create) агент не выполняет.
#
# Без --release-version/--min-updater/--config-schema сам определяет
# текущий опубликованный релиз (releases/latest/download/manifest.txt) и
# берёт следующий RELEASE_VERSION (+1), оставляя MIN_UPDATER_VERSION/
# CONFIG_SCHEMA_VERSION как есть - их поднимают вручную флагом только
# если реально менялся протокол обновлятора или схема config.yaml.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
cd "$ROOT"

REPO=${RELEASE_REPO:-f0nwa/mihomo-speedtest}

usage() {
  echo "Использование: $0 \"<текст --notes>\" [--release-version N] [--min-updater N] [--config-schema N]" >&2
  exit 2
}

[ $# -ge 1 ] || usage
NOTES=$1
shift

NEW_VERSION=""
MIN_UPDATER=""
CONFIG_SCHEMA=""
while [ $# -gt 0 ]; do
  case "$1" in
    --release-version) NEW_VERSION=$2; shift 2 ;;
    --min-updater) MIN_UPDATER=$2; shift 2 ;;
    --config-schema) CONFIG_SCHEMA=$2; shift 2 ;;
    *) echo "неизвестный аргумент: $1" >&2; usage ;;
  esac
done

if [ -z "$NEW_VERSION" ] || [ -z "$MIN_UPDATER" ] || [ -z "$CONFIG_SCHEMA" ]; then
  echo "cut_release.sh: читаю опубликованный manifest.txt (releases/latest/download) для определения текущих версий..." >&2
  PUBLISHED=$(curl -fsSL "https://github.com/$REPO/releases/latest/download/manifest.txt") || {
    echo "cut_release.sh: не удалось скачать опубликованный manifest.txt - если это первый релиз или сети сейчас нет, передайте --release-version/--min-updater/--config-schema явно" >&2
    exit 1
  }
  CUR_VERSION=$(printf '%s\n' "$PUBLISHED" | sed -n 's/^RELEASE_VERSION=\([0-9][0-9]*\)$/\1/p' | head -n1)
  CUR_MIN_UPDATER=$(printf '%s\n' "$PUBLISHED" | sed -n 's/^MIN_UPDATER_VERSION=\([0-9][0-9]*\)$/\1/p' | head -n1)
  CUR_CONFIG_SCHEMA=$(printf '%s\n' "$PUBLISHED" | sed -n 's/^CONFIG_SCHEMA_VERSION=\([0-9][0-9]*\)$/\1/p' | head -n1)
  [ -n "$CUR_VERSION" ] || { echo "cut_release.sh: не удалось разобрать RELEASE_VERSION из опубликованного manifest.txt" >&2; exit 1; }
  [ -n "$CUR_MIN_UPDATER" ] || { echo "cut_release.sh: не удалось разобрать MIN_UPDATER_VERSION из опубликованного manifest.txt" >&2; exit 1; }
  [ -n "$CUR_CONFIG_SCHEMA" ] || { echo "cut_release.sh: не удалось разобрать CONFIG_SCHEMA_VERSION из опубликованного manifest.txt" >&2; exit 1; }
  echo "cut_release.sh: текущий опубликованный релиз v$CUR_VERSION (MIN_UPDATER_VERSION=$CUR_MIN_UPDATER, CONFIG_SCHEMA_VERSION=$CUR_CONFIG_SCHEMA)" >&2
  [ -n "$NEW_VERSION" ] || NEW_VERSION=$((CUR_VERSION + 1))
  [ -n "$MIN_UPDATER" ] || MIN_UPDATER=$CUR_MIN_UPDATER
  [ -n "$CONFIG_SCHEMA" ] || CONFIG_SCHEMA=$CUR_CONFIG_SCHEMA
fi

case $NEW_VERSION in (*[!0-9]*|'') echo "release-version должен быть целым числом" >&2; exit 2;; esac
case $MIN_UPDATER in (*[!0-9]*|'') echo "min-updater должен быть целым числом" >&2; exit 2;; esac
case $CONFIG_SCHEMA in (*[!0-9]*|'') echo "config-schema должен быть целым числом" >&2; exit 2;; esac

TAG="v$NEW_VERSION"
echo "cut_release.sh: готовлю $TAG (RELEASE_VERSION=$NEW_VERSION, MIN_UPDATER_VERSION=$MIN_UPDATER, CONFIG_SCHEMA_VERSION=$CONFIG_SCHEMA)" >&2

command -v gh >/dev/null 2>&1 || { echo "cut_release.sh: не найден gh (GitHub CLI) - установите его перед публикацией" >&2; exit 1; }

sha_tool() {
  if command -v sha256sum >/dev/null 2>&1; then echo sha256sum
  elif command -v shasum >/dev/null 2>&1; then echo shasum
  elif command -v openssl >/dev/null 2>&1; then echo openssl
  else return 1; fi
}
sha_of() {
  case $SHA_TOOL in
    sha256sum) hash_output=$(sha256sum "$1") || return 1 ;;
    shasum) hash_output=$(shasum -a 256 "$1") || return 1 ;;
    openssl) hash_output=$(openssl dgst -sha256 "$1") || return 1 ;;
  esac
  hash_value=$(printf '%s\n' "$hash_output" | awk '{if ($1 ~ /^[0-9a-f]{64}$/) print $1; else if ($NF ~ /^[0-9a-f]{64}$/) print $NF}')
  [ "${#hash_value}" = 64 ] || return 1
  printf '%s\n' "$hash_value"
}
SHA_TOOL=$(sha_tool) || { echo "cut_release.sh: не найден инструмент SHA256 (sha256sum/shasum/openssl)" >&2; exit 1; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/mst-release-$TAG.XXXXXX")
trap 'rm -rf "$WORK"' EXIT INT TERM
MANIFEST=$WORK/manifest.txt
ASSETS=$WORK/assets
mkdir -p "$ASSETS"

sh release/generate_manifest.sh "$NEW_VERSION" "$MIN_UPDATER" "$CONFIG_SCHEMA" "$TAG" > "$MANIFEST"

# Манифест хранит только basename (см. release/manifest-format.md) - путь
# в самом репозитории берём из release/components.txt, той же
# декларации, которую сверял generate_manifest.sh при генерации.
file_count=0
while IFS='|' read -r kind _component src _dest size sha _mode _check; do
  [ "$kind" = FILE ] || continue
  base=${src##*/}
  repopath=$(awk -F'|' -v b="$base" '$1=="FILE" { n=split($3,a,"/"); if (a[n]==b) { print $3; exit } }' release/components.txt)
  [ -n "$repopath" ] || { echo "cut_release.sh: не найден путь в репозитории для $base (release/components.txt)" >&2; exit 1; }
  [ -f "$repopath" ] || { echo "cut_release.sh: $repopath не найден в рабочем дереве" >&2; exit 1; }
  cp "$repopath" "$ASSETS/$base"
  actual_size=$(wc -c < "$ASSETS/$base" | tr -d ' ')
  [ "$actual_size" = "$size" ] || { echo "cut_release.sh: $base - размер в манифесте ($size) не совпадает с рабочим деревом ($actual_size)" >&2; exit 1; }
  actual_sha=$(sha_of "$ASSETS/$base") || { echo "cut_release.sh: не удалось посчитать SHA256 для $base" >&2; exit 1; }
  [ "$actual_sha" = "$sha" ] || { echo "cut_release.sh: $base - SHA256 в манифесте не совпадает с рабочим деревом" >&2; exit 1; }
  file_count=$((file_count + 1))
done < "$MANIFEST"
[ "$file_count" -gt 0 ] || { echo "cut_release.sh: в манифесте не нашлось ни одной строки FILE" >&2; exit 1; }
echo "cut_release.sh: $file_count файлов проверены (размер + SHA256 совпадают с рабочим деревом)" >&2

cp "$MANIFEST" "$ASSETS/manifest.txt"

# Пишем во временный файл и переименовываем - "sha256sum * > SHA256SUMS"
# может успеть создать целевой файл раньше, чем оболочка раскрыла "*", и
# включить сам SHA256SUMS с хешем пустого файла (см. CHANGELOG.md,
# запись про релиз v4).
(
  cd "$ASSETS"
  case $SHA_TOOL in
    sha256sum) sha256sum * > "$WORK/SHA256SUMS.tmp" ;;
    shasum) shasum -a 256 * > "$WORK/SHA256SUMS.tmp" ;;
    openssl) for f in *; do printf '%s  %s\n' "$(sha_of "$f")" "$f"; done > "$WORK/SHA256SUMS.tmp" ;;
  esac
)
mv "$WORK/SHA256SUMS.tmp" "$ASSETS/SHA256SUMS"

echo "cut_release.sh: публикую $TAG в $REPO..." >&2
(
  cd "$ASSETS"
  gh release create "$TAG" ./* --repo "$REPO" --title "$TAG" --notes "$NOTES"
)

echo "cut_release.sh: готово. Проверка: curl -s https://github.com/$REPO/releases/latest/download/manifest.txt | head -6" >&2
