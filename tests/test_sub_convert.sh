#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
CONV=$ROOT/speedtest-runtime/sub_convert.awk
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/sub-convert-test.XXXXXX")
trap 'rm -rf "$TEST_ROOT"' EXIT INT TERM

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

run_conv() {
  case_name=$1
  input=$2
  LC_ALL=C awk -f "$CONV" "$input" \
    > "$TEST_ROOT/$case_name.out.yaml" \
    2> "$TEST_ROOT/$case_name.err.txt"
}

count_nodes() {
  grep -c '^  - name:' "$TEST_ROOT/$1.out.yaml" || true
}

# --- vless + xhttp + reality, remark без %-кодирования, с "мусорными"
#     провайдерскими параметрами (реальный пример durev) ---
V1=$TEST_ROOT/vless-xhttp.txt
printf '%s\n' 'vless://aaaaaaaa-1111-4222-8333-bbbbbbbbbbbb@node1.example.com:8443?type=xhttp&security=reality&sni=sni1.example.net&pbk=TestPublicKey1AAAAAAAAAAAAAAAAAAAAAAAAAAAAA&sid=0123abcd&fp=chrome&mode=stream-one&path=/xhttp&concurrency=4&x-durev-block=autoloca&x-durev-prio=1#Auto → [Оптимальная локация]' > "$V1"
run_conv vless_xhttp "$V1"
grep -q 'name: "Auto → \[Оптимальная локация\]"' "$TEST_ROOT/vless_xhttp.out.yaml" || fail "xhttp: remark без %% не сохранился как есть"
grep -q 'type: vless' "$TEST_ROOT/vless_xhttp.out.yaml" || fail "xhttp: нет type"
grep -q 'server: "node1.example.com"' "$TEST_ROOT/vless_xhttp.out.yaml" || fail "xhttp: нет server"
grep -q 'port: 8443' "$TEST_ROOT/vless_xhttp.out.yaml" || fail "xhttp: нет port"
grep -q 'uuid: "aaaaaaaa-1111-4222-8333-bbbbbbbbbbbb"' "$TEST_ROOT/vless_xhttp.out.yaml" || fail "xhttp: нет uuid"
grep -q 'network: xhttp' "$TEST_ROOT/vless_xhttp.out.yaml" || fail "xhttp: нет network"
grep -q 'tls: true' "$TEST_ROOT/vless_xhttp.out.yaml" || fail "xhttp: нет tls"
grep -q 'servername: "sni1.example.net"' "$TEST_ROOT/vless_xhttp.out.yaml" || fail "xhttp: нет servername"
grep -q 'client-fingerprint: "chrome"' "$TEST_ROOT/vless_xhttp.out.yaml" || fail "xhttp: нет client-fingerprint"
grep -q 'public-key: "TestPublicKey1AAAAAAAAAAAAAAAAAAAAAAAAAAAAA"' "$TEST_ROOT/vless_xhttp.out.yaml" || fail "xhttp: нет reality public-key"
grep -q 'short-id: "0123abcd"' "$TEST_ROOT/vless_xhttp.out.yaml" || fail "xhttp: нет reality short-id"
grep -q '    xhttp-opts:' "$TEST_ROOT/vless_xhttp.out.yaml" || fail "xhttp: нет xhttp-opts"
grep -q 'path: "/xhttp"' "$TEST_ROOT/vless_xhttp.out.yaml" || fail "xhttp: нет path в xhttp-opts"
grep -q 'x-durev-block\|concurrency\|mode:' "$TEST_ROOT/vless_xhttp.out.yaml" && fail "xhttp: неизвестные провайдерские параметры не должны попадать в вывод"

# --- vless + tcp + reality + xtls-rprx-vision, remark полностью
#     %-закодирован (реальный пример blancvpn - другая форма remark) ---
V2=$TEST_ROOT/vless-tcp.txt
printf '%s\n' 'vless://cccccccc-2222-4333-8444-dddddddddddd@203.0.113.10:443?security=reality&encryption=none&fp=firefox&headerType=none&type=tcp&flow=xtls-rprx-vision&sni=cdn3-87.taobao.com&pbk=TestPublicKey2BBBBBBBBBBBBBBBBBBBBBBBBBBBBB&sid=89abcdef01234567#%F0%9F%87%B3%F0%9F%87%B1%20%D0%90%D0%BC%D1%81%D1%82%D0%B5%D1%80%D0%B4%D0%B0%D0%BC%2C%20%D0%9D%D0%B8%D0%B4%D0%B5%D1%80%D0%BB%D0%B0%D0%BD%D0%B4%D1%8B%2C%20Extra' > "$V2"
run_conv vless_tcp "$V2"
grep -q 'name: "🇳🇱 Амстердам, Нидерланды, Extra"' "$TEST_ROOT/vless_tcp.out.yaml" || fail "tcp: remark не раскодирован"
grep -q 'network: tcp' "$TEST_ROOT/vless_tcp.out.yaml" || fail "tcp: нет network"
grep -q 'flow: "xtls-rprx-vision"' "$TEST_ROOT/vless_tcp.out.yaml" || fail "tcp: нет flow"
grep -q '    ws-opts:\|    xhttp-opts:' "$TEST_ROOT/vless_tcp.out.yaml" && fail "tcp: не должно быть ws-opts/xhttp-opts для network=tcp"

# --- vless + ws (сеть не встречается в реальных durev-примерах, но
#     поддержана дизайном наравне с tcp/xhttp - проверяем отдельно) ---
V3=$TEST_ROOT/vless-ws.txt
printf '%s\n' 'vless://11111111-2222-3333-4444-555555555555@ws.example.com:443?type=ws&path=%2Fws&host=ws.example.com&security=tls&sni=ws.example.com#WS node' > "$V3"
run_conv vless_ws "$V3"
grep -q 'name: "WS node"' "$TEST_ROOT/vless_ws.out.yaml" || fail "ws: имя не разобрано"
grep -q 'network: ws' "$TEST_ROOT/vless_ws.out.yaml" || fail "ws: нет network"
grep -q '    ws-opts:' "$TEST_ROOT/vless_ws.out.yaml" || fail "ws: нет ws-opts"
grep -q 'path: "/ws"' "$TEST_ROOT/vless_ws.out.yaml" || fail "ws: path не раскодирован (%%2F -> /)"
grep -q 'Host: "ws.example.com"' "$TEST_ROOT/vless_ws.out.yaml" || fail "ws: нет Host в ws-opts"

# --- ссылка без #remark вообще: подставляется резервное имя vless-host-port ---
V4=$TEST_ROOT/vless-noremark.txt
printf '%s\n' 'vless://66666666-7777-8888-9999-000000000000@noremark.example.com:8443?type=tcp' > "$V4"
run_conv vless_noremark "$V4"
grep -q 'name: "vless-noremark.example.com-8443"' "$TEST_ROOT/vless_noremark.out.yaml" || fail "noremark: резервное имя не подставлено"

# --- смесь валидных и битых строк в одном источнике: битые пропускаются,
#     остальные проходят, итог converted/skipped верный ---
MIX=$TEST_ROOT/mixed.txt
{
  cat "$V1"
  printf '%s\n' 'trojan://somepassword@host.example.com:443#notVless'
  printf '%s\n' 'vless://@nouuidhost.example.com:443#noUUID'
  printf '%s\n' 'vless://abc123@badportnoport.example.com#noPort'
  printf '%s\n' 'vless://uuid-here@host.example.com:443?security=reality&sni=x.com#noPbk'
  cat "$V2"
} > "$MIX"
run_conv mixed "$MIX"
[ "$(count_nodes mixed)" = 2 ] || fail "mixed: ожидалось 2 разобранных ноды, получено $(count_nodes mixed)"
grep -q 'converted=2 skipped=4' "$TEST_ROOT/mixed.err.txt" || fail "mixed: неверный итог converted/skipped: $(cat "$TEST_ROOT/mixed.err.txt")"

# --- пустой вход: 0 нод, без падения ---
EMPTY=$TEST_ROOT/empty.txt
: > "$EMPTY"
run_conv empty "$EMPTY"
[ "$(count_nodes empty)" = 0 ] || fail "empty: пустой вход должно дать 0 нод"
grep -q 'converted=0 skipped=0' "$TEST_ROOT/empty.err.txt" || fail "empty: неверный итог для пустого входа"

echo "OK: все проверки test_sub_convert.sh прошли"
