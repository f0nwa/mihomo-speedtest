#!/bin/sh
# Зеркала релиза при установке с нуля (install.sh: bootstrap_selfinstall):
# GitHub недоступен -> указатель канала и файлы из ветки dist через
# jsDelivr. Транспорт подменён (UPDATE_HTTP_CMD): URL https://<путь>
# отдаётся из $W/<путь>, нет файла - ошибка (код 22); URL пишутся в $URLS.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
SCRIPT=$ROOT/install.sh
TMP=$(mktemp -d "${TMPDIR:-/tmp}/install-mirrors-test.XXXXXX")
trap 'rm -rf "$TMP"' EXIT INT TERM

fail() { echo "FAIL: $*" >&2; exit 1; }
sum256() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else openssl dgst -sha256 "$1" | awk '{print $NF}'; fi; }

GH=https://gh.test/o/r/releases
M1=https://m1.test/gh/o/r
M2=https://m2.test/gh/o/r
W=$TMP/www
URLS=$TMP/urls
mkdir -p "$W"
cat > "$TMP/fake_http.sh" <<EOF
#!/bin/sh
printf '%s\n' "\$1" >> '$URLS'
f='$W'/\${1#https://}
[ -f "\$f" ] || exit 22
cat "\$f"
EOF
chmod +x "$TMP/fake_http.sh"

put() { mkdir -p "$(dirname "$W/${1#https://}")"; cat > "$W/${1#https://}"; }
# release BASE TAG: два файла и манифест релиза TAG в каталоге BASE.
release() {
  printf 'hello %s\n' "$2" | put "$1/greeting.txt"
  printf '#!/bin/sh\necho %s\n' "$2" | put "$1/runner.sh"
  g=$W/${1#https://}/greeting.txt r=$W/${1#https://}/runner.sh
  {
    printf 'FORMAT_VERSION=2\nRELEASE_TAG=%s\nRELEASE_VERSION=1\nMIN_UPDATER_VERSION=1\nCONFIG_SCHEMA_VERSION=1\nCOMPONENT|installer|x\n' "$2"
    printf 'FILE|installer|greeting.txt|/opt/etc/mihomo/greeting.txt|%s|%s|0644|none\n' "$(wc -c < "$g" | tr -d ' ')" "$(sum256 "$g")"
    printf 'FILE|installer|runner.sh|/opt/etc/mihomo/runner.sh|%s|%s|0755|sh\n' "$(wc -c < "$r" | tr -d ' ')" "$(sum256 "$r")"
  } | put "$1/manifest.txt"
}

INSTALL_PROXY_FALLBACK=0 UI=plain UI_LOG=$TMP/ui.log INSTALL_NETCHECK=0 INSTALL_RETRY_DELAY=0
export INSTALL_PROXY_FALLBACK UI UI_LOG INSTALL_NETCHECK INSTALL_RETRY_DELAY
INSTALL_LIB_ONLY=1 SELFDIR="$ROOT/installer" . "$SCRIPT"

N=0
# install_into CHANNEL [VAR=VALUE...]: bootstrap_selfinstall в новый каталог,
# код - в $rc, каталог - $D, stderr - $TMP/err.
install_into() {
  N=$((N + 1)); D=$TMP/dst$N; mkdir -p "$D"; : > "$URLS"
  ch=$1; shift
  rc=0
  (
    DIR=$D TMPROOT=$TMP UPDATE_STATE_DIR=$D/.update INSTALLED_MANIFEST_PATH=$D/.update/installed-manifest.txt
    UPDATE_HTTP_CMD=$TMP/fake_http.sh UPDATE_RELEASE_BASE=$GH/latest/download
    UPDATE_RELEASES_API=https://api.gh.test/releases UPDATE_RELEASES_FALLBACK=$GH
    UPDATE_MIRRORS="$M1 $M2" INSTALL_CHANNEL=$ch
    for a in "$@"; do eval "$a"; done
    bootstrap_selfinstall
  ) 2>"$TMP/err" || rc=$?
}
installed_tag() { sed -n 's/^RELEASE_TAG=//p' "$D/.update/installed-manifest.txt"; }

# 1. GitHub доступен - зеркала не трогаются.
release "$GH/download/1.0.0" 1.0.0
cp "$W/gh.test/o/r/releases/download/1.0.0/manifest.txt" "$TMP/m100"
put "$GH/latest/download/manifest.txt" < "$TMP/m100"
install_into stable
[ "$rc" = 0 ] || fail "GitHub доступен: $(cat "$TMP/err")"
[ "$(installed_tag)" = 1.0.0 ] || fail 'GitHub доступен: не 1.0.0'
if grep -q m1.test "$URLS"; then fail 'при доступном GitHub запрошено зеркало'; fi
[ "$(grep -c 'manifest.txt$' "$URLS")" = 1 ] || fail "манифест скачан не один раз: $(cat "$URLS")"

# 2. GitHub недоступен: m1 молчит, m2 отдаёт stable 1.2.0.
rm -rf "$W/gh.test"
echo 1.2.0 | put "$M2@dist/channels/stable"
release "$M2@dist-1.2.0/1.2.0" 1.2.0
install_into stable
[ "$rc" = 0 ] || fail "stable через зеркало: $(cat "$TMP/err")"
[ "$(installed_tag)" = 1.2.0 ] || fail 'stable через зеркало: не 1.2.0'
grep -q 'hello 1.2.0' "$D/greeting.txt" || fail 'файл не из зеркала'
[ -x "$D/runner.sh" ] || fail 'runner.sh без исполняемого бита'
grep -q 'через зеркало m2.test' "$TMP/err" || fail "нет сообщения о зеркале: $(cat "$TMP/err")"
grep -qx "$M2@dist-1.2.0/1.2.0/runner.sh" "$URLS" || fail "файлы не из закреплённой версии: $(cat "$URLS")"
grep -q 'Файлы проекта загружены и проверены (тег 1.2.0)' "$TMP/err" || fail "тег в итоговой строке: $(cat "$TMP/err")"

# 3. dev через зеркало: наибольший из channels/dev и channels/stable.
echo 1.1.0 | put "$M2@dist/channels/dev"
install_into dev
[ "$rc" = 0 ] || fail "dev (stable новее): $(cat "$TMP/err")"
[ "$(installed_tag)" = 1.2.0 ] || fail 'dev: stable 1.2.0 новее dev 1.1.0'
echo 1.3.0 | put "$M2@dist/channels/dev"
release "$M2@dist-1.3.0/1.3.0" 1.3.0
install_into dev
[ "$rc" = 0 ] || fail "dev через зеркало: $(cat "$TMP/err")"
[ "$(installed_tag)" = 1.3.0 ] || fail 'dev через зеркало: не 1.3.0'
grep -q 'Манифест 1.3.0 (dev)' "$TMP/err" || fail "нет пометки dev: $(cat "$TMP/err")"

# 4. Испорченный файл в зеркале - отказ, в DIR ничего не попало.
printf 'hello 1.2.X\n' | put "$M2@dist-1.2.0/1.2.0/greeting.txt"
install_into stable
[ "$rc" != 0 ] || fail 'испорченный файл зеркала принят'
[ ! -f "$D/greeting.txt" ] || fail 'испорченный релиз попал в DIR'
release "$M2@dist-1.2.0/1.2.0" 1.2.0

# 5. Манифест зеркала с чужим тегом - зеркало пропускается.
sed 's/^RELEASE_TAG=.*/RELEASE_TAG=1.2.9/' "$W/m2.test/gh/o/r@dist-1.2.0/1.2.0/manifest.txt" > "$TMP/bad"
put "$M2@dist-1.2.0/1.2.0/manifest.txt" < "$TMP/bad"
install_into stable
[ "$rc" != 0 ] || fail 'манифест с чужим тегом принят'
release "$M2@dist-1.2.0/1.2.0" 1.2.0

# 6. Всё недоступно - прежняя ошибка GitHub и пометка про зеркала.
mv "$W/m2.test" "$TMP/m2.off"
install_into stable
[ "$rc" != 0 ] || fail 'без источников установка прошла'
( BOOTSTRAP_FAIL_HINT=1 BOOTSTRAP_MIRRORS_TRIED=1 INSTALL_NETCHECK=0 bootstrap_fail_hint ) 2>"$TMP/hint"
grep -q 'Зеркала релиза (jsDelivr) тоже не ответили' "$TMP/hint" || fail "нет пометки про зеркала: $(cat "$TMP/hint")"
install_into dev INSTALL_RETRIES=1
[ "$rc" != 0 ] || fail 'dev без источников установка прошла'
grep -q 'список релизов' "$TMP/err" || fail "dev без источников: $(cat "$TMP/err")"
mv "$TMP/m2.off" "$W/m2.test"

# 7. Пустой UPDATE_MIRRORS и свой источник без настройки - без зеркал.
install_into stable UPDATE_MIRRORS=
[ "$rc" != 0 ] || fail 'пустой UPDATE_MIRRORS: установка через зеркало'
if grep -q m2.test "$URLS"; then fail 'пустой UPDATE_MIRRORS: зеркало запрошено'; fi
install_into stable 'unset UPDATE_MIRRORS'
[ "$rc" != 0 ] || fail 'свой источник: установка через зеркало по умолчанию'
if grep -q jsdelivr "$URLS"; then fail 'свой источник: запрошены зеркала по умолчанию'; fi
[ "$(UPDATE_RELEASE_BASE=$BOOTSTRAP_DEFAULT_BASE; unset UPDATE_MIRRORS; bootstrap_mirrors)" = "$BOOTSTRAP_MIRRORS_DEFAULT" ] ||
  fail 'штатный источник без настройки должен включать зеркала по умолчанию'

echo "test_install_mirrors.sh: OK"
