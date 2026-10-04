#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
SCRIPT=$ROOT/install.sh
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/install-test.XXXXXX")
# Не трогаем общие /tmp/mihomo-speedtest-* - там могут быть каталоги
# настоящей установки или другого пользователя.
export STATS_AUTH_RUNTIME_DIR="$TEST_ROOT/auth-runtime" STATS_UPDATE_RUNTIME_DIR="$TEST_ROOT/update-runtime"
export STATS_SERVICE_RUNTIME_DIR="$TEST_ROOT/service-runtime" LIVE_LOG_DIR="$TEST_ROOT/live-log" STATS_PROGRESS="$TEST_ROOT/progress.json"

# Общий фикстур для всего файла: фиктивные pidof/xkeen/ndmc, отвечающие
# версиями не ниже минимума из version_check.sh (см. Task 1). main()
# теперь начинается с check_mihomo_process && check_versions, поэтому
# каждый сценарий, запускающий install.sh как отдельный процесс, должен
# видеть рабочий pidof/xkeen/ndmc в PATH, иначе он падает на новой
# проверке раньше, чем доходит до логики, которую тестирует.
FAKEBIN=$(mktemp -d)
cat > "$FAKEBIN/pidof" <<'EOF'
#!/bin/sh
[ "$1" = "mihomo" ] && exit 0
exit 1
EOF
cat > "$FAKEBIN/xkeen" <<'EOF'
#!/bin/sh
case "$1" in
  -v) printf 'Версия XKeen 2.0 Stable (время сборки: 2026-06-06 08:53:30 MSK)\n  Ядро проксирования Mihomo версии 1.19.29\n' ;;
  -restart) exit 0 ;;
esac
EOF
cat > "$FAKEBIN/ndmc" <<'EOF'
#!/bin/sh
printf '  version: (unassigned)\n  ndm.core.version: "5.1.4 (KeeneticOS)"\n'
EOF
chmod +x "$FAKEBIN/pidof" "$FAKEBIN/xkeen" "$FAKEBIN/ndmc"
export PATH="$FAKEBIN:$PATH"

trap 'rm -rf "$TEST_ROOT" "$FAKEBIN"' EXIT INT TERM

# install.sh сорсит version_check.sh через $SELFDIR при подключении (даже
# под INSTALL_LIB_ONLY=1). Дефолт SELFDIR=. не годится - рабочий каталог
# этого теста не обязательно каталог tests/, а корень репозитория (см.
# инструкцию запуска "sh tests/test_install.sh"). Указываем реальный
# каталог, где лежит version_check.sh; отдельные сценарии ниже (FIXDIR и
# т.п.) переопределяют SELFDIR локально в своих подшеллах под свои нужды.
SELFDIR=$(mktemp -d)
cp "$ROOT"/install.sh "$ROOT"/uninstall.sh "$ROOT"/mihomo-speedtest.sh "$ROOT"/*/*.sh "$ROOT"/*/*.awk "$ROOT"/*/*.py "$ROOT"/*/*.html "$ROOT"/*/*.css "$ROOT"/*/*.js "$ROOT"/*/*.yaml "$SELFDIR/" 2>/dev/null
export SELFDIR

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_eq() {
  [ "$1" = "$2" ] || fail "expected [$1] = [$2]"
}

INSTALL_LIB_ONLY=1 . "$SCRIPT"
# Bash сохраняет экспорт временного присваивания при source; дочерние
# процессы ниже должны запускать main(), а не библиотечный режим.
unset INSTALL_LIB_ONLY

BLOCK=preset
resolve_block || fail "env BLOCK should resolve without prompt"
assert_eq "$BLOCK" preset
assert_eq "$BLOCK_SOURCE" "переменная окружения"
unset BLOCK BLOCK_SOURCE

BLOCK_COUNT=1
BLOCK_1='Russia|RU'
resolve_block || fail "single parsed value should resolve"
assert_eq "$BLOCK" 'Russia|RU'
assert_eq "$BLOCK_SOURCE" "из конфига"
unset BLOCK BLOCK_SOURCE BLOCK_COUNT BLOCK_1

BLOCK_COUNT=1
BLOCK_1='(?i)Russia|RU- | Обход'
resolve_block || fail "(?i) value should resolve"
assert_eq "$BLOCK" 'Russia|RU-|Обход'
unset BLOCK BLOCK_SOURCE BLOCK_COUNT BLOCK_1

BLOCK_COUNT=1
BLOCK_1='(?i)Russia|^.*(KZ|UA).*$|Обход'
WARN_FILE=$(mktemp)
resolve_block 2>"$WARN_FILE" || fail "regex-like value should still resolve"
WARN_OUT=$(cat "$WARN_FILE")
assert_eq "$BLOCK" 'Russia|^.*(KZ|UA).*$|Обход'
case $WARN_OUT in *"похожи на регулярное выражение"*) ;; *) fail "no regex warning: $WARN_OUT" ;; esac
case $WARN_OUT in *"^.*(KZ"*) ;; *) fail "regex warning does not list the piece: $WARN_OUT" ;; esac
case $WARN_OUT in *"  Russia"*|*"  Обход"*) fail "plain words listed as regex: $WARN_OUT" ;; esac
unset BLOCK BLOCK_SOURCE BLOCK_COUNT BLOCK_1

BLOCK_COUNT=1
BLOCK_1='(?i)Russia|RU-|Обход'
resolve_block 2>"$WARN_FILE" || fail "plain value should resolve"
WARN_OUT=$(cat "$WARN_FILE"); rm -f "$WARN_FILE"
assert_eq "$WARN_OUT" ''
unset BLOCK BLOCK_SOURCE BLOCK_COUNT BLOCK_1

BLOCK='(?i)Env|Value'
resolve_block || fail "env (?i) value should resolve"
assert_eq "$BLOCK" 'Env|Value'
unset BLOCK BLOCK_SOURCE

BLOCK_COUNT=2
BLOCK_1='Russia'
BLOCK_2='China'
resolve_block <<'EOF'
2
EOF
assert_eq "$BLOCK" 'China'
assert_eq "$BLOCK_SOURCE" 'из конфига (вариант 2)'
unset BLOCK BLOCK_SOURCE BLOCK_COUNT BLOCK_1 BLOCK_2

BLOCK_COUNT=2
BLOCK_1='Russia'
BLOCK_2='China'
resolve_block <<'EOF'
Custom|Filter
EOF
assert_eq "$BLOCK" 'Custom|Filter'
assert_eq "$BLOCK_SOURCE" 'введён вручную'
unset BLOCK BLOCK_SOURCE BLOCK_COUNT BLOCK_1 BLOCK_2

BLOCK_COUNT=0
resolve_block <<'EOF'
Manual|Value
EOF
assert_eq "$BLOCK" 'Manual|Value'
assert_eq "$BLOCK_SOURCE" 'введён вручную'
unset BLOCK BLOCK_SOURCE BLOCK_COUNT

# Фильтра в конфиге нет: меню минимальный / стандартный / свой.
DEFAULT_GEO=$(default_block)
[ -n "$DEFAULT_GEO" ] || fail "default_block should read &geofilter from config.example.yaml"

BLOCK_COUNT=0
resolve_block 2>/dev/null <<'EOF'

EOF
assert_eq "$BLOCK" "$MIN_BLOCK"
assert_eq "$BLOCK_SOURCE" 'минимальный'
unset BLOCK BLOCK_SOURCE BLOCK_COUNT

BLOCK_COUNT=0
resolve_block 2>/dev/null <<'EOF'
2
EOF
assert_eq "$BLOCK" "$(normalize_block "$DEFAULT_GEO")"
assert_eq "$BLOCK_SOURCE" 'стандартный из config.example.yaml'
unset BLOCK BLOCK_SOURCE BLOCK_COUNT

# Нет ответа вовсе (EOF, нет терминала) - минимальный, без отказа.
BLOCK_COUNT=0
resolve_block 2>/dev/null </dev/null || fail "EOF should fall back to minimal filter"
assert_eq "$BLOCK_SOURCE" 'минимальный'
unset BLOCK BLOCK_SOURCE BLOCK_COUNT

BLOCK_COUNT=2
BLOCK_1='Russia'
BLOCK_2='China'
if resolve_block <<'EOF'
99
EOF
then
  fail "resolve_block should fail for out-of-range numeric choice"
fi
[ -z "${BLOCK:-}" ] || fail "BLOCK must stay empty after invalid numeric choice"
unset BLOCK_COUNT BLOCK_1 BLOCK_2

# --- Загрузка релиза: причина отказа и обход через mihomo ---
case $(bootstrap_curl_reason 6) in *DNS*) ;; *) fail "curl 6 должен объясняться как DNS" ;; esac
case $(bootstrap_curl_reason 28) in *таймаут*) ;; *) fail "curl 28 должен объясняться как таймаут" ;; esac
case $(bootstrap_curl_reason 99) in *'код curl 99'*) ;; *) fail "неизвестный код должен печататься" ;; esac

PROXY_CFG=$TEST_ROOT/proxy-config.yaml
printf 'mixed-port: 7890\nexternal-controller: 0.0.0.0:9090\n' > "$PROXY_CFG"
(
  CONFIG=$PROXY_CFG
  # Напрямую - "блокировка" (curl 35), через прокси - успех.
  bootstrap_http_get() { [ -n "${BOOTSTRAP_PROXY:-}" ] || return 35; printf 'ok\n'; }
  bootstrap_download_to https://example.test/manifest.txt "$TEST_ROOT/dl.txt" 100 2>"$TEST_ROOT/dl.err" \
    || fail "загрузка должна пройти через mixed-port из конфига"
  assert_eq "$BOOTSTRAP_PROXY" 'http://127.0.0.1:7890'
  grep -q 'напрямую: соединение оборвано' "$TEST_ROOT/dl.err" || fail "нет причины отказа прямой загрузки"
  # Следующий файл сразу идёт через тот же прокси.
  bootstrap_download_to https://example.test/f2 "$TEST_ROOT/dl2.txt" 100 2>/dev/null || fail "второй файл через прокси"
) || exit 1

(
  # Портов в конфиге нет - временно открываем mixed-port через API и закрываем.
  printf 'external-controller: 0.0.0.0:9191\nsecret: s3\n' > "$PROXY_CFG"
  CONFIG=$PROXY_CFG
  PATCH_LOG=$TEST_ROOT/patch.log; : > "$PATCH_LOG"
  bootstrap_api_patch() { echo "$BOOTSTRAP_API $BOOTSTRAP_API_SECRET $1" >> "$PATCH_LOG"; }
  bootstrap_enable_proxy 2>/dev/null || fail "временный mixed-port через API"
  assert_eq "$BOOTSTRAP_PROXY" 'http://127.0.0.1:17890'
  bootstrap_disable_proxy
  assert_eq "$(sed -n 1p "$PATCH_LOG")" '127.0.0.1:9191 s3 {"mixed-port": 17890}'
  assert_eq "$(sed -n 2p "$PATCH_LOG")" '127.0.0.1:9191 s3 {"mixed-port": 0}'
) || exit 1

(
  # Ни портов, ни API - отказ с подсказкой.
  printf 'allow-lan: true\n' > "$PROXY_CFG"
  CONFIG=$PROXY_CFG
  bootstrap_api_patch() { return 1; }
  bootstrap_http_get() { return 6; }
  if bootstrap_download_to https://example.test/m "$TEST_ROOT/dl3.txt" 100 2>"$TEST_ROOT/dl3.err"; then
    fail "без прокси загрузка должна провалиться"
  fi
  assert_eq "$BOOTSTRAP_FAIL_HINT" '1'
  grep -q 'Обойти через mihomo не вышло' "$TEST_ROOT/dl3.err" || fail "нет сообщения о неудачном обходе"
  bootstrap_fail_hint 2>&1 | grep -q 'INSTALL_PROXY=' || fail "подсказка должна предлагать INSTALL_PROXY"
) || exit 1

(
  # INSTALL_PROXY важнее конфига.
  printf 'mixed-port: 7890\n' > "$PROXY_CFG"
  CONFIG=$PROXY_CFG
  INSTALL_PROXY=socks5h://10.0.0.1:1080
  bootstrap_enable_proxy 2>/dev/null
  assert_eq "$BOOTSTRAP_PROXY" 'socks5h://10.0.0.1:1080'
) || exit 1
echo "test_install.sh: обход загрузки через mihomo OK" >&2

(
  # Повторы: два обрыва (56), потом успех - без перехода на прокси.
  CONFIG=$TEST_ROOT/no-such-config.yaml
  INSTALL_RETRY_DELAY=0
  CNT=$TEST_ROOT/retry.cnt; echo 0 > "$CNT"
  bootstrap_http_get() { n=$(($(cat "$CNT") + 1)); echo "$n" > "$CNT"; [ "$n" -ge 3 ] || return 56; printf 'ok\n'; }
  bootstrap_download_to https://example.test/r "$TEST_ROOT/r.txt" 100 2>"$TEST_ROOT/r.err" || fail "третья попытка должна пройти"
  assert_eq "$(cat "$CNT")" '3'
  assert_eq "${BOOTSTRAP_PROXY:-}" ''
  grep -q 'повтор 2 из 3' "$TEST_ROOT/r.err" || fail "нет сообщения о повторе"
) || exit 1

(
  # Таймаут (28) и ошибка HTTP (22) не повторяются.
  CONFIG=$TEST_ROOT/no-such-config.yaml
  INSTALL_RETRY_DELAY=0
  INSTALL_PROXY_FALLBACK=0
  for code in 28 22; do
    CNT=$TEST_ROOT/retry.cnt; echo 0 > "$CNT"
    BOOTSTRAP_PROXY_TRIED=
    bootstrap_http_get() { echo $(($(cat "$CNT") + 1)) > "$CNT"; return "$code"; }
    bootstrap_download_to https://example.test/r "$TEST_ROOT/r.txt" 100 2>/dev/null && fail "код $code должен провалиться"
    assert_eq "$(cat "$CNT")" '1'
  done
) || exit 1
echo "test_install.sh: повторы загрузки OK" >&2

CRON_BIN=$TEST_ROOT/cronbin
mkdir -p "$CRON_BIN"
CRON_STORE=$TEST_ROOT/crontab.txt
: > "$CRON_STORE"
cat > "$CRON_BIN/crontab" <<EOF
#!/bin/sh
if [ "\$1" = "-l" ]; then cat "$CRON_STORE" 2>/dev/null; exit 0; fi
if [ "\$1" = "-" ]; then cat > "$CRON_STORE"; exit 0; fi
exit 1
EOF
chmod +x "$CRON_BIN/crontab"

(
  PATH="$CRON_BIN:$PATH"
  export PATH
  TMPROOT=$TEST_ROOT
  INSTALLED_SCRIPT=/opt/etc/mihomo/speedtest2.sh
  install_cron
)
grep -qF '0 */3 * * * /opt/etc/mihomo/speedtest2.sh' "$CRON_STORE" \
  || fail "cron line missing after first install"
LINES1=$(wc -l < "$CRON_STORE" | tr -d ' ')

(
  PATH="$CRON_BIN:$PATH"
  export PATH
  TMPROOT=$TEST_ROOT
  INSTALLED_SCRIPT=/opt/etc/mihomo/speedtest2.sh
  install_cron
)
LINES2=$(wc -l < "$CRON_STORE" | tr -d ' ')
assert_eq "$LINES1" "$LINES2"
[ -f "$TEST_ROOT/cron.bak" ] || fail "cron backup was not written"

# --- install_update_check_cron(): отдельная от install_cron() cron-строка,
#     идемпотентна, использует собственный бэкап-файл ---
(
  PATH="$CRON_BIN:$PATH"
  export PATH
  TMPROOT=$TEST_ROOT
  UPDATE_CHECK_SCRIPT=/opt/etc/mihomo/stats_update.sh
  install_update_check_cron
)
grep -qF '/opt/etc/mihomo/stats_update.sh check' "$CRON_STORE" || fail "update-check cron line missing"
grep -qF '0 */3 * * * /opt/etc/mihomo/speedtest2.sh' "$CRON_STORE" || fail "install_update_check_cron стёр старую cron-строку speedtest"
[ -f "$TEST_ROOT/cron-update.bak" ] || fail "cron-update.bak не создан"
LINES_BEFORE=$(wc -l < "$CRON_STORE" | tr -d ' ')
(
  PATH="$CRON_BIN:$PATH"
  export PATH
  TMPROOT=$TEST_ROOT
  UPDATE_CHECK_SCRIPT=/opt/etc/mihomo/stats_update.sh
  install_update_check_cron
)
LINES_AFTER=$(wc -l < "$CRON_STORE" | tr -d ' ')
assert_eq "$LINES_BEFORE" "$LINES_AFTER"

ATOMIC_DIR=$TEST_ROOT/atomic
mkdir -p "$ATOMIC_DIR"
printf 'content-v1\n' > "$ATOMIC_DIR/src.txt"
atomic_install "$ATOMIC_DIR/src.txt" "$ATOMIC_DIR/dst.txt" \
  || fail "atomic_install failed on clean write"
grep -q 'content-v1' "$ATOMIC_DIR/dst.txt" || fail "atomic_install did not write content"
[ -f "$ATOMIC_DIR/.dst.txt.$$" ] && fail "atomic_install left a temp file"

ENVOUT=$TEST_ROOT/speedtest2.env
SOURCES='/opt/etc/mihomo/config.yaml /opt/etc/mihomo/proxy-providers/a.yaml'
EXTYPE='trojan|ss'
BLOCK='Russia|RU'
BLOCK_SOURCE='из конфига'
MIN_SPEED=1572864
write_env "$ENVOUT" || fail "write_env failed"
grep -qF "SOURCES='/opt/etc/mihomo/config.yaml /opt/etc/mihomo/proxy-providers/a.yaml'" "$ENVOUT" \
  || fail "write_env lost SOURCES"
grep -qF "EXTYPE='trojan|ss'" "$ENVOUT" || fail "write_env lost EXTYPE"
grep -qF "BLOCK='Russia|RU'" "$ENVOUT" || fail "write_env lost BLOCK"
grep -qF "MIN_SPEED='1572864'" "$ENVOUT" || fail "write_env lost MIN_SPEED"

recalibrate_env "$ENVOUT" 2097152 || fail "recalibrate_env failed"
grep -qF "MIN_SPEED='2097152'" "$ENVOUT" || fail "recalibrate_env did not update MIN_SPEED"
grep -qF "BLOCK='Russia|RU'" "$ENVOUT" || fail "recalibrate_env damaged BLOCK"
assert_eq "$(grep -c '^MIN_SPEED=' "$ENVOUT" | tr -d ' ')" 1

RECAL_ENV=$TEST_ROOT/recal/speedtest2.env
mkdir -p "$TEST_ROOT/recal"
printf '%s\n' "SOURCES='/a.yaml'" "BLOCK='Russia|RU'" "MIN_SPEED='1048576'" > "$RECAL_ENV"

cat > "$TEST_ROOT/recal-curl" <<'EOF'
#!/bin/sh
echo "200 8388608"
EOF
chmod +x "$TEST_ROOT/recal-curl"

(
  PATH="$TEST_ROOT:$PATH"
  cp "$TEST_ROOT/recal-curl" "$TEST_ROOT/curl"
  export PATH
  DIR=$TEST_ROOT/recal
  ENVFILE=$RECAL_ENV
  recalibrate_main
)
grep -q '^MIN_SPEED=' "$RECAL_ENV" || fail "recalibrate_main lost MIN_SPEED"
grep -qF "BLOCK='Russia|RU'" "$RECAL_ENV" || fail "recalibrate_main damaged BLOCK"
if grep -qF "MIN_SPEED='1048576'" "$RECAL_ENV"; then
  fail "recalibrate_main did not change MIN_SPEED"
fi

MISSING_DIR=$TEST_ROOT/recal-missing
mkdir -p "$MISSING_DIR"
if (
  DIR=$MISSING_DIR
  ENVFILE=$MISSING_DIR/speedtest2.env
  recalibrate_main
); then
  fail "recalibrate_main should fail without an existing speedtest2.env"
fi

# main() должен звать проверку процесса mihomo/версий раньше любой другой
# логики: если pidof не находит mihomo, main обязан прерваться с
# диагностикой version_check.sh, не доходя до проверки CONFIG и т.д.
MISSING_PIDOF=$(mktemp -d)
cat > "$MISSING_PIDOF/pidof" <<'EOF'
#!/bin/sh
exit 1
EOF
chmod +x "$MISSING_PIDOF/pidof"
WORK=$(mktemp -d)
if PATH="$MISSING_PIDOF:$PATH" DIR="$WORK" CONFIG="$WORK/config.yaml" \
   sh "$SCRIPT" 2>"$WORK/err.log"; then
  fail "main should abort when mihomo process is missing"
fi
grep -q "Процесс mihomo не найден" "$WORK/err.log" || fail "missing process diagnostic"
rm -rf "$MISSING_PIDOF" "$WORK"

FIXDIR=$TEST_ROOT/install-fixture
mkdir -p "$FIXDIR/proxy-providers" "$FIXDIR/bin"
cp "$ROOT/speedtest-runtime/speedtest2.sh" "$ROOT/speedtest-runtime/prep.awk" "$ROOT/speedtest-runtime/providers.awk" "$ROOT/installer/version_check.sh" "$ROOT/web/render_stats.awk" "$ROOT/web/stats_cgi.sh" "$ROOT/web/stats_run.sh" "$ROOT/web/stats_update.sh" "$ROOT/web/stats_config.sh" "$ROOT/web/stats_xkeen.sh" "$ROOT/web/stats_codemirror.js" "$ROOT/web/stats_codemirror.css" "$ROOT/web/stats_httpd.py" "$ROOT/web/stats_auth.py" "$ROOT/web/stats_auth.sh" "$ROOT/web/stats_index.html" "$ROOT/web/stats_style.css" "$ROOT/web/stats_app.js" "$ROOT/web/stats_app_core.js" "$ROOT/web/stats_app_stats.js" "$ROOT/web/stats_app_settings.js" "$ROOT/web/stats_app_updates.js" "$ROOT/web/stats_app_log.js" "$ROOT/web/stats_app_config.js" "$ROOT/web/stats_app_xkeen.js" "$ROOT/speedtest-runtime/node_stats_update.awk" "$ROOT/speedtest-runtime/sub_convert.awk" "$ROOT/web/render_progress.awk" "$ROOT/web/stats_service.sh" "$ROOT/web/stats_init.sh" "$ROOT/install.sh" "$ROOT/uninstall.sh" "$ROOT/mihomo-speedtest.sh" "$ROOT/config-tools/setup.sh" "$ROOT/config-tools/detect_ua.sh" "$ROOT/config-tools/render_config.awk" "$ROOT/config-tools/fast_wg.awk" "$ROOT/config-tools/existing_config.awk" "$ROOT/config-tools/config.example.yaml" "$ROOT/updater/update.sh" "$ROOT/updater/update_plan.awk" "$ROOT/updater/update_prepare.sh" "$ROOT/updater/update_transaction.sh" "$ROOT/config-tools/migrate_config.sh" "$ROOT/config-tools/migrate_config.awk" "$ROOT/config-tools/config_diff.awk" "$FIXDIR/"

# Порция 3 (независимая служба): реальный STATS_HTTPD_PY/STATS_HTTPD_CMD
# ни к чему - main() ниже теперь сам вызывает "$INITD_SCRIPT restart" не
# дожидаясь пробного прогона (SKIP_TRIAL=1 тут не помогает), а значит
# supervisor реально форкнет фоновый процесс. Подставляем тот же приём,
# что в test_stats_service.sh/test_stats_init.sh - безобидный sh-скрипт
# вместо python3/busybox httpd, живущий, пока его не остановят явно.
FAKE_HTTPD=$FIXDIR/fake_httpd.sh
cat > "$FAKE_HTTPD" <<'EOF'
#!/bin/sh
while :; do sleep 1; done
EOF
chmod +x "$FAKE_HTTPD"

cat > "$FIXDIR/config.yaml" <<'EOF'
proxy-providers:
  demo:
    type: http
    url: "https://example.com/sub"
    path: ./proxy-providers/demo.yaml
    exclude-type: trojan|ss
    exclude-filter: 'Russia|RU'
  fast:
    type: file
    path: ./fast.yaml
EOF
printf 'proxies:\n  - name: n\n    type: vless\n    server: 1.2.3.4\n    port: 443\n' \
  > "$FIXDIR/proxy-providers/demo.yaml"

cat > "$FIXDIR/bin/mihomo" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$FIXDIR/bin/mihomo"

cat > "$FIXDIR/bin/curl" <<'EOF'
#!/bin/sh
echo "200 5242880"
EOF
chmod +x "$FIXDIR/bin/curl"

cat > "$FIXDIR/bin/crontab" <<EOF
#!/bin/sh
if [ "\$1" = "-l" ]; then cat "$FIXDIR/crontab.txt" 2>/dev/null; exit 0; fi
if [ "\$1" = "-" ]; then cat > "$FIXDIR/crontab.txt"; exit 0; fi
exit 1
EOF
chmod +x "$FIXDIR/bin/crontab"

(
  PATH="$FIXDIR/bin:$PATH"
  export PATH
  DIR=$FIXDIR
  BIN=$FIXDIR/bin/mihomo
  SELFDIR=$FIXDIR
  CONFIG=$FIXDIR/config.yaml
  MIHOMO_DIR=$FIXDIR
  TMPROOT=$FIXDIR
  SKIP_TRIAL=1
  BLOCK='forced-for-this-test'
  # Порция 3: INITD_DIR/INITD_SCRIPT по умолчанию смотрят в реальный
  # /opt/etc/init.d - переопределяем на путь внутри фикстуры, иначе
  # install_files() попробует писать в системный каталог этой машины.
  # STATS_SERVICE_RUNTIME_DIR/STATS_HTTPD_PY_CMD/STATS_HTTPD_PY нужны
  # экспортированными - main() запускает "$INITD_SCRIPT restart" как
  # отдельный процесс (stats_init.sh -> stats_service.sh), который читает
  # их из окружения, а не из переменных этого подшелла напрямую.
  INITD_DIR=$FIXDIR/etc-init.d
  export DIR
  export MIHOMO_DIR
  export STATS_SERVICE_RUNTIME_DIR="$FIXDIR/runtime"
  export STATS_HTTPD_PY_CMD=sh
  export STATS_HTTPD_PY="$FAKE_HTTPD"
  export STATS_HTTPD_CMD="sh $FAKE_HTTPD"
  # INSTALLED_SCRIPT/STATS_SERVICE_DEST/INITD_SCRIPT уже вычислены от
  # дефолтного DIR/INITD_DIR при первом sourcing этого файла (строка 18) и
  # как обычные переменные процесса наследуются даже в этот forked-
  # подшелл; без unset они сохранили бы старые пути вместо путей внутри
  # фикстуры ("${VAR:-default}" не пересчитывает уже непустую переменную).
  unset INSTALLED_SCRIPT STATS_SERVICE_DEST INITD_SCRIPT
  INSTALL_LIB_ONLY=1 . "$SCRIPT"
  main
)

[ -f "$FIXDIR/speedtest2.env" ] || fail "speedtest2.env was not written"
grep -qF "SOURCES='$FIXDIR/config.yaml $FIXDIR/proxy-providers/demo.yaml'" "$FIXDIR/speedtest2.env" \
  || fail "SOURCES missing expected path (CONFIG should lead, so static proxies: nodes are tested too)"
grep -qF "BLOCK='forced-for-this-test'" "$FIXDIR/speedtest2.env" \
  || fail "BLOCK override was not honored"
grep -q '^MIN_SPEED=' "$FIXDIR/speedtest2.env" || fail "MIN_SPEED missing"
[ -x "$FIXDIR/speedtest2.sh" ] || fail "speedtest2.sh was not installed executable"
[ -f "$FIXDIR/prep.awk" ] || fail "prep.awk was not installed"
[ -f "$FIXDIR/render_stats.awk" ] || fail "render_stats.awk was not installed"
[ -x "$FIXDIR/stats_cgi.sh" ] || fail "stats_cgi.sh was not installed executable"
[ -x "$FIXDIR/stats_run.sh" ] || fail "stats_run.sh was not installed executable"
[ -x "$FIXDIR/stats_update.sh" ] || fail "stats_update.sh не установлен или не исполняем"
[ -f "$FIXDIR/stats_httpd.py" ] || fail "stats_httpd.py was not installed"
[ -f "$FIXDIR/stats_auth.py" ] || fail "stats_auth.py was not installed"
[ -x "$FIXDIR/stats_auth.sh" ] || fail "stats_auth.sh was not installed executable"
[ -f "$FIXDIR/.stats-auth/setup-code.sha256" ] || fail "setup-code hash was not initialized"
[ -f "$FIXDIR/node_stats_update.awk" ] || fail "node_stats_update.awk was not installed"
[ -f "$FIXDIR/render_progress.awk" ] || fail "render_progress.awk was not installed"
[ -f "$FIXDIR/sub_convert.awk" ] || fail "sub_convert.awk was not installed"
grep -qF "$FIXDIR/speedtest2.sh" "$FIXDIR/crontab.txt" || fail "cron line was not installed"

INITD_SCRIPT_FIXDIR=$FIXDIR/etc-init.d/S80speedtest-stats
[ -x "$FIXDIR/stats_service.sh" ] || fail "stats_service.sh was not installed executable"
[ -x "$INITD_SCRIPT_FIXDIR" ] || fail "stats_init.sh (S80speedtest-stats) was not installed executable at $INITD_SCRIPT_FIXDIR"

# Порция 3: независимая служба должна быть запущена самим install.sh
# сразу, независимо от пробного прогона (SKIP_TRIAL=1 в этом сценарии).
[ -f "$FIXDIR/runtime/supervisor.pid" ] \
  || fail "install.sh did not start the independent stats service (no supervisor.pid) even though SKIP_TRIAL=1"
sup_pid=$(cat "$FIXDIR/runtime/supervisor.pid")
kill -0 "$sup_pid" 2>/dev/null \
  || fail "install.sh started the stats service, but its supervisor is not actually running"

# уборка - останавливаем фоновый supervisor, запущенный main() выше, той
# же обёрткой окружения (STATS_SERVICE_RUNTIME_DIR), что и сам запуск.
(
  STATS_SERVICE_RUNTIME_DIR=$FIXDIR/runtime
  export STATS_SERVICE_RUNTIME_DIR
  STOP_WAIT=3
  export STOP_WAIT
  "$INITD_SCRIPT_FIXDIR" stop >/dev/null 2>&1 || true
)

if (
  curl() { return 7; }
  result=$(measure_channel)
  [ "$result" = 0 ]
); then
  :
else
  fail "measure_channel did not fall back to 0 on curl failure"
fi

if (
  curl() { return 7; }
  measure_channel >/dev/null
); then
  :
else
  fail "measure_channel under set -eu must not abort the whole shell on curl failure"
fi

FIXDIR2=$TEST_ROOT/install-fixture-curlfail
mkdir -p "$FIXDIR2/proxy-providers" "$FIXDIR2/bin"
cp "$ROOT/speedtest-runtime/speedtest2.sh" "$ROOT/speedtest-runtime/prep.awk" "$ROOT/speedtest-runtime/providers.awk" "$ROOT/installer/version_check.sh" "$ROOT/web/render_stats.awk" "$ROOT/web/stats_cgi.sh" "$ROOT/web/stats_run.sh" "$ROOT/web/stats_update.sh" "$ROOT/web/stats_config.sh" "$ROOT/web/stats_xkeen.sh" "$ROOT/web/stats_codemirror.js" "$ROOT/web/stats_codemirror.css" "$ROOT/web/stats_httpd.py" "$ROOT/web/stats_auth.py" "$ROOT/web/stats_auth.sh" "$ROOT/web/stats_index.html" "$ROOT/web/stats_style.css" "$ROOT/web/stats_app.js" "$ROOT/web/stats_app_core.js" "$ROOT/web/stats_app_stats.js" "$ROOT/web/stats_app_settings.js" "$ROOT/web/stats_app_updates.js" "$ROOT/web/stats_app_log.js" "$ROOT/web/stats_app_config.js" "$ROOT/web/stats_app_xkeen.js" "$ROOT/speedtest-runtime/node_stats_update.awk" "$ROOT/speedtest-runtime/sub_convert.awk" "$ROOT/web/render_progress.awk" "$ROOT/web/stats_service.sh" "$ROOT/web/stats_init.sh" "$ROOT/install.sh" "$ROOT/uninstall.sh" "$ROOT/mihomo-speedtest.sh" "$ROOT/config-tools/setup.sh" "$ROOT/config-tools/detect_ua.sh" "$ROOT/config-tools/render_config.awk" "$ROOT/config-tools/fast_wg.awk" "$ROOT/config-tools/existing_config.awk" "$ROOT/config-tools/config.example.yaml" "$ROOT/updater/update.sh" "$ROOT/updater/update_plan.awk" "$ROOT/updater/update_prepare.sh" "$ROOT/updater/update_transaction.sh" "$ROOT/config-tools/migrate_config.sh" "$ROOT/config-tools/migrate_config.awk" "$ROOT/config-tools/config_diff.awk" "$FIXDIR2/"

FAKE_HTTPD2=$FIXDIR2/fake_httpd.sh
cat > "$FAKE_HTTPD2" <<'EOF'
#!/bin/sh
while :; do sleep 1; done
EOF
chmod +x "$FAKE_HTTPD2"

cat > "$FIXDIR2/config.yaml" <<'EOF'
proxy-providers:
  demo:
    type: http
    url: "https://example.com/sub"
    path: ./proxy-providers/demo.yaml
    exclude-type: trojan|ss
    exclude-filter: 'Russia|RU'
  fast:
    type: file
    path: ./fast.yaml
EOF
printf 'proxies:\n  - name: n\n    type: vless\n    server: 1.2.3.4\n    port: 443\n' \
  > "$FIXDIR2/proxy-providers/demo.yaml"

cat > "$FIXDIR2/bin/mihomo" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$FIXDIR2/bin/mihomo"

# curl всегда возвращает ошибку - имитирует сбой сети/DNS/таймаут на
# роутере. До фикса это ронял весь install.sh через set -eu; теперь
# main() должен откатиться на дефолтный MIN_SPEED из speedtest2.sh и
# завершиться успешно (без аварийного выхода).
cat > "$FIXDIR2/bin/curl" <<'EOF'
#!/bin/sh
exit 7
EOF
chmod +x "$FIXDIR2/bin/curl"

cat > "$FIXDIR2/bin/crontab" <<EOF
#!/bin/sh
if [ "\$1" = "-l" ]; then cat "$FIXDIR2/crontab.txt" 2>/dev/null; exit 0; fi
if [ "\$1" = "-" ]; then cat > "$FIXDIR2/crontab.txt"; exit 0; fi
exit 1
EOF
chmod +x "$FIXDIR2/bin/crontab"

DEFAULT_MIN_SPEED=$(awk -F= '/^MIN_SPEED=/{split($2,a," "); print a[1]; exit}' "$ROOT/speedtest-runtime/speedtest2.sh")
[ "$DEFAULT_MIN_SPEED" = 1048576 ] || fail "test setup: unexpected default MIN_SPEED parsed: [$DEFAULT_MIN_SPEED]"

(
  PATH="$FIXDIR2/bin:$PATH"
  export PATH
  DIR=$FIXDIR2
  BIN=$FIXDIR2/bin/mihomo
  SELFDIR=$FIXDIR2
  CONFIG=$FIXDIR2/config.yaml
  MIHOMO_DIR=$FIXDIR2
  TMPROOT=$FIXDIR2
  SKIP_TRIAL=1
  BLOCK='forced-for-this-test'
  # см. комментарий у FIXDIR выше - та же изоляция независимой службы.
  INITD_DIR=$FIXDIR2/etc-init.d
  export DIR
  export MIHOMO_DIR
  export STATS_SERVICE_RUNTIME_DIR="$FIXDIR2/runtime"
  export STATS_HTTPD_PY_CMD=sh
  export STATS_HTTPD_PY="$FAKE_HTTPD2"
  export STATS_HTTPD_CMD="sh $FAKE_HTTPD2"
  unset INSTALLED_SCRIPT STATS_SERVICE_DEST INITD_SCRIPT
  INSTALL_LIB_ONLY=1 . "$SCRIPT"
  main
) || fail "main must not abort install.sh when curl fails (set -e regression)"

(
  STATS_SERVICE_RUNTIME_DIR=$FIXDIR2/runtime
  export STATS_SERVICE_RUNTIME_DIR
  STOP_WAIT=3
  export STOP_WAIT
  "$FIXDIR2/etc-init.d/S80speedtest-stats" stop >/dev/null 2>&1 || true
)

[ -f "$FIXDIR2/speedtest2.env" ] || fail "speedtest2.env was not written after curl failure"
grep -qF "MIN_SPEED='$DEFAULT_MIN_SPEED'" "$FIXDIR2/speedtest2.env" \
  || fail "main did not fall back to speedtest2.sh default MIN_SPEED on curl failure"

# recalibrate_main тоже не должен ронять install.sh при сбое curl -
# он обязан корректно вернуть код ошибки и оставить старый MIN_SPEED.
RECAL_FAIL_ENV=$TEST_ROOT/recal-fail/speedtest2.env
mkdir -p "$TEST_ROOT/recal-fail"
printf '%s\n' "SOURCES='/a.yaml'" "BLOCK='Russia|RU'" "MIN_SPEED='1048576'" > "$RECAL_FAIL_ENV"
if (
  curl() { return 7; }
  DIR=$TEST_ROOT/recal-fail
  ENVFILE=$RECAL_FAIL_ENV
  recalibrate_main
); then
  fail "recalibrate_main should report failure when curl fails, not abort or silently succeed"
fi
grep -qF "MIN_SPEED='1048576'" "$RECAL_FAIL_ENV" \
  || fail "recalibrate_main must not touch MIN_SPEED when curl fails"

# ensure_python3: политика автоустановки python3 через opkg. На машине,
# где реально гоняются тесты, python3 почти всегда уже есть, а opkg нет -
# без переопределения have_python3/have_opkg/opkg сценарий "автоустановка"
# никогда бы не выполнился, поэтому подменяем их шелл-функциями прямо в
# подшелле (тот же приём, что и curl() { return 7; } выше).

OUT=$(
  have_python3() { return 0; }
  opkg() { echo "opkg не должен вызываться при уже установленном python3" >&2; return 1; }
  ensure_python3 2>&1
) || fail "ensure_python3 must succeed when python3 already present"
[ -z "$OUT" ] || fail "ensure_python3 must stay silent when python3 already present, got: $OUT"

if OUT=$(
  have_python3() { return 1; }
  have_opkg() { return 1; }
  ensure_python3 2>&1
); then fail "ensure_python3 must fail when opkg is unavailable"; fi
printf '%s' "$OUT" | grep -q "opkg недоступен"   || fail "expected 'opkg недоступен' warning when opkg is missing, got: $OUT"

PY_STATE1=$TEST_ROOT/py-state1
: > "$PY_STATE1"
OUT=$(
  PY_STATE1=$PY_STATE1
  have_python3() { grep -q installed "$PY_STATE1" 2>/dev/null; }
  have_opkg() { return 0; }
  opkg() {
    [ "$1" = install ] && [ "$2" = python3 ] || return 1
    echo installed > "$PY_STATE1"
    return 0
  }
  ensure_python3 2>&1
) || fail "ensure_python3 must succeed when opkg install python3 works on first try"
printf '%s' "$OUT" | grep -q "успешно установлен"   || fail "expected success message on first-try opkg install, got: $OUT"

PY_STATE2=$TEST_ROOT/py-state2
PY_ATTEMPT2=$TEST_ROOT/py-attempt2
: > "$PY_STATE2"
: > "$PY_ATTEMPT2"
OUT=$(
  PY_STATE2=$PY_STATE2
  PY_ATTEMPT2=$PY_ATTEMPT2
  have_python3() { grep -q installed "$PY_STATE2" 2>/dev/null; }
  have_opkg() { return 0; }
  opkg() {
    if [ "$1" = update ]; then return 0; fi
    if [ "$1" = install ] && [ "$2" = python3 ]; then
      if [ -s "$PY_ATTEMPT2" ]; then
        echo installed > "$PY_STATE2"
        return 0
      fi
      echo 1 > "$PY_ATTEMPT2"
      return 1
    fi
    return 1
  }
  ensure_python3 2>&1
) || fail "ensure_python3 must succeed after opkg update + retry"
printf '%s' "$OUT" | grep -q "обновляю список пакетов"   || fail "expected retry-via-opkg-update message, got: $OUT"
printf '%s' "$OUT" | grep -q "успешно установлен"   || fail "expected eventual success message after retry, got: $OUT"

if OUT=$(
  have_python3() { return 1; }
  have_opkg() { return 0; }
  opkg() { return 1; }
  ensure_python3 2>&1
); then fail "ensure_python3 must fail when opkg install keeps failing"; fi
printf '%s' "$OUT" | grep -q "Не удалось автоматически поставить"   || fail "expected final failure warning when opkg install never succeeds, got: $OUT"

# --- Финальный обзор (C1a): mihomo -t должен проверять конфиг относительно
# MIHOMO_DIR (каталог самой Mihomo: geo-базы, provider-кэши), а не DIR
# (каталог проекта speedtest2-stats). После разделения каталогов (см.
# docs/superpowers/specs/2026-09-25-install-dir-separation-design.md) это
# два разных пути; до исправления install.sh передавал сюда "$DIR", что на
# реальном роутере ломало бы пробный запуск mihomo (там нет geo-баз).
FIXDIR3=$TEST_ROOT/install-fixture-mihomo-dir-arg
mkdir -p "$FIXDIR3/proxy-providers" "$FIXDIR3/bin"
cp "$ROOT/speedtest-runtime/speedtest2.sh" "$ROOT/speedtest-runtime/prep.awk" "$ROOT/speedtest-runtime/providers.awk" "$ROOT/installer/version_check.sh" "$ROOT/web/render_stats.awk" "$ROOT/web/stats_cgi.sh" "$ROOT/web/stats_run.sh" "$ROOT/web/stats_update.sh" "$ROOT/web/stats_config.sh" "$ROOT/web/stats_xkeen.sh" "$ROOT/web/stats_codemirror.js" "$ROOT/web/stats_codemirror.css" "$ROOT/web/stats_httpd.py" "$ROOT/web/stats_auth.py" "$ROOT/web/stats_auth.sh" "$ROOT/web/stats_index.html" "$ROOT/web/stats_style.css" "$ROOT/web/stats_app.js" "$ROOT/web/stats_app_core.js" "$ROOT/web/stats_app_stats.js" "$ROOT/web/stats_app_settings.js" "$ROOT/web/stats_app_updates.js" "$ROOT/web/stats_app_log.js" "$ROOT/web/stats_app_config.js" "$ROOT/web/stats_app_xkeen.js" "$ROOT/speedtest-runtime/node_stats_update.awk" "$ROOT/speedtest-runtime/sub_convert.awk" "$ROOT/web/render_progress.awk" "$ROOT/web/stats_service.sh" "$ROOT/web/stats_init.sh" "$ROOT/install.sh" "$ROOT/uninstall.sh" "$ROOT/mihomo-speedtest.sh" "$ROOT/config-tools/setup.sh" "$ROOT/config-tools/detect_ua.sh" "$ROOT/config-tools/render_config.awk" "$ROOT/config-tools/fast_wg.awk" "$ROOT/config-tools/existing_config.awk" "$ROOT/config-tools/config.example.yaml" "$ROOT/updater/update.sh" "$ROOT/updater/update_plan.awk" "$ROOT/updater/update_prepare.sh" "$ROOT/updater/update_transaction.sh" "$ROOT/config-tools/migrate_config.sh" "$ROOT/config-tools/migrate_config.awk" "$ROOT/config-tools/config_diff.awk" "$FIXDIR3/"

cat > "$FIXDIR3/config.yaml" <<'EOF'
proxy-providers:
  demo:
    type: http
    url: "https://example.com/sub"
    path: ./proxy-providers/demo.yaml
EOF

MIHOMO_DIR_ARG_LOG=$TEST_ROOT/mihomo-arg.log
cat > "$FIXDIR3/bin/mihomo" <<EOF
#!/bin/sh
echo "\$@" > "$MIHOMO_DIR_ARG_LOG"
exit 0
EOF
chmod +x "$FIXDIR3/bin/mihomo"

# Каталог самой Mihomo нарочно ОТЛИЧАЕТСЯ от DIR - это и есть суть
# регрессии C1a: если install.sh перепутает их местами, лог ниже покажет
# "-d $FIXDIR3" вместо "-d $MIHOMO_HOME3".
MIHOMO_HOME3=$TEST_ROOT/mihomo-home-distinct
mkdir -p "$MIHOMO_HOME3"

(
  PATH="$FIXDIR3/bin:$PATH"
  export PATH
  DIR=$FIXDIR3
  BIN=$FIXDIR3/bin/mihomo
  SELFDIR=$FIXDIR3
  CONFIG=$FIXDIR3/config.yaml
  MIHOMO_DIR=$MIHOMO_HOME3
  export DIR MIHOMO_DIR
  INSTALL_LIB_ONLY=1 . "$SCRIPT"
  main >/dev/null 2>&1 || true
)

[ -f "$MIHOMO_DIR_ARG_LOG" ] \
  || fail "install.sh main() ни разу не вызвал \$BIN (mihomo -t) - регрессионный тест C1a не может ничего проверить"
grep -qF -- "-d $MIHOMO_HOME3 " "$MIHOMO_DIR_ARG_LOG" \
  || fail "install.sh передал mihomo -t не тот -d: ожидался MIHOMO_DIR ($MIHOMO_HOME3), получено: $(cat "$MIHOMO_DIR_ARG_LOG")"
grep -qF -- "-d $FIXDIR3 " "$MIHOMO_DIR_ARG_LOG" \
  && fail "install.sh передал mihomo -t каталог DIR ($FIXDIR3) вместо MIHOMO_DIR - регрессия C1a"


# --- advertise_host()/print_web_url()/show_url_main() (Task 1, 2026-09-26 plan) ---
WORK_URL=$(mktemp -d)
FAKEBIN_URL=$(mktemp -d)
cat > "$FAKEBIN_URL/ip" <<'EOF'
#!/bin/sh
echo "2: br0    inet 192.168.1.1/24 scope global br0"
EOF
chmod +x "$FAKEBIN_URL/ip"

(
  PATH="$FAKEBIN_URL:$PATH"
  export PATH
  INSTALL_LIB_ONLY=1 SELFDIR="$ROOT/installer" . "$SCRIPT"
  DIR=$WORK_URL
  cat > "$DIR/speedtest2.env" <<'EOF'
STATS_HTTP_PORT='8899'
STATS_HTTP_BIND='0.0.0.0'
EOF
  out=$(print_web_url 2>&1)
  case "$out" in
    *"http://192.168.1.1:8899/stats.html"*) echo "FAIL: print_web_url показывает удалённую страницу stats.html: $out" >&2; exit 1 ;;
    *"http://192.168.1.1:8899/stats"*) ;;
    *) echo "FAIL: print_web_url не показал реальный LAN IP: $out" >&2; exit 1 ;;
  esac
)

(
  PATH="$FAKEBIN_URL:$PATH"
  export PATH
  INSTALL_LIB_ONLY=1 SELFDIR="$ROOT/installer" . "$SCRIPT"
  DIR=$WORK_URL
  cat > "$DIR/speedtest2.env" <<'EOF'
STATS_HTTP_PORT='8899'
STATS_HTTP_BIND='0.0.0.0'
STATS_HTTP_ENABLE='0'
EOF
  out=$(print_web_url 2>&1)
  case "$out" in
    *"отключ"*) ;;
    *) echo "FAIL: print_web_url должен сообщать об отключённом веб-сервисе: $out" >&2; exit 1 ;;
  esac
)

# Review Focus: show-url до первой установки (нет speedtest2.env вообще).
(
  PATH="$FAKEBIN_URL:$PATH"
  export PATH
  INSTALL_LIB_ONLY=1 SELFDIR="$ROOT/installer" . "$SCRIPT"
  DIR=$(mktemp -d)
  out=$(print_web_url 2>&1) || true
  case "$out" in
    *"не найден"*|*"сначала"*|*"установ"*) ;;
    *) echo "FAIL: print_web_url без speedtest2.env должен просить установить проект первым, а не молчать/угадывать URL: $out" >&2; exit 1 ;;
  esac
  rm -rf "$DIR"
)
# Роутер за роутером провайдера: WAN (eth3) тоже получает частный адрес и
# стоит в списке раньше LAN-моста. Вывод - реальный Keenetic.
FAKEBIN_WAN=$(mktemp -d)
cat > "$FAKEBIN_WAN/ip" <<'EOF'
#!/bin/sh
case "$*" in
  *route*) echo "default via 192.168.101.1 dev eth3  metric 1000 " ;;
  *addr*) cat "$FAKE_IP_ADDRS" ;;
esac
EOF
chmod +x "$FAKEBIN_WAN/ip"
FAKE_IP_ADDRS=$FAKEBIN_WAN/addrs
export FAKE_IP_ADDRS

check_advertise() {
  # $1 - bind, $2 - ожидаемый адрес, $3 - описание
  got=$(
    PATH="$FAKEBIN_WAN:$PATH"
    export PATH
    INSTALL_LIB_ONLY=1 SELFDIR="$ROOT/installer" . "$SCRIPT"
    advertise_host "$1"
  )
  [ "$got" = "$2" ] || { echo "FAIL: advertise_host ($3): ждали $2, получили '$got'" >&2; exit 1; }
}

cat > "$FAKE_IP_ADDRS" <<'EOF'
9: ezcfg0    inet 198.51.100.37/32 scope global ezcfg0\       valid_lft forever preferred_lft forever
11: eth3    inet 192.168.101.2/24 brd 192.168.101.255 scope global eth3\       valid_lft forever preferred_lft forever
35: br0    inet 192.168.2.1/24 brd 192.168.2.255 scope global br0\       valid_lft forever preferred_lft forever
36: br1    inet 10.1.30.1/24 brd 10.1.30.255 scope global br1\       valid_lft forever preferred_lft forever
39: nwg0    inet 172.16.83.3/24 scope global nwg0\       valid_lft forever preferred_lft forever
EOF
check_advertise 0.0.0.0 192.168.2.1 "br0 важнее частного WAN-адреса"
check_advertise 192.168.50.1 192.168.50.1 "явный STATS_HTTP_BIND"

cat > "$FAKE_IP_ADDRS" <<'EOF'
9: ezcfg0    inet 10.0.0.5/32 scope global ezcfg0\       valid_lft forever preferred_lft forever
11: eth3    inet 192.168.101.2/24 brd 192.168.101.255 scope global eth3\       valid_lft forever preferred_lft forever
36: br1    inet 10.1.30.1/24 brd 10.1.30.255 scope global br1\       valid_lft forever preferred_lft forever
EOF
check_advertise 0.0.0.0 10.1.30.1 "без br0 пропускаются WAN и /32"

cat > "$FAKE_IP_ADDRS" <<'EOF'
11: eth3    inet 192.168.101.2/24 brd 192.168.101.255 scope global eth3\       valid_lft forever preferred_lft forever
EOF
check_advertise 0.0.0.0 192.168.101.2 "единственный адрес - на WAN"

rm -rf "$WORK_URL" "$FAKEBIN_URL" "$FAKEBIN_WAN"
echo "test_install.sh: advertise_host/print_web_url OK"


# --- write_env() сохраняет STATS_HTTP_ENABLE при переустановке (Task 2, 2026-09-26 plan) ---
WORK_ENV=$(mktemp -d)
cat > "$WORK_ENV/speedtest2.env" <<'EOF'
SOURCES='old'
BLOCK='old'
MIN_SPEED='1'
STATS_HTTP_ENABLE=0
EOF
(
  INSTALL_LIB_ONLY=1 SELFDIR="$ROOT/installer" . "$SCRIPT"
  SOURCES=new BLOCK=new MIN_SPEED=1 BLOCK_SOURCE=test write_env "$WORK_ENV/speedtest2.env"
)
grep -qF "STATS_HTTP_ENABLE=0" "$WORK_ENV/speedtest2.env" \
  || { echo "FAIL: write_env потерял STATS_HTTP_ENABLE=0 при переустановке" >&2; exit 1; }
rm -rf "$WORK_ENV"

# UPDATE_CHANNEL (канал обновлений из веб-настроек) переживает переустановку
WORK_ENV_CH=$(mktemp -d)
printf "SOURCES='old'\nBLOCK='old'\nMIN_SPEED='1'\nUPDATE_CHANNEL='dev'\n" > "$WORK_ENV_CH/speedtest2.env"
(
  INSTALL_LIB_ONLY=1 SELFDIR="$ROOT/installer" . "$SCRIPT"
  SOURCES=new BLOCK=new MIN_SPEED=1 BLOCK_SOURCE=test write_env "$WORK_ENV_CH/speedtest2.env"
)
grep -qxF "UPDATE_CHANNEL='dev'" "$WORK_ENV_CH/speedtest2.env" \
  || { echo "FAIL: write_env потерял UPDATE_CHANNEL='dev' при переустановке" >&2; exit 1; }
rm -rf "$WORK_ENV_CH"

WORK_ENV2=$(mktemp -d)
(
  INSTALL_LIB_ONLY=1 SELFDIR="$ROOT/installer" . "$SCRIPT"
  SOURCES=new BLOCK=new MIN_SPEED=1 BLOCK_SOURCE=test write_env "$WORK_ENV2/speedtest2.env"
)
grep -qF "STATS_HTTP_ENABLE=1" "$WORK_ENV2/speedtest2.env" \
  || { echo "FAIL: write_env не проставил дефолт STATS_HTTP_ENABLE=1 на чистой установке" >&2; exit 1; }
rm -rf "$WORK_ENV2"
echo "test_install.sh: STATS_HTTP_ENABLE persistence OK"

# --- stop-web/start-web: до первой установки (Review Focus) ---
(
  INSTALL_LIB_ONLY=1 SELFDIR="$ROOT/installer" . "$SCRIPT"
  DIR=$(mktemp -d)
  if stop_web_main 2>"$DIR/err.log"; then
    echo "FAIL: stop_web_main не должен успевать без предыдущей установки" >&2; exit 1
  fi
  grep -q "сначала обычная установка" "$DIR/err.log" \
    || { echo "FAIL: stop_web_main не даёт понятной причины отказа: $(cat "$DIR/err.log")" >&2; exit 1; }
  rm -rf "$DIR"
)

# --- stop-web ставит флаг и останавливает init-скрипт ---
WORK_SW=$(mktemp -d)
touch "$WORK_SW/speedtest2.env"
FAKE_INITD=$WORK_SW/initd
cat > "$FAKE_INITD" <<EOF
#!/bin/sh
echo "\$1" >> "$WORK_SW/initd-calls.log"
exit 0
EOF
chmod +x "$FAKE_INITD"
(
  INSTALL_LIB_ONLY=1 SELFDIR="$ROOT/installer" . "$SCRIPT"
  DIR=$WORK_SW
  INITD_SCRIPT=$FAKE_INITD
  stop_web_main
)
grep -qF "STATS_HTTP_ENABLE=0" "$WORK_SW/speedtest2.env" || { echo "FAIL: stop_web_main не выставил флаг" >&2; exit 1; }
grep -qF "stop" "$WORK_SW/initd-calls.log" || { echo "FAIL: stop_web_main не вызвал \$INITD_SCRIPT stop" >&2; exit 1; }
rm -rf "$WORK_SW"

# --- Ревью (2026-09-26, финальный обзор): show_url_main() не должен
# обрываться, когда веб-служба остановлена (INITD_SCRIPT check возвращает
# ненулевой статус - это его нормальное поведение при stop). "[ -x
# "$INITD_SCRIPT" ] && "$INITD_SCRIPT" check" как отдельная команда даёт
# ненулевой статус функции целиком, и под set -eu это раньше валило
# show_url_main() ДО его "return 0" - то есть "mihomo-speedtest show-url"
# после "mihomo-speedtest stop-web" завершался бы с ошибкой вместо показа
# адреса. Важно: воспроизводится ТОЛЬКО через настоящий дочерний процесс
# ("sh $SCRIPT --show-url", как реально делает mihomo-speedtest.sh) - если
# завернуть вызов show_url_main в "( ... ) || ..." в ЭТОМ ЖЕ интерпретаторе,
# ошибка внутри && оказывается частью нефинального члена AND-OR-списка
# снаружи, и set -e её не замечает (POSIX-исключение для "команда не
# последняя в AND-OR-списке" распространяется и на подпроцесс целиком) -
# такая обёртка была бы ложным подтверждением.
WORK_SHOWURL=$(mktemp -d)
cat > "$WORK_SHOWURL/speedtest2.env" <<'EOF'
STATS_HTTP_PORT='8899'
STATS_HTTP_BIND='0.0.0.0'
STATS_HTTP_ENABLE='0'
EOF
FAKE_INITD_STOPPED=$WORK_SHOWURL/initd
cat > "$FAKE_INITD_STOPPED" <<'EOF'
#!/bin/sh
exit 1
EOF
chmod +x "$FAKE_INITD_STOPPED"
if DIR=$WORK_SHOWURL INITD_SCRIPT=$FAKE_INITD_STOPPED sh "$SCRIPT" --show-url >"$WORK_SHOWURL/out.log" 2>"$WORK_SHOWURL/err.log"; then
  :
else
  fail "sh install.sh --show-url завершился с ошибкой при остановленной службе (check вернул не 0) вместо тихого продолжения: $(cat "$WORK_SHOWURL/err.log")"
fi
rm -rf "$WORK_SHOWURL"
echo "test_install.sh: show-url при остановленной службе OK"

echo "test_install.sh: stop-web/start-web basic OK"


# --- Регрессия: после stop-web обычный install.sh (main(), без флагов)
# не поднимает веб-сервис повторно - ключевое свойство фичи (Task 2).
(
  DIR=$FIXDIR
  SELFDIR=$FIXDIR
  MIHOMO_DIR=$FIXDIR
  export STATS_SERVICE_RUNTIME_DIR="$FIXDIR/runtime"
  export STATS_HTTPD_PY_CMD=sh
  export STATS_HTTPD_PY="$FAKE_HTTPD"
  export STATS_HTTPD_CMD="sh $FAKE_HTTPD"
  INITD_SCRIPT=$INITD_SCRIPT_FIXDIR
  unset INSTALLED_SCRIPT STATS_SERVICE_DEST
  INSTALL_LIB_ONLY=1 . "$SCRIPT"
  stop_web_main
)
rm -f "$FIXDIR/runtime/supervisor.pid"
(
  PATH="$FIXDIR/bin:$PATH"
  export PATH
  DIR=$FIXDIR
  BIN=$FIXDIR/bin/mihomo
  SELFDIR=$FIXDIR
  CONFIG=$FIXDIR/config.yaml
  MIHOMO_DIR=$FIXDIR
  TMPROOT=$FIXDIR
  SKIP_TRIAL=1
  BLOCK='forced-for-this-test'
  INITD_DIR=$FIXDIR/etc-init.d
  export DIR MIHOMO_DIR
  export STATS_SERVICE_RUNTIME_DIR="$FIXDIR/runtime"
  export STATS_HTTPD_PY_CMD=sh
  export STATS_HTTPD_PY="$FAKE_HTTPD"
  export STATS_HTTPD_CMD="sh $FAKE_HTTPD"
  unset INSTALLED_SCRIPT STATS_SERVICE_DEST INITD_SCRIPT
  INSTALL_LIB_ONLY=1 . "$SCRIPT"
  main
)
[ ! -f "$FIXDIR/runtime/supervisor.pid" ] \
  || fail "install.sh поднял веб-сервис повторно, хотя STATS_HTTP_ENABLE=0 (stop-web) сохранён в speedtest2.env"
echo "test_install.sh: stop-web persists across reinstall (regression) OK"

echo "test_install: OK (Task 9 + final review fixes, C1a regression covered)"
