#!/bin/sh
# Тесты web/stats_components.sh - проверка и обновление компонентов
# (mihomo, zashboard, xkeen). HTTP подменяется заглушкой COMPONENTS_HTTP_CMD
# (GitHub и API ядра), mihomo и xkeen - заглушками в $TMP/bin.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
SCRIPT=$ROOT/web/stats_components.sh
TMP=$(mktemp -d /tmp/test-stats-components.XXXXXX)
trap 'rm -rf "$TMP"' EXIT INT TERM
fail() { echo "FAIL: $*" >&2; exit 1; }
assert_contains() { case "$2" in *"$1"*) ;; *) fail "expected to find: $1 in: $2" ;; esac; }
assert_not_contains() { case "$2" in *"$1"*) fail "expected NOT to find: $1 in: $2" ;; esac; }

sh -n "$SCRIPT" || fail "stats_components.sh не проходит sh -n"

mkdir -p "$TMP/bin" "$TMP/mihomo" "$TMP/fx" "$TMP/rt"
cat > "$TMP/mihomo/config.yaml" <<'EOF'
external-controller: 0.0.0.0:9090
secret: "s3cret"
EOF

# Заглушка HTTP: последний аргумент - URL; ответ - файл из $TMP/fx.
cat > "$TMP/bin/http" <<EOF2
#!/bin/sh
for a in "\$@"; do url=\$a; done
echo "\$*" >> "$TMP/http.log"
case \$url in
  */version) [ ! -f "$TMP/fx/core_down" ] || exit 22; cat "$TMP/fx/version.json" ;;
  *) [ ! -f "$TMP/fx/gh_fail" ] || exit 22
     case \$url in
       */releases/tags/Prerelease-Alpha) cat "$TMP/fx/alpha.json" ;;
       */MetaCubeX/mihomo/releases/latest) cat "$TMP/fx/mihomo.json" ;;
       */Zephyruso/zashboard/releases/latest) cat "$TMP/fx/zash.json" ;;
       */repos/*/XKeen/releases/latest) cat "$TMP/fx/xkeen.json" ;;
       *) exit 22 ;;
     esac ;;
esac
EOF2
cat > "$TMP/bin/xkeen" <<'EOF2'
#!/bin/sh
case $1 in -v) echo "XKeen ${XKEEN_FAKE_VER-1.0}" ;; *) echo "flag $1" ;; esac
EOF2
chmod +x "$TMP/bin/http" "$TMP/bin/xkeen"

setfx() { # $1 mihomo-installed $2 mihomo-latest-tag $3 zash-tag $4 xkeen-tag
  printf '{"meta":true,"version":"%s"}' "$1" > "$TMP/fx/version.json"
  printf '{"tag_name":"%s"}' "$2" > "$TMP/fx/mihomo.json"
  printf '{"tag_name":"%s"}' "$3" > "$TMP/fx/zash.json"
  printf '{"tag_name":"%s"}' "$4" > "$TMP/fx/xkeen.json"
  printf '{"tag_name":"Prerelease-Alpha","assets":[{"name":"mihomo-linux-arm64-alpha-def5678.gz"}]}' > "$TMP/fx/alpha.json"
  rm -f "$TMP/fx/core_down" "$TMP/fx/gh_fail" "$TMP/rt/components.json"
}
export DIR=$TMP MIHOMO_DIR=$TMP/mihomo CONFIG=$TMP/mihomo/config.yaml \
  STATS_UPDATE_RUNTIME_DIR=$TMP/rt XKEEN_BIN=$TMP/bin/xkeen COMPONENTS_HTTP_CMD=$TMP/bin/http \
  GITHUB_API_BASE=https://gh.test TMPROOT=$TMP

jget() { python3 -c 'import json,sys; d=json.load(sys.stdin); print(eval("d"+sys.argv[1]))' "$1"; }
check() { sh "$SCRIPT" check button; }

# --- stable_update
setfx v1.19.2 v1.19.3 v2.6.0 v1.1
out=$(check)
[ "$(printf '%s' "$out" | jget '["items"]["mihomo"]["installed"]')" = v1.19.2 ] || fail "stable_update: installed"
[ "$(printf '%s' "$out" | jget '["items"]["mihomo"]["latest"]')" = v1.19.3 ] || fail "stable_update: latest"
[ "$(printf '%s' "$out" | jget '["items"]["mihomo"]["channel"]')" = stable ] || fail "stable_update: channel"
[ "$(printf '%s' "$out" | jget '["items"]["mihomo"]["available"]')" = True ] || fail "stable_update: available"
[ "$(printf '%s' "$out" | jget '["items"]["mihomo"]["can_apply"]')" = True ] || fail "stable_update: can_apply"
[ -f "$TMP/rt/components.json" ] || fail "stable_update: components.json не записан"

# --- alpha_channel
setfx alpha-abc1234 v1.19.3 v2.6.0 v1.1
out=$(check)
[ "$(printf '%s' "$out" | jget '["items"]["mihomo"]["channel"]')" = alpha ] || fail "alpha_channel: channel"
[ "$(printf '%s' "$out" | jget '["items"]["mihomo"]["latest"]')" = alpha-def5678 ] || fail "alpha_channel: latest"
[ "$(printf '%s' "$out" | jget '["items"]["mihomo"]["available"]')" = True ] || fail "alpha_channel: available"
setfx alpha-def5678 v1.19.3 v2.6.0 v1.1
out=$(check)
[ "$(printf '%s' "$out" | jget '["items"]["mihomo"]["available"]')" = False ] || fail "alpha_channel: тот же sha - не обновление"

# --- uptodate_and_newer
setfx v1.19.3 v1.19.3 v2.6.0 v1.1
[ "$(check | jget '["items"]["mihomo"]["available"]')" = False ] || fail "uptodate: равные версии"
setfx v1.20.0 v1.19.3 v2.6.0 v1.1
[ "$(check | jget '["items"]["mihomo"]["available"]')" = False ] || fail "newer: установленная новее"
setfx v1.9.0 v1.10.0 v2.6.0 v1.1
[ "$(check | jget '["items"]["mihomo"]["available"]')" = True ] || fail "numeric compare: 1.9.0 < 1.10.0"

# --- xkeen_indicator
setfx v1.19.3 v1.19.3 v2.6.0 v1.1
out=$(check)
[ "$(printf '%s' "$out" | jget '["items"]["xkeen"]["installed"]')" = 1.0 ] || fail "xkeen: installed"
[ "$(printf '%s' "$out" | jget '["items"]["xkeen"]["available"]')" = True ] || fail "xkeen: available"
[ "$(printf '%s' "$out" | jget '["items"]["xkeen"]["can_apply"]')" = False ] || fail "xkeen: can_apply должен быть false"
out=$(XKEEN_FAKE_VER= check)
[ "$(printf '%s' "$out" | jget '["items"]["xkeen"]["available"]')" = False ] || fail "xkeen: нераспознанная версия - не обновление"

# --- github_error_isolated
setfx v1.19.2 v1.19.3 v2.6.0 v1.1
: > "$TMP/fx/gh_fail"
rc=0; out=$(check) || rc=$?
[ "$rc" = 0 ] || fail "github_error: код выхода $rc"
for c in mihomo zashboard xkeen; do
  [ "$(printf '%s' "$out" | jget "[\"items\"][\"$c\"][\"latest\"]")" = None ] || fail "github_error: latest $c"
  [ "$(printf '%s' "$out" | jget "[\"items\"][\"$c\"][\"error\"]")" != None ] || fail "github_error: error $c"
done
[ "$(printf '%s' "$out" | jget '["items"]["mihomo"]["installed"]')" = v1.19.2 ] || fail "github_error: installed не должна пропадать"

# --- core_down
setfx v1.19.2 v1.19.3 v2.6.0 v1.1
: > "$TMP/fx/core_down"
out=$(check)
assert_contains 'ядро не отвечает' "$out"
[ "$(printf '%s' "$out" | jget '["items"]["mihomo"]["installed"]')" = None ] || fail "core_down: installed"
[ "$(printf '%s' "$out" | jget '["items"]["zashboard"]["latest"]')" = v2.6.0 ] || fail "core_down: zashboard считается"
[ "$(printf '%s' "$out" | jget '["items"]["xkeen"]["latest"]')" = v1.1 ] || fail "core_down: xkeen считается"

# --- no_controller / bad_secret
cp "$TMP/mihomo/config.yaml" "$TMP/config.good"
setfx v1.19.2 v1.19.3 v2.6.0 v1.1
printf 'log-level: silent\n' > "$TMP/mihomo/config.yaml"
out=$(check); assert_contains 'ядро не отвечает' "$out"
printf 'external-controller: 0.0.0.0:9090\nsecret: '"'"'a"b'"'"'\n' > "$TMP/mihomo/config.yaml"
out=$(check); assert_contains 'ядро не отвечает' "$out"
cp "$TMP/config.good" "$TMP/mihomo/config.yaml"

# --- zashboard_unknown_installed / marker
setfx v1.19.3 v1.19.3 v2.6.0 v1.1
out=$(check)
[ "$(printf '%s' "$out" | jget '["items"]["zashboard"]["installed"]')" = None ] || fail "zash: без маркера installed=null"
[ "$(printf '%s' "$out" | jget '["items"]["zashboard"]["available"]')" = False ] || fail "zash: без маркера не обновление"
mkdir -p "$TMP/mihomo/zash"; echo v2.5.0 > "$TMP/mihomo/zash/.mst-version"
out=$(check)
[ "$(printf '%s' "$out" | jget '["items"]["zashboard"]["available"]')" = True ] || fail "zash: маркер v2.5.0 < v2.6.0"
rm -rf "$TMP/mihomo/zash"

# --- status
rm -rf "$TMP/rt"; mkdir -p "$TMP/rt"
out=$(sh "$SCRIPT" status)
[ "$out" = '{"components":null,"job":null,"log":null}' ] || fail "status_nulls: $out"
setfx v1.19.2 v1.19.3 v2.6.0 v1.1; check >/dev/null
out=$(MST_COMPONENTS_ACTION=status REQUEST_METHOD=GET sh "$SCRIPT")
assert_contains 'Content-Type: application/json' "$out"
assert_contains '"items"' "$out"

echo "test_stats_components: OK"
