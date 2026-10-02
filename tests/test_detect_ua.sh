#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
SCRIPT=$ROOT/config-tools/detect_ua.sh
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/detect-ua-test.XXXXXX")
trap 'rm -rf "$TEST_ROOT"' EXIT INT TERM

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_eq() {
  [ "$1" = "$2" ] || fail "expected [$1] = [$2]"
}

DETECT_UA_LIB_ONLY=1 . "$SCRIPT"

# Пустой ответ.
EMPTY="$TEST_ROOT/empty.txt"
: > "$EMPTY"
assert_eq "$(classify_body "$EMPTY")" "пусто"

# JSON-конфиг v2ray/xray (типичный ответ под UA v2rayNG).
JSON="$TEST_ROOT/json.txt"
printf '[{"dns":{"servers":["1.1.1.1"]},"routing":{"rules":[]}}]' > "$JSON"
assert_eq "$(classify_body "$JSON")" "v2ray/xray JSON (НЕ подходит для mihomo proxy-providers)"

# Полный clash YAML (типичный ответ под UA clash.meta/mihomo/clash-verge).
FULL="$TEST_ROOT/full.txt"
cat > "$FULL" <<'EOF'
mixed-port: 7890
socks-port: 7891
allow-lan: true
proxies:
  - name: test
proxy-groups:
  - name: select
    type: select
EOF
assert_eq "$(classify_body "$FULL")" "clash YAML, полный (подходит для mihomo proxy-providers)"

# Укороченный clash YAML без mixed-port/proxy-groups (типичный ответ
# под старые ClashX/ClashforWindows).
SHORT="$TEST_ROOT/short.txt"
cat > "$SHORT" <<'EOF'
proxies:
  - name: test
    type: vless
EOF
assert_eq "$(classify_body "$SHORT")" "clash YAML, укороченный (частично подходит, сверьте набор нод)"

# Base64-список нод (типичный ответ под Shadowrocket/Quantumult X/Surge).
B64="$TEST_ROOT/b64.txt"
printf 'dmxlc3M6Ly90ZXN0LWNvbmZpZy1saW5lLW9uZQ==\ndmxlc3M6Ly90ZXN0LXR3bw==\n' > "$B64"
assert_eq "$(classify_body "$B64")" "v2ray-подписка, base64-список ссылок (подходит для mihomo proxy-providers напрямую)"

# Неизвестный формат (HTML-страница ошибки, символы вне base64-алфавита).
HTML="$TEST_ROOT/html.txt"
printf '<html><body>403 Forbidden</body></html>' > "$HTML"
assert_eq "$(classify_body "$HTML")" "неизвестный формат, смотрите тело ответа глазами"

# try_one() с недоступной сетью (curl всегда завершается ошибкой, как при
# заблокированном по allowlist хосте) не должен падать под set -eu и не
# должен склеивать код ответа в "000000" — код должен аккуратно
# откатываться на "000".
BIN_ROOT="$TEST_ROOT/bin"
mkdir -p "$BIN_ROOT"
cat > "$BIN_ROOT/curl" <<'EOF_CURL'
#!/bin/sh
exit 7
EOF_CURL
chmod +x "$BIN_ROOT/curl"

OUT="$TEST_ROOT/try_one_output.txt"
(
  PATH="$BIN_ROOT:$PATH"
  export PATH
  try_one "test-ua" "https://example.invalid" "$TEST_ROOT/net_fail.txt"
) > "$OUT"
LINE=$(cat "$OUT")
case "$LINE" in
  "UA=[test-ua] -> HTTP 000, bytes=0, пусто") ;;
  *) fail "неожиданный вывод try_one при сбое сети: $LINE" ;;
esac

# try_one() должен проходить редиректы (реальные подписочные панели
# отдают 301 на канонический путь со слэшом, а нужное содержимое - уже
# на конечном URL под тем же UA). Фиктивный curl эмулирует это: без -L
# отдаёт пустое тело с 301, с -L - итоговые 200 и clash YAML.
BIN_REDIRECT="$TEST_ROOT/bin_redirect"
mkdir -p "$BIN_REDIRECT"
cat > "$BIN_REDIRECT/curl" <<'EOF_CURL'
#!/bin/sh
follow=0; out=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out=$2; shift 2 ;;
    -w) shift 2 ;;
    -m) shift 2 ;;
    -A) shift 2 ;;
    *L*) follow=1; shift ;;
    *) shift ;;
  esac
done
if [ "$follow" = 1 ]; then
  printf 'mixed-port: 7890\nproxy-groups: []\nproxies: []\n' > "$out"
  printf '200'
else
  : > "$out"
  printf '301'
fi
EOF_CURL
chmod +x "$BIN_REDIRECT/curl"

OUT_REDIRECT="$TEST_ROOT/try_one_redirect.txt"
(
  PATH="$BIN_REDIRECT:$PATH"
  export PATH
  try_one "test-ua" "https://example.invalid/sub/x" "$TEST_ROOT/redirect.txt"
) > "$OUT_REDIRECT"
LINE_REDIRECT=$(cat "$OUT_REDIRECT")
case "$LINE_REDIRECT" in
  "UA=[test-ua] -> HTTP 200, bytes="*", clash YAML, полный"*) ;;
  *) fail "try_one не прошёл редирект 301 -> 200 (нет -L?): $LINE_REDIRECT" ;;
esac

# try_one() должен запрашивать распаковку gzip (--compressed) - реальная
# подписка (Cloudflare/nginx) отдаёт Content-Encoding: gzip даже на
# text/plain, и без --compressed curl сохраняет сырые сжатые байты
# (сигнатура gzip 1f 8b 08...), которые classify_body() не может
# разобрать ни при одном UA.
BIN_GZIP="$TEST_ROOT/bin_gzip"
mkdir -p "$BIN_GZIP"
cat > "$BIN_GZIP/curl" <<'EOF_CURL'
#!/bin/sh
compressed=0; out=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out=$2; shift 2 ;;
    -w) shift 2 ;;
    -m) shift 2 ;;
    -A) shift 2 ;;
    --compressed) compressed=1; shift ;;
    *) shift ;;
  esac
done
if [ "$compressed" = 1 ]; then
  printf 'mixed-port: 7890\nproxy-groups: []\nproxies: []\n' > "$out"
else
  printf '\037\213\010\000\000\000\000\000binary-gzip-stub' > "$out"
fi
printf '200'
EOF_CURL
chmod +x "$BIN_GZIP/curl"

OUT_GZIP="$TEST_ROOT/try_one_gzip.txt"
(
  PATH="$BIN_GZIP:$PATH"
  export PATH
  try_one "test-ua" "https://example.invalid/sub/gz" "$TEST_ROOT/gzip.txt"
) > "$OUT_GZIP"
LINE_GZIP=$(cat "$OUT_GZIP")
case "$LINE_GZIP" in
  "UA=[test-ua] -> HTTP 200, bytes="*", clash YAML, полный"*) ;;
  *) fail "try_one не запросил распаковку gzip (нет --compressed?): $LINE_GZIP" ;;
esac

echo "OK (test_detect_ua)"
