#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
SCRIPT=$ROOT/install.sh
# Соответствие плоского имени файла проекта (как в ALL_PROJECT_FILES -
# список всегда плоский, раскладка на роутере не менялась) его папке
# компонента в репозитории после реорганизации - см. release/components.txt.
component_of() {
  case $1 in
    update_transaction.sh|update_prepare.sh|update.sh|update_plan.awk) echo updater ;;
    speedtest2.sh|prep.awk|providers.awk|node_stats_update.awk|sub_convert.awk) echo speedtest-runtime ;;
    render_stats.awk|stats_cgi.sh|stats_run.sh|stats_update.sh|stats_config.sh|stats_xkeen.sh|stats_constructor.sh|stats_httpd.py|stats_auth.py|stats_auth.sh|stats_index.html|stats_style.css|stats_app.js|stats_app_core.js|stats_app_stats.js|stats_app_settings.js|stats_app_updates.js|stats_app_log.js|stats_app_config.js|stats_app_xkeen.js|stats_codemirror.js|stats_codemirror.css|render_progress.awk|stats_service.sh|stats_init.sh) echo web ;;
    version_check.sh|ui.sh) echo installer ;;
    migrate_config.sh|migrate_config.awk|config_diff.awk|setup.sh|detect_ua.sh|render_config.awk|fast_wg.awk|wg_import.awk|existing_config.awk|config.example.yaml|render_services.awk|services.default.tsv|config_to_state.awk|constructor_build.sh) echo config-tools ;;
    *) echo . ;;
  esac
}
# Обход через mihomo (bootstrap_enable_proxy) в этих тестах не нужен: на
# машине разработчика он мог бы открыть mixed-port у настоящего mihomo.
INSTALL_PROXY_FALLBACK=0
export INSTALL_PROXY_FALLBACK
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/install-bootstrap-test.XXXXXX")
# Журнал UI - во временный каталог (не /opt/var/log), вывод - plain.
UI_LOG=$TEST_ROOT/ui.log
UI=plain
export UI_LOG UI

CLEANUP_PIDS=""
cleanup_test() {
  for p in $CLEANUP_PIDS; do
    kill "$p" 2>/dev/null || true
  done
  rm -rf "$TEST_ROOT"
}
trap cleanup_test EXIT INT TERM

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

sh -n "$SCRIPT" || fail "install.sh не проходит sh -n"

have_busybox_httpd=1
command -v busybox >/dev/null 2>&1 || have_busybox_httpd=0
if [ "$have_busybox_httpd" = 1 ]; then
  busybox httpd 2>&1 | grep -qi applet && have_busybox_httpd=0
fi
command -v curl >/dev/null 2>&1 || have_busybox_httpd=0

[ "$have_busybox_httpd" = 1 ] || {
  echo "test_install_bootstrap.sh: busybox httpd/curl недоступны, сетевые проверки пропущены" >&2
  echo "test_install_bootstrap.sh: OK (частично)"
  exit 0
}

sha256_of_test() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  elif command -v openssl >/dev/null 2>&1; then openssl dgst -sha256 "$1" | awk '{print $NF}'
  else fail "нет sha256sum/openssl для подготовки фикстуры"
  fi
}

BASE_PORT=$((24000 + ($$ % 3000)))

start_httpd() {
  dir=$1; port=$2
  busybox httpd -f -p "127.0.0.1:$port" -h "$dir" >/dev/null 2>&1 &
  echo $!
}

wait_httpd() {
  port=$1; path=$2
  i=0
  while [ $i -lt 30 ]; do
    code=$(curl -s -m 1 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$port$path" 2>/dev/null)
    [ "$code" != "000" ] && return 0
    sleep 0.2; i=$((i + 1))
  done
  return 1
}

# Фикстура релиза: releases/latest/download/manifest.txt +
# releases/download/<tag>/<файл> - тот же протокол, что update.sh
# использует для PINNED_BASE (см. update.sh:pinned_base). Два маленьких
# фиктивных файла вместо реального набора из 35 - bootstrap_selfinstall
# скачивает файлы по строкам FILE| манифеста независимо от их числа и
# содержимого, поэтому для проверки самого механизма реальный набор не нужен.
SRV=$TEST_ROOT/srv
TAG=v-test-1
mkdir -p "$SRV/releases/latest/download" "$SRV/releases/download/$TAG"

printf 'hello-bootstrap\n' > "$SRV/releases/download/$TAG/greeting.txt"
printf '#!/bin/sh\necho ok\n' > "$SRV/releases/download/$TAG/runner.sh"

SUM_GREETING=$(sha256_of_test "$SRV/releases/download/$TAG/greeting.txt")
SUM_RUNNER=$(sha256_of_test "$SRV/releases/download/$TAG/runner.sh")
SIZE_GREETING=$(wc -c < "$SRV/releases/download/$TAG/greeting.txt" | tr -d ' ')
SIZE_RUNNER=$(wc -c < "$SRV/releases/download/$TAG/runner.sh" | tr -d ' ')

cat > "$SRV/releases/latest/download/manifest.txt" << EOF
FORMAT_VERSION=2
RELEASE_TAG=$TAG
RELEASE_VERSION=1
MIN_UPDATER_VERSION=1
CONFIG_SCHEMA_VERSION=1
COMPONENT|installer|Установщик
FILE|installer|greeting.txt|/opt/etc/mihomo/greeting.txt|$SIZE_GREETING|$SUM_GREETING|0644|none
FILE|installer|runner.sh|/opt/etc/mihomo/runner.sh|$SIZE_RUNNER|$SUM_RUNNER|0755|sh
EOF

PORT=$BASE_PORT
PID=$(start_httpd "$SRV" "$PORT")
CLEANUP_PIDS="$CLEANUP_PIDS $PID"
wait_httpd "$PORT" /releases/latest/download/manifest.txt || fail "тестовый httpd не поднялся"

BASE_URL="http://127.0.0.1:$PORT/releases/latest/download"

INSTALL_LIB_ONLY=1 SELFDIR="$ROOT/installer" . "$SCRIPT"
unset INSTALL_LIB_ONLY

# --- 1: пустой каталог - bootstrap_selfinstall скачивает всё с верными правами ---
DST1=$TEST_ROOT/dst-empty
mkdir -p "$DST1"
(
  DIR=$DST1
  TMPROOT=$TEST_ROOT
  UPDATE_RELEASE_BASE=$BASE_URL
  # UPDATE_STATE_DIR/INSTALLED_MANIFEST_PATH зафиксированы от DIR один раз
  # при сорсинге скрипта выше (та же схема, что в update.sh) - при вызове
  # bootstrap_selfinstall напрямую (не через полный запуск "sh install.sh"
  # с DIR в окружении процесса) их нужно переопределить явно вслед за DIR.
  UPDATE_STATE_DIR=$DST1/.update
  INSTALLED_MANIFEST_PATH=$DST1/.update/installed-manifest.txt
  bootstrap_selfinstall
) 2>"$TEST_ROOT/err-empty.log" || fail "bootstrap_selfinstall должен успешно скачать и проверить файлы в пустой каталог"

# Вид вывода (plain, stderr в файл): подробности по файлам - не отдельными
# строками "Скачиваю файл N/M", а полосой прогресса одного шага.
grep -q "Скачиваю файл [0-9]*/[0-9]*:" "$TEST_ROOT/err-empty.log" \
  && fail "строк 'Скачиваю файл N/M:' на каждый файл быть не должно - вместо них прогресс"
grep -q '^\[\.\.\] Файлы релиза 1/' "$TEST_ROOT/err-empty.log" \
  || fail "нет строки прогресса '[..] Файлы релиза 1/'"
grep -q '\[OK\] Файлы релиза' "$TEST_ROOT/err-empty.log" \
  || fail "нет итоговой строки '[OK] Файлы релиза'"
grep -q '\[OK\] Манифест v-test-1' "$TEST_ROOT/err-empty.log" \
  || fail "нет строки '[OK] Манифест v-test-1' (релиз должен быть назван до скачивания файлов)"

[ -f "$DST1/greeting.txt" ] || fail "greeting.txt не скачан"
[ -f "$DST1/runner.sh" ] || fail "runner.sh не скачан"
[ "$(cat "$DST1/greeting.txt")" = "hello-bootstrap" ] || fail "содержимое greeting.txt повреждено"
[ -x "$DST1/runner.sh" ] || fail "runner.sh должен быть исполняемым (режим 0755 из манифеста)"
[ ! -x "$DST1/greeting.txt" ] || fail "greeting.txt не должен быть исполняемым (режим 0644 из манифеста)"

MANIFEST_DST1=$DST1/.update/installed-manifest.txt
[ -f "$MANIFEST_DST1" ] || fail "bootstrap_selfinstall должен сохранить installed-manifest.txt в \$DIR/.update"
grep -q '^RELEASE_TAG=v-test-1$' "$MANIFEST_DST1" || fail "installed-manifest.txt: неверный или отсутствующий RELEASE_TAG"
grep -q '^FILE|installer|greeting.txt|' "$MANIFEST_DST1" || fail "installed-manifest.txt: нет строки FILE для greeting.txt"

echo "test_install_bootstrap.sh: часть 1 (пустой каталог, installed-manifest.txt сохранён) OK" >&2

# --- 1b: обрыв соединения (curl 35) на первой попытке - повтор тихий: на
# экране нет "Сбой загрузки", подробности только в журнале UI_LOG, а
# на экране - подпись прогресса "повтор 2/3".
DST1B=$TEST_ROOT/dst-retry
mkdir -p "$DST1B"
: > "$UI_LOG"
(
  DIR=$DST1B
  TMPROOT=$TEST_ROOT
  UPDATE_RELEASE_BASE=$BASE_URL
  UPDATE_STATE_DIR=$DST1B/.update
  INSTALLED_MANIFEST_PATH=$DST1B/.update/installed-manifest.txt
  INSTALL_RETRY_DELAY=0
  RETRY_CNT=$TEST_ROOT/retry1b.cnt; echo 0 > "$RETRY_CNT"
  bootstrap_http_get() {
    case $1 in
      */greeting.txt)
        n=$(($(cat "$RETRY_CNT") + 1)); echo "$n" > "$RETRY_CNT"
        [ "$n" -ge 2 ] || return 35 ;;
    esac
    curl -fsS --max-time 10 "$1"
  }
  bootstrap_selfinstall
) 2>"$TEST_ROOT/err-retry.log" || fail "повтор после обрыва (35) должен завершиться успехом"
grep -q "Сбой загрузки" "$TEST_ROOT/err-retry.log" \
  && fail "'Сбой загрузки' не должен попадать на экран (только в журнал)"
grep -q "повтор 2 из" "$UI_LOG" || fail "в UI_LOG нет 'повтор 2 из'"
grep -q "повтор 2/3" "$TEST_ROOT/err-retry.log" || fail "на экране нет подписи прогресса 'повтор 2/3'"
[ -f "$DST1B/greeting.txt" ] || fail "после повтора файл должен быть скачан"

echo "test_install_bootstrap.sh: часть 1b (тихий повтор, журнал) OK" >&2

# --- 2: повреждённая сумма - чистый отказ, ничего не записано ---
SRV_BAD=$TEST_ROOT/srv-bad
mkdir -p "$SRV_BAD/releases/latest/download" "$SRV_BAD/releases/download/$TAG"
cp "$SRV/releases/download/$TAG/greeting.txt" "$SRV_BAD/releases/download/$TAG/greeting.txt"
# Тот же размер в байтах, что заявлен в манифесте (18) - иначе curl
# --max-filesize оборвёт закачку раньше, чем дойдёт до сверки sha256, и
# тест проверит не ту ветку отказа (см. bootstrap_download_to).
printf '#!/bin/sh\necho no\n' > "$SRV_BAD/releases/download/$TAG/runner.sh"
[ "$(wc -c < "$SRV_BAD/releases/download/$TAG/runner.sh" | tr -d ' ')" = "$SIZE_RUNNER" ] \
  || fail "test setup: искажённый runner.sh должен быть того же размера, что и заявлено в манифесте"
cp "$SRV/releases/latest/download/manifest.txt" "$SRV_BAD/releases/latest/download/manifest.txt"

PORT_BAD=$((BASE_PORT + 1))
PID_BAD=$(start_httpd "$SRV_BAD" "$PORT_BAD")
CLEANUP_PIDS="$CLEANUP_PIDS $PID_BAD"
wait_httpd "$PORT_BAD" /releases/latest/download/manifest.txt || fail "тестовый httpd (bad) не поднялся"

DST2=$TEST_ROOT/dst-corrupt
mkdir -p "$DST2"
if (
  DIR=$DST2
  TMPROOT=$TEST_ROOT
  UPDATE_RELEASE_BASE="http://127.0.0.1:$PORT_BAD/releases/latest/download"
  bootstrap_selfinstall
) 2>"$TEST_ROOT/err-corrupt.log"; then
  fail "bootstrap_selfinstall должен отказать при неверной sha256"
fi
grep -q "SHA256" "$TEST_ROOT/err-corrupt.log" || fail "ожидалось сообщение о неверной сумме SHA256"
[ -z "$(find "$DST2" -type f)" ] || fail "при отказе по sha256 в каталог не должно быть ничего записано"

echo "test_install_bootstrap.sh: часть 2 (повреждённая сумма) OK" >&2

# --- 3: файлы уже на месте (DIR, дефолтный SELFDIR=$DIR) - bootstrap не
# запускается, сеть не трогается, install.sh идёт обычным путём. Триггер
# проверяет ВЕСЬ ALL_PROJECT_FILES (см. install.sh), поэтому в фикстуре
# должен быть полный набор - берём сам список из install.sh (сорсинг как
# библиотеки, INSTALL_LIB_ONLY=1), а не дублируем его здесь текстом:
# именно рассинхронизация двух independently поддерживаемых списков
# (раньше - два файла-часовых против полного списка в main()) и была
# причиной бага с недостающим migrate_config.sh на реальном роутере.
FAKEBIN=$TEST_ROOT/fakebin
mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/pidof" <<'EOF'
#!/bin/sh
exit 1
EOF
chmod +x "$FAKEBIN/pidof"

ALL_PROJECT_FILES_LIST=$(INSTALL_LIB_ONLY=1 SELFDIR="$ROOT/installer" sh -c '. "'"$SCRIPT"'"; printf "%s" "$ALL_PROJECT_FILES"')
[ -n "$ALL_PROJECT_FILES_LIST" ] || fail "не удалось получить ALL_PROJECT_FILES из install.sh"

WORK3=$TEST_ROOT/dst-present
mkdir -p "$WORK3"
for pf in $ALL_PROJECT_FILES_LIST; do
  cp "$ROOT/$(component_of "$pf")/$pf" "$WORK3/$pf"
done
touch "$WORK3/config.yaml"

if PATH="$FAKEBIN:$PATH" DIR="$WORK3" CONFIG="$WORK3/config.yaml" \
   UPDATE_RELEASE_BASE="http://127.0.0.1:1/releases/latest/download" \
   sh "$SCRIPT" 2>"$TEST_ROOT/err-present.log"; then
  fail "sh \"\$SCRIPT\" должен был упасть на проверке процесса mihomo (pidof подставлен неуспешным)"
fi
grep -q "Процесс mihomo не найден" "$TEST_ROOT/err-present.log" \
  || fail "install.sh должен дойти до штатной проверки процесса, минуя bootstrap (весь ALL_PROJECT_FILES уже есть в DIR, SELFDIR по умолчанию = DIR)"
grep -q "Не удалось скачать" "$TEST_ROOT/err-present.log" \
  && fail "bootstrap не должен был запускаться - весь набор файлов уже на месте в DIR"
grep -q "Устанавливается: файлы из $WORK3, версия релиза неизвестна" "$TEST_ROOT/err-present.log" \
  || fail "без installed-manifest.txt установщик должен честно сказать, что версия неизвестна"

# Переустановка поверх: файлы в DIR описывает installed-manifest.txt.
mkdir -p "$WORK3/.update"
printf 'FORMAT_VERSION=2\nRELEASE_VERSION=7\nRELEASE_TAG=1.2.4\n' > "$WORK3/.update/installed-manifest.txt"
PATH="$FAKEBIN:$PATH" DIR="$WORK3" CONFIG="$WORK3/config.yaml" \
  UPDATE_RELEASE_BASE="http://127.0.0.1:1/releases/latest/download" \
  sh "$SCRIPT" 2>"$TEST_ROOT/err-label.log" || true
grep -q "Устанавливается: релиз 1.2.4" "$TEST_ROOT/err-label.log" \
  || fail "установщик должен показать устанавливаемый релиз из installed-manifest.txt"
rm -rf "$WORK3/.update"

echo "test_install_bootstrap.sh: часть 3 (файлы уже на месте, сеть не трогается) OK" >&2

# --- 4: частичное состояние (version_check.sh есть, speedtest2.sh нет -
# именно так выглядит DIR после uninstall.sh до этого исправления, когда
# он удалял CORE-файлы, но не version_check.sh) - bootstrap должен
# сработать сам, без ручного вмешательства (rm version_check.sh) ---
WORK4=$TEST_ROOT/dst-partial
mkdir -p "$WORK4"
cp "$ROOT/installer/version_check.sh" "$WORK4/version_check.sh"
touch "$WORK4/config.yaml"

if PATH="$FAKEBIN:$PATH" DIR="$WORK4" CONFIG="$WORK4/config.yaml" \
   UPDATE_RELEASE_BASE="$BASE_URL" \
   sh "$SCRIPT" 2>"$TEST_ROOT/err-partial.log"; then
  fail "sh \"\$SCRIPT\" должен был упасть на проверке процесса mihomo после bootstrap (pidof подставлен неуспешным)"
fi
grep -q "Рядом нет файлов проекта" "$TEST_ROOT/err-partial.log" \
  || fail "bootstrap должен был сработать сам - version_check.sh есть, но speedtest2.sh отсутствует (частичное состояние)"
grep -q "Файлы проекта загружены и проверены" "$TEST_ROOT/err-partial.log" \
  || fail "bootstrap должен был успешно докачать недостающие файлы при частичном состоянии"
[ -f "$WORK4/greeting.txt" ] || fail "bootstrap должен был докачать полный набор из манифеста при частичном состоянии"

echo "test_install_bootstrap.sh: часть 4 (частичное состояние - version_check.sh есть, speedtest2.sh нет) OK" >&2

# --- 5: реальный случай с роутера владельца - оба файла-часовых старого
# триггера (version_check.sh, speedtest2.sh) на месте, но отсутствует
# migrate_config.sh (файл, не входивший в старый двухфайловый триггер) -
# bootstrap ДОЛЖЕН сработать сам, а не падать на "не найден рядом с
# install.sh" при последующей проверке полноты в main().
WORK5=$TEST_ROOT/dst-partial-other-file
mkdir -p "$WORK5"
for pf in $ALL_PROJECT_FILES_LIST; do
  [ "$pf" = "migrate_config.sh" ] && continue
  cp "$ROOT/$(component_of "$pf")/$pf" "$WORK5/$pf"
done
touch "$WORK5/config.yaml"

if PATH="$FAKEBIN:$PATH" DIR="$WORK5" CONFIG="$WORK5/config.yaml"    UPDATE_RELEASE_BASE="$BASE_URL"    sh "$SCRIPT" 2>"$TEST_ROOT/err-partial-other.log"; then
  fail "sh \"\$SCRIPT\" должен был упасть на проверке процесса mihomo после bootstrap (pidof подставлен неуспешным)"
fi
grep -q "Рядом нет файлов проекта" "$TEST_ROOT/err-partial-other.log"   || fail "bootstrap должен был сработать сам при отсутствующем migrate_config.sh, даже когда version_check.sh и speedtest2.sh на месте"
grep -q "не найден рядом с install.sh" "$TEST_ROOT/err-partial-other.log"   && fail "не должно быть отказа 'не найден рядом с install.sh' - bootstrap обязан был докачать недостающий файл сам"

echo "test_install_bootstrap.sh: часть 5 (version_check.sh и speedtest2.sh есть, migrate_config.sh нет) OK" >&2

# --- 6: лёгкие действия (--stop-web/--version) не должны запускать
# bootstrap даже при неполном $SELFDIR/$DIR - это чисто локальные команды
# (см. install.sh:bootstrap_skip_for_action), им не нужны ни полный набор
# файлов проекта, ни сеть. UPDATE_RELEASE_BASE указывает на порт, где
# никто не слушает - если bootstrap всё-таки попытается стартовать, скрипт
# неизбежно упадёт на попытке скачать manifest.txt, и тест это поймает.
WORK6=$TEST_ROOT/dst-lightweight
mkdir -p "$WORK6"
for pf in $ALL_PROJECT_FILES_LIST; do
  [ "$pf" = "migrate_config.sh" ] && continue
  cp "$ROOT/$(component_of "$pf")/$pf" "$WORK6/$pf"
done
touch "$WORK6/config.yaml"
printf 'STATS_HTTP_ENABLE=1\n' > "$WORK6/speedtest2.env"
mkdir -p "$WORK6/.update"
printf 'FORMAT_VERSION=2\nRELEASE_TAG=v7\nRELEASE_VERSION=7\nMIN_UPDATER_VERSION=1\nCONFIG_SCHEMA_VERSION=1\n' > "$WORK6/.update/installed-manifest.txt"

BAD_BASE="http://127.0.0.1:1/releases/latest/download"

out6a=$(DIR="$WORK6" CONFIG="$WORK6/config.yaml" UPDATE_RELEASE_BASE="$BAD_BASE" sh "$SCRIPT" --stop-web 2>&1) \
  || fail "install.sh --stop-web не должен падать при неполном \$DIR (получено: $out6a)"
case "$out6a" in *"Рядом нет файлов проекта"*) fail "install.sh --stop-web не должен запускать bootstrap: $out6a" ;; esac
case "$out6a" in *"остановлен и отключён"*) ;; *) fail "install.sh --stop-web должен дойти до штатного отключения веб-сервиса: $out6a" ;; esac

out6b=$(DIR="$WORK6" CONFIG="$WORK6/config.yaml" UPDATE_RELEASE_BASE="$BAD_BASE" sh "$SCRIPT" --version 2>&1) \
  || fail "install.sh --version не должен падать при неполном \$DIR (получено: $out6b)"
case "$out6b" in *"Рядом нет файлов проекта"*) fail "install.sh --version не должен запускать bootstrap: $out6b" ;; esac
case "$out6b" in *"Версия релиза: v7 (номер 7)"*) ;; *) fail "install.sh --version должен показать установленную версию релиза: $out6b" ;; esac

echo "test_install_bootstrap.sh: часть 6 (--stop-web/--version не запускают bootstrap при неполном DIR) OK" >&2

# --- 7: --version без installed-manifest.txt - понятное сообщение, а не
# ошибка и не bootstrap.
WORK7=$TEST_ROOT/dst-version-untracked
mkdir -p "$WORK7"
for pf in $ALL_PROJECT_FILES_LIST; do
  [ "$pf" = "migrate_config.sh" ] && continue
  cp "$ROOT/$(component_of "$pf")/$pf" "$WORK7/$pf"
done
touch "$WORK7/config.yaml"

out7=$(DIR="$WORK7" CONFIG="$WORK7/config.yaml" UPDATE_RELEASE_BASE="$BAD_BASE" sh "$SCRIPT" --version 2>&1) \
  || fail "install.sh --version не должен падать, если installed-manifest.txt отсутствует (получено: $out7)"
case "$out7" in *"не отслеживается"*) ;; *) fail "install.sh --version без installed-manifest.txt должен сообщать, что релиз не отслеживается: $out7" ;; esac

echo "test_install_bootstrap.sh: часть 7 (--version без installed-manifest.txt) OK" >&2

# --- 8: выбор канала при установке с нуля (bootstrap_choose_channel) ---
# Ответ читается из INSTALL_TTY (в бою /dev/tty); без tty - stable.
ch() {
  ( set +e; INSTALL_TTY=$1; shift
    for kv in "$@"; do export "$kv"; done
    DIR=$TEST_ROOT/no-such-dir
    bootstrap_choose_channel; printf '%s\n' "$INSTALL_CHANNEL" ) 2>"$TEST_ROOT/err-ch.log"
}
printf '2\n' > "$TEST_ROOT/tty-2"
printf '\n' > "$TEST_ROOT/tty-enter"
printf '7\n' > "$TEST_ROOT/tty-bad"
[ "$(ch "$TEST_ROOT/tty-2")" = dev ] || fail "ответ 2 должен выбрать канал dev"
grep -q "Канал обновлений" "$TEST_ROOT/err-ch.log" || fail "меню канала не показано: $(cat "$TEST_ROOT/err-ch.log")"
grep -q "(по умолчанию)" "$TEST_ROOT/err-ch.log" || fail "в меню канала не отмечен вариант по умолчанию"
[ "$(ch "$TEST_ROOT/tty-enter")" = stable ] || fail "Enter должен оставить stable"
[ "$(ch "$TEST_ROOT/tty-bad")" = stable ] || fail "неверный номер должен оставить stable"
[ "$(ch "$TEST_ROOT/no-tty")" = stable ] || fail "без терминала должен быть stable"
grep -q "Канал обновлений" "$TEST_ROOT/err-ch.log" && fail "без терминала меню канала не должно показываться"
[ "$(ch "$TEST_ROOT/tty-enter" UPDATE_CHANNEL=dev)" = dev ] || fail "UPDATE_CHANNEL=dev должен выбрать dev без вопроса"
grep -q "Канал обновлений" "$TEST_ROOT/err-ch.log" && fail "при UPDATE_CHANNEL меню канала не должно показываться"
[ "$(ch "$TEST_ROOT/tty-2" UPDATE_CHANNEL=stable)" = stable ] || fail "UPDATE_CHANNEL=stable должен выбрать stable без вопроса"
[ "$(ch "$TEST_ROOT/tty-enter" UPDATE_CHANNEL=beta)" = stable ] || fail "неизвестный UPDATE_CHANNEL - stable"
grep -q "beta" "$TEST_ROOT/err-ch.log" || fail "неизвестный UPDATE_CHANNEL должен дать предупреждение"
# Сохранённый dev в speedtest2.env (незавершённая установка) - вариант по умолчанию.
mkdir -p "$TEST_ROOT/ch-saved"
printf "UPDATE_CHANNEL='dev'\n" > "$TEST_ROOT/ch-saved/speedtest2.env"
saved=$( ( set +e; INSTALL_TTY=$TEST_ROOT/tty-enter; DIR=$TEST_ROOT/ch-saved
  bootstrap_choose_channel; printf '%s\n' "$INSTALL_CHANNEL" ) 2>/dev/null )
[ "$saved" = dev ] || fail "сохранённый канал dev должен быть вариантом по умолчанию (получено: $saved)"
echo "test_install_bootstrap.sh: часть 8 (выбор канала) OK" >&2

# --- 9: канал dev - наибольший тег x.y.z из списка релизов GitHub ---
DEVTAG=1.5.0
mkdir -p "$SRV/releases/download/$DEVTAG" "$SRV/api"
cp "$SRV/releases/download/$TAG/greeting.txt" "$SRV/releases/download/$TAG/runner.sh" "$SRV/releases/download/$DEVTAG/"
sed "s/^RELEASE_TAG=.*/RELEASE_TAG=$DEVTAG/" "$SRV/releases/latest/download/manifest.txt" > "$SRV/releases/download/$DEVTAG/manifest.txt"
# Стабильный hotfix 1.4.2 вышел позже dev 1.5.0, старые теги v26.x - мимо.
printf '[{"tag_name": "1.4.2", "prerelease": false},{"tag_name":"%s","prerelease":true},{"tag_name":"v26.10.3.4"},{"tag_name":"1.3.9"}]\n' "$DEVTAG" > "$SRV/api/releases.json"
DST9=$TEST_ROOT/dst-dev
mkdir -p "$DST9"
(
  DIR=$DST9; TMPROOT=$TEST_ROOT; UPDATE_RELEASE_BASE=$BASE_URL
  UPDATE_RELEASES_API="http://127.0.0.1:$PORT/api/releases.json"
  UPDATE_STATE_DIR=$DST9/.update; INSTALLED_MANIFEST_PATH=$DST9/.update/installed-manifest.txt
  INSTALL_CHANNEL=dev
  bootstrap_selfinstall
) 2>"$TEST_ROOT/err-dev.log" || fail "канал dev: установка должна пройти: $(cat "$TEST_ROOT/err-dev.log")"
grep -qx "RELEASE_TAG=$DEVTAG" "$DST9/.update/installed-manifest.txt" || fail "канал dev должен поставить релиз $DEVTAG"
[ -f "$DST9/greeting.txt" ] || fail "канал dev: файлы не скачаны"
grep -q "Манифест $DEVTAG (dev)" "$TEST_ROOT/err-dev.log" || fail "канал dev должен быть виден в строке манифеста: $(cat "$TEST_ROOT/err-dev.log")"

# Манифест dev-тега с чужим RELEASE_TAG - отказ.
DEVTAG2=1.7.0
mkdir -p "$SRV/releases/download/$DEVTAG2"
cp "$SRV/releases/download/$DEVTAG/manifest.txt" "$SRV/releases/download/$DEVTAG2/manifest.txt"
printf '[{"tag_name":"%s"}]\n' "$DEVTAG2" > "$SRV/api/releases2.json"
DST9B=$TEST_ROOT/dst-dev-bad
mkdir -p "$DST9B"
if (
  DIR=$DST9B; TMPROOT=$TEST_ROOT; UPDATE_RELEASE_BASE=$BASE_URL
  UPDATE_RELEASES_API="http://127.0.0.1:$PORT/api/releases2.json"
  UPDATE_STATE_DIR=$DST9B/.update; INSTALLED_MANIFEST_PATH=$DST9B/.update/installed-manifest.txt
  INSTALL_CHANNEL=dev
  bootstrap_selfinstall
) 2>"$TEST_ROOT/err-dev-bad.log"; then fail "манифест с чужим RELEASE_TAG должен отклоняться"; fi
grep -q "не соответствует" "$TEST_ROOT/err-dev-bad.log" || fail "нет понятной причины отказа: $(cat "$TEST_ROOT/err-dev-bad.log")"
[ ! -f "$DST9B/greeting.txt" ] || fail "при отказе файлы не должны попадать в DIR"

# Список релизов недоступен - понятная ошибка, без тихого перехода на stable.
DST9C=$TEST_ROOT/dst-dev-noapi
mkdir -p "$DST9C"
if (
  DIR=$DST9C; TMPROOT=$TEST_ROOT; UPDATE_RELEASE_BASE=$BASE_URL
  UPDATE_RELEASES_API="http://127.0.0.1:$PORT/api/missing.json"
  UPDATE_STATE_DIR=$DST9C/.update; INSTALLED_MANIFEST_PATH=$DST9C/.update/installed-manifest.txt
  INSTALL_CHANNEL=dev INSTALL_RETRIES=1
  bootstrap_selfinstall
) 2>"$TEST_ROOT/err-dev-noapi.log"; then fail "без списка релизов канал dev не должен ставиться"; fi
grep -q "список релизов" "$TEST_ROOT/err-dev-noapi.log" || fail "нет понятной ошибки про список релизов: $(cat "$TEST_ROOT/err-dev-noapi.log")"
[ ! -f "$DST9C/greeting.txt" ] || fail "без списка релизов не должен ставиться stable"
echo "test_install_bootstrap.sh: часть 9 (канал dev) OK" >&2

echo "test_install_bootstrap.sh: OK"
