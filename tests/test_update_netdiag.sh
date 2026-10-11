#!/bin/sh
# update.sh: при сбое загрузки - причина словами, диагностика сети и совет
# вместо голого «код загрузчика: N»; прокси из UPDATE_PROXY/INSTALL_PROXY.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
T=$(mktemp -d "${TMPDIR:-/tmp}/update-netdiag.XXXXXX")
trap 'rm -rf "$T"' EXIT INT TERM
fail() { echo "FAIL: $*" >&2; exit 1; }

# Как на роутере: update.sh и netcheck.sh лежат рядом.
mkdir "$T/app" "$T/bin" "$T/tmp"
cp "$ROOT/updater/update.sh" "$ROOT/updater/update_plan.awk" "$ROOT/installer/netcheck.sh" "$T/app/"
SCRIPT=$T/app/update.sh

# curl по таблице "ключ код_возврата http_код": ключ - хост (или хост@proxy);
# скачивание манифеста (с -f) без записи в таблице - как контрольная проба.
cat > "$T/bin/curl" <<'STUB'
#!/bin/sh
proxy=
for a in "$@"; do last=$a; done
prev=
for a in "$@"; do [ "$prev" = -x ] && proxy=$a; prev=$a; done
printf '%s\n' "$*" >> "$STUB_LOG"
host=${last#*://}; host=${host%%/*}
key=$host; [ -z "$proxy" ] || key="$host@proxy"
rc=0; code=200
while read -r k r c; do [ "$k" = "$key" ] && { rc=$r; code=$c; }; done < "$STUB_RULES"
case " $* " in *" -w "*) printf '%s' "$code" ;; esac
exit "$rc"
STUB
chmod +x "$T/bin/curl"
STUB_RULES=$T/rules; STUB_LOG=$T/log
export STUB_RULES STUB_LOG
NC_TIMEOUT=2; export NC_TIMEOUT

run_update() {
  : > "$STUB_LOG"
  PATH="$T/bin:$PATH" TMPROOT="$T/tmp" UPDATE_RELEASE_BASE=https://example.invalid/releases/latest/download \
    UPDATE_ENV_FILE="$T/none.env" MIHOMO_DIR="$T/none" NC_CONFIG="$T/none.yaml" \
    sh "$SCRIPT" --check >"$T/out.log" 2>"$T/err.log"
}

# 1. GitHub режется, контрольные хосты отвечают, прокси нет
cat > "$STUB_RULES" <<'RULES'
example.invalid 28 000
github.com 28 000
api.github.com 28 000
raw.githubusercontent.com 28 000
objects.githubusercontent.com 28 000
RULES
if run_update; then fail "--check должен остановиться при сбое загрузки"; fi
for expected in 'таймаут' 'код загрузчика: 28' 'Диагностика сети:' 'GitHub напрямую' 'INSTALL_PROXY' \
  'https://example.invalid/releases/latest/download/manifest.txt' 'Повторите обновление через несколько минут'; do
  grep -Fq "$expected" "$T/err.log" || fail "нет в выводе: $expected ($(cat "$T/err.log"))"
done
grep -q 'Не удалось скачать файл обновления: таймаут' "$T/err.log" || fail "причина словами должна стоять в первой строке ошибки: $(cat "$T/err.log")"
[ ! -s "$T/out.log" ] || fail "диагностика попала в stdout"
[ -z "$(ls -A "$T/tmp")" ] || fail "временные файлы не очищены: $(ls -A "$T/tmp")"

# 2. Нет интернета вообще
cat > "$STUB_RULES" <<'RULES'
example.invalid 28 000
1.1.1.1 28 000
www.gstatic.com 28 000
www.cloudflare.com 28 000
github.com 28 000
api.github.com 28 000
raw.githubusercontent.com 28 000
objects.githubusercontent.com 28 000
RULES
if run_update; then fail "нет интернета: --check должен остановиться"; fi
grep -q 'не выходит в интернет' "$T/err.log" || fail "нет совета про отсутствие интернета: $(cat "$T/err.log")"

# 3. Прокси из UPDATE_PROXY: загрузка идёт через него, диагностика его проверяет
cat > "$STUB_RULES" <<'RULES'
example.invalid 28 000
RULES
: > "$STUB_LOG"
PATH="$T/bin:$PATH" TMPROOT="$T/tmp" UPDATE_RELEASE_BASE=https://example.invalid/releases/latest/download \
  UPDATE_ENV_FILE="$T/none.env" MIHOMO_DIR="$T/none" UPDATE_PROXY=http://127.0.0.1:7890 \
  sh "$SCRIPT" --check >"$T/out.log" 2>"$T/err.log" || :
grep -q -- '-x http://127.0.0.1:7890' "$T/log" || fail "UPDATE_PROXY не передан curl: $(cat "$T/log")"
# INSTALL_PROXY тоже понимается
: > "$STUB_LOG"
PATH="$T/bin:$PATH" TMPROOT="$T/tmp" UPDATE_RELEASE_BASE=https://example.invalid/releases/latest/download \
  UPDATE_ENV_FILE="$T/none.env" MIHOMO_DIR="$T/none" INSTALL_PROXY=http://127.0.0.1:7891 \
  sh "$SCRIPT" --check >"$T/out.log" 2>"$T/err.log" || :
grep -q -- '-x http://127.0.0.1:7891' "$T/log" || fail "INSTALL_PROXY не передан curl"

# 4. Отключение: ни проб, ни блока диагностики
: > "$STUB_LOG"
PATH="$T/bin:$PATH" TMPROOT="$T/tmp" UPDATE_RELEASE_BASE=https://example.invalid/releases/latest/download \
  UPDATE_ENV_FILE="$T/none.env" MIHOMO_DIR="$T/none" UPDATE_NETCHECK=0 \
  sh "$SCRIPT" --check >"$T/out.log" 2>"$T/err.log" || :
grep -q 'Диагностика сети' "$T/err.log" && fail "UPDATE_NETCHECK=0 не отключает диагностику"
grep -q 'таймаут' "$T/err.log" || fail "причина словами остаётся и без диагностики"
[ "$(wc -l < "$T/log" | tr -d ' ')" -le 1 ] || fail "при UPDATE_NETCHECK=0 пробы не запускаются: $(cat "$T/log")"

# 5. Без netcheck.sh рядом (старая установка): прежнее сообщение, без падений
rm "$T/app/netcheck.sh"
cat > "$STUB_RULES" <<'RULES'
example.invalid 28 000
RULES
run_update && fail "без netcheck.sh --check тоже должен остановиться"
grep -q 'код загрузчика: 28' "$T/err.log" || fail "без netcheck.sh нет прежнего сообщения: $(cat "$T/err.log")"
grep -q 'Диагностика сети' "$T/err.log" && fail "без netcheck.sh диагностики быть не может"

echo "OK test_update_netdiag"
