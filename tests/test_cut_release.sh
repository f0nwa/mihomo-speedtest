#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
SCRIPT=$ROOT/release/cut_release.sh
TMP=$(mktemp -d "${TMPDIR:-/tmp}/cut-release-test.XXXXXX")
trap 'rm -rf "$TMP"' EXIT INT TERM

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_contains() {
  case "$2" in
    *"$1"*) ;;
    *) fail "ожидалось найти: $1 (контекст: $3)" ;;
  esac
}

sh -n "$SCRIPT" || fail "cut_release.sh не проходит sh -n"

mkdir -p "$TMP/bin"
# gh: список тегов из $GH_TAGS; release create пишет аргументы в $GH_CREATE_ARGS.
cat > "$TMP/bin/gh" <<'EOF2'
#!/bin/sh
case "$*" in
  "release list"*"--limit 1000"*) cat "$GH_TAGS" ;;
  "release create"*) printf '%s\n' "$*" > "$GH_CREATE_ARGS" ;;
  *) echo "gh stub: неожиданные аргументы: $*" >&2; exit 1 ;;
esac
EOF2
# curl: releases/latest -> $MANIFEST_LATEST, releases/download/<тег> ->
# $MANIFEST_DIR/<тег>; каждый URL дописывается в $CURL_LOG.
cat > "$TMP/bin/curl" <<'EOF2'
#!/bin/sh
for a in "$@"; do url=$a; done
printf '%s\n' "$url" >> "$CURL_LOG"
case "$url" in
  */releases/latest/download/manifest.txt) cat "$MANIFEST_LATEST" ;;
  */releases/download/*/manifest.txt)
    tag=${url%/manifest.txt}; tag=${tag##*/}
    [ -f "$MANIFEST_DIR/$tag" ] || { echo "curl stub: нет манифеста $tag" >&2; exit 22; }
    cat "$MANIFEST_DIR/$tag" ;;
  *) echo "curl stub: неожиданный URL: $url" >&2; exit 22 ;;
esac
EOF2
# git: rev-parse HEAD -> $GIT_HEAD, rev-parse @{u} -> $GIT_UPSTREAM (пусто - нет upstream).
cat > "$TMP/bin/git" <<'EOF2'
#!/bin/sh
case "$*" in
  "rev-parse HEAD") printf '%s\n' "$GIT_HEAD" ;;
  "rev-parse @{u}") [ -n "$GIT_UPSTREAM" ] || { echo "fatal: no upstream" >&2; exit 128; }; printf '%s\n' "$GIT_UPSTREAM" ;;
  *) echo "git stub: неожиданные аргументы: $*" >&2; exit 1 ;;
esac
EOF2
chmod +x "$TMP/bin/gh" "$TMP/bin/curl" "$TMP/bin/git"
mkdir -p "$TMP/manifests"
GH_CREATE_ARGS=$TMP/create.args
GH_TAGS=$TMP/tags.txt
MANIFEST_LATEST=$TMP/latest.txt
MANIFEST_DIR=$TMP/manifests
CURL_LOG=$TMP/curl.log
GIT_HEAD=0123456789abcdef0123456789abcdef01234567
GIT_UPSTREAM=$GIT_HEAD
export GH_CREATE_ARGS GH_TAGS MANIFEST_LATEST MANIFEST_DIR CURL_LOG GIT_HEAD GIT_UPSTREAM
printf '1.0.0\n1.1.0\n1.1.1\nv26\n' > "$GH_TAGS"
# Стабильный (latest) старше dev 1.1.1.
printf 'RELEASE_VERSION=30\nMIN_UPDATER_VERSION=3\nCONFIG_SCHEMA_VERSION=1\n' > "$MANIFEST_LATEST"
printf 'RELEASE_VERSION=31\nMIN_UPDATER_VERSION=4\nCONFIG_SCHEMA_VERSION=2\n' > "$MANIFEST_DIR/1.1.1"
run() { PATH="$TMP/bin:$PATH" sh "$SCRIPT" notes "$@"; }

out=$(run --channel dev --dry-run 2>/dev/null) || fail "dev dry-run завершился с ошибкой"
assert_contains "CHANNEL=dev" "$out" dev
assert_contains "TAG=1.1.2" "$out" dev
assert_contains "RELEASE_VERSION=32" "$out" dev
assert_contains "MIN_UPDATER_VERSION=4" "$out" dev
assert_contains "CONFIG_SCHEMA_VERSION=2" "$out" dev
assert_contains "PRERELEASE=1" "$out" dev

out=$(run --channel stable --promote --dry-run 2>/dev/null) || fail "promote dry-run завершился с ошибкой"
assert_contains "TAG=1.2.0" "$out" promote
assert_contains "PRERELEASE=0" "$out" promote

out=$(run --channel stable --dry-run 2>/dev/null) || fail "stable dry-run завершился с ошибкой"
assert_contains "TAG=1.0.1" "$out" stable

out=$(run --channel stable --major --dry-run 2>/dev/null) || fail "major dry-run завершился с ошибкой"
assert_contains "TAG=2.0.0" "$out" major

out=$(run --channel dev --tag 1.3.0 --release-version 40 --dry-run 2>/dev/null) || fail "override dry-run завершился с ошибкой"
assert_contains "TAG=1.3.0" "$out" override
assert_contains "RELEASE_VERSION=40" "$out" override

# Манифест наибольшего dev-тега читается по releases/download/1.1.1, а не 1.1.0.
: > "$CURL_LOG"
run --channel dev --dry-run >/dev/null 2>&1 || fail "dev dry-run (лог curl) завершился с ошибкой"
grep -q '/releases/download/1.1.1/manifest.txt$' "$CURL_LOG" || fail "не прочитан манифест наибольшего dev-тега: $(cat "$CURL_LOG")"
grep -q '/releases/latest/download/manifest.txt$' "$CURL_LOG" || fail "не прочитан манифест releases/latest: $(cat "$CURL_LOG")"

# Стабильный новее dev: побеждает его RELEASE_VERSION и его MIN_UPDATER/CONFIG_SCHEMA.
printf 'RELEASE_VERSION=35\nMIN_UPDATER_VERSION=5\nCONFIG_SCHEMA_VERSION=3\n' > "$MANIFEST_LATEST"
out=$(run --channel dev --dry-run 2>/dev/null) || fail "dry-run (stable новее) завершился с ошибкой"
assert_contains "RELEASE_VERSION=36" "$out" stable-newer
assert_contains "MIN_UPDATER_VERSION=5" "$out" stable-newer
assert_contains "CONFIG_SCHEMA_VERSION=3" "$out" stable-newer

# Без dev-тегов x.y.z манифест dev не запрашивается.
printf '1.0.0\nv26\n' > "$GH_TAGS"
: > "$CURL_LOG"
out=$(run --channel stable --dry-run 2>/dev/null) || fail "dry-run без dev-тегов завершился с ошибкой"
assert_contains "RELEASE_VERSION=36" "$out" no-dev
if grep -q '/releases/download/' "$CURL_LOG"; then fail "без dev-тегов запрошен dev-манифест: $(cat "$CURL_LOG")"; fi
printf '1.0.0\n1.1.0\n1.1.1\nv26\n' > "$GH_TAGS"
printf 'RELEASE_VERSION=30\nMIN_UPDATER_VERSION=3\nCONFIG_SCHEMA_VERSION=1\n' > "$MANIFEST_LATEST"

if run --channel beta --dry-run >/dev/null 2>&1; then
  fail "неизвестный канал должен давать ненулевой код"
fi

# Без --dry-run: gh release create получает --prerelease и тег.
rm -f "$GH_CREATE_ARGS"
run --channel dev >/dev/null 2>&1 || fail "dev публикация завершилась с ошибкой"
[ -f "$GH_CREATE_ARGS" ] || fail "gh release create не вызван"
args=$(cat "$GH_CREATE_ARGS")
assert_contains "--prerelease" "$args" create
assert_contains "1.1.2" "$args" create
assert_contains "--target $GIT_HEAD" "$args" create

rm -f "$GH_CREATE_ARGS"
run --channel stable >/dev/null 2>&1 || fail "stable публикация завершилась с ошибкой"
args=$(cat "$GH_CREATE_ARGS")
case "$args" in *--prerelease*) fail "stable не должен быть --prerelease" ;; esac
assert_contains "--target $GIT_HEAD" "$args" stable-create

# HEAD не запушен -> отказ до публикации.
rm -f "$GH_CREATE_ARGS"
if GIT_UPSTREAM=fedcba9876543210fedcba9876543210fedcba98 run --channel dev >/dev/null 2>"$TMP/err"; then
  fail "незапушенный HEAD должен давать ненулевой код"
fi
grep -q 'не запушен' "$TMP/err" || fail "нет сообщения о незапушенном HEAD: $(cat "$TMP/err")"
[ ! -f "$GH_CREATE_ARGS" ] || fail "gh release create вызван при незапушенном HEAD"

# Нет upstream -> отказ.
if GIT_UPSTREAM= run --channel dev >/dev/null 2>"$TMP/err"; then
  fail "ветка без upstream должна давать ненулевой код"
fi
grep -q 'upstream' "$TMP/err" || fail "нет сообщения об upstream: $(cat "$TMP/err")"
[ ! -f "$GH_CREATE_ARGS" ] || fail "gh release create вызван без upstream"

# --dry-run не требует запушенного HEAD.
GIT_UPSTREAM= run --channel dev --dry-run >/dev/null 2>&1 || fail "dry-run не должен проверять upstream"

echo "OK: test_cut_release"
