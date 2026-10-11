#!/bin/sh
# install.sh: встроенная копия installer/netcheck.sh (блок netcheck-bootstrap) и
# диагностика сети перед загрузкой релиза (bootstrap_netcheck).
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
INSTALL=$ROOT/install.sh
LIB=$ROOT/installer/netcheck.sh
T=$(mktemp -d "${TMPDIR:-/tmp}/install-netcheck.XXXXXX")
trap 'rm -rf "$T"' EXIT INT TERM
fail() { echo "FAIL: $*" >&2; exit 1; }

# ----- встроенная копия совпадает с библиотекой (по функциям) -----
grep -q '^# >>> netcheck-bootstrap' "$INSTALL" || fail "в install.sh нет маркера '# >>> netcheck-bootstrap'"
grep -q '^# <<< netcheck-bootstrap' "$INSTALL" || fail "в install.sh нет маркера '# <<< netcheck-bootstrap'"
awk '/^# >>> netcheck-bootstrap/{f=1;next} /^# <<< netcheck-bootstrap/{f=0} f' "$INSTALL" > "$T/block.sh"
[ -s "$T/block.sh" ] || fail "блок netcheck-bootstrap пуст"
extract_fn() {
  awk -v n="$2" '
    !f && index($0, n "()") == 1 && $0 ~ /^[A-Za-z_0-9]+\(\) *\{/ { f = 1; print; next }
    f { print; if ($0 == "}") exit }
  ' "$1"
}
for fn in nc_say nc_block nc_classify nc_reason nc_probe nc_proxy_url nc_run nc_cleanup nc_result nc_verdict nc_advice_for nc_summary nc_diagnose; do
  extract_fn "$LIB" "$fn" > "$T/lib.fn"
  extract_fn "$T/block.sh" "$fn" > "$T/emb.fn"
  [ -s "$T/lib.fn" ] || fail "в installer/netcheck.sh нет функции $fn"
  [ -s "$T/emb.fn" ] || fail "во встроенном блоке нет функции $fn"
  cmp -s "$T/lib.fn" "$T/emb.fn" || fail "функция $fn во встроенной копии отличается от installer/netcheck.sh"
done
grep -q '^NC_TIMEOUT=' "$T/block.sh" || fail "во встроенном блоке нет NC_TIMEOUT"

# ----- bootstrap_netcheck -----
mkdir "$T/bin"
cat > "$T/bin/curl" <<'STUB'
#!/bin/sh
proxy=
while [ $# -gt 1 ]; do [ "$1" = -x ] && proxy=$2; shift; done
url=$1; host=${url#*://}; host=${host%%/*}
key=$host; [ -z "$proxy" ] || key="$host@proxy"
rc=0; code=200
while read -r k r c; do [ "$k" = "$key" ] && { rc=$r; code=$c; }; done < "$STUB_RULES"
printf '%s' "$code"; exit "$rc"
STUB
chmod +x "$T/bin/curl"
STUB_RULES=$T/rules
UI_LOG=$T/ui.log
NC_CONFIG=$T/none.yaml
NC_TIMEOUT=2
export STUB_RULES UI_LOG NC_CONFIG NC_TIMEOUT
OLDPATH=$PATH
PATH="$T/bin:$PATH"; export PATH
INSTALL_LIB_ONLY=1 SELFDIR="$ROOT/installer" . "$INSTALL"
unset INSTALL_LIB_ONLY

# всё доступно: одна строка
: > "$STUB_RULES"
bootstrap_netcheck > "$T/out" 2>&1
grep -q 'Сеть: GitHub доступен напрямую' "$T/out" || fail "нет короткой строки при исправной сети: $(cat "$T/out")"
[ "$(wc -l < "$T/out" | tr -d ' ')" -le 2 ] || fail "при исправной сети вывод должен быть коротким: $(cat "$T/out")"

# GitHub режется: сводка и совет, установка не прерывается (код 0)
printf '%s\n' "github.com 28 000" "api.github.com 28 000" "raw.githubusercontent.com 28 000" "objects.githubusercontent.com 28 000" > "$STUB_RULES"
rc=0; bootstrap_netcheck > "$T/out" 2>&1 || rc=$?
[ "$rc" = 0 ] || fail "bootstrap_netcheck не должен прерывать установку (код $rc)"
grep -q 'GitHub напрямую' "$T/out" || fail "нет сводки: $(cat "$T/out")"
grep -q 'INSTALL_PROXY' "$T/out" || fail "нет совета про INSTALL_PROXY: $(cat "$T/out")"

# INSTALL_PROXY: проверяется путь через него
rc=0; INSTALL_PROXY=http://127.0.0.1:7890 bootstrap_netcheck > "$T/out" 2>&1 || rc=$?
grep -q 'через mihomo (http://127.0.0.1:7890)' "$T/out" || fail "INSTALL_PROXY не проверяется: $(cat "$T/out")"

# отключение и подменённый транспорт (тесты): проб нет вовсе
rm -f "$T/curl.log"
cat > "$T/bin/curl" <<'STUB'
#!/bin/sh
echo called >> "$CURL_LOG"; exit 0
STUB
CURL_LOG=$T/curl.log; export CURL_LOG
INSTALL_NETCHECK=0 bootstrap_netcheck > "$T/out" 2>&1
UPDATE_HTTP_CMD=true bootstrap_netcheck >> "$T/out" 2>&1
[ ! -s "$T/curl.log" ] || fail "при INSTALL_NETCHECK=0 и UPDATE_HTTP_CMD пробы не запускаются"
[ ! -s "$T/out" ] || fail "при отключении вывода нет: $(cat "$T/out")"
PATH=$OLDPATH

echo "OK test_install_netcheck"
