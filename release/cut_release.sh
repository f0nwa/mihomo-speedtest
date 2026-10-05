#!/bin/sh
# Собирает и публикует очередной релиз проекта на GitHub - канал, из
# которого install.sh (curl | sh) и update.sh реально качают файлы; git
# push его не трогает и не пересобирает (см. AGENTS.md, "После коммита и
# пуша - сразу инструкции по публикации релиза"). Запускается владельцем
# на своей машине с настоящим доступом к github.com - публикацию (gh
# release create) агент не выполняет.
#
# Каналы: ветка main -> stable, ветка dev -> dev (иначе ошибка); --channel
# stable|dev перекрывает ветку. dev публикуется как pre-release
# (gh release create --prerelease), поэтому releases/latest всегда
# стабильный.
#
# Теги x.y.z: main - чётный minor (1.0.0, 1.0.1, 1.2.0), dev - нечётный
# (1.1.0, 1.1.1, 1.3.0). Следующий тег считает release/next_tag.sh по
# списку тегов из gh release list; --promote (stable: продвинуть текущий
# dev) и --major (новый major) передаются ему как есть. Тег можно задать
# явно флагом --tag. Старые теги v1..v26.x не трогаются и игнорируются.
#
# RELEASE_VERSION - внутренний целый счётчик, общий для обоих каналов: по
# нему update.sh сравнивает версии. Без --release-version/--min-updater/
# --config-schema читаются два манифеста: releases/latest/download/
# manifest.txt (самый новый стабильный) и, если есть dev-тег x.y.z
# (нечётный minor), releases/download/<наибольший dev-тег>/manifest.txt.
# RELEASE_VERSION = максимум из двух + 1, MIN_UPDATER_VERSION/
# CONFIG_SCHEMA_VERSION - как есть из манифеста с большим RELEASE_VERSION.
# MIN_UPDATER_VERSION поднимают флагом, если менялся протокол обновлятора.
# CONFIG_SCHEMA_VERSION растёт на 1 сама, если в этом манифесте другие
# sha256 файлов шаблона (SCHEMA_FILES ниже): роутер покажет отдельное
# обновление конфига. Явные флаги важнее.
#
# Публикация (без --dry-run) требует, чтобы HEAD был запушен (совпадал с
# upstream ветки), и создаёт тег именно на нём (gh release create --target).
#
# --dry-run печатает CHANNEL/TAG/RELEASE_VERSION/MIN_UPDATER_VERSION/
# CONFIG_SCHEMA_VERSION/CONFIG_SCHEMA_BUMPED/PRERELEASE и выходит, ничего не собирая. Ему всё
# равно нужны gh и сеть до github.com (список тегов, манифесты), если тег
# и версии не заданы флагами.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
cd "$ROOT"

REPO=${RELEASE_REPO:-f0nwa/mihomo-speedtest}

usage() {
  echo "Использование: $0 \"<текст --notes>\" [--channel stable|dev] [--promote] [--major] [--tag TAG] [--release-version N] [--min-updater N] [--config-schema N] [--dry-run]" >&2
  exit 2
}

[ $# -ge 1 ] || usage
NOTES=$1
shift

NEW_VERSION=""
MIN_UPDATER=""
CONFIG_SCHEMA=""
TAG=""
CHANNEL=""
PROMOTE=""
MAJOR=""
DRY_RUN=0
CONFIG_SCHEMA_BUMPED=0
while [ $# -gt 0 ]; do
  case "$1" in
    --release-version|--min-updater|--config-schema|--tag|--channel)
      [ $# -ge 2 ] || { echo "Для $1 нужно значение" >&2; usage; } ;;
  esac
  case "$1" in
    --release-version) NEW_VERSION=$2; shift 2 ;;
    --min-updater) MIN_UPDATER=$2; shift 2 ;;
    --config-schema) CONFIG_SCHEMA=$2; shift 2 ;;
    --tag) TAG=$2; shift 2 ;;
    --channel) CHANNEL=$2; shift 2 ;;
    --promote) PROMOTE=--promote; shift ;;
    --major) MAJOR=--major; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    *) echo "Неизвестный аргумент: $1" >&2; usage ;;
  esac
done

if [ -z "$CHANNEL" ]; then
  branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null) || branch=""
  case $branch in
    main) CHANNEL=stable ;;
    dev) CHANNEL=dev ;;
    *) echo "cut_release.sh: Релиз выпускается только из веток main или dev (сейчас: ${branch:-неизвестно}); канал можно задать флагом --channel" >&2; exit 1 ;;
  esac
fi
case $CHANNEL in
  stable) PRERELEASE=0 ;;
  dev) PRERELEASE=1 ;;
  *) echo "cut_release.sh: Неизвестный канал: $CHANNEL (нужен stable или dev)" >&2; exit 2 ;;
esac

command -v gh >/dev/null 2>&1 || { echo "cut_release.sh: Не найден gh (GitHub CLI) - установите его перед публикацией" >&2; exit 1; }

# Список тегов нужен и для подбора тега, и для поиска наибольшего dev-тега.
ALL_TAGS=
if [ -z "$TAG" ] || [ -z "$NEW_VERSION" ] || [ -z "$MIN_UPDATER" ] || [ -z "$CONFIG_SCHEMA" ]; then
  # pipefail нет в POSIX sh: теги сначала в переменную, чтобы ошибку gh не потерять.
  ALL_TAGS=$(gh release list --repo "$REPO" --limit 1000 --exclude-drafts --json tagName --jq '.[].tagName') || {
    echo "cut_release.sh: Не удалось получить список тегов (gh release list) - передайте --tag/--release-version/--min-updater/--config-schema явно" >&2
    exit 1
  }
fi

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
# check_services_template: config.example.yaml хранится собранным - участки
# между маркерами SERVICE_* должны совпадать со сборкой render_services.awk
# из services.default.tsv (см. docs/superpowers/specs/
# 2026-10-05-config-constructor-design.md). Иначе выпуск отменяется.
# CONFIG_TOOLS_DIR - только для тестов.
check_services_template() {
  cst_dir=${CONFIG_TOOLS_DIR:-$ROOT/config-tools}
  cst_out=$(mktemp "${TMPDIR:-/tmp}/cut-release-template.XXXXXX") || exit 1
  if ! awk -v services_file="$cst_dir/services.default.tsv" -f "$cst_dir/render_services.awk" "$cst_dir/config.example.yaml" > "$cst_out" \
     || ! cmp -s "$cst_out" "$cst_dir/config.example.yaml"; then
    rm -f "$cst_out"
    echo "cut_release.sh: config.example.yaml не совпадает со сборкой из services.default.tsv - пересоберите: awk -v services_file=config-tools/services.default.tsv -f config-tools/render_services.awk config-tools/config.example.yaml > /tmp/t && cat /tmp/t > config-tools/config.example.yaml" >&2
    exit 1
  fi
  rm -f "$cst_out"
}
check_services_template

# Файлы, от которых зависит схема config.yaml (см. release/manifest-format.md,
# "Версии и заголовок"): их изменение относительно прошлого релиза
# автоматически поднимает CONFIG_SCHEMA_VERSION - роутер увидит отдельное
# обновление конфига.
SCHEMA_FILES="config.example.yaml migrate_config.awk fast_wg.awk"

# template_changed_files TEXT: basename изменённых или отсутствующих в
# манифесте TEXT файлов схемы (через пробел). Код 2 - в манифесте нет ни
# одной строки FILE этих файлов (сравнивать не с чем).
template_changed_files() {
  tcf_changed= tcf_found=0
  [ -n "${SHA_TOOL:-}" ] || SHA_TOOL=$(sha_tool) || { echo "cut_release.sh: Не найден инструмент SHA256 (sha256sum/shasum/openssl)" >&2; exit 1; }
  for tcf_name in $SCHEMA_FILES; do
    tcf_old=$(printf '%s\n' "$1" | awk -F'|' -v n="$tcf_name" '$1=="FILE" && $3==n {print $6; exit}')
    if [ -z "$tcf_old" ]; then tcf_changed="$tcf_changed $tcf_name"; continue; fi
    tcf_found=1
    tcf_new=$(sha_of "config-tools/$tcf_name") || { echo "cut_release.sh: Не удалось посчитать SHA256 config-tools/$tcf_name" >&2; exit 1; }
    [ "$tcf_old" = "$tcf_new" ] || tcf_changed="$tcf_changed $tcf_name"
  done
  [ "$tcf_found" = 1 ] || return 2
  printf '%s\n' "${tcf_changed# }"
}

# read_manifest URL LABEL: скачивает manifest.txt и выставляет M_VERSION,
# M_MIN_UPDATER, M_CONFIG_SCHEMA.
read_manifest() {
  echo "cut_release.sh: Читаю manifest.txt ($2)..." >&2
  M_TEXT=$(curl -fsSL "$1") || {
    echo "cut_release.sh: Не удалось скачать manifest.txt ($2) - если сети сейчас нет, передайте --release-version/--min-updater/--config-schema явно" >&2
    exit 1
  }
  M_VERSION=$(printf '%s\n' "$M_TEXT" | sed -n 's/^RELEASE_VERSION=\([0-9][0-9]*\)$/\1/p' | head -n1)
  M_MIN_UPDATER=$(printf '%s\n' "$M_TEXT" | sed -n 's/^MIN_UPDATER_VERSION=\([0-9][0-9]*\)$/\1/p' | head -n1)
  M_CONFIG_SCHEMA=$(printf '%s\n' "$M_TEXT" | sed -n 's/^CONFIG_SCHEMA_VERSION=\([0-9][0-9]*\)$/\1/p' | head -n1)
  [ -n "$M_VERSION" ] || { echo "cut_release.sh: Не удалось разобрать RELEASE_VERSION из manifest.txt ($2)" >&2; exit 1; }
  [ -n "$M_MIN_UPDATER" ] || { echo "cut_release.sh: Не удалось разобрать MIN_UPDATER_VERSION из manifest.txt ($2)" >&2; exit 1; }
  [ -n "$M_CONFIG_SCHEMA" ] || { echo "cut_release.sh: Не удалось разобрать CONFIG_SCHEMA_VERSION из manifest.txt ($2)" >&2; exit 1; }
}

if [ -z "$NEW_VERSION" ] || [ -z "$MIN_UPDATER" ] || [ -z "$CONFIG_SCHEMA" ]; then
  # Самый новый стабильный (releases/latest; до каналов это v26.x) и
  # наибольший dev-тег x.y.z (нечётный minor), если он есть: побеждает
  # манифест с большим RELEASE_VERSION. Порядок gh release list по дате
  # не используется - два релиза на одном коммите упорядочены неоднозначно.
  read_manifest "https://github.com/$REPO/releases/latest/download/manifest.txt" "последний стабильный релиз"
  CUR_VERSION=$M_VERSION CUR_MIN_UPDATER=$M_MIN_UPDATER CUR_CONFIG_SCHEMA=$M_CONFIG_SCHEMA CUR_TEXT=$M_TEXT CUR_FROM=latest
  DEV_TAG=$(printf '%s\n' "$ALL_TAGS" | awk -F. '
    /^[0-9]+\.[0-9]+\.[0-9]+$/ && $2 % 2 == 1 {
      if (best == "" || $1 + 0 > b1 || ($1 + 0 == b1 && ($2 + 0 > b2 || ($2 + 0 == b2 && $3 + 0 > b3)))) {
        best = $0; b1 = $1 + 0; b2 = $2 + 0; b3 = $3 + 0
      }
    }
    END { if (best != "") print best }')
  if [ -n "$DEV_TAG" ]; then
    read_manifest "https://github.com/$REPO/releases/download/$DEV_TAG/manifest.txt" "dev-релиз $DEV_TAG"
    if [ "$M_VERSION" -gt "$CUR_VERSION" ]; then
      CUR_VERSION=$M_VERSION CUR_MIN_UPDATER=$M_MIN_UPDATER CUR_CONFIG_SCHEMA=$M_CONFIG_SCHEMA CUR_TEXT=$M_TEXT CUR_FROM=$DEV_TAG
    fi
  fi
  echo "cut_release.sh: Текущие версии взяты из релиза $CUR_FROM (RELEASE_VERSION=$CUR_VERSION, MIN_UPDATER_VERSION=$CUR_MIN_UPDATER, CONFIG_SCHEMA_VERSION=$CUR_CONFIG_SCHEMA)" >&2
  [ -n "$NEW_VERSION" ] || NEW_VERSION=$((CUR_VERSION + 1))
  [ -n "$MIN_UPDATER" ] || MIN_UPDATER=$CUR_MIN_UPDATER
  if [ -z "$CONFIG_SCHEMA" ]; then
    CONFIG_SCHEMA=$CUR_CONFIG_SCHEMA
    tcf_rc=0; tcf_list=$(template_changed_files "$CUR_TEXT") || tcf_rc=$?
    if [ "$tcf_rc" = 2 ]; then
      echo "cut_release.sh: WARN: в манифесте $CUR_FROM нет файлов шаблона - не с чем сравнить шаблон, схема конфига остаётся $CONFIG_SCHEMA" >&2
    elif [ "$tcf_rc" != 0 ]; then
      exit 1
    elif [ -n "$tcf_list" ]; then
      CONFIG_SCHEMA=$((CUR_CONFIG_SCHEMA + 1))
      CONFIG_SCHEMA_BUMPED=1
      echo "cut_release.sh: шаблон конфига изменился ($tcf_list) - схема $CUR_CONFIG_SCHEMA -> $CONFIG_SCHEMA" >&2
    fi
  fi
fi

case $NEW_VERSION in (*[!0-9]*|'') echo "release-version должен быть целым числом" >&2; exit 2;; esac
case $MIN_UPDATER in (*[!0-9]*|'') echo "min-updater должен быть целым числом" >&2; exit 2;; esac
case $CONFIG_SCHEMA in (*[!0-9]*|'') echo "config-schema должен быть целым числом" >&2; exit 2;; esac

if [ -z "$TAG" ]; then
  # shellcheck disable=SC2086
  TAG=$(printf '%s\n' "$ALL_TAGS" | sh release/next_tag.sh "$CHANNEL" $PROMOTE $MAJOR) || exit 1
fi
case $TAG in (''|[!A-Za-z0-9]*|*[!A-Za-z0-9_.-]*|*..*) echo "cut_release.sh: Недопустимый тег: $TAG" >&2; exit 2;; esac
echo "cut_release.sh: Готовлю $TAG, канал $CHANNEL (RELEASE_VERSION=$NEW_VERSION, MIN_UPDATER_VERSION=$MIN_UPDATER, CONFIG_SCHEMA_VERSION=$CONFIG_SCHEMA)" >&2

if [ "$DRY_RUN" = 1 ]; then
  printf 'CHANNEL=%s\nTAG=%s\nRELEASE_VERSION=%s\nMIN_UPDATER_VERSION=%s\nCONFIG_SCHEMA_VERSION=%s\nCONFIG_SCHEMA_BUMPED=%s\nPRERELEASE=%s\n' \
    "$CHANNEL" "$TAG" "$NEW_VERSION" "$MIN_UPDATER" "$CONFIG_SCHEMA" "$CONFIG_SCHEMA_BUMPED" "$PRERELEASE"
  exit 0
fi

# Тег создаётся на текущем коммите (--target), а не на ветке по умолчанию
# GitHub: иначе dev-релиз пометил бы код main. Поэтому HEAD обязан быть
# уже запушен - тот же коммит, что и upstream текущей ветки.
HEAD_SHA=$(git rev-parse HEAD) || { echo "cut_release.sh: Не удалось определить текущий коммит (git rev-parse HEAD)" >&2; exit 1; }
UPSTREAM_SHA=$(git rev-parse '@{u}' 2>/dev/null) || { echo "cut_release.sh: У текущей ветки нет upstream - сначала выполните git push -u, затем повторите публикацию" >&2; exit 1; }
[ "$HEAD_SHA" = "$UPSTREAM_SHA" ] || { echo "cut_release.sh: Текущий коммит не запушен (HEAD $HEAD_SHA, upstream $UPSTREAM_SHA) - сначала выполните git push, затем повторите публикацию" >&2; exit 1; }

SHA_TOOL=$(sha_tool) || { echo "cut_release.sh: Не найден инструмент SHA256 (sha256sum/shasum/openssl)" >&2; exit 1; }

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
  [ -n "$repopath" ] || { echo "cut_release.sh: Не найден путь в репозитории для $base (release/components.txt)" >&2; exit 1; }
  [ -f "$repopath" ] || { echo "cut_release.sh: $repopath не найден в рабочем дереве" >&2; exit 1; }
  cp "$repopath" "$ASSETS/$base"
  actual_size=$(wc -c < "$ASSETS/$base" | tr -d ' ')
  [ "$actual_size" = "$size" ] || { echo "cut_release.sh: $base - размер в манифесте ($size) не совпадает с рабочим деревом ($actual_size)" >&2; exit 1; }
  actual_sha=$(sha_of "$ASSETS/$base") || { echo "cut_release.sh: Не удалось посчитать SHA256 для $base" >&2; exit 1; }
  [ "$actual_sha" = "$sha" ] || { echo "cut_release.sh: $base - SHA256 в манифесте не совпадает с рабочим деревом" >&2; exit 1; }
  file_count=$((file_count + 1))
done < "$MANIFEST"
[ "$file_count" -gt 0 ] || { echo "cut_release.sh: В манифесте не нашлось ни одной строки FILE" >&2; exit 1; }
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

echo "cut_release.sh: Публикую $TAG в $REPO..." >&2
(
  cd "$ASSETS"
  if [ "$PRERELEASE" = 1 ]; then
    gh release create "$TAG" ./* --repo "$REPO" --target "$HEAD_SHA" --title "$TAG" --notes "$NOTES" --prerelease
  else
    gh release create "$TAG" ./* --repo "$REPO" --target "$HEAD_SHA" --title "$TAG" --notes "$NOTES"
  fi
)

echo "cut_release.sh: Готово. Проверка: curl -s https://github.com/$REPO/releases/download/$TAG/manifest.txt | head -6" >&2
