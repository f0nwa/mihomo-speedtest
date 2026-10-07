#!/bin/sh
# Канал обновлений dev в updater/update.sh: выбор канала (окружение /
# speedtest2.env), запрос последнего релиза через API, закрепление базы и
# сверка RELEASE_TAG манифеста с найденным тегом.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
SCRIPT=$ROOT/updater/update.sh
TMP=$(mktemp -d "${TMPDIR:-/tmp}/update-channel-test.XXXXXX")
trap 'rm -rf "$TMP"' EXIT INT TERM

fail() { echo "FAIL: $*" >&2; exit 1; }

STABLE_BASE=https://example.test/releases/latest/download
API=https://api.example.test/releases

mkdir -p "$TMP/tmp" "$TMP/www/stable" "$TMP/www/dev"
sh "$ROOT/release/generate_manifest.sh" 3 4 2 1.0.0 > "$TMP/www/stable/manifest.txt"
sh "$ROOT/release/generate_manifest.sh" 4 4 2 1.1.0 > "$TMP/www/dev/manifest.txt"
sh "$ROOT/release/generate_manifest.sh" 4 4 2 1.1.9 > "$TMP/dev-mismatch.txt"
mkdir -p "$TMP/www/dev130"
sh "$ROOT/release/generate_manifest.sh" 6 4 2 1.3.0 > "$TMP/www/dev130/manifest.txt"
# Установленные манифесты для --plan: новее stable (5), равный stable (3).
sh "$ROOT/release/generate_manifest.sh" 5 4 2 1.3.0 > "$TMP/installed-newer.txt"
sh "$ROOT/release/generate_manifest.sh" 3 4 2 1.0.0 > "$TMP/installed-same.txt"

cat > "$TMP/fake_http.sh" <<EOF
#!/bin/sh
case \$1 in
  '$STABLE_BASE/manifest.txt') cat '$TMP/www/stable/manifest.txt' ;;
  'https://example.test/releases/download/1.1.0/manifest.txt') cat '$TMP/www/dev/manifest.txt' ;;
  'https://example.test/releases/download/1.3.0/manifest.txt') cat '$TMP/www/dev130/manifest.txt' ;;
  '$API') echo api >> '$TMP/api.count'; [ ! -f '$TMP/api.fail' ] || exit 22; cat '$TMP/api.json' ;;
  'https://example.test/releases') echo page >> '$TMP/page.count'; cat '$TMP/releases.html' ;;
  *) echo "unexpected url: \$1" >&2; exit 22 ;;
esac
EOF
chmod +x "$TMP/fake_http.sh"

# run <env-assignments...>: запускает --check, пишет out/err/rc.
run() {
  rm -f "$TMP/api.count"
  rc=0
  env TMPROOT="$TMP/tmp" UPDATE_HTTP_CMD="$TMP/fake_http.sh" \
    UPDATE_RELEASE_BASE=$STABLE_BASE UPDATE_RELEASES_API=$API \
    UPDATE_ENV_FILE="$TMP/no-such.env" INSTALLED_MANIFEST_PATH="$TMP/no-installed" \
    "$@" sh "$SCRIPT" --check > "$TMP/out" 2> "$TMP/err" || rc=$?
}
expect_ok() {
  [ "$rc" = 0 ] || fail "$1: код $rc, stderr: $(cat "$TMP/err")"
  grep -Fq "Доступна версия релиза: $2 " "$TMP/out" || fail "$1: нет версии $2 в выводе: $(cat "$TMP/out")"
}
api_calls() { if [ -f "$TMP/api.count" ]; then wc -l < "$TMP/api.count" | tr -d ' '; else echo 0; fi; }

printf '%s\n' '[{"url":"x","tag_name":"1.1.0","prerelease":true}]' > "$TMP/api.json"

# 1. Нет канала, нет env-файла -> stable, API не трогается.
run UPDATE_CHANNEL=
expect_ok 'stable по умолчанию' 1.0.0
[ ! -f "$TMP/api.count" ] || fail 'stable обратился к API'

# 2. Канал dev из env-файла (одинарные кавычки, последняя строка побеждает).
printf "UPDATE_CHANNEL=stable\nUPDATE_CHANNEL='dev'\n" > "$TMP/speedtest2.env"
run UPDATE_ENV_FILE="$TMP/speedtest2.env"
expect_ok 'dev из env-файла' 1.1.0
[ "$(api_calls)" = 1 ] || fail "dev: ожидался ровно 1 запрос к API, было $(api_calls)"

# 2a. Двойные кавычки тоже снимаются.
printf 'UPDATE_CHANNEL="dev"\n' > "$TMP/speedtest2.env"
run UPDATE_ENV_FILE="$TMP/speedtest2.env"
expect_ok 'dev из env-файла в двойных кавычках' 1.1.0

# 2b. Окружение важнее файла.
run UPDATE_ENV_FILE="$TMP/speedtest2.env" UPDATE_CHANNEL=stable
expect_ok 'окружение важнее файла' 1.0.0
[ ! -f "$TMP/api.count" ] || fail 'stable из окружения обратился к API'

# 3. Неизвестный канал -> stable.
run UPDATE_CHANNEL=junk
expect_ok 'junk как stable' 1.0.0
[ ! -f "$TMP/api.count" ] || fail 'junk обратился к API'

# 4. Пустой список релизов -> ошибка.
printf '[]\n' > "$TMP/api.json"
run UPDATE_CHANNEL=dev
[ "$rc" != 0 ] || fail 'пустой ответ API принят'
grep -Fq 'канала разработки' "$TMP/err" || fail "пустой ответ API: нет сообщения, stderr: $(cat "$TMP/err")"

# 5. Недопустимый тег -> ошибка.
printf '%s\n' '[{"tag_name":"../x"}]' > "$TMP/api.json"
run UPDATE_CHANNEL=dev
[ "$rc" != 0 ] || fail 'тег ../x принят'
grep -Fq 'канала разработки' "$TMP/err" || fail "тег ../x: нет сообщения, stderr: $(cat "$TMP/err")"

# 5a. Несколько релизов не по порядку версий (stable hotfix 1.2.1 вышел
# после dev 1.3.0, старый v26 в конце) -> наибольший x.y.z, то есть 1.3.0.
# Одна строка, как отдаёт GitHub API.
printf '%s\n' '[{"tag_name":"1.2.1","prerelease":false},{"tag_name":"1.3.0","prerelease":true},{"tag_name":"1.10.0x"},{"tag_name":"v26"}]' > "$TMP/api.json"
run UPDATE_CHANNEL=dev
expect_ok 'наибольший тег x.y.z (одна строка)' 1.3.0

# 5b. То же в многострочном JSON; 1.2.10 > 1.2.9 численно, но < 1.3.0.
printf '[\n  {\n    "tag_name": "1.2.9"\n  },\n  {\n    "tag_name": "1.3.0"\n  },\n  {\n    "tag_name": "1.2.10"\n  }\n]\n' > "$TMP/api.json"
run UPDATE_CHANNEL=dev
expect_ok 'наибольший тег x.y.z (многострочный)' 1.3.0

# 5c. Только старые v-теги -> ошибка канала разработки.
printf '%s\n' '[{"tag_name":"v26.10.3.4"},{"tag_name":"v26"}]' > "$TMP/api.json"
run UPDATE_CHANNEL=dev
[ "$rc" != 0 ] || fail 'только v-теги приняты'
grep -Fq 'Не удалось определить последний релиз канала разработки' "$TMP/err" || fail "только v-теги: нет сообщения, stderr: $(cat "$TMP/err")"

# 6. RELEASE_TAG dev-манифеста не совпадает с тегом из API -> ошибка.
printf '%s\n' '[{"url":"x","tag_name":"1.1.0","prerelease":true}]' > "$TMP/api.json"
cp "$TMP/www/dev/manifest.txt" "$TMP/dev-good.txt"
cp "$TMP/dev-mismatch.txt" "$TMP/www/dev/manifest.txt"
run UPDATE_CHANNEL=dev
[ "$rc" != 0 ] || fail 'манифест с чужим RELEASE_TAG принят'
cp "$TMP/dev-good.txt" "$TMP/www/dev/manifest.txt"

# 7. Уже закреплённая база (bootstrap child) -> без запроса к API.
run UPDATE_CHANNEL=dev UPDATE_RELEASE_BASE=https://example.test/releases/download/1.1.0
expect_ok 'закреплённая база' 1.1.0
[ ! -f "$TMP/api.count" ] || fail 'закреплённая база обратилась к API'

# 8. Child prepare от родителя v6: база не закреплена, манифест stable
# передан через UPDATE_PINNED_MANIFEST, в env канал dev. Child не должен
# запрашивать API и сверять stable-манифест с dev-тегом.
rm -f "$TMP/api.count"
mkdir -p "$TMP/target/opt/etc/mihomo-speedtest" "$TMP/target/opt/etc/mihomo"
rc=0
env TMPROOT="$TMP/tmp" UPDATE_HTTP_CMD="$TMP/fake_http.sh" \
  UPDATE_RELEASE_BASE=$STABLE_BASE UPDATE_RELEASES_API=$API \
  UPDATE_CHANNEL=dev INSTALLED_MANIFEST_PATH="$TMP/no-installed" \
  UPDATE_STATE_DIR="$TMP/state" UPDATE_TARGET_ROOT="$TMP/target" \
  UPDATE_BOOTSTRAP_DIR="$ROOT/updater" UPDATE_PINNED_MANIFEST="$TMP/www/stable/manifest.txt" \
  sh "$SCRIPT" --prepare --components=updater --format=json > "$TMP/out" 2> "$TMP/err" || rc=$?
[ ! -f "$TMP/api.count" ] || fail 'child prepare обратился к API'
if grep -Fq 'Манифест не соответствует' "$TMP/err"; then fail "child prepare сверил stable-манифест с dev-тегом: $(cat "$TMP/err")"; fi

# 9. --plan: манифест канала старше установленного (переключение dev ->
# stable при установленной сборке dev) -> та же ошибка, что при подготовке.
# run_plan <installed-manifest> <env-assignments...>
run_plan() {
  inst=$1; shift
  rm -f "$TMP/api.count"
  rc=0
  env TMPROOT="$TMP/tmp" UPDATE_HTTP_CMD="$TMP/fake_http.sh" \
    UPDATE_RELEASE_BASE=$STABLE_BASE UPDATE_RELEASES_API=$API \
    UPDATE_ENV_FILE="$TMP/no-such.env" INSTALLED_MANIFEST_PATH="$inst" \
    UPDATE_STATE_DIR="$TMP/state-plan" UPDATE_TARGET_ROOT="$TMP/target" \
    "$@" sh "$SCRIPT" --plan > "$TMP/out" 2> "$TMP/err" || rc=$?
}
DOWNGRADE_MSG='Установлена версия новее, чем последняя в выбранном канале обновлений; обновление появится со следующим релизом'
run_plan "$TMP/installed-newer.txt" UPDATE_CHANNEL=stable
[ "$rc" != 0 ] || fail '--plan с манифестом старше установленного завершился успешно'
grep -Fq "$DOWNGRADE_MSG" "$TMP/err" || fail "--plan downgrade: нет сообщения, stderr: $(cat "$TMP/err")"

# 9a. --check в той же ситуации остаётся информационным.
run UPDATE_CHANNEL=stable INSTALLED_MANIFEST_PATH="$TMP/installed-newer.txt"
expect_ok '--check при установленной более новой версии' 1.0.0

# 9b. Равная версия -> --plan без ошибки.
run_plan "$TMP/installed-same.txt" UPDATE_CHANNEL=stable
[ "$rc" = 0 ] || fail "--plan с равной версией: код $rc, stderr: $(cat "$TMP/err")"
if grep -Fq "$DOWNGRADE_MSG" "$TMP/err"; then fail '--plan с равной версией выдал ошибку версии'; fi

# 10. --plan в канале dev: база закрепляется по API, план строится по
# манифесту 1.1.0 (RELEASE_VERSION 4 > установленного 3).
printf '%s\n' '[{"tag_name":"1.1.0","prerelease":true}]' > "$TMP/api.json"
run_plan "$TMP/installed-same.txt" UPDATE_CHANNEL=dev
[ "$rc" = 0 ] || fail "--plan в канале dev: код $rc, stderr: $(cat "$TMP/err")"
[ "$(api_calls)" = 1 ] || fail "--plan dev: ожидался 1 запрос к API, было $(api_calls)"
grep -Fq '/opt/etc/mihomo-speedtest/update.sh [updater]' "$TMP/out" || fail "--plan dev: нет плана в выводе: $(cat "$TMP/out")"

# 11. API недоступен (403 -> код 22): теги берутся со страницы релизов,
# выбор тот же (наибольший x.y.z, hotfix 1.2.1 после dev 1.3.0 не мешает).
printf '%s\n' '<a href="/o/r/releases/tag/1.2.1">x</a> <a href="/o/r/releases/tag/1.3.0">y</a> <a href="/o/r/releases/tag/v26.1">z</a>' > "$TMP/releases.html"
touch "$TMP/api.fail"; rm -f "$TMP/page.count"
run UPDATE_CHANNEL=dev UPDATE_RELEASES_FALLBACK=https://example.test/releases
expect_ok 'fallback при отказе API' 1.3.0
[ -f "$TMP/page.count" ] || fail 'fallback не обратился к странице релизов'
# Страница без тегов x.y.z -> прежняя ошибка канала разработки.
printf '%s\n' '<html>пусто</html>' > "$TMP/releases.html"
run UPDATE_CHANNEL=dev UPDATE_RELEASES_FALLBACK=https://example.test/releases
[ "$rc" != 0 ] || fail 'пустой fallback принят'
grep -Fq 'канала разработки' "$TMP/err" || fail "пустой fallback: нет сообщения, stderr: $(cat "$TMP/err")"
rm -f "$TMP/api.fail"

echo 'test_update_channel.sh: OK' >&2
