#!/bin/sh
# release/publish_dist.sh на настоящем git с локальным bare-репозиторием
# вместо GitHub; gh и curl (purge jsDelivr) подменяются через PATH.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/publish-dist-test.XXXXXX")
trap 'rm -rf "$TMP"' EXIT INT TERM

fail() { echo "FAIL: $*" >&2; exit 1; }
sum256() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }

sh -n "$ROOT/release/publish_dist.sh" || fail "publish_dist.sh не проходит sh -n"

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
git init -q --bare "$TMP/remote.git"
git init -q "$TMP/repo"
mkdir -p "$TMP/repo/release"
cp "$ROOT/release/publish_dist.sh" "$TMP/repo/release/"
( cd "$TMP/repo" && git remote add origin "$TMP/remote.git" )
SCRIPT=$TMP/repo/release/publish_dist.sh

mkdir -p "$TMP/bin"
cat > "$TMP/bin/curl" <<'EOF2'
#!/bin/sh
for a in "$@"; do url=$a; done
printf '%s\n' "$url" >> "$CURL_LOG"
EOF2
# gh: release download копирует $GH_ASSETS/<тег>, release view печатает текст.
cat > "$TMP/bin/gh" <<'EOF2'
#!/bin/sh
case "$*" in
  "release download "*) tag=$3; shift 3
    while [ $# -gt 0 ]; do [ "$1" = --dir ] && dir=$2; shift; done
    cp "$GH_ASSETS/$tag"/* "$dir/" ;;
  "release view "*) echo "Текст релиза $3" ;;
  *) echo "gh stub: $*" >&2; exit 1 ;;
esac
EOF2
chmod +x "$TMP/bin/curl" "$TMP/bin/gh"
CURL_LOG=$TMP/curl.log GH_ASSETS=$TMP/gh
export CURL_LOG GH_ASSETS
: > "$CURL_LOG"

# make_assets DIR TAG: файлы релиза с корректным манифестом.
make_assets() {
  mkdir -p "$1"
  printf '#!/bin/sh\necho install %s\n' "$2" > "$1/install.sh"
  printf 'echo update %s\n' "$2" > "$1/update.sh"
  {
    printf 'FORMAT_VERSION=2\nRELEASE_VERSION=1\nRELEASE_TAG=%s\nMIN_UPDATER_VERSION=1\nCONFIG_SCHEMA_VERSION=1\n' "$2"
    for f in install.sh update.sh; do
      printf 'FILE|installer|%s|/opt/etc/mihomo-speedtest/%s|%s|%s|0755|sh\n' "$f" "$f" "$(wc -c < "$1/$f" | tr -d ' ')" "$(sum256 "$1/$f")"
    done
  } > "$1/manifest.txt"
  ( cd "$1" && for f in *; do printf '%s  %s\n' "$(sum256 "$f")" "$f"; done > SHA256SUMS.tmp && mv SHA256SUMS.tmp SHA256SUMS )
}
run() { ( cd "$TMP/repo" && PATH="$TMP/bin:$PATH" sh "$SCRIPT" "$@" ); }
show() { git --git-dir="$TMP/remote.git" show "$1"; }
files() { git --git-dir="$TMP/remote.git" ls-tree -r --name-only "$1"; }

# Первый стабильный: ветки ещё нет.
make_assets "$TMP/a/1.0.0" 1.0.0
echo "Заметки 1.0.0" > "$TMP/notes"
run 1.0.0 --assets "$TMP/a/1.0.0" --notes-file "$TMP/notes" 2>"$TMP/err" || fail "1.0.0: $(cat "$TMP/err")"
[ "$(show dist:channels/stable)" = 1.0.0 ] || fail "channels/stable не 1.0.0"
[ "$(show dist:1.0.0/notes.txt)" = "Заметки 1.0.0" ] || fail "нет notes.txt"
show dist:1.0.0/manifest.txt | grep -q '^RELEASE_TAG=1.0.0$' || fail "нет манифеста 1.0.0"
show dist:install.sh | grep -q 'install 1.0.0' || fail "корневой install.sh не из 1.0.0"
git --git-dir="$TMP/remote.git" ls-tree dist install.sh | grep -q '^100755' || fail "install.sh без исполняемого бита"
[ "$(git --git-dir="$TMP/remote.git" rev-parse dist-1.0.0)" = "$(git --git-dir="$TMP/remote.git" rev-parse dist)" ] || fail "тег dist-1.0.0 не на коммите dist"
grep -q 'purge.jsdelivr.net/gh/f0nwa/mihomo-speedtest@dist/channels/stable$' "$CURL_LOG" || fail "не сброшен кэш channels/stable: $(cat "$CURL_LOG")"
grep -q '@dist/install.sh$' "$CURL_LOG" || fail "не сброшен кэш install.sh"
# Рабочее дерево и HEAD репозитория не тронуты.
[ -z "$(cd "$TMP/repo" && git status --porcelain --untracked-files=no)" ] || fail "изменён индекс рабочего репозитория"

# dev-релиз: канал по нечётному minor, стабильный указатель и install.sh не меняются.
make_assets "$TMP/a/1.1.0" 1.1.0
: > "$CURL_LOG"
run 1.1.0 --assets "$TMP/a/1.1.0" 2>"$TMP/err" || fail "1.1.0: $(cat "$TMP/err")"
[ "$(show dist:channels/dev)" = 1.1.0 ] || fail "channels/dev не 1.1.0"
[ "$(show dist:channels/stable)" = 1.0.0 ] || fail "dev сдвинул channels/stable"
show dist:install.sh | grep -q 'install 1.0.0' || fail "dev заменил корневой install.sh"
files dist | grep -q '^1.0.0/manifest.txt$' || fail "пропал 1.0.0"
grep -q '@dist/install.sh$' "$CURL_LOG" && fail "dev сбрасывает кэш install.sh"
git --git-dir="$TMP/remote.git" merge-base --is-ancestor dist-1.0.0 dist || fail "dist не продолжает историю"

# Повтор того же тега - отказ.
if run 1.1.0 --assets "$TMP/a/1.1.0" 2>"$TMP/err"; then fail "повторная публикация 1.1.0 прошла"; fi
grep -q 'уже опубликован' "$TMP/err" || fail "нет сообщения о повторе: $(cat "$TMP/err")"

# Обрезка: DIST_KEEP=2 по каналу.
for t in 1.0.1 1.0.2; do
  make_assets "$TMP/a/$t" "$t"
  DIST_KEEP=2 run "$t" --assets "$TMP/a/$t" 2>"$TMP/err" || fail "$t: $(cat "$TMP/err")"
done
[ "$(show dist:channels/stable)" = 1.0.2 ] || fail "channels/stable не 1.0.2"
files dist | grep -q '^1.0.0/' && fail "1.0.0 не убран обрезкой"
files dist | grep -q '^1.0.1/' || fail "1.0.1 убран лишний"
files dist | grep -q '^1.1.0/' || fail "dev 1.1.0 убран обрезкой стабильного канала"
files dist-1.0.0 | grep -q '^1.0.0/manifest.txt$' || fail "тег dist-1.0.0 потерял файлы"

# Старый тег не откатывает указатель.
make_assets "$TMP/a/0.8.0" 0.8.0
DIST_KEEP=2 run 0.8.0 --assets "$TMP/a/0.8.0" 2>"$TMP/err" || fail "0.8.0: $(cat "$TMP/err")"
[ "$(show dist:channels/stable)" = 1.0.2 ] || fail "старый тег откатил channels/stable"
show dist:install.sh | grep -q 'install 1.0.2' || fail "старый тег заменил install.sh"

# Порча файла - отказ до пуша.
make_assets "$TMP/a/1.2.0" 1.2.0
echo x >> "$TMP/a/1.2.0/update.sh"
if run 1.2.0 --assets "$TMP/a/1.2.0" 2>"$TMP/err"; then fail "испорченный файл прошёл"; fi
grep -q 'update.sh - размер' "$TMP/err" || fail "нет сообщения о размере: $(cat "$TMP/err")"
files dist | grep -q '^1.2.0/' && fail "испорченный релиз попал в dist"

# Тег манифеста не совпадает.
make_assets "$TMP/a/1.2.0" 1.2.1
if run 1.2.0 --assets "$TMP/a/1.2.0" 2>"$TMP/err"; then fail "чужой манифест прошёл"; fi
grep -q 'RELEASE_TAG' "$TMP/err" || fail "нет сообщения о RELEASE_TAG"

# Не x.y.z - отказ.
if run v26 --assets "$TMP/a/1.0.0" 2>/dev/null; then fail "тег v26 принят"; fi

# Без --assets: файлы и текст из gh.
make_assets "$TMP/gh/1.3.0" 1.3.0
run 1.3.0 2>"$TMP/err" || fail "1.3.0 через gh: $(cat "$TMP/err")"
[ "$(show dist:channels/dev)" = 1.3.0 ] || fail "channels/dev не 1.3.0"
[ "$(show dist:1.3.0/notes.txt)" = "Текст релиза 1.3.0" ] || fail "notes.txt не из gh release view"

echo "OK: test_publish_dist"
