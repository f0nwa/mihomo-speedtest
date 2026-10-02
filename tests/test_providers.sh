#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
PARSER=$ROOT/speedtest-runtime/providers.awk
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/providers-test.XXXXXX")
trap 'rm -rf "$TEST_ROOT"' EXIT INT TERM

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_eq() {
  [ "$1" = "$2" ] || fail "expected [$1] = [$2]"
}

run_parser() {
  confdir=$1
  input=$2
  awk -v CONFDIR="$confdir" -f "$PARSER" "$input"
}

STANDARD=$TEST_ROOT/standard.yaml
printf '%s\n' \
  'proxy-providers:' \
  '  provA:' \
  '    type: http' \
  '    url: "https://example.com/a"' \
  '    path: ./proxy-providers/a.yaml' \
  '  provB:' \
  '    type: http' \
  '    url: "https://example.com/b"' \
  '    path: ./proxy-providers/b.yaml' \
  '  fast:' \
  '    type: file' \
  '    path: ./fast.yaml' > "$STANDARD"
OUT=$(run_parser /cfg "$STANDARD")
echo "$OUT" | grep -qF "SOURCES='/cfg/proxy-providers/a.yaml /cfg/proxy-providers/b.yaml'" \
  || fail "standard sources mismatch: $OUT"

NOSECTION=$TEST_ROOT/nosection.yaml
printf '%s\n' 'proxies:' '  - name: one' > "$NOSECTION"
set +e
run_parser /cfg "$NOSECTION" >/dev/null 2>"$TEST_ROOT/err.txt"
rc=$?
set -e
assert_eq "$rc" 2
grep -q 'Не найдено' "$TEST_ROOT/err.txt" || fail "missing-section error message absent"

NOPATH=$TEST_ROOT/nopath.yaml
printf '%s\n' \
  'proxy-providers:' \
  '  provA:' \
  '    type: http' \
  '    url: "https://example.com/a"' > "$NOPATH"
set +e
run_parser /cfg "$NOPATH" >/dev/null 2>"$TEST_ROOT/err2.txt"
rc=$?
set -e
assert_eq "$rc" 2
grep -q 'без path' "$TEST_ROOT/err2.txt" || fail "missing-path warning absent"

WITHFILTER=$TEST_ROOT/withfilter.yaml
printf '%s\n' \
  'proxy-providers:' \
  '  provA:' \
  '    type: http' \
  '    url: "https://example.com/a"' \
  '    path: ./proxy-providers/a.yaml' \
  '    exclude-type: trojan|ss' \
  "    exclude-filter: 'Russia|RU'" \
  '  provB:' \
  '    type: http' \
  '    url: "https://example.com/b"' \
  '    path: ./proxy-providers/b.yaml' \
  '    exclude-type: trojan|ss' \
  "    exclude-filter: 'Russia|RU'" > "$WITHFILTER"
OUT=$(run_parser /cfg "$WITHFILTER")
echo "$OUT" | grep -qF "EXTYPE='trojan|ss'" || fail "EXTYPE missing: $OUT"
echo "$OUT" | grep -qF "BLOCK_COUNT='1'" || fail "expected single BLOCK: $OUT"
echo "$OUT" | grep -qF "BLOCK_1='Russia|RU'" || fail "BLOCK_1 missing: $OUT"

NOFILTER=$TEST_ROOT/nofilter.yaml
printf '%s\n' \
  'proxy-providers:' \
  '  provA:' \
  '    type: http' \
  '    url: "https://example.com/a"' \
  '    path: ./proxy-providers/a.yaml' > "$NOFILTER"
OUT=$(run_parser /cfg "$NOFILTER")
echo "$OUT" | grep -q '^EXTYPE=' && fail "EXTYPE should be absent: $OUT"
echo "$OUT" | grep -qF "BLOCK_COUNT='0'" || fail "expected zero filters: $OUT"

MULTI=$TEST_ROOT/multi.yaml
printf '%s\n' \
  'proxy-providers:' \
  '  provA:' \
  '    type: http' \
  '    url: "https://example.com/a"' \
  '    path: ./proxy-providers/a.yaml' \
  "    exclude-filter: 'Russia'" \
  '  provB:' \
  '    type: http' \
  '    url: "https://example.com/b"' \
  '    path: ./proxy-providers/b.yaml' \
  "    exclude-filter: 'China'" > "$MULTI"
OUT=$(run_parser /cfg "$MULTI")
echo "$OUT" | grep -qF "BLOCK_COUNT='2'" || fail "expected two filters: $OUT"
echo "$OUT" | grep -qF "BLOCK_1='Russia'" || fail "BLOCK_1 mismatch: $OUT"
echo "$OUT" | grep -qF "BLOCK_2='China'" || fail "BLOCK_2 mismatch: $OUT"

ANCHORED=$TEST_ROOT/anchored.yaml
printf '%s\n' \
  'anchors:' \
  "  http-provider: &http-provider { type: http, interval: 3600, exclude-filter: &geofilter 'Russia|RU' }" \
  'proxy-providers:' \
  '  blancvpn:' \
  '    <<: *http-provider' \
  '    url: "https://example.com/b"' \
  '    path: ./proxy-providers/blancvpn.yaml' \
  '  epsiquad:' \
  '    <<: *http-provider' \
  '    url: "https://example.com/e"' \
  '    path: ./proxy-providers/epsiquad.yaml' \
  '  fast:' \
  '    type: file' \
  '    path: ./fast.yaml' > "$ANCHORED"
OUT=$(awk -v CONFIG="$ANCHORED" -v CONFDIR=/cfg -f "$PARSER" "$ANCHORED")
echo "$OUT" | grep -qF "SOURCES='$ANCHORED /cfg/proxy-providers/blancvpn.yaml /cfg/proxy-providers/epsiquad.yaml'" \
  || fail "anchored sources mismatch (CONFIG should lead SOURCES): $OUT"
echo "$OUT" | grep -qF "BLOCK_COUNT='1'" || fail "anchored filter should dedupe to one: $OUT"
echo "$OUT" | grep -qF "BLOCK_1='Russia|RU'" || fail "anchored filter value mismatch: $OUT"

DIRECTREF=$TEST_ROOT/directref.yaml
printf '%s\n' \
  'anchors:' \
  "  geo: &geofilter 'Turkey|TR'" \
  'proxy-providers:' \
  '  provA:' \
  '    type: http' \
  '    url: "https://example.com/a"' \
  '    path: ./proxy-providers/a.yaml' \
  '    exclude-filter: *geofilter' > "$DIRECTREF"
OUT=$(awk -v CONFIG="$DIRECTREF" -v CONFDIR=/cfg -f "$PARSER" "$DIRECTREF")
echo "$OUT" | grep -qF "BLOCK_1='Turkey|TR'" || fail "direct *anchor reference not resolved: $OUT"

DIVERGENT_TYPES=$TEST_ROOT/divergent-types.yaml
printf '%s\n' \
  'proxy-providers:' \
  '  provA:' \
  '    type: http' \
  '    url: "https://example.com/a"' \
  '    path: ./proxy-providers/a.yaml' \
  '    exclude-type: trojan|ss' \
  '  provB:' \
  '    type: http' \
  '    url: "https://example.com/b"' \
  '    path: ./proxy-providers/b.yaml' \
  '    exclude-type: vmess' > "$DIVERGENT_TYPES"
OUT=$(run_parser /cfg "$DIVERGENT_TYPES" 2>"$TEST_ROOT/divergent.err")
echo "$OUT" | grep -qF "EXTYPE='trojan|ss'" \
  || fail "divergent exclude-type: EXTYPE should still print first value: $OUT"
grep -q 'exclude-type' "$TEST_ROOT/divergent.err" \
  || fail "divergent exclude-type must warn on stderr, got: $(cat "$TEST_ROOT/divergent.err")"
grep -qF "'trojan|ss'" "$TEST_ROOT/divergent.err" \
  || fail "warning should mention the winning value: $(cat "$TEST_ROOT/divergent.err")"
grep -qF "'vmess'" "$TEST_ROOT/divergent.err" \
  || fail "warning should mention the ignored value: $(cat "$TEST_ROOT/divergent.err")"

WITH_CONFIG_SOURCE=$TEST_ROOT/with-config-source.yaml
printf '%s\n' \
  'proxies:' \
  "  - name: 'Static Hysteria2'" \
  '    type: hysteria2' \
  '    server: static.example.com' \
  'proxy-providers:' \
  '  provA:' \
  '    type: http' \
  '    url: "https://example.com/a"' \
  '    path: ./proxy-providers/a.yaml' > "$WITH_CONFIG_SOURCE"
OUT=$(awk -v CONFIG="$WITH_CONFIG_SOURCE" -v CONFDIR=/cfg -f "$PARSER" "$WITH_CONFIG_SOURCE")
echo "$OUT" | grep -qF "SOURCES='$WITH_CONFIG_SOURCE /cfg/proxy-providers/a.yaml'" \
  || fail "CONFIG (static proxies:) must lead SOURCES so prep.awk also tests them: $OUT"

WITHOUT_CONFIG_ARG=$TEST_ROOT/without-config-arg.yaml
printf '%s\n' \
  'proxy-providers:' \
  '  provA:' \
  '    type: http' \
  '    url: "https://example.com/a"' \
  '    path: ./proxy-providers/a.yaml' > "$WITHOUT_CONFIG_ARG"
OUT=$(run_parser /cfg "$WITHOUT_CONFIG_ARG")
echo "$OUT" | grep -qF "SOURCES='/cfg/proxy-providers/a.yaml'" \
  || fail "SOURCES must not gain a stray leading entry when CONFIG is not passed: $OUT"

echo "test_providers: OK (Task 3)"
