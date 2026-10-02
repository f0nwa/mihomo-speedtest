#!/bin/sh
set -eu
# Тесты uninstall.sh: остановка веб-службы статистики, снятие cron-строки,
# удаление установленных файлов надстройки, откат config.yaml к бэкапу
# setup.sh (с сохранением текущего конфига своим бэкапом) и опциональная
# полная очистка данных (PURGE_DATA=1). mihomo/xkeen/crontab/curl -
# фиктивные, как в test_install.sh/test_setup.sh; stats_init.sh и
# stats_service.sh настоящие, HTTP-бэкенд подменяется (см. fake_httpd.sh
# в test_stats_init.sh).

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
UNINSTALL=$ROOT/uninstall.sh
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/uninstall-test.XXXXXX")
trap 'rm -rf "$TEST_ROOT"' EXIT INT TERM

FAILED=0
fail() {
  echo "FAIL: $*" >&2
  FAILED=1
}

FAKEBIN=$TEST_ROOT/bin
mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/xkeen" <<'EOF'
#!/bin/sh
[ "$1" = "-restart" ] && exit 0
exit 0
EOF
cat > "$FAKEBIN/mihomo" <<'EOF'
#!/bin/sh
# "-t" - валидация: провалить только явно битый файл с меткой BADCONFIG.
for a in "$@"; do
  case "$a" in
    -f) shift_next=f ;;
    *)
      if [ "${shift_next:-}" = f ]; then
        grep -q BADCONFIG "$a" 2>/dev/null && exit 1
        shift_next=""
      fi
      ;;
  esac
done
exit 0
EOF
chmod +x "$FAKEBIN/xkeen" "$FAKEBIN/mihomo"

# --- фиктивный crontab поверх отдельного файла-хранилища ---
mk_fake_crontab() {
  store=$1
  bindir=$2
  mkdir -p "$bindir"
  cat > "$bindir/crontab" <<EOF
#!/bin/sh
if [ "\$1" = "-l" ]; then cat "$store" 2>/dev/null; exit 0; fi
if [ "\$1" = "-" ]; then cat > "$store"; exit 0; fi
exit 1
EOF
  chmod +x "$bindir/crontab"
}

# --- фиктивный curl: /version отвечает успехом сразу (mihomo "поднят") ---
cat > "$FAKEBIN/curl" <<'EOF'
#!/bin/sh
for a in "$@"; do
  case "$a" in
    *9090/version) exit 0 ;;
  esac
done
exit 0
EOF
chmod +x "$FAKEBIN/curl"

new_dir() {
  d=$TEST_ROOT/$1
  mkdir -p "$d"
  for f in $CORE_LIST; do
    echo "stub $f" > "$d/$f"
  done
  echo "stub env" > "$d/speedtest2.env"
  printf 'stub log\n' > "$d/speedtest.log"
  printf 'a\tb\n' > "$d/speedtest_runs.tsv"
  printf 'a\tb\n' > "$d/speedtest_history.tsv"
  printf 'a\tb\n' > "$d/node_stability.tsv"
  mkdir -p "$d/stats_www"
  echo "<html></html>" > "$d/stats_www/stats.html"
  echo "stub stats_init.sh" > "$d/stats_init.sh"
  printf 'fast: stub\n' > "$d/fast.yaml"
  printf 'stub last\n' > "$d/speedtest_last.txt"
  printf '%s' "$d"
}

CORE_LIST="speedtest2.sh prep.awk render_stats.awk stats_cgi.sh stats_run.sh stats_update.sh \
stats_index.html stats_style.css stats_app.js stats_chart.js stats_httpd.py stats_auth.py stats_auth.sh \
node_stats_update.awk sub_convert.awk render_progress.awk stats_service.sh"

# =====================================================================
# Сценарий 1: базовый прогон - файлы, cron-строка и бэкап config.yaml
# есть; SKIP_CONFIRM=1; PURGE_DATA не задан.
# =====================================================================
W1=$(new_dir w1)
INITD1=$TEST_ROOT/initd1
mkdir -p "$INITD1"
INIT1=$INITD1/S80speedtest-stats
cat > "$INIT1" <<'EOF'
#!/bin/sh
echo "$1" >> "$STOP_LOG"
exit 0
EOF
chmod +x "$INIT1"

CRON1=$TEST_ROOT/cron1.txt
CRONBIN1=$TEST_ROOT/cronbin1
mk_fake_crontab "$CRON1" "$CRONBIN1"
printf '0 */3 * * * %s\n0 4 * * * /some/other/job.sh\n17 5 * * * %s check\n' "$W1/speedtest2.sh" "$W1/stats_update.sh" > "$CRON1"

UPDATE_RUNTIME1=$TEST_ROOT/update-runtime1
mkdir -p "$UPDATE_RUNTIME1"
echo stub > "$UPDATE_RUNTIME1/last-check.json"

printf 'mixed-port: 7890\n# CURRENT\n' > "$W1/config.yaml"
printf 'mixed-port: 7890\n# OLDBACKUP\n' > "$W1/config.yaml.2026-01-01_000000.bak"

STOP_LOG1=$TEST_ROOT/stop1.log
: > "$STOP_LOG1"

if ! env PATH="$FAKEBIN:$CRONBIN1:$PATH" DIR="$W1" BIN=mihomo API_MAIN=127.0.0.1:9090 \
    CONFIG="$W1/config.yaml" INSTALLED_SCRIPT="$W1/speedtest2.sh" \
    STATS_SERVICE_DEST="$W1/stats_service.sh" INITD_SCRIPT="$INIT1" \
    STATS_SERVICE_RUNTIME_DIR="$TEST_ROOT/runtime1" STATS_HTTP_DIR="$W1/stats_www" \
    STATS_UPDATE_RUNTIME_DIR="$UPDATE_RUNTIME1" \
    STOP_LOG="$STOP_LOG1" SKIP_CONFIRM=1 \
    sh "$UNINSTALL" >"$W1.log" 2>&1; then
  fail "сценарий 1: uninstall.sh завершился с ошибкой ($(cat "$W1.log"))"
fi

grep -qF stop "$STOP_LOG1" || fail "сценарий 1: init-скрипт не был остановлен ($1 != stop)"
for f in $CORE_LIST; do
  [ -f "$W1/$f" ] && fail "сценарий 1: $f не удалён"
done
[ -f "$W1/speedtest2.env" ] && fail "сценарий 1: speedtest2.env не удалён"
[ -f "$INIT1" ] && fail "сценарий 1: init-скрипт не удалён"
grep -qF "$W1/speedtest2.sh" "$CRON1" && fail "сценарий 1: cron-строка не снята"
grep -qF "/some/other/job.sh" "$CRON1" || fail "сценарий 1: посторонняя cron-строка не должна была пострадать"
grep -qF "OLDBACKUP" "$W1/config.yaml" || fail "сценарий 1: config.yaml не откачен к бэкапу"
own_baks=$(ls "$W1"/config.yaml.*.bak 2>/dev/null | grep -v 2026-01-01_000000 || true)
[ -n "$own_baks" ] || fail "сценарий 1: не создан бэкап конфига, который был текущим перед откатом"
if [ -n "$own_baks" ]; then
  grep -qF "CURRENT" "$own_baks" || fail "сценарий 1: собственный бэкап не содержит прежний config.yaml"
fi
[ -f "$W1/speedtest.log" ] || fail "сценарий 1: без PURGE_DATA журнал speedtest.log не должен удаляться"
[ -d "$W1/stats_www" ] || fail "сценарий 1: без PURGE_DATA stats_www не должен удаляться"
[ -f "$W1/stats_init.sh" ] && fail "сценарий 1: stats_init.sh - оставшийся исходник bootstrap, а не данные, должен удаляться всегда"
[ -f "$W1/fast.yaml" ] || fail "сценарий 1: без PURGE_DATA fast.yaml не должен удаляться"
[ -f "$W1/speedtest_last.txt" ] || fail "сценарий 1: без PURGE_DATA speedtest_last.txt не должен удаляться"
grep -qF "$W1/stats_update.sh" "$CRON1" && fail "сценарий 1: update-check cron-строка не снята"
[ -d "$UPDATE_RUNTIME1" ] && fail "сценарий 1: STATS_UPDATE_RUNTIME_DIR не удалён"

# =====================================================================
# Сценарий 2: подтверждение диалогом - "n" отменяет, "y" продолжает.
# =====================================================================
W2=$(new_dir w2)
INIT2=$TEST_ROOT/init2.sh
cat > "$INIT2" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$INIT2"
CRON2=$TEST_ROOT/cron2.txt
CRONBIN2=$TEST_ROOT/cronbin2
mk_fake_crontab "$CRON2" "$CRONBIN2"
: > "$CRON2"

if printf 'n\n' | env PATH="$FAKEBIN:$CRONBIN2:$PATH" DIR="$W2" BIN=mihomo \
    CONFIG="$W2/does-not-exist.yaml" INSTALLED_SCRIPT="$W2/speedtest2.sh" \
    STATS_SERVICE_DEST="$W2/stats_service.sh" INITD_SCRIPT="$INIT2" \
    STATS_SERVICE_RUNTIME_DIR="$TEST_ROOT/runtime2" STATS_HTTP_DIR="$W2/stats_www" \
    STATS_UPDATE_RUNTIME_DIR="$TEST_ROOT/update-runtime2" \
    sh "$UNINSTALL" >"$W2.log" 2>&1; then
  fail "сценарий 2: отказ (n) должен завершаться ошибкой"
fi
[ -f "$W2/speedtest2.sh" ] || fail "сценарий 2: отказ (n) не должен был ничего удалять"

if ! printf 'y\n' | env PATH="$FAKEBIN:$CRONBIN2:$PATH" DIR="$W2" BIN=mihomo \
    CONFIG="$W2/does-not-exist.yaml" INSTALLED_SCRIPT="$W2/speedtest2.sh" \
    STATS_SERVICE_DEST="$W2/stats_service.sh" INITD_SCRIPT="$INIT2" \
    STATS_SERVICE_RUNTIME_DIR="$TEST_ROOT/runtime2" STATS_HTTP_DIR="$W2/stats_www" \
    STATS_UPDATE_RUNTIME_DIR="$TEST_ROOT/update-runtime2" \
    sh "$UNINSTALL" >"$W2.log" 2>&1; then
  fail "сценарий 2: подтверждение (y) завершилось ошибкой ($(cat "$W2.log"))"
fi
[ -f "$W2/speedtest2.sh" ] && fail "сценарий 2: подтверждение (y) должно было удалить файлы"

# =====================================================================
# Сценарий 3: PURGE_DATA=1 - журналы, история и веб-статика удаляются.
# =====================================================================
W3=$(new_dir w3)
mkdir -p "$W3/.stats-auth"
echo secret > "$W3/.stats-auth/credentials.json"
INIT3=$TEST_ROOT/init3.sh
cat > "$INIT3" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$INIT3"
CRON3=$TEST_ROOT/cron3.txt
CRONBIN3=$TEST_ROOT/cronbin3
mk_fake_crontab "$CRON3" "$CRONBIN3"
: > "$CRON3"

if ! env PATH="$FAKEBIN:$CRONBIN3:$PATH" DIR="$W3" BIN=mihomo \
    MIHOMO_DIR="$W3" \
    CONFIG="$W3/does-not-exist.yaml" INSTALLED_SCRIPT="$W3/speedtest2.sh" \
    STATS_SERVICE_DEST="$W3/stats_service.sh" INITD_SCRIPT="$INIT3" \
    STATS_SERVICE_RUNTIME_DIR="$TEST_ROOT/runtime3" STATS_HTTP_DIR="$W3/stats_www" \
    STATS_UPDATE_RUNTIME_DIR="$TEST_ROOT/update-runtime3" \
    SKIP_CONFIRM=1 PURGE_DATA=1 \
    sh "$UNINSTALL" >"$W3.log" 2>&1; then
  fail "сценарий 3: PURGE_DATA=1 завершился с ошибкой ($(cat "$W3.log"))"
fi
[ -f "$W3/speedtest.log" ] && fail "сценарий 3: PURGE_DATA=1 должен был удалить speedtest.log"
[ -f "$W3/speedtest_history.tsv" ] && fail "сценарий 3: PURGE_DATA=1 должен был удалить speedtest_history.tsv"
[ -d "$W3/stats_www" ] && fail "сценарий 3: PURGE_DATA=1 должен был удалить stats_www"
[ -d "$W3/.stats-auth" ] && fail "сценарий 3: PURGE_DATA=1 должен был удалить данные авторизации"
[ -f "$W3/fast.yaml" ] && fail "сценарий 3: PURGE_DATA=1 должен был удалить fast.yaml"
[ -f "$W3/speedtest_last.txt" ] && fail "сценарий 3: PURGE_DATA=1 должен был удалить speedtest_last.txt"

# =====================================================================
# Сценарий 4: бэкапа config.yaml нет - конфиг не трогаем, но остальное
# всё равно чистим; отдельно проверяем идемпотентность повторного запуска.
# =====================================================================
W4=$(new_dir w4)
INIT4=$TEST_ROOT/init4.sh
cat > "$INIT4" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$INIT4"
CRON4=$TEST_ROOT/cron4.txt
CRONBIN4=$TEST_ROOT/cronbin4
mk_fake_crontab "$CRON4" "$CRONBIN4"
: > "$CRON4"
printf 'mixed-port: 7890\n# NOBACKUP\n' > "$W4/config.yaml"

if ! env PATH="$FAKEBIN:$CRONBIN4:$PATH" DIR="$W4" BIN=mihomo \
    CONFIG="$W4/config.yaml" INSTALLED_SCRIPT="$W4/speedtest2.sh" \
    STATS_SERVICE_DEST="$W4/stats_service.sh" INITD_SCRIPT="$INIT4" \
    STATS_SERVICE_RUNTIME_DIR="$TEST_ROOT/runtime4" STATS_HTTP_DIR="$W4/stats_www" \
    STATS_UPDATE_RUNTIME_DIR="$TEST_ROOT/update-runtime4" \
    SKIP_CONFIRM=1 \
    sh "$UNINSTALL" >"$W4.log" 2>&1; then
  fail "сценарий 4: без бэкапа завершился с ошибкой ($(cat "$W4.log"))"
fi
grep -qF "NOBACKUP" "$W4/config.yaml" || fail "сценарий 4: config.yaml не должен был измениться без бэкапа"
grep -q "нет бэкапов" "$W4.log" || fail "сценарий 4: не сообщено об отсутствии бэкапа"
[ -f "$W4/speedtest2.sh" ] && fail "сценарий 4: файлы надстройки должны были удалиться и без отката конфига"

# повторный запуск на уже деинсталлированном каталоге - не ошибка
if ! env PATH="$FAKEBIN:$CRONBIN4:$PATH" DIR="$W4" BIN=mihomo \
    CONFIG="$W4/config.yaml" INSTALLED_SCRIPT="$W4/speedtest2.sh" \
    STATS_SERVICE_DEST="$W4/stats_service.sh" INITD_SCRIPT="$INIT4" \
    STATS_SERVICE_RUNTIME_DIR="$TEST_ROOT/runtime4" STATS_HTTP_DIR="$W4/stats_www" \
    STATS_UPDATE_RUNTIME_DIR="$TEST_ROOT/update-runtime4" \
    SKIP_CONFIRM=1 \
    sh "$UNINSTALL" >"$W4.repeat.log" 2>&1; then
  fail "сценарий 4: повторный прогон на уже деинсталлированном каталоге не должен завершаться ошибкой ($(cat "$W4.repeat.log"))"
fi

# =====================================================================
# Сценарий 5: реальная связка stats_init.sh + stats_service.sh с фиктивным
# HTTP-бэкендом - служба действительно запущена, uninstall.sh должен её
# остановить (та же техника, что в test_stats_init.sh).
# =====================================================================
W5=$(new_dir w5)
cp "$ROOT/web/stats_init.sh" "$TEST_ROOT/init5.sh"
INIT5=$TEST_ROOT/init5.sh
chmod +x "$INIT5"
cp "$ROOT/web/stats_service.sh" "$W5/stats_service.sh"
cp "$ROOT/speedtest-runtime/speedtest2.sh" "$W5/speedtest2.sh"
: > "$W5/speedtest2.env"

FAKE_HTTPD=$TEST_ROOT/fake_httpd.sh
cat > "$FAKE_HTTPD" <<'EOF'
#!/bin/sh
while :; do sleep 1; done
EOF
chmod +x "$FAKE_HTTPD"

RUNTIME5=$TEST_ROOT/runtime5
CRON5=$TEST_ROOT/cron5.txt
CRONBIN5=$TEST_ROOT/cronbin5
mk_fake_crontab "$CRON5" "$CRONBIN5"
: > "$CRON5"

env PATH="$FAKEBIN:$PATH" DIR="$W5" SERVICE="$W5/stats_service.sh" ENV="$W5/speedtest2.env" \
    STATS_SERVICE_RUNTIME_DIR="$RUNTIME5" STATS_HTTP_DIR="$W5/stats_www" \
    STATS_HTTPD_PY_CMD=sh STATS_HTTPD_PY="$FAKE_HTTPD" STATS_HTTPD_CMD="sh $FAKE_HTTPD" \
    STATS_HTTP_ENABLE=1 STATS_SERVICE_BACKOFF="1 1 1 1" STOP_WAIT=5 \
    sh "$INIT5" start >"$TEST_ROOT/init5-start.log" 2>&1 || fail "сценарий 5: не удалось поднять фиктивную службу для проверки остановки"

n=0
while [ "$n" -lt 5 ] && [ ! -f "$RUNTIME5/httpd.pid" ]; do sleep 1; n=$((n + 1)); done
[ -f "$RUNTIME5/supervisor.pid" ] || fail "сценарий 5: supervisor.pid не появился перед проверкой остановки"
sup5=$(cat "$RUNTIME5/supervisor.pid" 2>/dev/null || echo "")

if ! env PATH="$FAKEBIN:$CRONBIN5:$PATH" DIR="$W5" BIN=mihomo \
    CONFIG="$W5/does-not-exist.yaml" INSTALLED_SCRIPT="$W5/speedtest2.sh" \
    STATS_SERVICE_DEST="$W5/stats_service.sh" INITD_SCRIPT="$INIT5" \
    STATS_SERVICE_RUNTIME_DIR="$RUNTIME5" STATS_HTTP_DIR="$W5/stats_www" \
    STATS_UPDATE_RUNTIME_DIR="$TEST_ROOT/update-runtime5" \
    SERVICE="$W5/stats_service.sh" ENV="$W5/speedtest2.env" \
    STATS_HTTPD_PY_CMD=sh STATS_HTTPD_PY="$FAKE_HTTPD" STATS_HTTPD_CMD="sh $FAKE_HTTPD" \
    STOP_WAIT=5 SKIP_CONFIRM=1 \
    sh "$UNINSTALL" >"$W5.log" 2>&1; then
  fail "сценарий 5: uninstall.sh с реальной службой завершился с ошибкой ($(cat "$W5.log"))"
fi

[ -f "$RUNTIME5/supervisor.pid" ] && fail "сценарий 5: supervisor.pid должен быть убран после uninstall.sh"
[ -n "$sup5" ] && kill -0 "$sup5" 2>/dev/null && fail "сценарий 5: supervisor всё ещё жив после uninstall.sh"
[ -f "$INIT5" ] && fail "сценарий 5: init-скрипт не удалён"


# =====================================================================
# Сценарий 6: REVERT_BEFORE_FAST=1 - берём не последний бэкап, а самый
# РАННИЙ из тех, где ещё нет группы fast (path: ./fast.yaml).
# =====================================================================
W6=$(new_dir w6)
INIT6=$TEST_ROOT/init6.sh
cat > "$INIT6" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$INIT6"
CRON6=$TEST_ROOT/cron6.txt
CRONBIN6=$TEST_ROOT/cronbin6
mk_fake_crontab "$CRON6" "$CRONBIN6"
: > "$CRON6"

printf 'mixed-port: 7890\nproxy-providers:\n  fast:\n    type: file\n    path: ./fast.yaml\n# CURRENT-WITH-FAST\n' > "$W6/config.yaml"
printf 'mixed-port: 7890\n# PREFAST-OLD\n' > "$W6/config.yaml.2026-01-01_000000.bak"
printf 'mixed-port: 7890\n# PREFAST-NEW\n' > "$W6/config.yaml.2026-01-15_000000.bak"
printf 'mixed-port: 7890\nproxy-providers:\n  fast:\n    type: file\n    path: ./fast.yaml\n# POSTFAST\n' > "$W6/config.yaml.2026-02-01_000000.bak"

if ! env PATH="$FAKEBIN:$CRONBIN6:$PATH" DIR="$W6" BIN=mihomo API_MAIN=127.0.0.1:9090 \
    CONFIG="$W6/config.yaml" INSTALLED_SCRIPT="$W6/speedtest2.sh" \
    STATS_SERVICE_DEST="$W6/stats_service.sh" INITD_SCRIPT="$INIT6" \
    STATS_SERVICE_RUNTIME_DIR="$TEST_ROOT/runtime6" STATS_HTTP_DIR="$W6/stats_www" \
    STATS_UPDATE_RUNTIME_DIR="$TEST_ROOT/update-runtime6" \
    SKIP_CONFIRM=1 REVERT_BEFORE_FAST=1 \
    sh "$UNINSTALL" >"$W6.log" 2>&1; then
  fail "сценарий 6: REVERT_BEFORE_FAST=1 завершился с ошибкой ($(cat "$W6.log"))"
fi
grep -qF "PREFAST-OLD" "$W6/config.yaml" || fail "сценарий 6: должен быть выбран самый ранний бэкап БЕЗ группы fast (PREFAST-OLD)"
grep -qF "PREFAST-NEW" "$W6/config.yaml" && fail "сценарий 6: не должен быть выбран более новый бэкап без fast (PREFAST-NEW)"
grep -qF "POSTFAST" "$W6/config.yaml" && fail "сценарий 6: не должен быть выбран бэкап, где fast уже есть (POSTFAST), даже если он самый свежий"

# =====================================================================
# Сценарий 7: REVERT_BEFORE_FAST=1, но группа fast есть во всех бэкапах -
# config.yaml не трогаем, но сообщаем об этом понятно (а не тихо).
# =====================================================================
W7=$(new_dir w7)
INIT7=$TEST_ROOT/init7.sh
cat > "$INIT7" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$INIT7"
CRON7=$TEST_ROOT/cron7.txt
CRONBIN7=$TEST_ROOT/cronbin7
mk_fake_crontab "$CRON7" "$CRONBIN7"
: > "$CRON7"

printf 'mixed-port: 7890\nproxy-providers:\n  fast:\n    type: file\n    path: ./fast.yaml\n# CURRENT-ALWAYS-FAST\n' > "$W7/config.yaml"
printf 'mixed-port: 7890\nproxy-providers:\n  fast:\n    type: file\n    path: ./fast.yaml\n# OLD-ALSO-FAST\n' > "$W7/config.yaml.2026-01-01_000000.bak"

if ! env PATH="$FAKEBIN:$CRONBIN7:$PATH" DIR="$W7" BIN=mihomo API_MAIN=127.0.0.1:9090 \
    CONFIG="$W7/config.yaml" INSTALLED_SCRIPT="$W7/speedtest2.sh" \
    STATS_SERVICE_DEST="$W7/stats_service.sh" INITD_SCRIPT="$INIT7" \
    STATS_SERVICE_RUNTIME_DIR="$TEST_ROOT/runtime7" STATS_HTTP_DIR="$W7/stats_www" \
    STATS_UPDATE_RUNTIME_DIR="$TEST_ROOT/update-runtime7" \
    SKIP_CONFIRM=1 REVERT_BEFORE_FAST=1 \
    sh "$UNINSTALL" >"$W7.log" 2>&1; then
  fail "сценарий 7: REVERT_BEFORE_FAST=1 (все бэкапы с fast) завершился с ошибкой ($(cat "$W7.log"))"
fi
grep -qF "CURRENT-ALWAYS-FAST" "$W7/config.yaml" || fail "сценарий 7: config.yaml не должен был измениться - все бэкапы уже содержат fast"
grep -q "нет ни одного без группы fast" "$W7.log" || fail "сценарий 7: не сообщено, что среди бэкапов нет варианта без fast"

# =====================================================================
# Финальный обзор (C1c): revert_config() должен проверять бэкап через
# mihomo -t относительно MIHOMO_DIR (каталог самой Mihomo), а не DIR
# (каталог проекта speedtest2-stats) - см.
# docs/superpowers/specs/2026-09-25-install-dir-separation-design.md.
# До исправления uninstall.sh передавал сюда "$DIR". Вызываем
# revert_config() напрямую через UNINSTALL_LIB_ONLY=1, а не весь main() -
# только эта функция зависит от -d.
# =====================================================================
W8=$(new_dir w8)
printf 'mixed-port: 7890\n# CURRENT\n' > "$W8/config.yaml"
printf 'mixed-port: 7890\n# BACKUP\n' > "$W8/config.yaml.2026-01-01_000000.bak"

MIHOMO_ARG_LOG8=$TEST_ROOT/mihomo-arg8.log
FAKEBIN8=$TEST_ROOT/bin8
mkdir -p "$FAKEBIN8"
cat > "$FAKEBIN8/mihomo" <<EOF
#!/bin/sh
echo "\$@" > "$MIHOMO_ARG_LOG8"
exit 0
EOF
chmod +x "$FAKEBIN8/mihomo"

MIHOMO_HOME8=$TEST_ROOT/mihomo-home8
mkdir -p "$MIHOMO_HOME8"

(
  PATH="$FAKEBIN8:$PATH"
  export PATH
  DIR=$W8
  BIN=$FAKEBIN8/mihomo
  CONFIG=$W8/config.yaml
  MIHOMO_DIR=$MIHOMO_HOME8
  export DIR BIN CONFIG MIHOMO_DIR
  UNINSTALL_LIB_ONLY=1 . "$UNINSTALL"
  revert_config
) || true

[ -f "$MIHOMO_ARG_LOG8" ] || fail "сценарий 8 (C1c): revert_config() ни разу не вызвал \$BIN (mihomo -t) - регрессионный тест не может ничего проверить"
if [ -f "$MIHOMO_ARG_LOG8" ]; then
  grep -qF -- "-d $MIHOMO_HOME8 " "$MIHOMO_ARG_LOG8" \
    || fail "сценарий 8 (C1c): uninstall.sh передал mihomo -t не тот -d: ожидался MIHOMO_DIR ($MIHOMO_HOME8), получено: $(cat "$MIHOMO_ARG_LOG8")"
  grep -qF -- "-d $W8 " "$MIHOMO_ARG_LOG8" \
    && fail "сценарий 8 (C1c): uninstall.sh передал mihomo -t каталог DIR ($W8) вместо MIHOMO_DIR - регрессия C1c"
fi

# --- удаление символической ссылки mihomo-speedtest при полном сносе
# (Task 4, 2026-09-26 plan). Review Focus: ссылка может быть в /opt/bin,
# а не только в /opt/sbin - проверяем оба каталога-кандидата раздельно, и
# посторонняя ссылка в другом каталоге не должна тронуться.
for BINDIR_NAME in sbin bin; do
  WORK_LINK=$(mktemp -d)
  mkdir -p "$WORK_LINK/opt-sbin" "$WORK_LINK/opt-bin" "$WORK_LINK/dir"
  touch "$WORK_LINK/dir/mihomo-speedtest.sh"
  ln -s "$WORK_LINK/dir/mihomo-speedtest.sh" "$WORK_LINK/opt-$BINDIR_NAME/mihomo-speedtest"
  OTHER_NAME=sbin
  [ "$BINDIR_NAME" = sbin ] && OTHER_NAME=bin
  ln -s "/something/unrelated" "$WORK_LINK/opt-$OTHER_NAME/foreign-link" 2>/dev/null || true
  (
    DIR=$WORK_LINK/dir
    BIN_SBIN_DIR=$WORK_LINK/opt-sbin
    BIN_BIN_DIR=$WORK_LINK/opt-bin
    UNINSTALL_LIB_ONLY=1 . "$UNINSTALL"
    remove_mihomo_speedtest_symlink
  )
  [ -L "$WORK_LINK/opt-$BINDIR_NAME/mihomo-speedtest" ] && fail "символическая ссылка на \$DIR/mihomo-speedtest.sh не удалена ($BINDIR_NAME)"
  [ -L "$WORK_LINK/opt-$OTHER_NAME/foreign-link" ] || fail "посторонняя ссылка в другом каталоге была затронута ($OTHER_NAME)"
  rm -rf "$WORK_LINK"
done

# --- посторонняя ссылка с ИМЕНЕМ mihomo-speedtest, указывающая не на
# $DIR/mihomo-speedtest.sh, не должна удаляться ---
WORK_LINK2=$(mktemp -d)
mkdir -p "$WORK_LINK2/opt-sbin" "$WORK_LINK2/dir"
touch "$WORK_LINK2/dir/mihomo-speedtest.sh"
ln -s "/something/else/entirely" "$WORK_LINK2/opt-sbin/mihomo-speedtest"
(
  DIR=$WORK_LINK2/dir
  BIN_SBIN_DIR=$WORK_LINK2/opt-sbin
  BIN_BIN_DIR=$WORK_LINK2/opt-bin
  UNINSTALL_LIB_ONLY=1 . "$UNINSTALL"
  remove_mihomo_speedtest_symlink
)
[ -L "$WORK_LINK2/opt-sbin/mihomo-speedtest" ] || fail "посторонняя ссылка (не на наш mihomo-speedtest.sh) была удалена по ошибке"
rm -rf "$WORK_LINK2"

# --- Ревью (2026-09-26, финальный обзор): посторонняя символическая
# ссылка с ИМЕНЕМ mihomo-speedtest, указывающая не на наш файл, лежит в
# ПОСЛЕДНЕМ проверяемом каталоге (/opt/bin) - "[ "$current" = "$own_target" ]
# && rm -f "$link"" как отдельная команда цикла при несовпадении даёт
# ненулевой статус, и под set -eu это раньше валило remove_project_files()
# (и весь uninstall.sh) целиком, не дойдя до остальной очистки.
WORK_LINK3=$(mktemp -d)
mkdir -p "$WORK_LINK3/opt-sbin" "$WORK_LINK3/opt-bin" "$WORK_LINK3/dir"
touch "$WORK_LINK3/dir/mihomo-speedtest.sh"
ln -s "/something/else/entirely" "$WORK_LINK3/opt-bin/mihomo-speedtest"
(
  DIR=$WORK_LINK3/dir
  BIN_SBIN_DIR=$WORK_LINK3/opt-sbin
  BIN_BIN_DIR=$WORK_LINK3/opt-bin
  UNINSTALL_LIB_ONLY=1 . "$UNINSTALL"
  remove_mihomo_speedtest_symlink
) || fail "посторонняя ссылка в ПОСЛЕДНЕМ каталоге (opt-bin) обрывает remove_mihomo_speedtest_symlink() целиком (set -e) вместо тихого пропуска"
[ -L "$WORK_LINK3/opt-bin/mihomo-speedtest" ] || fail "посторонняя ссылка в opt-bin была удалена по ошибке (сценарий 3)"
rm -rf "$WORK_LINK3"

echo "test_uninstall.sh: mihomo-speedtest symlink removal OK"

if [ "$FAILED" -ne 0 ]; then
  exit 1
fi
echo "OK: test_uninstall.sh (C1c regression covered)"
