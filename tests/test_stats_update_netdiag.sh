#!/bin/sh
# Веб-проверка обновлений: при сбое загрузки last-check.json несёт поле "diag"
# (блок «Диагностика сети:» из stderr update.sh), при успехе - diag:null.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
T=$(mktemp -d "${TMPDIR:-/tmp}/stats-netdiag.XXXXXX")
trap 'rm -rf "$T"' EXIT INT TERM
fail() { echo "FAIL: $*" >&2; exit 1; }
has() { case "$2" in *"$1"*) ;; *) fail "нет: $1 ($3: $2)";; esac; }

mkdir "$T/w" "$T/rt"
cp "$ROOT/web/stats_update.sh" "$T/w/"
cat > "$T/w/update.sh" <<'FAKE'
#!/bin/sh
if [ -n "${FAKE_FAIL:-}" ]; then
  echo 'ERROR: Не удалось скачать файл обновления: таймаут (код загрузчика: 28).' >&2
  echo 'Адрес: https://x/manifest.txt' >&2
  printf '\nДиагностика сети:\n' >&2
  echo '  GitHub напрямую: таймаут "quoted"' >&2
  echo '  Совет: задайте INSTALL_PROXY=http://127.0.0.1:ПОРТ' >&2
  echo 'Повторите обновление через несколько минут.' >&2
  exit 1
fi
echo '{"release_version":"9"}'
FAKE
chmod +x "$T/w/update.sh" "$T/w/stats_update.sh"

run() {
  DIR="$T/w" TMPROOT="$T/tmp" UPDATE_SCRIPT="$T/w/update.sh" STATS_UPDATE_RUNTIME_DIR="$T/rt" \
    UPDATE_NOTES_HTTP_CMD=false MST_UPDATE_ACTION=check REQUEST_METHOD=POST "$T/w/stats_update.sh" || :
}
mkdir -p "$T/tmp"
OUT=$(FAKE_FAIL=1 run)
has '"ok":false' "$OUT" fail
has '"diag":"' "$OUT" "diag есть"
has 'GitHub напрямую: таймаут \"quoted\"' "$OUT" "экранирование"
has '\n' "$OUT" "переносы"
has 'INSTALL_PROXY' "$OUT" "совет"
case "$OUT" in *Повторите*) fail "хвост «Повторите» не должен попадать в diag" ;; esac
if command -v python3 >/dev/null 2>&1; then
  printf '%s' "$OUT" | sed -n '/^{/,$p' | python3 -c 'import json,sys; d=json.load(sys.stdin); assert "\n" in d["diag"] and d["diag"].startswith("  GitHub")' || fail "невалидный JSON/diag"
fi
OUT=$(run)
has '"ok":true' "$OUT" ok
has '"diag":null' "$OUT" "diag null при успехе"
echo "OK test_stats_update_netdiag"
