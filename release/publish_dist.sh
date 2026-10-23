#!/bin/sh
# Выкладывает файлы релиза в ветку dist - зеркало для jsDelivr
# (cdn.jsdelivr.net/gh/<repo>@dist-<TAG>/<TAG>/<файл>). Через jsDelivr
# install.sh и update.sh качают релиз, когда GitHub (github.com,
# *.githubusercontent.com, api.github.com) с роутера недоступен: jsDelivr
# не отдаёт вложения GitHub Releases, только файлы из дерева git, поэтому
# те же файлы дублируются в отдельную ветку.
#
# Устройство ветки dist (orphan, к истории main/dev отношения не имеет):
#   <TAG>/            - все файлы релиза (manifest.txt, SHA256SUMS, файлы
#                       компонентов) + notes.txt (текст релиза);
#   channels/stable   - тег последнего стабильного релиза (одна строка);
#   channels/dev      - тег последнего dev-релиза;
#   install.sh        - копия из последнего стабильного релиза: вход для
#                       "curl | sh" без raw.githubusercontent.com.
# На каждый коммит dist ставится неизменяемый тег dist-<TAG>: по нему
# jsDelivr отдаёт ровно эту версию и кэширует её навсегда. Указатели
# @dist/channels/* и @dist/install.sh jsDelivr кэширует до 12 ч - после
# публикации скрипт сбрасывает их кэш через purge.jsdelivr.net.
# jsDelivr не отдаёт ветку/тег, если дерево больше 50 МБ, поэтому в dist
# остаются только последние DIST_KEEP релизов каждого канала (релиз
# ~2 МБ); старые коммиты доступны по своим тегам dist-<TAG>.
#
# Рабочее дерево и текущая ветка не трогаются: дерево dist собирается во
# временном индексе (GIT_INDEX_FILE) и пушится коммитом напрямую.
#
# Использование:
#   sh release/publish_dist.sh TAG
#       скачать файлы и текст уже опубликованного релиза через gh и
#       выложить их (первичное заполнение зеркала, повтор после сбоя);
#   sh release/publish_dist.sh TAG --assets DIR --notes-file FILE [--channel stable|dev]
#       выложить собранные файлы (так зовёт release/cut_release.sh).
# Канал по умолчанию - по тегу: чётный minor - stable, нечётный - dev.
# Окружение: RELEASE_REPO (f0nwa/mihomo-speedtest), DIST_REMOTE (origin),
# DIST_KEEP (4), DIST_PURGE (1; 0 - не сбрасывать кэш jsDelivr).
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
cd "$ROOT"

REPO=${RELEASE_REPO:-f0nwa/mihomo-speedtest}
REMOTE=${DIST_REMOTE:-origin}
KEEP=${DIST_KEEP:-4}
BRANCH=dist

say() { echo "publish_dist.sh: $*" >&2; }
die() { say "$*"; exit 1; }
usage() {
  echo "Использование: $0 TAG [--assets DIR --notes-file FILE] [--channel stable|dev]" >&2
  exit 2
}

[ $# -ge 1 ] || usage
TAG=$1
shift
ASSETS_IN="" NOTES_IN="" CHANNEL=""
while [ $# -gt 0 ]; do
  case "$1" in
    --assets|--notes-file|--channel) [ $# -ge 2 ] || usage ;;
  esac
  case "$1" in
    --assets) ASSETS_IN=$2; shift 2 ;;
    --notes-file) NOTES_IN=$2; shift 2 ;;
    --channel) CHANNEL=$2; shift 2 ;;
    *) echo "Неизвестный аргумент: $1" >&2; usage ;;
  esac
done
case $KEEP in (''|*[!0-9]*|0) die "DIST_KEEP должен быть целым числом больше 0" ;; esac
printf '%s\n' "$TAG" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' || die "Зеркало ведётся только для тегов x.y.z (получено: $TAG)"
if [ -z "$CHANNEL" ]; then
  minor=$(printf '%s\n' "$TAG" | cut -d. -f2)
  if [ $((minor % 2)) = 1 ]; then CHANNEL=dev; else CHANNEL=stable; fi
fi
case $CHANNEL in stable|dev) ;; *) die "Неизвестный канал: $CHANNEL (нужен stable или dev)" ;; esac
[ -n "$ASSETS_IN" ] || [ -z "$NOTES_IN" ] || usage

sha_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'
  elif command -v openssl >/dev/null 2>&1; then openssl dgst -sha256 "$1" | awk '{print $NF}'
  else die "Не найден инструмент SHA256 (sha256sum/shasum/openssl)"; fi
}

# ver_gt A B: A > B для тегов x.y.z (покомпонентно, числами).
ver_gt() {
  awk -v a="$1" -v b="$2" 'BEGIN {
    split(a, x, "."); split(b, y, ".")
    for (i = 1; i <= 3; i++) { if (x[i] + 0 > y[i] + 0) exit 0; if (x[i] + 0 < y[i] + 0) exit 1 }
    exit 1
  }'
}

WORK=$(mktemp -d "${TMPDIR:-/tmp}/mst-dist-$TAG.XXXXXX")
trap 'rm -rf "$WORK"' EXIT INT TERM
ASSETS=$WORK/assets
mkdir -p "$ASSETS"

if [ -n "$ASSETS_IN" ]; then
  [ -d "$ASSETS_IN" ] || die "Нет каталога с файлами релиза: $ASSETS_IN"
  cp "$ASSETS_IN"/* "$ASSETS/" || die "Не удалось скопировать файлы релиза из $ASSETS_IN"
  if [ -n "$NOTES_IN" ]; then cp "$NOTES_IN" "$WORK/notes.txt"; else : > "$WORK/notes.txt"; fi
else
  command -v gh >/dev/null 2>&1 || die "Не найден gh (GitHub CLI) - он нужен, чтобы скачать релиз $TAG"
  say "Скачиваю файлы релиза $TAG из $REPO..."
  gh release download "$TAG" --repo "$REPO" --dir "$ASSETS" || die "Не удалось скачать файлы релиза $TAG (gh release download)"
  gh release view "$TAG" --repo "$REPO" --json body --jq .body > "$WORK/notes.txt" || die "Не удалось получить текст релиза $TAG (gh release view)"
fi

# Сверка: зеркало должно отдавать ровно то, что описывает манифест релиза.
[ -f "$ASSETS/manifest.txt" ] || die "В файлах релиза нет manifest.txt"
m_tag=$(sed -n 's/^RELEASE_TAG=//p' "$ASSETS/manifest.txt" | head -n1)
[ "$m_tag" = "$TAG" ] || die "RELEASE_TAG манифеста ($m_tag) не совпадает с тегом $TAG"
file_count=0
while IFS='|' read -r kind _c base _dest size sum _mode _check; do
  [ "$kind" = FILE ] || continue
  [ -f "$ASSETS/$base" ] || die "Нет файла релиза $base"
  [ "$(wc -c < "$ASSETS/$base" | tr -d ' ')" = "$size" ] || die "$base - размер не совпадает с манифестом"
  [ "$(sha_of "$ASSETS/$base")" = "$sum" ] || die "$base - SHA256 не совпадает с манифестом"
  file_count=$((file_count + 1))
done < "$ASSETS/manifest.txt"
[ "$file_count" -gt 0 ] || die "В манифесте нет ни одной строки FILE"
[ -f "$ASSETS/install.sh" ] || [ "$CHANNEL" = dev ] || die "В стабильном релизе нет install.sh"
cp "$WORK/notes.txt" "$ASSETS/notes.txt"

git rev-parse --git-dir >/dev/null 2>&1 || die "Запускайте из git-репозитория проекта"
if git ls-remote --exit-code --tags "$REMOTE" "refs/tags/dist-$TAG" >/dev/null 2>&1; then
  die "Тег dist-$TAG уже есть в $REMOTE - релиз $TAG в зеркале уже опубликован"
fi
PARENT=""
ls_rc=0
git ls-remote --exit-code --heads "$REMOTE" "$BRANCH" >/dev/null 2>&1 || ls_rc=$?
case $ls_rc in
  0)
    git fetch -q "$REMOTE" "+refs/heads/$BRANCH:refs/remotes/$REMOTE/$BRANCH" || die "Не удалось получить ветку $BRANCH из $REMOTE"
    PARENT=$(git rev-parse "refs/remotes/$REMOTE/$BRANCH") ;;
  2) say "Ветки $BRANCH в $REMOTE ещё нет - создаю" ;;
  *) die "Не удалось обратиться к $REMOTE (git ls-remote)" ;;
esac

GIT_INDEX_FILE=$WORK/index
export GIT_INDEX_FILE
if [ -n "$PARENT" ]; then git read-tree "$PARENT"; else git read-tree --empty; fi

add_blob() { # add_blob FILE PATH MODE
  ab_sha=$(git hash-object -w "$1") || die "Не удалось записать $2 в git"
  git update-index --add --cacheinfo "$3,$ab_sha,$2" || die "Не удалось добавить $2 в дерево $BRANCH"
}
pointer_of() { # pointer_of CHANNEL -> тег из channels/<канал> текущего индекса
  po_sha=$(git ls-files -s "channels/$1" | awk '{print $2}')
  [ -z "$po_sha" ] || git cat-file blob "$po_sha" | head -n1
}

git rm -q -r --cached --ignore-unmatch "$TAG" >/dev/null
for f in "$ASSETS"/*; do add_blob "$f" "$TAG/${f##*/}" 100644; done

current=$(pointer_of "$CHANNEL")
if [ -z "$current" ] || ! ver_gt "$current" "$TAG"; then
  printf '%s\n' "$TAG" > "$WORK/pointer"
  add_blob "$WORK/pointer" "channels/$CHANNEL" 100644
  [ "$CHANNEL" = dev ] || add_blob "$ASSETS/install.sh" install.sh 100755
  POINTER_MOVED=1
else
  say "channels/$CHANNEL остаётся на $current (новее $TAG)"
  POINTER_MOVED=0
fi

# Обрезка: по каналу оставляем DIST_KEEP наибольших тегов и всегда - тег
# указателя канала.
keep_stable=$(pointer_of stable) keep_dev=$(pointer_of dev)
git ls-files | awk -F/ 'NF > 1 && $1 ~ /^[0-9]+\.[0-9]+\.[0-9]+$/ { print $1 }' | sort -u |
  awk -F. -v keep="$KEEP" -v ks="$keep_stable" -v kd="$keep_dev" '
    { ch = ($2 % 2 == 1) ? "dev" : "stable"; n[ch]++; t[ch, n[ch]] = $0 }
    END {
      for (c in n) {
        # сортировка вставками по убыванию версии
        for (i = 2; i <= n[c]; i++) {
          v = t[c, i]; j = i - 1
          while (j >= 1 && gt(v, t[c, j])) { t[c, j + 1] = t[c, j]; j-- }
          t[c, j + 1] = v
        }
        for (i = keep + 1; i <= n[c]; i++) if (t[c, i] != ks && t[c, i] != kd) print t[c, i]
      }
    }
    function gt(a, b,   x, y, k) {
      split(a, x, "."); split(b, y, ".")
      for (k = 1; k <= 3; k++) { if (x[k] + 0 > y[k] + 0) return 1; if (x[k] + 0 < y[k] + 0) return 0 }
      return 0
    }' > "$WORK/prune"
while read -r old; do
  git rm -q -r --cached "$old" >/dev/null
  say "Убираю из $BRANCH старый релиз $old (остаётся доступен по тегу dist-$old)"
done < "$WORK/prune"

TREE=$(git write-tree) || die "Не удалось собрать дерево $BRANCH"
COMMIT=$(git commit-tree "$TREE" ${PARENT:+-p "$PARENT"} -m "dist: $TAG ($CHANNEL)") || die "Не удалось создать коммит $BRANCH (проверьте git config user.name/user.email)"

say "Пушу $BRANCH и тег dist-$TAG в $REMOTE..."
git push -q --atomic "$REMOTE" "$COMMIT:refs/heads/$BRANCH" "$COMMIT:refs/tags/dist-$TAG" ||
  die "Не удалось запушить $BRANCH/dist-$TAG - повторите: sh release/publish_dist.sh $TAG"

CDN=https://cdn.jsdelivr.net/gh/$REPO
if [ "$POINTER_MOVED" = 1 ] && [ "${DIST_PURGE:-1}" != 0 ]; then
  purge_paths="channels/$CHANNEL"
  [ "$CHANNEL" = dev ] || purge_paths="$purge_paths install.sh"
  for p in $purge_paths; do
    if curl -fsS -m 30 -o /dev/null "https://purge.jsdelivr.net/gh/$REPO@$BRANCH/$p" 2>/dev/null; then
      say "Кэш jsDelivr сброшен: @$BRANCH/$p"
    else
      say "WARN: не удалось сбросить кэш jsDelivr для @$BRANCH/$p - зеркало подхватит $TAG в течение 12 ч; вручную: curl https://purge.jsdelivr.net/gh/$REPO@$BRANCH/$p"
    fi
  done
fi
say "Готово. Проверка: curl -s $CDN@dist-$TAG/$TAG/manifest.txt | head -6"
