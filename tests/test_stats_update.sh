#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
SCRIPT=$ROOT/web/stats_update.sh
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/stats-update-test.XXXXXX")
trap 'rm -rf "$TEST_ROOT"' EXIT INT TERM

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_contains() { case "$2" in *"$1"*) ;; *) fail "expected: $1 (context: $3)";; esac; }

sh -n "$SCRIPT" || fail "stats_update.sh не проходит sh -n"

# --- CGI без DIR: понятная JSON-ошибка, не падение ---
OUT_NODIR=$(MST_UPDATE_ACTION=check REQUEST_METHOD=POST "$SCRIPT")
assert_contains "Content-Type: application/json" "$OUT_NODIR" "no-DIR content-type"
assert_contains '"error"' "$OUT_NODIR" "no-DIR error field"

# --- Финальный обзор (C2a): дефолт DIR (без явного переопределения)
# должен указывать на каталог ПРОЕКТА /opt/etc/mihomo-speedtest, а не на
# каталог самой Mihomo /opt/etc/mihomo - см.
# docs/superpowers/specs/2026-09-25-install-dir-separation-design.md. Не
# переопределённый UPDATE_SCRIPT ($DIR/update.sh) не существует на этой
# машине, поэтому попытка его запустить в cmd_check() естественным
# образом утекает РЕЗОЛВНУТЫЙ путь в "error" - именно это здесь и
# проверяется (до исправления там был бы /opt/etc/mihomo/update.sh).
assert_contains "/opt/etc/mihomo-speedtest/update.sh" "$OUT_NODIR" "C2a: DIR должен резолвиться в новый каталог проекта"
case "$OUT_NODIR" in
  *"/opt/etc/mihomo/update.sh"*) fail "C2a: DIR по умолчанию резолвится в старый каталог Mihomo вместо каталога проекта: $OUT_NODIR" ;;
esac

# --- фикстура: локальный httpd с манифестом (тот же приём, что test_update_cli.sh) ---
SHA_X=$(printf '%s' "1111111111111111111111111111111111111111111111111111111111111111" | cut -c1-64)
SRV=$TEST_ROOT/srv
mkdir -p "$SRV"
cat > "$SRV/manifest.txt" << EOF
FORMAT_VERSION=2
RELEASE_VERSION=9
MIN_UPDATER_VERSION=1
CONFIG_SCHEMA_VERSION=1
RELEASE_TAG=v9
COMPONENT|updater|Обновлятор
NOTE|updater|заметка
FILE|updater|update.sh|/opt/etc/mihomo-speedtest/update.sh|10|$SHA_X|0755|sh
ACTION|updater|restart-mihomo
EOF
command -v busybox >/dev/null 2>&1 || { echo "test_stats_update.sh: busybox недоступен, сетевая часть пропущена"; echo "test_stats_update.sh: OK (частично)"; exit 0; }
PORT=$((23500 + ($$ % 2000)))
busybox httpd -f -p "127.0.0.1:$PORT" -h "$SRV" >/dev/null 2>&1 &
HTTPD_PID=$!
trap 'kill "$HTTPD_PID" 2>/dev/null || true; rm -rf "$TEST_ROOT"' EXIT INT TERM
i=0; while [ $i -lt 30 ]; do curl -s -m 1 -o /dev/null "http://127.0.0.1:$PORT/manifest.txt" && break; sleep 0.2; i=$((i+1)); done

W=$TEST_ROOT/w
mkdir -p "$W"
cp "$ROOT/updater/update.sh" "$ROOT/updater/update_plan.awk" "$ROOT/updater/update_prepare.sh" "$ROOT/updater/update_transaction.sh" "$ROOT/web/stats_update.sh" "$W/"
chmod +x "$W/update.sh" "$W/stats_update.sh"

STATE=$TEST_ROOT/state
RUNDIR=$TEST_ROOT/rt
mkdir -p "$TEST_ROOT/tmp"
# UPDATE_NOTES_HTTP_CMD=false - без реального обращения к api.github.com
# (fetch_release_note() сразу получает код возврата 1 без сети/таймаута):
# в этой фикстуре нет установленного манифеста, поэтому installed_version
# считается 0 и диапазон notes был бы v1..v9 - реальные сетевые попытки
# на 9 версий сделали бы этот тест медленным и хрупким без надёжной сети.
OUT=$(DIR="$W" TMPROOT="$TEST_ROOT/tmp" UPDATE_SCRIPT="$W/update.sh" \
  UPDATE_RELEASE_BASE="http://127.0.0.1:$PORT" UPDATE_STATE_DIR="$STATE" \
  STATS_UPDATE_RUNTIME_DIR="$RUNDIR" UPDATE_NOTES_HTTP_CMD=false \
  MST_UPDATE_ACTION=check REQUEST_METHOD=POST "$W/stats_update.sh")
assert_contains '"ok":true' "$OUT" "check POST ok=true"
assert_contains '"release_version":"9"' "$OUT" "check POST содержит план"
[ -f "$RUNDIR/last-check.json" ] || fail "last-check.json не создан"
grep -q '"release_version":"9"' "$RUNDIR/last-check.json" || fail "last-check.json не содержит план"
# notes: без установленного манифеста и без доступа к API - пустой
# массив, а не ошибка/падение check (не блокирует основной результат) ---
assert_contains '"notes":[]' "$OUT" "check POST: notes - пустой массив без сети/установленной версии"

# --- notes: cmd_check добавляет текст релиза(ов) через UPDATE_NOTES_HTTP_CMD
#     (фикстура вместо реального api.github.com) - "что нового"/пропущенные
#     релизы (задача веб-редизайна) ---
NOTES_DIR=$TEST_ROOT/notes-fixtures
mkdir -p "$NOTES_DIR"
printf '{"tag_name":"v8","body":"Релиз 8: правка X"}' > "$NOTES_DIR/v8.json"
printf '{"tag_name":"v9","body":"Релиз 9: правка Y"}' > "$NOTES_DIR/v9.json"
cat > "$TEST_ROOT/fake_notes_http.sh" << 'FAKEEOF'
#!/bin/sh
tag=${1##*/}
cat "$NOTES_FIXTURE_DIR/$tag.json" 2>/dev/null || exit 1
FAKEEOF
chmod +x "$TEST_ROOT/fake_notes_http.sh"

# ровно одна пропущенная версия (installed=8, target=9) -> один элемент
# installed-manifest.txt должен пройти ту же валидацию схемы, что и
# настоящий установленный манифест (update_prepare.sh: VALIDATE_ONLY=1 на
# PLAN_AWK) - урезанный вручную файл вроде одной строки RELEASE_VERSION=N
# был бы отвергнут как "невалидный установленный манифест" раньше, чем
# дело дойдёт до notes ---
NOTES_STATE1=$TEST_ROOT/notes-state1
mkdir -p "$NOTES_STATE1"
cat > "$NOTES_STATE1/installed-manifest.txt" << EOF
FORMAT_VERSION=2
RELEASE_VERSION=8
MIN_UPDATER_VERSION=1
CONFIG_SCHEMA_VERSION=1
RELEASE_TAG=v8
COMPONENT|updater|Обновлятор
NOTE|updater|заметка
FILE|updater|update.sh|/opt/etc/mihomo-speedtest/update.sh|10|$SHA_X|0755|sh
ACTION|updater|restart-mihomo
EOF
RUNDIR_NOTES1=$TEST_ROOT/rt-notes1
OUT_NOTES1=$(NOTES_FIXTURE_DIR="$NOTES_DIR" DIR="$W" TMPROOT="$TEST_ROOT/tmp" UPDATE_SCRIPT="$W/update.sh" \
  UPDATE_RELEASE_BASE="http://127.0.0.1:$PORT" UPDATE_STATE_DIR="$NOTES_STATE1" \
  STATS_UPDATE_RUNTIME_DIR="$RUNDIR_NOTES1" UPDATE_NOTES_HTTP_CMD="$TEST_ROOT/fake_notes_http.sh" \
  MST_UPDATE_ACTION=check REQUEST_METHOD=POST "$W/stats_update.sh")
assert_contains '"notes":[{"version":9,"tag":"v9","body":"Релиз 9: правка Y"}]' "$OUT_NOTES1" "notes: одна пропущенная версия"

# уже установлена та же версия (installed=9, target=9) -> всё равно текст
# этого релиза: раздел показывает "что нового в установленной версии" ---
NOTES_STATE5=$TEST_ROOT/notes-state5
mkdir -p "$NOTES_STATE5"
sed 's/^RELEASE_VERSION=8$/RELEASE_VERSION=9/; s/^RELEASE_TAG=v8$/RELEASE_TAG=v9/' \
  "$NOTES_STATE1/installed-manifest.txt" > "$NOTES_STATE5/installed-manifest.txt"
RUNDIR_NOTES5=$TEST_ROOT/rt-notes5
OUT_NOTES5=$(NOTES_FIXTURE_DIR="$NOTES_DIR" DIR="$W" TMPROOT="$TEST_ROOT/tmp" UPDATE_SCRIPT="$W/update.sh" \
  UPDATE_RELEASE_BASE="http://127.0.0.1:$PORT" UPDATE_STATE_DIR="$NOTES_STATE5" \
  STATS_UPDATE_RUNTIME_DIR="$RUNDIR_NOTES5" UPDATE_NOTES_HTTP_CMD="$TEST_ROOT/fake_notes_http.sh" \
  MST_UPDATE_ACTION=check REQUEST_METHOD=POST "$W/stats_update.sh")
assert_contains '"notes":[{"version":9,"tag":"v9","body":"Релиз 9: правка Y"}]' "$OUT_NOTES5" "notes: установленная версия тоже с текстом релиза"

# несколько пропущенных версий (installed=7, target=9) -> оба текста, по
# порядку от старой к новой ("перечислить все изменения из предыдущих
# релизов")
NOTES_STATE2=$TEST_ROOT/notes-state2
mkdir -p "$NOTES_STATE2"
cat > "$NOTES_STATE2/installed-manifest.txt" << EOF
FORMAT_VERSION=2
RELEASE_VERSION=7
MIN_UPDATER_VERSION=1
CONFIG_SCHEMA_VERSION=1
RELEASE_TAG=v7
COMPONENT|updater|Обновлятор
NOTE|updater|заметка
FILE|updater|update.sh|/opt/etc/mihomo-speedtest/update.sh|10|$SHA_X|0755|sh
ACTION|updater|restart-mihomo
EOF
RUNDIR_NOTES2=$TEST_ROOT/rt-notes2
OUT_NOTES2=$(NOTES_FIXTURE_DIR="$NOTES_DIR" DIR="$W" TMPROOT="$TEST_ROOT/tmp" UPDATE_SCRIPT="$W/update.sh" \
  UPDATE_RELEASE_BASE="http://127.0.0.1:$PORT" UPDATE_STATE_DIR="$NOTES_STATE2" \
  STATS_UPDATE_RUNTIME_DIR="$RUNDIR_NOTES2" UPDATE_NOTES_HTTP_CMD="$TEST_ROOT/fake_notes_http.sh" \
  MST_UPDATE_ACTION=check REQUEST_METHOD=POST "$W/stats_update.sh")
# С тегами-датами промежуточные релизы не вычислить - заметки только к новому.
assert_contains '"notes":[{"version":9,"tag":"v9","body":"Релиз 9: правка Y"}]' \
  "$OUT_NOTES2" "notes: при нескольких пропущенных версиях - только новый релиз"

# один из текстов недоступен (нет фикстуры v8.json в этом каталоге) -
# он молча пропускается, check не должен из-за этого падать целиком
# (ruling: сетевая недоступность notes не блокирует сам check)
NOTES_DIR_PARTIAL=$TEST_ROOT/notes-fixtures-partial
mkdir -p "$NOTES_DIR_PARTIAL"
cp "$NOTES_DIR/v9.json" "$NOTES_DIR_PARTIAL/v9.json"
RUNDIR_NOTES3=$TEST_ROOT/rt-notes3
OUT_NOTES3=$(NOTES_FIXTURE_DIR="$NOTES_DIR_PARTIAL" DIR="$W" TMPROOT="$TEST_ROOT/tmp" UPDATE_SCRIPT="$W/update.sh" \
  UPDATE_RELEASE_BASE="http://127.0.0.1:$PORT" UPDATE_STATE_DIR="$NOTES_STATE2" \
  STATS_UPDATE_RUNTIME_DIR="$RUNDIR_NOTES3" UPDATE_NOTES_HTTP_CMD="$TEST_ROOT/fake_notes_http.sh" \
  MST_UPDATE_ACTION=check REQUEST_METHOD=POST "$W/stats_update.sh")
assert_contains '"ok":true' "$OUT_NOTES3" "notes: частичная недоступность не должна ронять check"
assert_contains '"notes":[{"version":9,"tag":"v9","body":"Релиз 9: правка Y"}]' "$OUT_NOTES3" "notes: недоступный релиз молча пропущен"

# --- регрессия: единственная (и последняя) итерация цикла в
#     fetch_release_notes() заканчивается ОШИБКОЙ fetch_release_note() -
#     ровно тот же класс ловушки set -eu ("&&" бесповоротным top-level
#     оператором), что был найден и исправлен в
#     uninstall.sh:remove_mihomo_speedtest_symlink() ранее в этой сессии;
#     здесь под "последней командой цикла/функции" риск ещё выше ---
# installed=8, целевая версия (из фикстуры SRV/manifest.txt) = 9 -
# диапазон ровно одна версия (v9), и фикстура для неё отсутствует -
# именно "последняя и единственная итерация цикла завершается ошибкой".
NOTES_STATE4=$TEST_ROOT/notes-state4
mkdir -p "$NOTES_STATE4"
cat > "$NOTES_STATE4/installed-manifest.txt" << EOF
FORMAT_VERSION=2
RELEASE_VERSION=8
MIN_UPDATER_VERSION=1
CONFIG_SCHEMA_VERSION=1
RELEASE_TAG=v8
COMPONENT|updater|Обновлятор
NOTE|updater|заметка
FILE|updater|update.sh|/opt/etc/mihomo-speedtest/update.sh|10|$SHA_X|0755|sh
ACTION|updater|restart-mihomo
EOF
NOTES_DIR_EMPTY=$TEST_ROOT/notes-fixtures-empty
mkdir -p "$NOTES_DIR_EMPTY"
RUNDIR_NOTES4=$TEST_ROOT/rt-notes4
OUT_NOTES4=$(NOTES_FIXTURE_DIR="$NOTES_DIR_EMPTY" DIR="$W" TMPROOT="$TEST_ROOT/tmp" UPDATE_SCRIPT="$W/update.sh" \
  UPDATE_RELEASE_BASE="http://127.0.0.1:$PORT" UPDATE_STATE_DIR="$NOTES_STATE4" \
  STATS_UPDATE_RUNTIME_DIR="$RUNDIR_NOTES4" UPDATE_NOTES_HTTP_CMD="$TEST_ROOT/fake_notes_http.sh" \
  MST_UPDATE_ACTION=check REQUEST_METHOD=POST "$W/stats_update.sh")
assert_contains '"ok":true' "$OUT_NOTES4" "notes: единственная версия недоступна - check не должен упасть под set -eu"
assert_contains '"notes":[]' "$OUT_NOTES4" "notes: единственная недоступная версия даёт пустой массив, а не падение"

# --- status: нет ни одного файла -> оба null ---
RUNDIR2=$TEST_ROOT/rt-empty
OUT_EMPTY=$(STATS_UPDATE_RUNTIME_DIR="$RUNDIR2" MST_UPDATE_ACTION=status REQUEST_METHOD=GET DIR="$W" "$W/stats_update.sh")
assert_contains '"last_check":null' "$OUT_EMPTY" "status: пустой last_check"
assert_contains '"job":null' "$OUT_EMPTY" "status: пустой job"

# --- status: last-check.json есть, job.json есть -> оба видны как есть ---
RUNDIR3=$TEST_ROOT/rt-filled
mkdir -p "$RUNDIR3"
printf '{"schema_version":1,"ok":true}\n' > "$RUNDIR3/last-check.json"
printf '{"schema_version":1,"state":"running"}\n' > "$RUNDIR3/job.json"
OUT_FILLED=$(STATS_UPDATE_RUNTIME_DIR="$RUNDIR3" MST_UPDATE_ACTION=status REQUEST_METHOD=GET DIR="$W" "$W/stats_update.sh")
assert_contains '"last_check":{"schema_version":1,"ok":true}' "$OUT_FILLED" "status: last_check передан как есть"
assert_contains '"job":{"schema_version":1,"state":"running"}' "$OUT_FILLED" "status: job передан как есть"

# --- status: неизвестный метод/действие по-прежнему даёт понятную ошибку ---
OUT_BAD=$(STATS_UPDATE_RUNTIME_DIR="$RUNDIR2" MST_UPDATE_ACTION=status REQUEST_METHOD=POST DIR="$W" "$W/stats_update.sh")
assert_contains '"error":"unknown_action"' "$OUT_BAD" "status: POST не поддерживается"

# --- prepare/discard: реальный фоновый --prepare (задача 3) ---
# Отдельный локальный httpd со своей файловой раскладкой релиза - pinned_base()
# в update.sh требует, чтобы UPDATE_RELEASE_BASE оканчивался буквально на
# ".../releases/latest/download" (иначе --prepare сразу падает с die), а
# сами файлы релиза берутся из соседнего ".../releases/download/<тег>/".
SRV2=$TEST_ROOT/srv2
RELDIR2=$SRV2/releases/download/v9
mkdir -p "$SRV2/releases/latest/download" "$RELDIR2"

# bootstrap_prepare() в update.sh качает движок (update.sh/update_plan.awk/
# update_prepare.sh/update_transaction.sh) как обычные файлы компонента
# "updater" из того же релиза - копии реальных, уже проверенных sh -n файлов
# из $ROOT (не заглушки), тем же приёмом, что и в реальном релизе.
for eng in update.sh update_plan.awk update_prepare.sh update_transaction.sh; do
  cp "$ROOT/updater/$eng" "$RELDIR2/$eng"
done
printf '%s' '#!/bin/sh
echo ok
' > "$RELDIR2/update.sh.rel"

gen_manifest_row() {
  # $1 component-id, $2 имя файла (относительно RELDIR2), $3 dest, $4 mode, $5 check
  f=$RELDIR2/$2
  sz=$(wc -c < "$f" | tr -d ' ')
  sum=$(sha256sum "$f" | cut -d' ' -f1)
  printf 'FILE|%s|%s|%s|%s|%s|%s|%s\n' "$1" "$2" "$3" "$sz" "$sum" "$4" "$5"
}
{
  # CONFIG_SCHEMA_VERSION=1 у релиза и нет установленного installed-manifest -
  # миграция конфига не требуется (реальная подготовка без миграции;
  # отдельный тест на show-config-diff в эту задачу не входит, см.
  # task-3-report.md - причины и объём риска описаны там).
  printf 'FORMAT_VERSION=2\nRELEASE_VERSION=9\nMIN_UPDATER_VERSION=1\nCONFIG_SCHEMA_VERSION=1\nRELEASE_TAG=v9\n'
  printf 'COMPONENT|updater|Обновлятор\nCOMPONENT|speedtest-runtime|Ядро\n'
  printf 'NOTE|updater|заметка\nNOTE|speedtest-runtime|заметка\n'
  gen_manifest_row updater update.sh /opt/etc/mihomo-speedtest/update.sh 0755 sh
  gen_manifest_row updater update_plan.awk /opt/etc/mihomo-speedtest/update_plan.awk 0644 awk
  gen_manifest_row updater update_prepare.sh /opt/etc/mihomo-speedtest/update_prepare.sh 0755 sh
  gen_manifest_row updater update_transaction.sh /opt/etc/mihomo-speedtest/update_transaction.sh 0755 sh
  gen_manifest_row speedtest-runtime update.sh.rel /opt/etc/mihomo-speedtest/prep.awk 0644 none
} > "$SRV2/releases/latest/download/manifest.txt"

PORT2=$((PORT + 1))
busybox httpd -f -p "127.0.0.1:$PORT2" -h "$SRV2" >/dev/null 2>&1 &
HTTPD_PID2=$!
trap 'kill "$HTTPD_PID" 2>/dev/null || true; kill "$HTTPD_PID2" 2>/dev/null || true; rm -rf "$TEST_ROOT"' EXIT INT TERM
i=0; while [ $i -lt 30 ]; do curl -s -m 1 -o /dev/null "http://127.0.0.1:$PORT2/releases/latest/download/manifest.txt" && break; sleep 0.2; i=$((i+1)); done

W2=$TEST_ROOT/w2
mkdir -p "$W2"
cp "$ROOT"/install.sh "$ROOT"/uninstall.sh "$ROOT"/*/*.sh "$ROOT"/*/*.awk "$W2/" 2>/dev/null || true
chmod +x "$W2"/*.sh

STATE2=$TEST_ROOT/state2
TARGET2=$TEST_ROOT/target2
mkdir -p "$TARGET2" "$TEST_ROOT/tmp2"
RUNDIR4=$TEST_ROOT/rt-prepare
OUT_PREP=$(DIR="$W2" TMPROOT="$TEST_ROOT/tmp2" UPDATE_SCRIPT="$W2/update.sh" \
  UPDATE_RELEASE_BASE="http://127.0.0.1:$PORT2/releases/latest/download" UPDATE_STATE_DIR="$STATE2" \
  UPDATE_TARGET_ROOT="$TARGET2" \
  STATS_UPDATE_RUNTIME_DIR="$RUNDIR4" \
  MST_UPDATE_ACTION=prepare REQUEST_METHOD=POST CONTENT_LENGTH=0 "$W2/stats_update.sh")
assert_contains '"started":true' "$OUT_PREP" "prepare: фон запущен"

# ждём завершения фонового воркера (job.json.state переходит в done/error)
i=0
while [ $i -lt 100 ]; do
  grep -q '"state":"done"' "$RUNDIR4/job.json" 2>/dev/null && break
  grep -q '"state":"error"' "$RUNDIR4/job.json" 2>/dev/null && fail "prepare воркер завершился ошибкой: $(cat "$RUNDIR4/job.json")"
  sleep 0.1; i=$((i+1))
done
grep -q '"state":"done"' "$RUNDIR4/job.json" || fail "prepare воркер не завершился за 10с"
grep -q '"prepared":true' "$RUNDIR4/job.json" || fail "job.json.plan.prepared не true"
PLAN_ID=$(sed -n 's/.*"plan_id":"\([0-9a-f]\{64\}\)".*/\1/p' "$RUNDIR4/job.json" | head -1)
[ -n "$PLAN_ID" ] || fail "job.json не содержит plan_id"
[ -d "$TEST_ROOT/tmp2/mst-update-plans/$PLAN_ID" ] || fail "план не сохранён в /tmp после prepare"

# --- job.log: мини консоль раздела /updates (задача веб-редизайна) - лог
#     фонового prepare виден через status.log целиком, одной JSON-строкой ---
[ -f "$RUNDIR4/job.log" ] || fail "job.log не создан после prepare"
grep -q 'Подготовка обновления: загрузка файлов релиза' "$RUNDIR4/job.log" || fail "job.log не содержит строку прогресса prepare"
OUT_STATUS_LOG=$(STATS_UPDATE_RUNTIME_DIR="$RUNDIR4" MST_UPDATE_ACTION=status REQUEST_METHOD=GET DIR="$W2" "$W2/stats_update.sh")
assert_contains '"log":"' "$OUT_STATUS_LOG" "status: поле log присутствует"
assert_contains 'Подготовка обновления' "$OUT_STATUS_LOG" "status: log содержит прогресс prepare"

# --- job.log усекается при каждом новом запуске воркера - "мусор" от
#     прошлого прогона не должен пережить следующий (иначе мини консоль
#     показала бы хвост предыдущей операции при старте новой) ---
printf 'МУСОР_ОТ_ПРОШЛОГО_ПРОГОНА\n' >> "$RUNDIR4/job.log"
OUT_PREP_AGAIN=$(DIR="$W2" TMPROOT="$TEST_ROOT/tmp2" UPDATE_SCRIPT="$W2/update.sh" \
  UPDATE_RELEASE_BASE="http://127.0.0.1:$PORT2/releases/latest/download" UPDATE_STATE_DIR="$STATE2" \
  UPDATE_TARGET_ROOT="$TARGET2" \
  STATS_UPDATE_RUNTIME_DIR="$RUNDIR4" \
  MST_UPDATE_ACTION=prepare REQUEST_METHOD=POST CONTENT_LENGTH=0 "$W2/stats_update.sh")
assert_contains '"started":true' "$OUT_PREP_AGAIN" "повторный prepare: фон запущен"
i=0
while [ $i -lt 100 ]; do
  grep -q '"state":"done"' "$RUNDIR4/job.json" 2>/dev/null && break
  grep -q '"state":"error"' "$RUNDIR4/job.json" 2>/dev/null && fail "повторный prepare завершился ошибкой: $(cat "$RUNDIR4/job.json")"
  sleep 0.1; i=$((i+1))
done
grep -q '"state":"done"' "$RUNDIR4/job.json" || fail "повторный prepare не завершился за 10с"
grep -q 'МУСОР_ОТ_ПРОШЛОГО_ПРОГОНА' "$RUNDIR4/job.log" && fail "job.log не усечён при старте нового prepare"
grep -q 'Подготовка обновления: загрузка файлов релиза' "$RUNDIR4/job.log" || fail "job.log после усечения не содержит новую строку прогресса"
PLAN_ID=$(sed -n 's/.*"plan_id":"\([0-9a-f]\{64\}\)".*/\1/p' "$RUNDIR4/job.json" | head -1)
[ -n "$PLAN_ID" ] || fail "job.json (повторный prepare) не содержит plan_id"

# --- discard: повторно можно подготовить план (проверка, что план реально удалён) ---
BODY="plan_id=$PLAN_ID"
BLEN=$(printf '%s' "$BODY" | wc -c | tr -d ' ')
OUT_DISCARD=$(printf '%s' "$BODY" | DIR="$W2" TMPROOT="$TEST_ROOT/tmp2" UPDATE_SCRIPT="$W2/update.sh" \
  STATS_UPDATE_RUNTIME_DIR="$RUNDIR4" \
  MST_UPDATE_ACTION=discard REQUEST_METHOD=POST CONTENT_LENGTH="$BLEN" "$W2/stats_update.sh")
assert_contains '"ok":true' "$OUT_DISCARD" "discard: успех"
[ -f "$RUNDIR4/job.json" ] && fail "discard не удалил job.json"
[ -d "$TEST_ROOT/tmp2/mst-update-plans/$PLAN_ID" ] && fail "discard не удалил подготовленный план из /tmp"

# --- discard: повторный discard уже удалённого (протухшего) плана -
# идемпотентен, не падает (update.sh --discard-plan делает rm -rf,
# который не требует существования каталога) ---
OUT_DISCARD2=$(printf '%s' "$BODY" | DIR="$W2" TMPROOT="$TEST_ROOT/tmp2" UPDATE_SCRIPT="$W2/update.sh" \
  STATS_UPDATE_RUNTIME_DIR="$RUNDIR4" \
  MST_UPDATE_ACTION=discard REQUEST_METHOD=POST CONTENT_LENGTH="$BLEN" "$W2/stats_update.sh")
assert_contains '"ok":true' "$OUT_DISCARD2" "discard: повторный discard протухшего плана идемпотентен"

# --- prepare: клик "Проверить сейчас" при уже занятой блокировке update.sh ---
# (is_update_running() лишь подглядывает в $TMPROOT/mst-update-plans/.lock/pid,
# см. ruling п.8 брифа задачи 3 - подделываем чужую блокировку напрямую, без
# реального прогона --prepare, чтобы не гонять сеть ради этой одной проверки)
LOCKDIR=$TEST_ROOT/tmp2/mst-update-plans/.lock
mkdir -p "$LOCKDIR"
sh -c 'sleep 5' &
FAKE_LOCK_PID=$!
printf '%s\n' "$FAKE_LOCK_PID" > "$LOCKDIR/pid"
OUT_BUSY=$(DIR="$W2" TMPROOT="$TEST_ROOT/tmp2" UPDATE_SCRIPT="$W2/update.sh" \
  STATS_UPDATE_RUNTIME_DIR="$RUNDIR4" \
  MST_UPDATE_ACTION=prepare REQUEST_METHOD=POST CONTENT_LENGTH=0 "$W2/stats_update.sh")
assert_contains '"started":false' "$OUT_BUSY" "prepare: уже выполняется"
assert_contains '"already_running"' "$OUT_BUSY" "prepare: причина already_running"
kill "$FAKE_LOCK_PID" 2>/dev/null || true
rm -rf "$LOCKDIR"

# --- discard: неверный plan_id отклоняется до вызова update.sh ---
BADBODY='plan_id=not-hex'
BADLEN=$(printf '%s' "$BADBODY" | wc -c | tr -d ' ')
OUT_BADID=$(printf '%s' "$BADBODY" | DIR="$W2" TMPROOT="$TEST_ROOT/tmp2" UPDATE_SCRIPT="$W2/update.sh" \
  STATS_UPDATE_RUNTIME_DIR="$RUNDIR4" \
  MST_UPDATE_ACTION=discard REQUEST_METHOD=POST CONTENT_LENGTH="$BADLEN" "$W2/stats_update.sh")
assert_contains '"error":"invalid_plan_id"' "$OUT_BADID" "discard: неверный plan_id"

# --- apply: успешный сценарий на неизменённом FILE (та же фикстура SRV2/W2/
#     TARGET2, что и в блоке prepare/discard выше, но со своим RUNDIR и без
#     discard - идём до конца) ---
RUNDIR5=$TEST_ROOT/rt-apply
OUT_PREP2=$(DIR="$W2" TMPROOT="$TEST_ROOT/tmp2" UPDATE_SCRIPT="$W2/update.sh" \
  UPDATE_RELEASE_BASE="http://127.0.0.1:$PORT2/releases/latest/download" UPDATE_STATE_DIR="$STATE2" \
  UPDATE_TARGET_ROOT="$TARGET2" \
  STATS_UPDATE_RUNTIME_DIR="$RUNDIR5" \
  MST_UPDATE_ACTION=prepare REQUEST_METHOD=POST CONTENT_LENGTH=0 "$W2/stats_update.sh")
assert_contains '"started":true' "$OUT_PREP2" "apply-фикстура: prepare фон запущен"

i=0
while [ $i -lt 100 ]; do
  grep -q '"state":"done"' "$RUNDIR5/job.json" 2>/dev/null && break
  grep -q '"state":"error"' "$RUNDIR5/job.json" 2>/dev/null && fail "apply-фикстура: prepare завершился ошибкой: $(cat "$RUNDIR5/job.json")"
  sleep 0.1; i=$((i+1))
done
grep -q '"state":"done"' "$RUNDIR5/job.json" || fail "apply-фикстура: prepare не завершился за 10с"
PLAN_ID2=$(sed -n 's/.*"plan_id":"\([0-9a-f]\{64\}\)".*/\1/p' "$RUNDIR5/job.json" | head -1)
[ -n "$PLAN_ID2" ] || fail "apply-фикстура: job.json не содержит plan_id"

BODY_APPLY="plan_id=$PLAN_ID2"
BLEN_APPLY=$(printf '%s' "$BODY_APPLY" | wc -c | tr -d ' ')

# --- сценарий 24: блокировка параллельных операций - пока update.sh держит
#     свою блокировку (verify_plan()/lock_plans() внутри --apply, ruling
#     п.8 брифа задачи 3/4), повторный apply отвечает already_running, а
#     не плодит вторую фоновую операцию. Подделываем чужую блокировку тем
#     же приёмом, что и для prepare выше - без гонки с реальным фоновым
#     apply (реальный apply на этой фикстуре быстрый - файлы уже в кэше
#     плана, сети нет - гоняться за его lock-окном было бы хрупко) ---
LOCKDIR5=$TEST_ROOT/tmp2/mst-update-plans/.lock
mkdir -p "$LOCKDIR5"
sh -c 'sleep 5' &
FAKE_LOCK_PID2=$!
printf '%s\n' "$FAKE_LOCK_PID2" > "$LOCKDIR5/pid"
OUT_APPLY_BUSY=$(printf '%s' "$BODY_APPLY" | DIR="$W2" TMPROOT="$TEST_ROOT/tmp2" UPDATE_SCRIPT="$W2/update.sh" \
  STATS_UPDATE_RUNTIME_DIR="$RUNDIR5" \
  MST_UPDATE_ACTION=apply REQUEST_METHOD=POST CONTENT_LENGTH="$BLEN_APPLY" "$W2/stats_update.sh")
assert_contains '"started":false' "$OUT_APPLY_BUSY" "сценарий 24: apply отклонён во время занятой блокировки"
assert_contains '"already_running"' "$OUT_APPLY_BUSY" "сценарий 24: причина already_running"
kill "$FAKE_LOCK_PID2" 2>/dev/null || true
rm -rf "$LOCKDIR5"

# --- реальный apply: блокировка свободна - запускается фоновый воркер ---
OUT_APPLY=$(printf '%s' "$BODY_APPLY" | DIR="$W2" TMPROOT="$TEST_ROOT/tmp2" UPDATE_SCRIPT="$W2/update.sh" \
  UPDATE_RELEASE_BASE="http://127.0.0.1:$PORT2/releases/latest/download" UPDATE_STATE_DIR="$STATE2" \
  UPDATE_TARGET_ROOT="$TARGET2" \
  STATS_UPDATE_RUNTIME_DIR="$RUNDIR5" \
  MST_UPDATE_ACTION=apply REQUEST_METHOD=POST CONTENT_LENGTH="$BLEN_APPLY" "$W2/stats_update.sh")
assert_contains '"started":true' "$OUT_APPLY" "apply: фон запущен"

# --- сценарий 25: воркер порождён отвязанным процессом - HTTP-подобный
#     вызов выше (OUT_APPLY) уже вернул управление (command substitution
#     дождалась завершения самого stats_update.sh, обработавшего POST), а
#     фоновый apply-worker продолжает жить и дописывает job.json уже ПОСЛЕ
#     этого - проверяем отдельным опросом ниже ---
i=0
while [ $i -lt 150 ]; do
  grep -q '"action":"apply"' "$RUNDIR5/job.json" 2>/dev/null && grep -q '"state":"done"' "$RUNDIR5/job.json" 2>/dev/null && break
  grep -q '"action":"apply"' "$RUNDIR5/job.json" 2>/dev/null && grep -q '"state":"error"' "$RUNDIR5/job.json" 2>/dev/null && fail "apply завершился ошибкой: $(cat "$RUNDIR5/job.json")"
  sleep 0.1; i=$((i+1))
done
grep -q '"state":"done"' "$RUNDIR5/job.json" || fail "apply не завершился за 15с"
grep -q '"status":"applied"' "$RUNDIR5/job.json" || fail "job.json.result не applied"
[ -f "$TARGET2/opt/etc/mihomo-speedtest/prep.awk" ] || fail "apply не опубликовал файл релиза в целевой каталог"

# --- job.log: мини консоль во время apply - те же прогресс-строки, что и
#     у prepare выше, плюс собственные строки apply (задача веб-редизайна) ---
[ -f "$RUNDIR5/job.log" ] || fail "job.log не создан после apply"
grep -q 'Проверка скачанного обновления' "$RUNDIR5/job.log" || fail "job.log (apply) не содержит строку проверки плана"
grep -q 'Применение обновления' "$RUNDIR5/job.log" || fail "job.log (apply) не содержит строку применения"
grep -q 'Обновление установлено, финальные шаги' "$RUNDIR5/job.log" || fail "job.log (apply) не содержит финальную строку прогресса"
# Построчный прогресс записи конкретного файла (пункт 1 фидбека по макету
# "Панель управления") - не только общий чекпоинт на всю транзакцию. Прогресс
# загрузки того же файла проверяется отдельно в test_update_prepare.sh - в
# job.log этой (apply) операции его уже нет: файл на этот момент только
# читается из уже подготовленного плана на диске, заново не скачивается, а
# сам job.log усекается заново в начале apply (см. stats_update.sh).
grep -q 'Запись файла: /opt/etc/mihomo-speedtest/prep.awk' "$RUNDIR5/job.log" || fail "job.log (apply) не содержит построчный прогресс записи prep.awk"
OUT_STATUS_LOG2=$(STATS_UPDATE_RUNTIME_DIR="$RUNDIR5" MST_UPDATE_ACTION=status REQUEST_METHOD=GET DIR="$W2" "$W2/stats_update.sh")
assert_contains '"log":"' "$OUT_STATUS_LOG2" "status после apply: поле log присутствует"
assert_contains 'Применение обновления' "$OUT_STATUS_LOG2" "status после apply: log содержит прогресс применения"

# --- урок ревью задачи 3 (self-exec утечка переменных окружения): если бы
#     MST_UPDATE_ACTION/REQUEST_METHOD не были явно очищены перед self-exec
#     "$0 apply-worker ...", дочерний процесс снова попал бы в CGI-ветку и
#     форкнул себя же повторно - job.json навсегда застрял бы в "queued" (уже
#     исключено ожиданием state=done выше) И в системе остались бы висящие/
#     зациклившиеся процессы apply-worker. Проверяем явно отсутствие таких
#     процессов после завершения ---
if command -v pgrep >/dev/null 2>&1; then
  sleep 0.3
  LEFTOVER_APPLY=$(pgrep -f 'stats_update\.sh apply-worker' 2>/dev/null | wc -l | tr -d ' ')
  [ "$LEFTOVER_APPLY" = 0 ] || fail "self-exec: после done остался незавершённый процесс apply-worker (${LEFTOVER_APPLY})"
fi

# --- сценарий 26: job.json пережил "перезапуск" stats_httpd.py - тут это
#     эквивалентно повторному вызову status из ОТДЕЛЬНОГО процесса ПОСЛЕ
#     того, как процесс stats_update.sh (запустивший фон) уже завершился ---
OUT_STATUS_LATE=$(STATS_UPDATE_RUNTIME_DIR="$RUNDIR5" MST_UPDATE_ACTION=status REQUEST_METHOD=GET DIR="$W2" "$W2/stats_update.sh")
assert_contains '"status":"applied"' "$OUT_STATUS_LATE" "status после отдельного процесса видит завершённый apply"

# --- Review Focus: даже успешный apply не должен ничего добавлять в
#     бейдж/список сам по себе - last-check.json НЕ создаётся/не трогается
#     действием apply, только следующим check ---
[ ! -f "$RUNDIR5/last-check.json" ] || fail "apply не должен создавать/трогать last-check.json"

# --- сценарий 27: ежедневная проверка (cmd_check) никогда не зовёт
#     --prepare/--apply/--verify-plan - статическая проверка по исходнику:
#     тело функции cmd_check() (от заголовка до закрывающей "}" в начале
#     строки) не должно содержать этих флагов ---
awk '/^cmd_check\(\) \{/{f=1} f{print} f&&/^}/{exit}' "$ROOT/web/stats_update.sh" > "$TEST_ROOT/cmd_check_body.txt"
if grep -q -- '--prepare\|--apply\|--verify-plan' "$TEST_ROOT/cmd_check_body.txt"; then
  fail "cmd_check() зовёт --prepare/--apply/--verify-plan (сценарий 27 нарушен)"
fi

# --- Review Focus: зависший job.json (state=running, без живого pid в
#     .lock/pid) - status отдаёт файл как есть, не "чинит" и не удаляет
#     запись; UI сам решает, как показать зависшее состояние (задача 6) ---
RUNDIR6=$TEST_ROOT/rt-stale
mkdir -p "$RUNDIR6"
STALE_PLAN_ID=$(printf '%064d' 1)
printf '{"schema_version":1,"action":"apply","state":"running","requested_at":"2020-01-01 00:00:00","finished_at":null,"components":"","plan_id":"%s","plan":null,"config_diff":null,"confirm_local":false,"confirm_config":false,"result":null,"error":null}\n' \
  "$STALE_PLAN_ID" > "$RUNDIR6/job.json"
STALE_BEFORE=$(cat "$RUNDIR6/job.json")
OUT_STALE=$(STATS_UPDATE_RUNTIME_DIR="$RUNDIR6" MST_UPDATE_ACTION=status REQUEST_METHOD=GET DIR="$W2" TMPROOT="$TEST_ROOT/tmp-stale-empty" "$W2/stats_update.sh")
assert_contains '"state":"running"' "$OUT_STALE" "зависший job: status отдаёт state running как есть"
[ "$(cat "$RUNDIR6/job.json")" = "$STALE_BEFORE" ] || fail "зависший job: stats_update.sh изменил чужой job.json при вызове status"

kill "$HTTPD_PID2" 2>/dev/null || true

echo "test_stats_update.sh: OK"
