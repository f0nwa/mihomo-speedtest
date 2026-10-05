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

# --- Схема конфига растёт сама, если в прошлом релизе другие sha256 файлов
# шаблона (config.example.yaml, migrate_config.awk, fast_wg.awk).
sum256() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }
SUM_EX=$(sum256 "$ROOT/config-tools/config.example.yaml")
SUM_MIG=$(sum256 "$ROOT/config-tools/migrate_config.awk")
SUM_WG=$(sum256 "$ROOT/config-tools/fast_wg.awk")
ZERO=0000000000000000000000000000000000000000000000000000000000000000
# schema_manifest EX MIG WG: манифест (latest новее dev) с FILE-строками; "-" - строки нет.
schema_manifest() {
  printf 'RELEASE_VERSION=50\nMIN_UPDATER_VERSION=5\nCONFIG_SCHEMA_VERSION=3\n'
  [ "$1" = - ] || printf 'FILE|config-tools|config.example.yaml|/opt/etc/mihomo-speedtest/config.example.yaml|1|%s|0644|none\n' "$1"
  [ "$2" = - ] || printf 'FILE|config-tools|migrate_config.awk|/opt/etc/mihomo-speedtest/migrate_config.awk|1|%s|0644|awk\n' "$2"
  [ "$3" = - ] || printf 'FILE|config-tools|fast_wg.awk|/opt/etc/mihomo-speedtest/fast_wg.awk|1|%s|0644|awk\n' "$3"
}

schema_manifest "$SUM_EX" "$SUM_MIG" "$SUM_WG" > "$MANIFEST_LATEST"
out=$(run --channel dev --dry-run 2>/dev/null) || fail "schema-same: dry-run завершился с ошибкой"
assert_contains "CONFIG_SCHEMA_VERSION=3" "$out" schema-same
assert_contains "CONFIG_SCHEMA_BUMPED=0" "$out" schema-same

schema_manifest "$SUM_EX" "$SUM_MIG" "$ZERO" > "$MANIFEST_LATEST"
out=$(run --channel dev --dry-run 2>"$TMP/err") || fail "schema-bump: dry-run завершился с ошибкой"
assert_contains "CONFIG_SCHEMA_VERSION=4" "$out" schema-bump
assert_contains "CONFIG_SCHEMA_BUMPED=1" "$out" schema-bump
assert_contains "шаблон конфига изменился (fast_wg.awk) - схема 3 -> 4" "$(cat "$TMP/err")" schema-bump-msg

out=$(run --channel dev --config-schema 7 --dry-run 2>/dev/null) || fail "schema-explicit: dry-run завершился с ошибкой"
assert_contains "CONFIG_SCHEMA_VERSION=7" "$out" schema-explicit
assert_contains "CONFIG_SCHEMA_BUMPED=0" "$out" schema-explicit

schema_manifest - "$SUM_MIG" "$SUM_WG" > "$MANIFEST_LATEST"
out=$(run --channel dev --dry-run 2>/dev/null) || fail "schema-missing-file: dry-run завершился с ошибкой"
assert_contains "CONFIG_SCHEMA_VERSION=4" "$out" schema-missing-file
assert_contains "CONFIG_SCHEMA_BUMPED=1" "$out" schema-missing-file

schema_manifest - - - > "$MANIFEST_LATEST"
out=$(run --channel dev --dry-run 2>"$TMP/err") || fail "schema-no-files: dry-run завершился с ошибкой"
assert_contains "CONFIG_SCHEMA_VERSION=3" "$out" schema-no-files
assert_contains "CONFIG_SCHEMA_BUMPED=0" "$out" schema-no-files
assert_contains "WARN" "$(cat "$TMP/err")" schema-no-files-warn
assert_contains "не с чем сравнить шаблон" "$(cat "$TMP/err")" schema-no-files-warn
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

# Шаблон должен совпадать со сборкой из services.default.tsv.
grep -q check_services_template "$SCRIPT" || fail "в cut_release.sh нет check_services_template"
mkdir -p "$TMP/ct"
cp "$ROOT/config-tools/render_services.awk" "$ROOT/config-tools/services.default.tsv" "$TMP/ct/"
sed 's/^  - name: YouTube$/  - name: YouTubeX/' "$ROOT/config-tools/config.example.yaml" > "$TMP/ct/config.example.yaml"
if CONFIG_TOOLS_DIR="$TMP/ct" run --channel dev --dry-run >/dev/null 2>"$TMP/err"; then
  fail "рассинхрон шаблона и services.default.tsv должен давать ненулевой код"
fi
grep -q 'services.default.tsv' "$TMP/err" || fail "нет сообщения о рассинхроне шаблона: $(cat "$TMP/err")"

echo "OK: test_cut_release"
