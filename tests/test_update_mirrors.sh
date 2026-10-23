#!/bin/sh
# Зеркала релизов в updater/update.sh (select_source): GitHub недоступен ->
# указатели каналов и файлы релиза берутся из ветки dist через jsDelivr.
# Транспорт подменён: URL https://<путь> отдаётся из $TMP/www/<путь>,
# нет файла - ошибка (код 22); каждый URL пишется в $TMP/urls.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
SCRIPT=$ROOT/updater/update.sh
TMP=$(mktemp -d "${TMPDIR:-/tmp}/update-mirrors-test.XXXXXX")
trap 'rm -rf "$TMP"' EXIT INT TERM

fail() { echo "FAIL: $*" >&2; exit 1; }

GH=https://gh.test/o/r/releases
M1=https://m1.test/gh/o/r
M2=https://m2.test/gh/o/r
W=$TMP/www
mkdir -p "$TMP/tmp" "$W"

cat > "$TMP/fake_http.sh" <<EOF
#!/bin/sh
printf '%s\n' "\$1" >> '$TMP/urls'
f='$W'/\${1#https://}
# Файл-метка <файл>.fail35 - обрыв TLS (код curl 35), как у GitHub с роутера.
[ ! -f "\$f.fail35" ] || exit 35
[ -f "\$f" ] || exit 22
cat "\$f"
EOF
chmod +x "$TMP/fake_http.sh"

put() { mkdir -p "$(dirname "$W/${1#https://}")"; cat > "$W/${1#https://}"; }
manifest() { sh "$ROOT/release/generate_manifest.sh" "$1" 4 2 "$2"; }
# mirror_release ROOT TAG VERSION: манифест и файлы релиза в зеркале.
mirror_release() {
  manifest "$3" "$2" | put "$1@dist-$2/$2/manifest.txt"
  awk -F'|' '$1=="FILE" {print $3}' "$ROOT/release/components.txt" | while read -r p; do
    put "$1@dist-$2/$2/${p##*/}" < "$ROOT/$p"
  done
}

# run CMD [ARGS...] -- <env-assignments...>
run() {
  args=
  while [ $# -gt 0 ] && [ "$1" != -- ]; do args="$args $1"; shift; done
  [ $# -eq 0 ] || shift
  : > "$TMP/urls"
  rc=0
  # shellcheck disable=SC2086
  env TMPROOT="$TMP/tmp" UPDATE_HTTP_CMD="$TMP/fake_http.sh" \
    UPDATE_RELEASE_BASE=$GH/latest/download UPDATE_RELEASES_API=https://api.gh.test/releases \
    UPDATE_RELEASES_FALLBACK=$GH UPDATE_MIRRORS="$M1 $M2" UPDATE_NETCHECK=0 UPDATE_RETRY_DELAY=0 \
    UPDATE_ENV_FILE="$TMP/no-such.env" INSTALLED_MANIFEST_PATH="$TMP/no-installed" \
    "$@" sh "$SCRIPT" $args > "$TMP/out" 2> "$TMP/err" || rc=$?
}
expect_version() {
  [ "$rc" = 0 ] || fail "$1: код $rc, stderr: $(cat "$TMP/err")"
  grep -Fq "Доступна версия релиза: $2 " "$TMP/out" || fail "$1: нет версии $2: $(cat "$TMP/out")"
}
asked() { grep -Fq "$1" "$TMP/urls"; }

# 1. GitHub доступен - зеркала не трогаются, манифест качается один раз.
manifest 3 1.0.0 | put "$GH/latest/download/manifest.txt"
run --check
expect_version 'GitHub доступен' 1.0.0
if asked m1.test; then fail 'при доступном GitHub запрошено зеркало'; fi
[ "$(grep -c 'manifest.txt$' "$TMP/urls")" = 1 ] || fail "манифест скачан не один раз: $(cat "$TMP/urls")"

# 2. GitHub недоступен: m1 не отвечает, m2 отдаёт stable.
rm -rf "$W/gh.test"
echo 1.2.0 | put "$M2@dist/channels/stable"
mirror_release "$M2" 1.2.0 7
run --check
expect_version 'stable через зеркало' 1.2.0
grep -Fq 'зеркало m2.test (релиз 1.2.0)' "$TMP/err" || fail "нет сообщения о зеркале: $(cat "$TMP/err")"
asked "$M1@dist/channels/stable" || fail 'не опрошено первое зеркало'
asked "$M2@dist-1.2.0/1.2.0/manifest.txt" || fail 'манифест не из закреплённой версии зеркала'

# 3. Канал dev, GitHub (API и страница релизов) недоступен: наибольший из
# channels/dev и channels/stable.
echo 1.1.0 | put "$M2@dist/channels/dev"
mirror_release "$M2" 1.1.0 6
run --check -- UPDATE_CHANNEL=dev
expect_version 'dev через зеркало: stable новее' 1.2.0
asked https://api.gh.test/releases || fail 'dev не попробовал API GitHub'
echo 1.3.0 | put "$M2@dist/channels/dev"
mirror_release "$M2" 1.3.0 8
run --check -- UPDATE_CHANNEL=dev
expect_version 'dev через зеркало' 1.3.0

# 4. Манифест зеркала с чужим RELEASE_TAG - зеркало пропускается.
manifest 7 1.2.9 | put "$M2@dist-1.2.0/1.2.0/manifest.txt"
run --check
[ "$rc" != 0 ] || fail 'манифест с чужим тегом принят'
mirror_release "$M2" 1.2.0 7

# 5. Всё недоступно.
mv "$W/m2.test" "$TMP/m2.off"
run --check
[ "$rc" != 0 ] || fail 'stable без источников завершился успешно'
grep -Fq 'Не удалось скачать файл обновления' "$TMP/err" || fail "stable без источников: $(cat "$TMP/err")"
run --check -- UPDATE_CHANNEL=dev
[ "$rc" != 0 ] || fail 'dev без источников завершился успешно'
grep -Fq 'GitHub и зеркала недоступны' "$TMP/err" || fail "dev без источников: $(cat "$TMP/err")"
mv "$TMP/m2.off" "$W/m2.test"

# 6. Пустой UPDATE_MIRRORS отключает зеркала; в speedtest2.env - тоже.
run --check -- UPDATE_MIRRORS=
[ "$rc" != 0 ] || fail 'пустой UPDATE_MIRRORS: зеркало использовано'
if asked m2.test; then fail 'пустой UPDATE_MIRRORS: зеркало запрошено'; fi
printf 'UPDATE_MIRRORS=""\n' > "$TMP/speedtest2.env"
: > "$TMP/urls"; rc=0
env TMPROOT="$TMP/tmp" UPDATE_HTTP_CMD="$TMP/fake_http.sh" UPDATE_RELEASE_BASE=$GH/latest/download \
  UPDATE_ENV_FILE="$TMP/speedtest2.env" INSTALLED_MANIFEST_PATH="$TMP/no-installed" UPDATE_NETCHECK=0 \
  sh "$SCRIPT" --check > "$TMP/out" 2> "$TMP/err" || rc=$?
[ "$rc" != 0 ] || fail 'UPDATE_MIRRORS="" в env-файле: зеркало использовано'
if asked m2.test; then fail 'UPDATE_MIRRORS="" в env-файле: зеркало запрошено'; fi
# Зеркала из env-файла.
printf 'UPDATE_MIRRORS="%s"\n' "$M2" > "$TMP/speedtest2.env"
: > "$TMP/urls"; rc=0
env TMPROOT="$TMP/tmp" UPDATE_HTTP_CMD="$TMP/fake_http.sh" UPDATE_RELEASE_BASE=$GH/latest/download \
  UPDATE_ENV_FILE="$TMP/speedtest2.env" INSTALLED_MANIFEST_PATH="$TMP/no-installed" UPDATE_NETCHECK=0 \
  sh "$SCRIPT" --check > "$TMP/out" 2> "$TMP/err" || rc=$?
expect_version 'зеркала из env-файла' 1.2.0
# Свой UPDATE_RELEASE_BASE без настройки - зеркал по умолчанию нет.
: > "$TMP/urls"; rc=0
env TMPROOT="$TMP/tmp" UPDATE_HTTP_CMD="$TMP/fake_http.sh" UPDATE_RELEASE_BASE=$GH/latest/download \
  UPDATE_ENV_FILE="$TMP/no-such.env" INSTALLED_MANIFEST_PATH="$TMP/no-installed" UPDATE_NETCHECK=0 \
  sh "$SCRIPT" --check > "$TMP/out" 2> "$TMP/err" || rc=$?
[ "$rc" != 0 ] || fail 'свой источник без зеркал завершился успешно'
if asked jsdelivr; then fail 'свой источник: запрошены зеркала по умолчанию'; fi

# 7. "@" в адресе источника допустим только как зеркало в пути.
for bad in 'https://u@gh.test/o/r/releases/latest/download' 'https://gh.test/o/r@x/releases/latest/download'; do
  run --check -- UPDATE_RELEASE_BASE="$bad"
  [ "$rc" != 0 ] && grep -Fq 'Неверный URL источника' "$TMP/err" || fail "принят источник $bad"
done
run --check -- UPDATE_RELEASE_BASE="$M2@dist-1.2.0/1.2.0" UPDATE_MIRRORS=
expect_version 'закреплённое зеркало' 1.2.0
run --check -- UPDATE_RELEASE_BASE="$M2@dist-1.3.0/1.2.0" UPDATE_MIRRORS=
[ "$rc" != 0 ] || fail 'зеркало с разными тегами принято'

# 8. Подготовка обновления через зеркало: движок и файлы - из закреплённой
# версии зеркала.
mkdir -p "$TMP/target/opt/etc/mihomo-speedtest" "$TMP/target/opt/etc/mihomo"
run --prepare --components=updater --format=json -- UPDATE_STATE_DIR="$TMP/state" UPDATE_TARGET_ROOT="$TMP/target"
[ "$rc" = 0 ] || fail "prepare через зеркало: код $rc, stderr: $(cat "$TMP/err")"
asked "$M2@dist-1.2.0/1.2.0/update_prepare.sh" || fail "движок не из зеркала: $(cat "$TMP/urls")"
if grep -v '^https://m[12].test/' "$TMP/urls" | grep -v '^https://gh.test/o/r/releases/latest/download/manifest.txt$' | grep -q .; then
  fail "prepare: лишние адреса: $(cat "$TMP/urls")"
fi
grep -q '"plan_id"' "$TMP/out" || fail "prepare: нет плана: $(cat "$TMP/out")"
plan_id=$(sed -n 's/.*"plan_id":"\([0-9a-f]*\)".*/\1/p' "$TMP/out" | head -n 1)
[ "${#plan_id}" = 64 ] || fail "prepare: не разобран plan_id: $(cat "$TMP/out")"
# Проверка плана (перед применением) - тоже через зеркало.
run --verify-plan "$plan_id" --format=json -- UPDATE_STATE_DIR="$TMP/state" UPDATE_TARGET_ROOT="$TMP/target"
[ "$rc" = 0 ] || fail "verify-plan через зеркало: код $rc, stderr: $(cat "$TMP/err")"
asked "$M2@dist-1.2.0/1.2.0/manifest.txt" || fail "verify-plan: манифест не из зеркала: $(cat "$TMP/urls")"

# 9. GitHub отдал манифест, но рвёт загрузку файла (код 35): после
# повторов файл берётся с зеркала того же релиза; подготовка проходит.
manifest 7 1.2.0 | put "$GH/latest/download/manifest.txt"
awk -F'|' '$1=="FILE" {print $3}' "$ROOT/release/components.txt" | while read -r p; do
  put "$GH/download/1.2.0/${p##*/}" < "$ROOT/$p"
done
touch "$W/gh.test/o/r/releases/download/1.2.0/update_plan.awk.fail35"
rm -rf "$TMP/state" "$TMP/tmp/mst-update-plans"
run --prepare --components=updater --format=json -- UPDATE_STATE_DIR="$TMP/state" UPDATE_TARGET_ROOT="$TMP/target"
[ "$rc" = 0 ] || fail "обрыв файла на GitHub: код $rc, stderr: $(cat "$TMP/err")"
grep -Fq 'Файл update_plan.awk: основной источник не отдал файл - взят с зеркала m2.test' "$TMP/err" || fail "нет сообщения о зеркале для файла: $(cat "$TMP/err")"
if grep -Fq 'GitHub недоступен' "$TMP/err"; then fail 'манифест должен был остаться с GitHub'; fi
[ "$(grep -c '^https://gh.test/o/r/releases/download/1.2.0/update_plan.awk$' "$TMP/urls")" -ge 3 ] || fail "нет повторов при обрыве: $(cat "$TMP/urls")"
asked "$GH/download/1.2.0/update.sh" || fail 'остальные файлы должны идти с GitHub'
# Обрыв без зеркал - прежняя ошибка с адресом GitHub.
rm -rf "$TMP/state" "$TMP/tmp/mst-update-plans"
run --prepare --components=updater --format=json -- UPDATE_STATE_DIR="$TMP/state" UPDATE_TARGET_ROOT="$TMP/target" UPDATE_MIRRORS=
[ "$rc" != 0 ] || fail 'обрыв без зеркал завершился успешно'
grep -Fq 'Адрес: https://gh.test/o/r/releases/download/1.2.0/update_plan.awk' "$TMP/err" || fail "нет адреса в ошибке: $(cat "$TMP/err")"

echo 'test_update_mirrors.sh: OK' >&2
