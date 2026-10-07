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
  */upgrade/ui) [ ! -f "$TMP/fx/upgrade_reject" ] || exit 22
     [ ! -f "$TMP/fx/slow" ] || sleep 3
     [ -f "$TMP/fx/ui_empty" ] || { mkdir -p "$TMP/mihomo/zash"; echo x > "$TMP/mihomo/zash/index.html"; }
     echo '{"status":"ok"}' ;;
  */upgrade) [ ! -f "$TMP/fx/upgrade_reject" ] || exit 22
     if [ -f "$TMP/fx/upgrade_break" ]; then printf '#!/bin/sh\necho BROKEN\n' > "$TMP/bin/mihomo"
     elif [ ! -f "$TMP/fx/upgrade_noop" ]; then
       printf '{"meta":true,"version":"%s"}' "\$(cat "$TMP/fx/new_version")" > "$TMP/fx/version.json"
       printf '#!/bin/sh\necho NEW\n' > "$TMP/bin/mihomo"
     fi
     echo '{"status":"ok"}' ;;
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
echo "$1" >> "${XKEEN_LOG:-/dev/null}"
case $1 in -v) echo "XKeen ${XKEEN_FAKE_VER-1.0}" ;; *) echo "flag $1" ;; esac
EOF2
cat > "$TMP/bin/mihomo.orig" <<'EOF2'
#!/bin/sh
# mihomo -t: падает, если рядом лежит флаг conf_bad
[ "$1" != -t ] || [ ! -f "$(dirname "$0")/../fx/conf_bad" ] || { echo "bad config" >&2; exit 1; }
echo ORIG
EOF2
chmod +x "$TMP/bin/http" "$TMP/bin/xkeen" "$TMP/bin/mihomo.orig"

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
  GITHUB_API_BASE=https://gh.test TMPROOT=$TMP BIN=$TMP/bin/mihomo CONFIGEDIT_LOCK=$TMP/lock \
  XKEEN_LOG=$TMP/xkeen.log COMPONENTS_UPGRADE_WAIT=2 COMPONENTS_POLL=1

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

# ===== apply =====
apply_req() { MST_COMPONENTS_ACTION=apply REQUEST_METHOD=POST QUERY_STRING="name=$1" sh "$SCRIPT" </dev/null; }
reset_apply() {
  setfx "${1:-v1.19.2}" v1.19.3 v2.6.0 v1.1
  cp "$TMP/bin/mihomo.orig" "$TMP/bin/mihomo"; chmod +x "$TMP/bin/mihomo"
  echo v1.19.3 > "$TMP/fx/new_version"
  rm -rf "$TMP/mihomo/zash" "$TMP/lock" "$TMP/rt" "$TMP/xkeen.log" "$TMP/bin/mihomo.mst-bak"; mkdir -p "$TMP/rt"
  rm -f "$TMP/fx/upgrade_reject" "$TMP/fx/upgrade_break" "$TMP/fx/upgrade_noop" "$TMP/fx/ui_empty" "$TMP/fx/slow" "$TMP/fx/conf_bad"
}
wait_job() {
  n=0
  while [ "$n" -lt 40 ]; do
    sh "$SCRIPT" status > "$TMP/status.json"
    st=$(jget '["job"]["state"]' < "$TMP/status.json" 2>/dev/null || echo none)
    case $st in done|error) return 0 ;; esac
    sleep 0.5; n=$((n + 1))
  done
  fail "задание не завершилось (state=$st)"
}
joblog() { jget '["log"]' < "$TMP/status.json"; }

# --- apply_zashboard_ok
reset_apply v1.19.3
out=$(apply_req zashboard); assert_contains '"started":true' "$out"
wait_job
[ "$st" = done ] || fail "apply_zashboard_ok: state=$st: $(joblog)"
assert_contains 'zashboard обновлён' "$(joblog)"
[ "$(cat "$TMP/mihomo/zash/.mst-version")" = v2.6.0 ] || fail "apply_zashboard_ok: маркер версии"
assert_not_contains '-restart' "$(cat "$TMP/xkeen.log" 2>/dev/null || true)"
[ "$(jget '["components"]["items"]["zashboard"]["available"]' < "$TMP/status.json")" = False ] || fail "apply_zashboard_ok: components.json не пересчитан"
[ ! -d "$TMP/lock" ] || fail "apply_zashboard_ok: замок не снят"

# --- apply_zashboard_empty_dir
reset_apply; : > "$TMP/fx/ui_empty"
apply_req zashboard >/dev/null; wait_job
[ "$st" = error ] || fail "apply_zashboard_empty_dir: state=$st"
[ ! -d "$TMP/lock" ] || fail "apply_zashboard_empty_dir: замок не снят"

# --- apply_mihomo_ok
reset_apply
apply_req mihomo >/dev/null; wait_job
[ "$st" = done ] || fail "apply_mihomo_ok: state=$st: $(joblog)"
assert_contains 'ядро обновлено до v1.19.3' "$(joblog)"
[ "$("$TMP/bin/mihomo")" = NEW ] || fail "apply_mihomo_ok: бинарник не обновлён"
[ ! -e "$TMP/bin/mihomo.mst-bak" ] || fail "apply_mihomo_ok: бэкап должен удаляться после успеха"

# --- apply_mihomo_rollback
reset_apply; : > "$TMP/fx/upgrade_break"
apply_req mihomo >/dev/null; wait_job
[ "$st" = error ] || fail "apply_mihomo_rollback: state=$st"
assert_contains 'откат выполнен' "$(joblog)"
[ "$("$TMP/bin/mihomo")" = ORIG ] || fail "apply_mihomo_rollback: бинарник не восстановлен"
assert_contains '-restart' "$(cat "$TMP/xkeen.log")"
[ ! -d "$TMP/lock" ] || fail "apply_mihomo_rollback: замок не снят"

# --- apply_mihomo_config_invalid: /upgrade не вызывался
reset_apply; : > "$TMP/fx/conf_bad"; : > "$TMP/http.log"
apply_req mihomo >/dev/null; wait_job
[ "$st" = error ] || fail "apply_mihomo_config_invalid: state=$st"
assert_not_contains '/upgrade' "$(cat "$TMP/http.log")"
[ "$("$TMP/bin/mihomo" -x)" = ORIG ] || fail "apply_mihomo_config_invalid: ядро тронуто"

# --- apply_mihomo_unsupported: ядро отклонило /upgrade - без ожидания и без отката
reset_apply; : > "$TMP/fx/upgrade_reject"
apply_req mihomo >/dev/null; wait_job
[ "$st" = error ] || fail "apply_mihomo_unsupported: state=$st"
assert_contains 'недоступно' "$(joblog)"
assert_not_contains '-restart' "$(cat "$TMP/xkeen.log" 2>/dev/null || true)"

# --- apply_busy_lock: замок занят живым процессом - 409, задание не создано
reset_apply
sleep 20 & lp=$!
mkdir "$TMP/lock"; echo "$lp" > "$TMP/lock/pid"
out=$(apply_req zashboard)
assert_contains 'Status: 409' "$out"; assert_contains 'busy' "$out"
[ ! -f "$TMP/rt/components-job.json" ] || fail "apply_busy_lock: job создан"
kill "$lp" 2>/dev/null || true; wait "$lp" 2>/dev/null || true

# --- apply_busy_running: второй apply во время работы первого
reset_apply; : > "$TMP/fx/slow"
apply_req zashboard >/dev/null
out=$(apply_req mihomo)
assert_contains 'Status: 409' "$out"
wait_job; [ "$st" = done ] || fail "apply_busy_running: первый apply должен дойти до done ($st)"

# --- apply_unknown_name: xkeen не обновляется
reset_apply
out=$(apply_req xkeen); assert_contains 'Status: 400' "$out"; assert_contains 'unknown_component' "$out"
out=$(apply_req foo); assert_contains 'unknown_component' "$out"
[ ! -f "$TMP/rt/components-job.json" ] || fail "apply_unknown_name: job создан"

echo "test_stats_components: OK"
