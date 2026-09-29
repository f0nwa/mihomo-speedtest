#!/bin/sh
# CGI/CLI-обёртка над update.sh для веб-раздела "Обновления" (см. README.md
# и docs/superpowers/sdd/2026-09-24-managed-updates-portion-5/task-*-brief.md,
# "Веб-флоу"). Ставится install.sh в $DIR/stats_update.sh; копия внутри
# раздаваемого каталога (cgi-bin/update) пишется сама write_stats_update()
# из speedtest2.sh - править нужно этот файл, копия перезаписывается сама.
#
# Действия: MST_UPDATE_ACTION=check|status|prepare|apply|discard (из
# API_ALIASES stats_httpd.py) или первый позиционный аргумент при прямом
# запуске (cron раз в UPDATE_CHECK_HOURS зовёт "check", "cron-sync" - только
# переписать cron-строку, служебные воркеры - "prepare-worker"/
# "apply-worker", наружу через CGI не проброшены).
set -eu

# Старые версии обновлятора передавали эти маркеры перезапускаемой панели.
# Каждый веб-запрос начинает собственную проверку через штатный bootstrap.
unset UPDATE_VERIFIED_ENGINE_DIR UPDATE_VERIFIED_PLAN_ID UPDATE_RECOVERY_ENGINE_DIR
unset UPDATE_BOOTSTRAP_DIR UPDATE_PINNED_MANIFEST

DIR=${DIR:-/opt/etc/mihomo-speedtest}
TMPROOT=${TMPROOT:-/tmp}
UPDATE_SCRIPT=${UPDATE_SCRIPT:-$DIR/update.sh}
STATS_UPDATE_RUNTIME_DIR=${STATS_UPDATE_RUNTIME_DIR:-/tmp/mihomo-speedtest-update}
LAST_CHECK_FILE=$STATS_UPDATE_RUNTIME_DIR/last-check.json
JOB_FILE=$STATS_UPDATE_RUNTIME_DIR/job.json
# job.log - путь ФИКСИРОВАННЫЙ (не $$-суффиксный, в отличие от прежних
# cpw_err/caw_err) - только так статус (cmd_status(), другой процесс) может
# читать его ПОКА фоновый воркер ещё работает: это и есть "мини консоль"
# раздела /updates (задача веб-редизайна, см. CHANGELOG). Усекается самим
# воркером в начале prepare-worker/apply-worker; наружу отдаётся как есть,
# без ротации - следующий запуск воркера снова усекает.
JOB_LOG=$STATS_UPDATE_RUNTIME_DIR/job.log
export DIR TMPROOT UPDATE_SCRIPT STATS_UPDATE_RUNTIME_DIR
export UPDATE_RELEASE_BASE=${UPDATE_RELEASE_BASE:-} UPDATE_STATE_DIR=${UPDATE_STATE_DIR:-} \
  UPDATE_TARGET_ROOT=${UPDATE_TARGET_ROOT:-} UPDATE_HTTP_TIMEOUT=${UPDATE_HTTP_TIMEOUT:-} \
  UPDATE_HTTP_CMD=${UPDATE_HTTP_CMD:-}
# UPDATE_NOTES_API_BASE/UPDATE_NOTES_HTTP_CMD - для cmd_check(): текст "что
# нового" в релизе (задача веб-редизайна). UPDATE_NOTES_HTTP_CMD - только
# для тестов (подменяет и curl, и сам API GitHub локальной фикстурой),
# аналогично UPDATE_HTTP_CMD у update.sh.
UPDATE_NOTES_API_BASE=${UPDATE_NOTES_API_BASE:-https://api.github.com/repos/f0nwa/mihomo-speedtest/releases/tags}
UPDATE_NOTES_HTTP_CMD=${UPDATE_NOTES_HTTP_CMD:-}

json_error() {
  echo "Content-Type: application/json; charset=utf-8"
  echo
  printf '{"error":"%s"}\n' "$1"
  exit 0
}

json_ok() {
  # $1 = путь к уже готовому телу ответа (без внешних фигурных скобок не
  # требуется - файл содержит целый JSON-документ).
  echo "Content-Type: application/json; charset=utf-8"
  echo
  cat "$1"
}

# Печатает JSON-строку в кавычках для ОДНОСТРОЧНОГО текста (переносы строк
# заменяются пробелом до вызова - см. capture_stderr_line() ниже). Строкой
# JSON-парсер сам не поднимается, экранируем только структурно опасные
# символы, как json_escape() в update_plan.awk.
json_escape_line() {
  printf '%s' "$1" | tr '\n\t\r' '   ' | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

# Сообщение об ошибке из stderr дочернего update.sh - одной строкой (die()
# в update.sh всегда печатает одну строку "ERROR: ...", но на всякий
# случай схлопываем весь stderr в одну строку и обрезаем длину).
capture_stderr_line() {
  # Берём ПОСЛЕДНЮЮ строку "ERROR: ..." (die() в update.sh всегда пишет
  # именно так), а не весь файл целиком - после того как job.log начал
  # получать несколько строк прогресса (мини консоль, задача веб-
  # редизайна), схлопывание всего файла в одну строку и обрезка по 400
  # символам могла бы отрезать саму ошибку, если прогресс-строк перед ней
  # накопилось много. Если строки "ERROR:" нет вовсе (не должно случаться
  # при code=1 от update.sh, но лучше отдать хоть что-то) - старое
  # поведение как запасной вариант.
  cfl_line=$(grep '^ERROR:' "$1" 2>/dev/null | tail -1)
  if [ -n "$cfl_line" ]; then
    printf '%s' "$cfl_line" | cut -c1-400
  else
    tr '\n' ' ' < "$1" | cut -c1-400
  fi
}

urldecode() {
  printf '%s' "$1" | awk '
    BEGIN { for (i = 0; i <= 255; i++) { h = sprintf("%02x", i); H = sprintf("%02X", i); byte[h] = sprintf("%c", i); byte[H] = sprintf("%c", i) } }
    { s = $0; out = ""; n = length(s); i = 1
      while (i <= n) {
        c = substr(s, i, 1)
        if (c == "+") { out = out " "; i += 1 }
        else if (c == "%" && i + 2 <= n && substr(s, i + 1, 2) in byte) { out = out byte[substr(s, i + 1, 2)]; i += 3 }
        else { out = out c; i += 1 }
      }
      printf "%s", out }'
}

parse_body_fields() {
  printf '%s' "$body" | awk -F '&' '
    { for (i = 1; i <= NF; i++) {
        if ($i == "") continue
        eq = index($i, "=")
        if (eq == 0) { name = $i; val = "" } else { name = substr($i, 1, eq - 1); val = substr($i, eq + 1) }
        if (name !~ /^[A-Za-z_][A-Za-z0-9_]*$/) continue
        gsub(/'"'"'/, "'"'"'\\'"'"''"'"'", val)
        printf "RAW_%s='"'"'%s'"'"'\n", name, val
      } }'
}

read_body() {
  # Ветка "if" вместо "[ ... ] && body=..." - под set -eu хвостовой "&&"
  # как последняя команда функции отдаёт код возврата самого теста при
  # len=0 (обычный случай, тело POST-запроса пустое), что аварийно
  # прерывает весь скрипт через set -e.
  len=${CONTENT_LENGTH:-0}
  case $len in *[!0-9]*|'') len=0 ;; esac
  body=""
  if [ "$len" -gt 0 ]; then
    body=$(dd bs=1 count="$len" 2>/dev/null)
  fi
}

write_json_atomic() {
  # $1 = временный файл с готовым содержимым, $2 = целевой путь. Локальная
  # переменная называется НЕ "tmp" - у cmd_check() (и будущих job-обработчиков)
  # своя переменная "tmp" с исходным файлом; POSIX sh не гарантирует "local",
  # одноимённая переменная здесь тихо затирала бы значение в вызывающей
  # функции и её временный файл переставал бы удаляться после публикации.
  destdir=${2%/*}
  mkdir -p "$destdir" 2>/dev/null || true
  chmod 0700 "$destdir" 2>/dev/null || true
  wja_tmp="$destdir/.$$.$(basename "$2")"
  cp "$1" "$wja_tmp" && chmod 0600 "$wja_tmp" && mv "$wja_tmp" "$2"
}

is_update_running() {
  lockpid=$(cat "$TMPROOT/mst-update-plans/.lock/pid" 2>/dev/null) || return 1
  case $lockpid in *[!0-9]*|''|0) return 1 ;; esac
  kill -0 "$lockpid" 2>/dev/null
}

valid_plan_id() {
  [ "${#1}" = 64 ] && case $1 in *[!0-9a-f]*) return 1 ;; esac
}

# Печатает содержимое JSON-файла как есть, или "null" если файла нет -
# для полей ответа cmd_status(), где last-check.json/job.json могут
# отсутствовать (ничего ещё не запускалось после перезагрузки /tmp).
read_json_or_null() {
  [ -f "$1" ] && cat "$1" || printf 'null'
}

# Локальное чтение одного поля из FORMAT_VERSION=2-манифеста (то же самое,
# что manifest_field() в update.sh) - update.sh запускается ОТДЕЛЬНЫМ
# процессом (sh "$UPDATE_SCRIPT" ...), его shell-функции сюда не
# пробрасываются, поэтому копия нужна: используется только для чтения
# installed_version при формировании notes (см. fetch_release_notes()
# ниже) и НЕ меняет схему update_plan.awk/update.sh (задача веб-редизайна -
# минимизация отпечатка изменения).
su_manifest_field() { awk -F= -v k="$2" '$1==k{print $2; exit}' "$1" 2>/dev/null; }

# Путь к установленному манифесту - та же логика по умолчанию, что и в
# update.sh (DIR/UPDATE_STATE_DIR/INSTALLED_MANIFEST_PATH), но вычисляется
# здесь заново: update.sh не экспортирует свои переменные наружу.
su_installed_manifest_path() {
  su_state_dir=${UPDATE_STATE_DIR:-$DIR/.update}
  printf '%s' "${INSTALLED_MANIFEST_PATH:-$su_state_dir/installed-manifest.txt}"
}

# Забирает текст релиза (поле "body") с GitHub API для одного тега -
# $1=тег (например "v10"). Печатает уже готовую JSON-строку В КАВЫЧКАХ
# (json.dumps дал бы то же самое, но парсер здесь наивный - экранирование
# всегда через python3, чтобы переносы строк/кавычки в тексте релиза не
# ломали итоговый JSON last-check.json). Возврат 1 при любой сетевой/
# парсинг-ошибке - вызывающий код (fetch_release_notes) должен считать
# это некритичным и не блокировать сам check.
fetch_release_note() {
  frn_tag=$1
  frn_url="$UPDATE_NOTES_API_BASE/$frn_tag"
  frn_json=$STATS_UPDATE_RUNTIME_DIR/.notes-$$.json
  mkdir -p "$STATS_UPDATE_RUNTIME_DIR" 2>/dev/null || true
  if [ -n "$UPDATE_NOTES_HTTP_CMD" ]; then
    $UPDATE_NOTES_HTTP_CMD "$frn_url" > "$frn_json" 2>/dev/null || { rm -f "$frn_json"; return 1; }
  elif command -v curl >/dev/null 2>&1; then
    curl -fsSL --max-time "${UPDATE_HTTP_TIMEOUT:-15}" -H 'Accept: application/vnd.github+json' \
      -H 'User-Agent: mihomo-speedtest' "$frn_url" > "$frn_json" 2>/dev/null || { rm -f "$frn_json"; return 1; }
  else
    return 1
  fi
  command -v python3 >/dev/null 2>&1 || { rm -f "$frn_json"; return 1; }
  python3 -c '
import json, sys
try:
    with open(sys.argv[1], "r", encoding="utf-8") as f:
        data = json.load(f)
    print(json.dumps(data.get("body") or "", ensure_ascii=False))
except Exception:
    sys.exit(1)
' "$frn_json"
  frn_rc=$?
  rm -f "$frn_json"
  return $frn_rc
}

# Собирает JSON-массив "notes" с описанием только нового релиза плана:
# с тегами-датами (v26.9.29) промежуточные теги по номеру не вычислить.
# $1=целевой RELEASE_VERSION (число), $2=его тег. Печатает "[]", если
# установлена та же или более новая версия либо текст не добыт
# (сеть/API недоступны) - check из-за заметок не блокируется.
fetch_release_notes() {
  frs_target=$1
  frs_tag=$2
  frs_installed=$(su_manifest_field "$(su_installed_manifest_path)" RELEASE_VERSION)
  case $frs_installed in *[!0-9]*|'') frs_installed=0 ;; esac
  if [ "$frs_installed" -ge "$frs_target" ] || [ -z "$frs_tag" ]; then
    printf '[]'
    return 0
  fi
  # "if", а не цепочка "&&": неудачная загрузка под set -eu не должна
  # завершать cmd_check().
  if frs_body=$(fetch_release_note "$frs_tag") && [ -n "$frs_body" ]; then
    printf '[{"version":%s,"tag":"%s","body":%s}]' "$frs_target" "$frs_tag" "$frs_body"
  else
    printf '[]'
  fi
}

cmd_check() {
  # $1 = источник ("cron" или "button") - только для диагностики в файле,
  # фронтенд источник не показывает (оба пишут в один и тот же файл).
  source=$1
  err=$STATS_UPDATE_RUNTIME_DIR/.check-err.$$
  mkdir -p "$STATS_UPDATE_RUNTIME_DIR" 2>/dev/null || true
  out=$STATS_UPDATE_RUNTIME_DIR/.check-out.$$
  if sh "$UPDATE_SCRIPT" --plan --format=json > "$out" 2>"$err"; then
    ok=true; errline=null
  else
    ok=false
    errline=$(json_escape_line "$(capture_stderr_line "$err")")
    errline="\"$errline\""
    printf '{}' > "$out"
  fi
  planval=null
  # То же самое: "if" вместо хвостового "&&", иначе при ok=false (обычный
  # путь для ошибки update.sh --plan) set -e прерывает cmd_check() раньше
  # публикации last-check.json.
  if [ "$ok" = true ]; then
    planval=$(cat "$out")
  fi
  # notes - только когда план получен успешно И объявляет release_version
  # (не блокирует check при сбое: см. fetch_release_notes()) - минорная
  # веб-фича, не часть контракта update.sh --plan.
  notesval=null
  if [ "$ok" = true ]; then
    cc_target=$(printf '%s' "$planval" | sed -n 's/.*"release_version":"\([0-9]*\)".*/\1/p')
    cc_tag=$(printf '%s' "$planval" | sed -n 's/.*"release_tag":"\([A-Za-z0-9_.-]*\)".*/\1/p')
    if [ -n "$cc_target" ]; then
      notesval=$(fetch_release_notes "$cc_target" "$cc_tag") || notesval='[]'
    fi
  fi
  tmp=$STATS_UPDATE_RUNTIME_DIR/.last-check.$$
  {
    printf '{"schema_version":1,"checked_at":"%s","source":"%s","ok":%s,"error":%s,"plan":%s,"notes":%s}\n' \
      "$(date '+%Y-%m-%d %H:%M:%S')" "$source" "$ok" "$errline" "$planval" "$notesval"
  } > "$tmp"
  write_json_atomic "$tmp" "$LAST_CHECK_FILE"
  rm -f "$out" "$err" "$tmp"
  cat "$LAST_CHECK_FILE"
  [ "$ok" = true ]
}

# Отдаёт содержимое job.log как ОДНУ JSON-строку (для поля "log" в
# cmd_status()) - переносы строк экранируются самим json_escape_line() в
# "\n" средствами printf %s не подойдёт (тот схлопывает переносы в
# пробел, это годится для однострочной сводки ошибки, но не для мини-
# консоли, где переносы строк - это и есть границы этапов). Используем
# python3 для честного JSON-экранирования всего файла целиком, включая
# управляющие символы; при отсутствии python3 или файла - "null".
read_job_log_json() {
  [ -f "$1" ] || { printf 'null'; return 0; }
  command -v python3 >/dev/null 2>&1 || { printf 'null'; return 0; }
  python3 -c '
import json, sys
try:
    with open(sys.argv[1], "r", encoding="utf-8", errors="replace") as f:
        print(json.dumps(f.read(), ensure_ascii=False))
except Exception:
    print("null")
' "$1"
}

cmd_status() {
  printf '{"last_check":%s,"job":%s,"log":%s}\n' \
    "$(read_json_or_null "$LAST_CHECK_FILE")" "$(read_json_or_null "$JOB_FILE")" "$(read_job_log_json "$JOB_LOG")"
}

# --- prepare/discard: фоновый воркер и экран подтверждения (задача 3) ---

# Публикует job.json в заданном состоянии - единственная точка записи
# job.json для действий prepare/discard (и будущего apply, задача 4).
# Позиционные параметры (без "local" - POSIX sh его не гарантирует, поэтому
# ВСЕ переменные здесь с префиксом "jw_", чтобы не затирать одноимённые
# переменные вызывающей функции, см. комментарий write_json_atomic() выше -
# та же ловушка была бы, назови мы их "err"/"out"/"plan_id" как в cmd_prepare_worker()):
#   $1 state ($2 action $3 components $4 plan_id-или-строка "null"
#   $5 plan(json-документ или "null") $6 config_diff(json-документ или "null")
#   $7 confirm_local(0/1) $8 confirm_config(0/1) $9 result(json или "null")
#   $10 error(готовая JSON-строка в кавычках или "null")
# finished_at публикуется только для конечных состояний done/error - иначе
# опрос status во время queued/running видел бы уже проставленное время
# завершения ещё не завершившейся операции.
write_job() {
  jw_state=$1; jw_action=$2; jw_comp=$3; jw_plan_id=$4; jw_plan=$5
  jw_diff=$6; jw_cl=$7; jw_cc=$8; jw_result=$9; jw_err=${10}
  mkdir -p "$STATS_UPDATE_RUNTIME_DIR" 2>/dev/null || true
  case $jw_state in
    done|error) jw_fin="\"$(date '+%Y-%m-%d %H:%M:%S')\"" ;;
    *) jw_fin=null ;;
  esac
  jw_cl_json=false; [ "$jw_cl" = 1 ] && jw_cl_json=true
  jw_cc_json=false; [ "$jw_cc" = 1 ] && jw_cc_json=true
  jw_plan_id_json=null
  [ "$jw_plan_id" = null ] || jw_plan_id_json="\"$jw_plan_id\""
  jw_comp_json=$(json_escape_line "$jw_comp")
  jw_tmp=$STATS_UPDATE_RUNTIME_DIR/.job.$$
  {
    printf '{"schema_version":1,"action":"%s","state":"%s","requested_at":"%s","finished_at":%s,' \
      "$jw_action" "$jw_state" "$(date '+%Y-%m-%d %H:%M:%S')" "$jw_fin"
    printf '"components":"%s","plan_id":%s,"plan":%s,"config_diff":%s,' \
      "$jw_comp_json" "$jw_plan_id_json" "$jw_plan" "$jw_diff"
    printf '"confirm_local":%s,"confirm_config":%s,"result":%s,"error":%s}\n' \
      "$jw_cl_json" "$jw_cc_json" "$jw_result" "$jw_err"
  } > "$jw_tmp"
  write_json_atomic "$jw_tmp" "$JOB_FILE"
  rm -f "$jw_tmp"
}

# Фоновый воркер действия "prepare". Вызывается ТОЛЬКО через self-exec
# "$0 prepare-worker <components>" из фонового ответвления CGI-обработчика
# ниже - полностью отвязан от HTTP-запроса (без этого HTTP-ответ ждал бы
# минуты: --prepare качает файлы релиза и при повышении схемы конфига
# гоняет mihomo -t, см. ruling п.3 брифа задачи 3). Публикует прогресс
# тремя шагами: "running" сразу при старте (до любого сетевого вызова),
# затем "done"/"error" по завершении - так опрос status видит реальный
# прогресс, а не мгновенный скачок queued->done. Наружу через CGI-
# диспетчер не проброшен - недокументированный служебный вызов.
cmd_prepare_worker() {
  cpw_components=$1
  mkdir -p "$STATS_UPDATE_RUNTIME_DIR" 2>/dev/null || true
  # job.log усекается ЗДЕСЬ, до первой строки write_job(running) - мини-
  # консоль на фронтенде должна увидеть пустой лог сразу при переходе в
  # running, а не хвост предыдущей операции (задача веб-редизайна).
  : > "$JOB_LOG"
  write_job running prepare "$cpw_components" null null null 0 0 null null
  cpw_out=$STATS_UPDATE_RUNTIME_DIR/.prepare-out.$$
  cpw_comp_arg=""
  [ -n "$cpw_components" ] && cpw_comp_arg="--components=$cpw_components"
  if sh "$UPDATE_SCRIPT" --prepare ${cpw_comp_arg:+"$cpw_comp_arg"} --format=json > "$cpw_out" 2>>"$JOB_LOG"; then
    cpw_plan_json=$(cat "$cpw_out")
    cpw_plan_id=$(sed -n 's/.*"plan_id":"\([0-9a-f]\{64\}\)".*/\1/p' "$cpw_out" | head -1)
    cpw_diff_json=null
    # Diff запрашивается тем же воркером сразу после успешного --prepare,
    # если план требует миграции конфига (ruling п.7 брифа задачи 3).
    # Шаблон ищет РОВНО "config_migration":{"required":true - соседнее
    # поле "confirmation_required" содержит подстроку "required":true
    # тоже, но перед ним нет открывающей кавычки+"required" отдельно -
    # уточнённый якорь на всякий случай исключает путаницу между ними.
    if [ -n "$cpw_plan_id" ] && grep -q '"config_migration":{"required":true' "$cpw_out"; then
      cpw_derr=$STATS_UPDATE_RUNTIME_DIR/.diff-err.$$
      cpw_dout=$STATS_UPDATE_RUNTIME_DIR/.diff-out.$$
      if sh "$UPDATE_SCRIPT" --show-config-diff "$cpw_plan_id" --format=json > "$cpw_dout" 2>"$cpw_derr"; then
        cpw_diff_json=$(cat "$cpw_dout")
      fi
      rm -f "$cpw_derr" "$cpw_dout"
    fi
    write_job done prepare "$cpw_components" "${cpw_plan_id:-null}" "$cpw_plan_json" "$cpw_diff_json" 0 0 null null
  else
    cpw_errline="\"$(json_escape_line "$(capture_stderr_line "$JOB_LOG")")\""
    write_job error prepare "$cpw_components" null null null 0 0 null "$cpw_errline"
  fi
  rm -f "$cpw_out"
}

# Фоновый воркер действия "apply". Вызывается ТОЛЬКО через self-exec
# "$0 apply-worker <plan_id> <confirm_local> <confirm_config>" из фонового
# ответвления CGI-обработчика ниже - полностью отвязан от HTTP-запроса
# (--apply не качает файлы релиза заново, план уже лежит подготовленным
# после --prepare, но mihomo -t/xkeen -restart/health-check при миграции
# конфига легко превышают таймаут CGI, см. ruling п.4 брифа задачи 4).
# job.json на входе уже существует в состоянии "queued" (его пишет ветка
# apply:POST перед self-exec) - воркер лишь переводит state в "running"
# точечной правкой (update_job_state(), без потери уже записанных
# plan_id/confirm_*), затем публикует финальный "done"/"error" целиком
# через write_job() - plan/config_diff от предыдущего prepare намеренно
# не переносятся дальше: применённый план фронтенду больше не нужен,
# важен только итоговый result.
cmd_apply_worker() {
  caw_plan_id=$1; caw_cl=$2; caw_cc=$3
  mkdir -p "$STATS_UPDATE_RUNTIME_DIR" 2>/dev/null || true
  # job.log усекается ЗДЕСЬ, до перевода job.json в running - та же
  # причина, что и в cmd_prepare_worker() выше: мини-консоль не должна
  # унаследовать хвост лога от предыдущего prepare этого же плана.
  : > "$JOB_LOG"
  update_job_state running
  set -- --apply "$caw_plan_id"
  [ "$caw_cl" = 1 ] && set -- "$@" --confirm-local
  [ "$caw_cc" = 1 ] && set -- "$@" --confirm-config
  set -- "$@" --format=json
  caw_out=$STATS_UPDATE_RUNTIME_DIR/.apply-out.$$
  if sh "$UPDATE_SCRIPT" "$@" > "$caw_out" 2>>"$JOB_LOG"; then
    write_job done apply "" null null null "$caw_cl" "$caw_cc" "$(cat "$caw_out")" null
  else
    caw_errline="\"$(json_escape_line "$(capture_stderr_line "$JOB_LOG")")\""
    write_job error apply "" null null null "$caw_cl" "$caw_cc" null "$caw_errline"
  fi
  rm -f "$caw_out"
}

# Точечно меняет "state" в уже существующем job.json (записан write_job()
# при постановке в очередь) - минимальная правка одним sed вместо полной
# пересборки: остальные поля (action/plan_id/confirm_*) на этот момент уже
# верны. Используется только для перехода queued->running - конечные
# состояния done/error по-прежнему публикуются целиком через write_job(),
# чтобы finished_at/result/error попадали атомарно одним mv.
update_job_state() {
  [ -f "$JOB_FILE" ] || return 0
  ujs_tmp=$STATS_UPDATE_RUNTIME_DIR/.job-state.$$
  sed 's/"state":"[a-z]*"/"state":"'"$1"'"/' "$JOB_FILE" > "$ujs_tmp"
  write_json_atomic "$ujs_tmp" "$JOB_FILE"
  rm -f "$ujs_tmp"
}

# Синхронный discard подготовленного плана (кнопка "Отмена" на экране
# подтверждения, или отказ от протухшего плана) - без фона, см. ruling
# п.6 брифа задачи 3: удаление каталога плана под блокировкой быстрое
# (rm -rf), ждать нечего, гонять его через "( ... & )" незачем. Возврат:
# 0 - удалено (или план уже отсутствовал - update.sh --discard-plan не
# требует существования плана), 1 - update.sh отказал, 2 - неверный
# plan_id (защита от вызова с непрошедшими валидацию данными).
cmd_discard() {
  cd_plan_id=$1
  valid_plan_id "$cd_plan_id" || return 2
  cd_err=$STATS_UPDATE_RUNTIME_DIR/.discard-err.$$
  if sh "$UPDATE_SCRIPT" --discard-plan "$cd_plan_id" >/dev/null 2>"$cd_err"; then
    rm -f "$cd_err"
    rm -f "$JOB_FILE"
    return 0
  fi
  rm -f "$cd_err"
  return 1
}

# --- частота фоновой проверки обновлений (cron) ---
# UPDATE_CHECK_HOURS в speedtest2.env (поле "Проверять обновления" в
# настройках веб-интерфейса) - раз во сколько часов cron зовёт "check".
# Допустимы только делители суток, чтобы интервал укладывался в "*/N"
# без перекоса на стыке суток; всё остальное (или пусто) = 12.
UPDATE_CHECK_SCRIPT=${UPDATE_CHECK_SCRIPT:-$DIR/stats_update.sh}

update_check_hours() {
  uch=$(sed -n "s/^UPDATE_CHECK_HOURS=['\"]\{0,1\}\([0-9]*\)['\"]\{0,1\}\$/\1/p" "${ENV:-$DIR/speedtest2.env}" 2>/dev/null | tail -n 1)
  case $uch in
    1|2|3|4|6|8|12|24) printf '%s' "$uch" ;;
    *) printf '12' ;;
  esac
}

update_cron_line() {
  # Минута 17 - не совпадает с минутой "0" cron-строки speedtest2.sh.
  case $1 in
    24) printf '17 5 * * * %s check' "$UPDATE_CHECK_SCRIPT" ;;
    1) printf '17 * * * * %s check' "$UPDATE_CHECK_SCRIPT" ;;
    *) printf '17 */%s * * * %s check' "$1" "$UPDATE_CHECK_SCRIPT" ;;
  esac
}

# Приводит cron-строку проверки к UPDATE_CHECK_HOURS. Без аргумента "add"
# только заменяет уже существующую строку (так её мигрирует сам cron-вызов
# "check" на роутерах со старой ежедневной строкой), с "add" - ещё и
# добавляет, если строки нет (сохранение настроек в веб-интерфейсе).
cmd_cron_sync() {
  command -v crontab >/dev/null 2>&1 || return 0
  ccs_line=$(update_cron_line "$(update_check_hours)")
  ccs_cur=$(crontab -l 2>/dev/null || true)
  if printf '%s\n' "$ccs_cur" | grep -qF "$UPDATE_CHECK_SCRIPT"; then
    [ "$(printf '%s\n' "$ccs_cur" | grep -F "$UPDATE_CHECK_SCRIPT")" = "$ccs_line" ] && return 0
  else
    [ "${1:-}" = add ] || return 0
  fi
  ccs_rest=$(printf '%s\n' "$ccs_cur" | grep -vF "$UPDATE_CHECK_SCRIPT" || true)
  { [ -n "$ccs_rest" ] && printf '%s\n' "$ccs_rest"; printf '%s\n' "$ccs_line"; } | crontab -
}

# --- точка входа: CGI (REQUEST_METHOD задан) или прямой CLI-вызов ---
action=${MST_UPDATE_ACTION:-${1:-}}
if [ -n "${REQUEST_METHOD:-}" ]; then
  [ -n "$DIR" ] || json_error "config: DIR не задан (CGI запущен не через stats_service.sh)"
  case $action:$REQUEST_METHOD in
    check:POST)
      read_body
      out=$(cmd_check button) && rc=0 || rc=1
      echo "Content-Type: application/json; charset=utf-8"; echo
      printf '%s\n' "$out"
      exit 0 ;;
    status:GET|status:HEAD)
      echo "Content-Type: application/json; charset=utf-8"; echo
      cmd_status
      exit 0 ;;
    prepare:POST)
      read_body
      eval "$(parse_body_fields)"
      pw_components=$(urldecode "${RAW_components:-}")
      # is_update_running() лишь подглядывает в блокировку самого update.sh
      # (ruling п.8 брифа задачи 3) - окно между стартом фона и первым
      # lock_plans() внутри update.sh не перекрыто, но два одновременных
      # прогона всё равно безопасны (последний write_job() в job.json
      # выигрывает, ни один из них не портит файловую систему за пределами
      # /tmp) - отдельной блокировки stats_update.sh не заводит.
      if is_update_running; then
        echo "Content-Type: application/json; charset=utf-8"; echo
        printf '{"started":false,"reason":"already_running"}\n'
        exit 0
      fi
      write_job queued prepare "$pw_components" null null null 0 0 null null
      # MST_UPDATE_ACTION/REQUEST_METHOD явно очищаются для дочернего
      # процесса - иначе они наследуются из окружения ЭТОГО CGI-вызова
      # (префиксное присваивание "VAR=val cmd" экспортирует VAR в окружение
      # cmd и далее наследуется её потомками через fork/exec) и self-exec
      # "$0 prepare-worker ..." повторно попадает в ветку CGI-диспетчера
      # (action=$MST_UPDATE_ACTION="prepare" побеждает позиционный $1) вместо
      # прямого CLI-вызова cmd_prepare_worker() - job.json навсегда
      # застревает в "queued" (воспроизведено и подтверждено эмпирически).
      ( MST_UPDATE_ACTION= REQUEST_METHOD= "$0" prepare-worker "$pw_components" </dev/null >/dev/null 2>&1 & )
      echo "Content-Type: application/json; charset=utf-8"; echo
      printf '{"started":true}\n'
      exit 0 ;;
    apply:POST)
      read_body
      eval "$(parse_body_fields)"
      ap_plan_id=$(urldecode "${RAW_plan_id:-}")
      ap_cl=0; [ "${RAW_confirm_local:-}" = "1" ] && ap_cl=1
      ap_cc=0; [ "${RAW_confirm_config:-}" = "1" ] && ap_cc=1
      if ! valid_plan_id "$ap_plan_id"; then json_error "invalid_plan_id"; fi
      # is_update_running() - то же подглядывание в блокировку update.sh,
      # что и у prepare:POST выше (ruling п.8 брифа задачи 3/4) - сценарий 24:
      # пока apply идёт, update.sh держит $TMPROOT/mst-update-plans/.lock
      # (verify_plan() внутри --apply зовёт lock_plans()), повторный
      # POST apply/prepare получает already_running, а не плодит вторую
      # фоновую операцию.
      if is_update_running; then
        echo "Content-Type: application/json; charset=utf-8"; echo
        printf '{"started":false,"reason":"already_running"}\n'
        exit 0
      fi
      write_job queued apply "" "$ap_plan_id" null null "$ap_cl" "$ap_cc" null null
      # MST_UPDATE_ACTION/REQUEST_METHOD явно очищаются для дочернего
      # процесса - та же ловушка self-exec, что у prepare:POST выше (см.
      # комментарий там): без очистки self-exec "$0 apply-worker ..."
      # снова попадает в CGI-ветку этого же диспетчера (action=
      # $MST_UPDATE_ACTION="apply" побеждает позиционный $1) и форкает
      # себя же в фон повторно - job.json навсегда застревает в "queued",
      # а в системе накапливаются висящие процессы (воспроизведено и
      # подтверждено на действии prepare в задаче 3, тот же механизм).
      ( MST_UPDATE_ACTION= REQUEST_METHOD= "$0" apply-worker "$ap_plan_id" "$ap_cl" "$ap_cc" </dev/null >/dev/null 2>&1 & )
      echo "Content-Type: application/json; charset=utf-8"; echo
      printf '{"started":true}\n'
      exit 0 ;;
    discard:POST)
      read_body
      eval "$(parse_body_fields)"
      dp_plan_id=$(urldecode "${RAW_plan_id:-}")
      if ! valid_plan_id "$dp_plan_id"; then json_error "invalid_plan_id"; fi
      if cmd_discard "$dp_plan_id"; then
        echo "Content-Type: application/json; charset=utf-8"; echo
        printf '{"ok":true}\n'
      else
        json_error "discard_failed"
      fi
      exit 0 ;;
    *) json_error "unknown_action" ;;
  esac
else
  case $action in
    check) cmd_cron_sync || true; cmd_check "${2:-button}" >/dev/null ;;
    cron-sync) cmd_cron_sync "${2:-}" ;;
    prepare-worker) cmd_prepare_worker "${2:-}" ;;
    apply-worker) cmd_apply_worker "${2:-}" "${3:-0}" "${4:-0}" ;;
    *) echo "usage: stats_update.sh check|cron-sync|status|prepare|apply|discard" >&2; exit 2 ;;
  esac
fi
