#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
PREP=$ROOT/speedtest-runtime/prep.awk
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/prep-test.XXXXXX")
trap 'rm -rf "$TEST_ROOT"' EXIT INT TERM

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_eq() {
  [ "$1" = "$2" ] || fail "expected [$1] = [$2]"
}

run_prep() {
  case_name=$1
  input=$2
  mkdir -p "$TEST_ROOT/$case_name/nodes"
  awk -v NODEDIR="$TEST_ROOT/$case_name/nodes" \
      -v MAPFILE="$TEST_ROOT/$case_name/map.txt" \
      -v CNTFILE="$TEST_ROOT/$case_name/count.txt" \
      -v BLOCK='Russia|RU' -v EXTYPE='trojan|ss' \
      -f "$PREP" "$input" \
      > "$TEST_ROOT/$case_name/out.yaml" \
      2> "$TEST_ROOT/$case_name/err.txt"
}

STANDARD=$TEST_ROOT/standard.yaml
printf '%s\n' \
  'proxies:' \
  '  - name: one' \
  '    type: vless' \
  '    server: 1.2.3.4' \
  '    port: 443' \
  '  - name: two' \
  '    type: vless' \
  '    server: 1.2.3.5' \
  '    port: 443' > "$STANDARD"
run_prep standard "$STANDARD"
assert_eq "$(cat "$TEST_ROOT/standard/count.txt")" 2
[ -f "$TEST_ROOT/standard/nodes/n0001.yaml" ] || fail "standard first node missing"
[ -f "$TEST_ROOT/standard/nodes/n0002.yaml" ] || fail "standard second node missing"

DASH_ONLY=$TEST_ROOT/dash-only.yaml
printf '%s\n' \
  'proxies:' \
  '    -' \
  '      name: one' \
  '      type: vless' \
  '      server: 1.2.3.4' \
  '      port: 443' \
  '    -' \
  '      name: two' \
  '      type: vless' \
  '      server: 1.2.3.5' \
  '      port: 443' > "$DASH_ONLY"
run_prep dash_only "$DASH_ONLY"
assert_eq "$(cat "$TEST_ROOT/dash_only/count.txt")" 2
[ -f "$TEST_ROOT/dash_only/nodes/n0001.yaml" ] || fail "dash-only first node missing"
[ -f "$TEST_ROOT/dash_only/nodes/n0002.yaml" ] || fail "dash-only second node missing"
grep -q '^  -$' "$TEST_ROOT/dash_only/out.yaml" || fail "four-space input was not normalized to two spaces"

FILTERS=$TEST_ROOT/filters.yaml
printf '%s\n' \
  'proxies:' \
  '  - name: keep' \
  '    type: vless' \
  '  - name: drop-trojan' \
  '    type: trojan' \
  '  - name: drop-ss' \
  '    type: ss' \
  '  - name: RU blocked' \
  '    type: vless' > "$FILTERS"
run_prep filters "$FILTERS"
assert_eq "$(cat "$TEST_ROOT/filters/count.txt")" 1
grep -q 'keep' "$TEST_ROOT/filters/map.txt" || fail "allowed node was filtered"

COMMENTED=$TEST_ROOT/commented.yaml
printf '%s\n' \
  'proxies:' \
  '  - name: one' \
  '    type: vless' \
  '# separator outside the list item' \
  '  - name: two' \
  '    type: vless' > "$COMMENTED"
run_prep commented "$COMMENTED"
assert_eq "$(cat "$TEST_ROOT/commented/count.txt")" 2
if grep -q '^# separator' "$TEST_ROOT/commented/out.yaml"; then
  fail "top-level comment leaked into a proxy block"
fi

INLINE=$TEST_ROOT/inline.yaml
printf '%s\n' \
  'proxies:' \
  '  - {name: inline, type: vless, server: 1.2.3.4, port: 443}' > "$INLINE"
mkdir -p "$TEST_ROOT/inline/nodes"
set +e
awk -v NODEDIR="$TEST_ROOT/inline/nodes" \
    -v MAPFILE="$TEST_ROOT/inline/map.txt" \
    -v CNTFILE="$TEST_ROOT/inline/count.txt" \
    -v BLOCK='Russia|RU' -v EXTYPE='trojan|ss' \
    -f "$PREP" "$INLINE" \
    > "$TEST_ROOT/inline/out.yaml" \
    2> "$TEST_ROOT/inline/err.txt"
inline_rc=$?
set -e
assert_eq "$inline_rc" 2
[ ! -s "$TEST_ROOT/inline/out.yaml" ] || fail "inline map produced corrupt output"
grep -q 'inline proxy maps are not supported' "$TEST_ROOT/inline/err.txt" || fail "inline error is not diagnostic"

INCOMPLETE=$TEST_ROOT/incomplete.yaml
printf '%s\n' 'proxies:' '  - name: missing-type' > "$INCOMPLETE"
mkdir -p "$TEST_ROOT/incomplete/nodes"
set +e
awk -v NODEDIR="$TEST_ROOT/incomplete/nodes" \
    -v MAPFILE="$TEST_ROOT/incomplete/map.txt" \
    -v CNTFILE="$TEST_ROOT/incomplete/count.txt" \
    -v BLOCK='Russia|RU' -v EXTYPE='trojan|ss' \
    -f "$PREP" "$INCOMPLETE" \
    > "$TEST_ROOT/incomplete/out.yaml" \
    2> "$TEST_ROOT/incomplete/err.txt"
incomplete_rc=$?
set -e
assert_eq "$incomplete_rc" 2
[ ! -s "$TEST_ROOT/incomplete/out.yaml" ] || fail "incomplete node produced output"

# WGFILE: WireGuard/AmneziaWG-ноды не попадают в пул второго ядра (stdout),
# но остаются в map.txt (весь пул, стабильность) и перечисляются в WGFILE
# с исходными именами - их проверяют через основное ядро.
WG=$TEST_ROOT/wg.yaml
printf '%s\n' \
  'proxies:' \
  '  - name: one' \
  '    type: vless' \
  '    server: 1.2.3.4' \
  "  - name: 'Blanc NL'" \
  '    type: wireguard' \
  '    server: wg.example' \
  '    allowed-ips:' \
  '    - 0.0.0.0/0' \
  '    amnezia-wg-option:' \
  '      jc: 4' \
  '  - name: two' \
  '    type: hysteria2' \
  '    server: 1.2.3.5' > "$WG"
mkdir -p "$TEST_ROOT/wg/nodes"
awk -v NODEDIR="$TEST_ROOT/wg/nodes" -v MAPFILE="$TEST_ROOT/wg/map.txt" \
    -v CNTFILE="$TEST_ROOT/wg/count.txt" -v WGFILE="$TEST_ROOT/wg/wg.txt" \
    -v BLOCK='Russia|RU' -v EXTYPE='trojan|ss' \
    -f "$PREP" "$WG" > "$TEST_ROOT/wg/out.yaml"
assert_eq "$(cat "$TEST_ROOT/wg/count.txt")" 3
assert_eq "$(cat "$TEST_ROOT/wg/wg.txt")" "$(printf 'n0002\tBlanc NL')"
assert_eq "$(cut -f1 "$TEST_ROOT/wg/map.txt" | tr '\n' ' ')" "n0001 n0002 n0003 "
grep -q 'wireguard\|wg.example\|n0002' "$TEST_ROOT/wg/out.yaml" && fail "WG node leaked into second-core pool"
grep -q 'name: n0003' "$TEST_ROOT/wg/out.yaml" || fail "node after WG lost"
[ -s "$TEST_ROOT/wg/nodes/n0002.yaml" ] || fail "WG node file missing"

# Без WGFILE - прежнее поведение: WG-нода в общем пуле.
mkdir -p "$TEST_ROOT/wg_legacy/nodes"
awk -v NODEDIR="$TEST_ROOT/wg_legacy/nodes" -v MAPFILE="$TEST_ROOT/wg_legacy/map.txt" \
    -v CNTFILE="$TEST_ROOT/wg_legacy/count.txt" \
    -v BLOCK='Russia|RU' -v EXTYPE='trojan|ss' \
    -f "$PREP" "$WG" > "$TEST_ROOT/wg_legacy/out.yaml"
grep -q 'name: n0002' "$TEST_ROOT/wg_legacy/out.yaml" || fail "legacy mode dropped WG node"

# BLOCK из exclude-filter с префиксом (?i): префикс игнорируется, иначе
# первый кусок искался бы буквально как "(?i)russia" и Russia проходила.
REGEXPFX=$TEST_ROOT/regexpfx.yaml
printf '%s\n' \
  'proxies:' \
  '  - name: Russia 01' \
  '    type: vless' \
  '  - name: RU-MSK-2' \
  '    type: vless' \
  '  - name: Brussels BE' \
  '    type: vless' > "$REGEXPFX"
mkdir -p "$TEST_ROOT/regexpfx/nodes"
awk -v NODEDIR="$TEST_ROOT/regexpfx/nodes" -v MAPFILE="$TEST_ROOT/regexpfx/map.txt" \
    -v CNTFILE="$TEST_ROOT/regexpfx/count.txt" \
    -v BLOCK='(?i)Russia|(?i)RU-' -v EXTYPE='trojan' \
    -f "$PREP" "$REGEXPFX" > "$TEST_ROOT/regexpfx/out.yaml"
assert_eq "$(cat "$TEST_ROOT/regexpfx/count.txt")" 1
grep -q 'Brussels BE' "$TEST_ROOT/regexpfx/map.txt" || fail "(?i): wrong node kept"

echo "test_prep: OK"
